-- M5.1: immutable completed events. Draft/UI workflows are deliberately absent.
alter table public.hydrants add constraint hydrants_id_organization_key unique (id, organization_id);
create table public.inspections (
    id uuid primary key,
    hydrant_id uuid not null,
    organization_id uuid not null references public.organizations(id) on delete restrict,
    inspector_id uuid not null references public.profiles(id) on delete restrict,
    mode text not null check (mode in ('QUICK','GUIDED','CLASSIC')),
    result text not null check (result in ('PASS','PASS_WITH_ISSUES','FAIL','NOT_INSPECTED')),
    started_at timestamptz not null check (isfinite(started_at)),
    completed_at timestamptz not null check (isfinite(completed_at) and completed_at >= started_at),
    notes text,
    pressure_bar numeric(5,2) check (pressure_bar between 0 and 999.99),
    flow_l_min numeric(8,2) check (flow_l_min between 0 and 999999.99),
    created_at timestamptz not null default clock_timestamp(),
    -- Immutable receipt: lets an offline client distinguish our status update from
    -- intervening master edits. These are not caller-supplied optimistic versions.
    hydrant_version_before bigint not null check (hydrant_version_before > 0),
    hydrant_version_after bigint not null check (
        hydrant_version_after >= hydrant_version_before and hydrant_version_after <= hydrant_version_before + 1),
    constraint inspections_hydrant_organization_fk foreign key (hydrant_id, organization_id)
        references public.hydrants(id, organization_id) on delete restrict
);
create index inspections_hydrant_history_idx on public.inspections(organization_id, hydrant_id, completed_at desc, id desc);
create index inspections_inspector_idx on public.inspections(inspector_id);
alter table public.inspections enable row level security;
revoke all on public.inspections from public, anon, authenticated, service_role;
grant select on public.inspections to authenticated;
create policy inspections_member_read on public.inspections for select to authenticated
using (
    private.is_organization_member(organization_id)
    and exists (select 1 from public.organizations o where o.id = inspections.organization_id and o.active)
    -- Hydrant RLS also hides inactive hydrants from firefighters.
    and exists (select 1 from public.hydrants h where h.id = inspections.hydrant_id
        and h.organization_id = inspections.organization_id)
);

create function private.inspection_immutable() returns trigger
language plpgsql set search_path = '' as $$
begin
    raise exception 'Completed inspections are append-only' using errcode = '42501';
end;
$$;
alter function private.inspection_immutable() owner to postgres;
revoke all on function private.inspection_immutable() from public, anon, authenticated, service_role;
create trigger inspections_no_change before update or delete on public.inspections
    for each row execute function private.inspection_immutable();
create trigger inspections_no_truncate before truncate on public.inspections
    for each statement execute function private.inspection_immutable();

create function public.complete_inspection(
    organization uuid, hydrant_id uuid, inspection_id uuid, inspection_mode text, inspection_result text,
    inspection_started_at timestamptz, inspection_completed_at timestamptz,
    inspection_notes text default null, pressure_bar numeric default null, flow_l_min numeric default null
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
    actor uuid;
    before_row public.hydrants;
    after_row public.hydrants;
    receipt public.inspections;
    mapped_status text;
begin
    -- Same organization/profile serialization and live authorization as hydrant RPCs.
    actor := private.authorize_hydrant_write(organization, array['FIREFIGHTER','MANAGER','ADMIN']::text[]);
    select * into before_row from public.hydrants h
        where h.id = hydrant_id and h.organization_id = organization for update;
    if not found or (not before_row.active and not private.has_organization_role(organization, array['MANAGER','ADMIN']::text[])) then
        raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    if inspection_id is null or inspection_mode is null or inspection_mode not in ('QUICK','GUIDED','CLASSIC')
        or inspection_result is null or inspection_result not in ('PASS','PASS_WITH_ISSUES','FAIL','NOT_INSPECTED')
        or inspection_started_at is null or inspection_completed_at is null
        or not isfinite(inspection_started_at) or not isfinite(inspection_completed_at)
        or inspection_completed_at < inspection_started_at
        or (pressure_bar is not null and (pressure_bar not between 0 and 999.99 or pressure_bar <> round(pressure_bar,2)))
        or (flow_l_min is not null and (flow_l_min not between 0 and 999999.99 or flow_l_min <> round(flow_l_min,2))) then
        raise exception 'INVALID_INSPECTION' using errcode = '22023';
    end if;
    select * into receipt from public.inspections i where i.id = inspection_id;
    if found then
        -- A UUID retry must mean exactly the same event and actor, not an overwrite
        -- or an opportunity to repeat a status change after another inspection.
        if receipt.organization_id <> organization or receipt.hydrant_id <> hydrant_id or receipt.inspector_id <> actor
            or receipt.mode <> inspection_mode or receipt.result <> inspection_result
            or receipt.started_at <> inspection_started_at or receipt.completed_at <> inspection_completed_at
            or receipt.notes is distinct from inspection_notes or receipt.pressure_bar is distinct from pressure_bar
            or receipt.flow_l_min is distinct from flow_l_min then
            raise exception 'INSPECTION_UUID_REUSED' using errcode = '23505';
        end if;
        return jsonb_build_object('inspection',to_jsonb(receipt),'hydrant',to_jsonb(before_row));
    end if;
    mapped_status := case inspection_result when 'PASS' then 'WORKING'
        when 'PASS_WITH_ISSUES' then 'NEEDS_INSPECTION' when 'FAIL' then 'NOT_WORKING' else null end;
    after_row := before_row;
    if mapped_status is not null then
        -- Use the locked current version: independent inspection events are not
        -- competing master-data edits. Existing trigger/version/audit rules still run.
        after_row := public.change_hydrant_status(organization,hydrant_id,mapped_status,before_row.version);
    end if;
    insert into public.inspections(id,hydrant_id,organization_id,inspector_id,mode,result,started_at,completed_at,
        notes,pressure_bar,flow_l_min,hydrant_version_before,hydrant_version_after)
    values (inspection_id,hydrant_id,organization,actor,inspection_mode,inspection_result,
        inspection_started_at,inspection_completed_at,inspection_notes,pressure_bar,flow_l_min,before_row.version,after_row.version)
    returning * into receipt;
    perform private.write_audit(organization,actor,'INSPECTION_COMPLETED','inspections',receipt.id,null,
        jsonb_build_object('hydrant_id',hydrant_id,'mode',inspection_mode,'result',inspection_result,
            'hydrant_version_before',before_row.version,'hydrant_version_after',after_row.version));
    -- Any insert, status or audit failure aborts the complete transaction.
    return jsonb_build_object('inspection',to_jsonb(receipt),'hydrant',to_jsonb(after_row));
end;
$$;
alter function public.complete_inspection(uuid,uuid,uuid,text,text,timestamptz,timestamptz,text,numeric,numeric) owner to postgres;
revoke all on function public.complete_inspection(uuid,uuid,uuid,text,text,timestamptz,timestamptz,text,numeric,numeric)
    from public, anon, authenticated, service_role;
grant execute on function public.complete_inspection(uuid,uuid,uuid,text,text,timestamptz,timestamptz,text,numeric,numeric) to authenticated;
