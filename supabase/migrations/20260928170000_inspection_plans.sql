-- M7.3: frozen selections only. No assignment or route model.
create table public.inspection_plans (
 id uuid primary key,
 organization_id uuid not null references public.organizations(id) on delete restrict,
 name text not null check(char_length(btrim(name)) between 1 and 120),
 status text not null check(status in ('DRAFT','PLANNED','ACTIVE','COMPLETED','CANCELLED')),
 selection_mode text not null check(selection_mode in ('MANUAL','OVERDUE','DUE_SOON_AND_OVERDUE','ALL','CURRENT_FILTER')),
 selection_snapshot jsonb not null default '{}'::jsonb,
 start_latitude numeric, start_longitude numeric, return_to_start boolean not null default false,
 created_by uuid not null references public.profiles(id) on delete restrict,
 created_at timestamptz not null default statement_timestamp(), updated_at timestamptz not null default statement_timestamp(),
 started_at timestamptz, completed_at timestamptz,
 version bigint not null default 1 check(version>0),
 last_operation_id uuid not null, last_request jsonb not null,
 unique(id,organization_id),
 check((start_latitude is null)=(start_longitude is null)),
 check(start_latitude between -90 and 90), check(start_longitude between -180 and 180)
);
create table public.inspection_plan_teams (
 plan_id uuid not null, organization_id uuid not null, team_id uuid not null,
 active boolean not null default true,
 primary key(plan_id,team_id),
 foreign key(plan_id,organization_id) references public.inspection_plans(id,organization_id) on delete restrict,
 foreign key(team_id,organization_id) references public.inspection_teams(id,organization_id) on delete restrict
);
create table public.inspection_plan_items (
 id uuid primary key default gen_random_uuid(), plan_id uuid not null, organization_id uuid not null,
 hydrant_id uuid not null references public.hydrants(id) on delete restrict,
 active boolean not null default true, created_at timestamptz not null default statement_timestamp(),
 unique(plan_id,hydrant_id),
 foreign key(plan_id,organization_id) references public.inspection_plans(id,organization_id) on delete restrict
);
create index inspection_plans_org_idx on public.inspection_plans(organization_id,status,id);
create index inspection_plan_teams_org_idx on public.inspection_plan_teams(organization_id,team_id);
create index inspection_plan_items_org_idx on public.inspection_plan_items(organization_id,hydrant_id);
alter table public.inspection_plans enable row level security;
alter table public.inspection_plan_teams enable row level security;
alter table public.inspection_plan_items enable row level security;
revoke all on public.inspection_plans,public.inspection_plan_teams,public.inspection_plan_items from public,anon,authenticated,service_role;
grant select on public.inspection_plans,public.inspection_plan_teams,public.inspection_plan_items to authenticated;
create policy plans_read on public.inspection_plans for select to authenticated using (
 private.is_organization_member(organization_id) and exists(select 1 from public.organizations o where o.id=organization_id and o.active));
create policy plan_teams_read on public.inspection_plan_teams for select to authenticated using (
 private.is_organization_member(organization_id) and exists(select 1 from public.organizations o where o.id=organization_id and o.active));
create policy plan_items_read on public.inspection_plan_items for select to authenticated using (
 private.is_organization_member(organization_id) and exists(select 1 from public.organizations o where o.id=organization_id and o.active));
create trigger plans_time before insert or update on public.inspection_plans for each row execute function public.maintain_record_timestamps();
create trigger plans_no_delete before delete on public.inspection_plans for each row execute function private.audit_immutable();
create trigger plan_teams_no_delete before delete on public.inspection_plan_teams for each row execute function private.audit_immutable();
create trigger plan_items_no_delete before delete on public.inspection_plan_items for each row execute function private.audit_immutable();
create trigger plans_no_truncate before truncate on public.inspection_plans for each statement execute function private.audit_immutable();
create trigger plan_teams_no_truncate before truncate on public.inspection_plan_teams for each statement execute function private.audit_immutable();
create trigger plan_items_no_truncate before truncate on public.inspection_plan_items for each statement execute function private.audit_immutable();

create function public.read_inspection_plans(organization uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_organization_member(organization) or not exists(select 1 from public.organizations where id=organization and active) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 return jsonb_build_object(
  'plans',coalesce((select jsonb_agg(to_jsonb(p)-'last_request' order by p.created_at desc,p.id) from public.inspection_plans p where p.organization_id=organization),'[]'::jsonb),
  'teams',coalesce((select jsonb_agg(to_jsonb(t) order by t.plan_id,t.team_id) from public.inspection_plan_teams t where t.organization_id=organization),'[]'::jsonb),
  'items',coalesce((select jsonb_agg(to_jsonb(i) order by i.plan_id,i.hydrant_id) from public.inspection_plan_items i where i.organization_id=organization),'[]'::jsonb));
end;
$$;
create function public.save_inspection_plan(organization uuid, request jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare actor uuid; p public.inspection_plans; plan uuid:=(request->>'id')::uuid;
 operation uuid:=(request->>'operation_id')::uuid; expected bigint:=(request->>'version')::bigint;
 desired text:=request->>'status'; mode text:=request->>'selection_mode'; title text:=btrim(request->>'name');
 teams uuid[]; hydrants uuid[]; item uuid; before_data jsonb; lat numeric; lon numeric;
begin
 actor:=private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']::text[]);
 if plan is null or operation is null or expected is null or expected<0 or desired is null or desired not in ('DRAFT','PLANNED','CANCELLED')
  or mode is null or mode not in ('MANUAL','OVERDUE','DUE_SOON_AND_OVERDUE','ALL','CURRENT_FILTER')
  or title is null or char_length(title) not between 1 and 120
  or jsonb_typeof(request->'teams') is distinct from 'array' or jsonb_typeof(request->'hydrants') is distinct from 'array'
  or jsonb_typeof(request->'return_to_start') is distinct from 'boolean' then
  raise exception 'INVALID_PLAN' using errcode='22023';
 end if;
 select * into p from public.inspection_plans where id=plan and organization_id=organization for update;
 if found then
  if p.last_operation_id=operation then
   if p.last_request is distinct from request then raise exception 'OPERATION_REUSED' using errcode='22023'; end if;
   return public.read_inspection_plans(organization);
  end if;
  if p.status not in ('DRAFT','PLANNED') then raise exception 'PLAN_NOT_EDITABLE' using errcode='22023'; end if;
  if p.version<>expected then raise exception 'PLAN_VERSION_CONFLICT' using errcode='P0001'; end if;
  before_data:=to_jsonb(p);
 elsif expected<>0 or desired='CANCELLED' then
  raise exception 'PLAN_VERSION_CONFLICT' using errcode='P0001';
 end if;
 select coalesce(array_agg(value::uuid),'{}'::uuid[]) into teams from jsonb_array_elements_text(request->'teams');
 select coalesce(array_agg(value::uuid),'{}'::uuid[]) into hydrants from jsonb_array_elements_text(request->'hydrants');
 if exists(select 1 from unnest(teams) u group by u having count(*)>1 or u is null)
  or exists(select 1 from unnest(hydrants) u group by u having count(*)>1 or u is null) then
  raise exception 'DUPLICATE_SELECTION' using errcode='22023';
 end if;
 lat:=(request->>'start_latitude')::numeric; lon:=(request->>'start_longitude')::numeric;
 -- Existing abandoned selections can be cancelled even after eligibility changes.
 if desired<>'CANCELLED' then
  if desired='PLANNED' and (cardinality(teams)=0 or cardinality(hydrants)=0) then
   raise exception 'TEAM_AND_HYDRANT_REQUIRED' using errcode='22023';
  end if;
  foreach item in array teams loop
   perform 1 from public.inspection_teams t where t.id=item and t.organization_id=organization and (desired<>'PLANNED' or t.active) for share;
   if not found then raise exception 'INVALID_PLAN_TEAM' using errcode='22023'; end if;
  end loop;
  foreach item in array hydrants loop
   perform 1 from public.hydrants h where h.id=item and h.organization_id=organization
    and (mode='MANUAL' or h.active) for share;
   if not found then raise exception 'INVALID_PLAN_HYDRANT' using errcode='22023'; end if;
  end loop;
 end if;
 if before_data is null then
  insert into public.inspection_plans(id,organization_id,name,status,selection_mode,selection_snapshot,start_latitude,start_longitude,return_to_start,created_by,last_operation_id,last_request)
  values(plan,organization,title,desired,mode,coalesce(request->'selection_snapshot','{}'::jsonb),lat,lon,(request->>'return_to_start')::boolean,actor,operation,request);
 else
  update public.inspection_plans set
   name=case when desired='CANCELLED' then p.name else title end,status=desired,
   selection_mode=case when desired='CANCELLED' then p.selection_mode else mode end,
   selection_snapshot=case when desired='CANCELLED' then p.selection_snapshot else coalesce(request->'selection_snapshot','{}'::jsonb) end,
   start_latitude=case when desired='CANCELLED' then p.start_latitude else lat end,
   start_longitude=case when desired='CANCELLED' then p.start_longitude else lon end,
   return_to_start=case when desired='CANCELLED' then p.return_to_start else (request->>'return_to_start')::boolean end,
   version=p.version+1,last_operation_id=operation,last_request=request where id=plan;
 end if;
 if desired<>'CANCELLED' then
  update public.inspection_plan_teams set active=false where plan_id=plan and active and not(team_id=any(teams));
  insert into public.inspection_plan_teams(plan_id,organization_id,team_id) select plan,organization,u from unnest(teams) u
   on conflict(plan_id,team_id) do update set active=true;
  update public.inspection_plan_items set active=false where plan_id=plan and active and not(hydrant_id=any(hydrants));
  insert into public.inspection_plan_items(plan_id,organization_id,hydrant_id) select plan,organization,u from unnest(hydrants) u
   on conflict(plan_id,hydrant_id) do update set active=true;
 end if;
 perform private.write_audit(organization,actor,'PLAN_SAVED','inspection_plans',plan,before_data,
  (select to_jsonb(t)||jsonb_build_object('actor_source','authenticated','database_principal',session_user) from public.inspection_plans t where id=plan));
 return public.read_inspection_plans(organization);
end;
$$;
alter function public.read_inspection_plans(uuid) owner to postgres;
alter function public.save_inspection_plan(uuid,jsonb) owner to postgres;
revoke all on function public.read_inspection_plans(uuid),public.save_inspection_plan(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.read_inspection_plans(uuid),public.save_inspection_plan(uuid,jsonb) to authenticated;

