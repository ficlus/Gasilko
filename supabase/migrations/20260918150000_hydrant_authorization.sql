-- M2.2: scoped reads and narrow, audited mutations. No direct client writes.
grant select on public.hydrants, public.hydrant_types to authenticated;
create policy hydrants_member_read on public.hydrants for select to authenticated
using (
    (active and private.is_organization_member(organization_id))
    or private.has_organization_role(organization_id, array['MANAGER','ADMIN']::text[])
);

create function private.has_any_organization_membership() returns boolean
language sql stable security definer set search_path = '' as $$
    select private.is_active_user() and exists (
        select 1 from public.user_organizations where user_id = (select auth.uid())
    );
$$;
create policy hydrant_types_member_read on public.hydrant_types for select to authenticated
using (
    (active and ((organization_id is null and (select private.has_any_organization_membership()))
        or private.is_organization_member(organization_id)))
    or private.has_organization_role(organization_id, array['ADMIN']::text[])
);

-- Uses the same serialization row as membership mutations. Recheck authority
-- after waiting; stale stronger-isolation snapshots fail on the actual lock write.
create function private.authorize_hydrant_write(organization uuid, allowed_roles text[])
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare actor uuid := auth.uid();
begin
    if actor is null or organization is null then
        raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    perform private.lock_organization(organization);
    perform 1 from public.profiles where id = actor and account_status = 'ACTIVE' for share;
    if not found then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    if not exists (select 1 from public.user_organizations
        where user_id = actor and organization_id = organization and role = any(allowed_roles)) then
        raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    perform 1 from public.organizations where id = organization and active for share;
    if not found then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return actor;
end;
$$;

create function private.lock_hydrant_change(organization uuid, hydrant_id uuid, allowed_roles text[], expected_version bigint)
returns public.hydrants language plpgsql volatile security definer set search_path = '' as $$
declare h public.hydrants;
begin
    perform private.authorize_hydrant_write(organization, allowed_roles);
    select * into h from public.hydrants where id = hydrant_id and organization_id = organization for update;
    if not found then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    if not h.active and not private.has_organization_role(organization, array['MANAGER','ADMIN']::text[]) then
        raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    if expected_version is null or expected_version < 1 then
        raise exception 'EXPECTED_VERSION_REQUIRED' using errcode = '22023';
    end if;
    if expected_version <> h.version then
        raise exception 'HYDRANT_VERSION_CONFLICT' using errcode = 'P0001';
    end if;
    return h;
end;
$$;

-- A patch can touch only this explicit domain allowlist. Unknown keys fail,
-- including actors, ownership, UUID, active, code, timestamps and version.
create function private.validate_hydrant_fields(fields jsonb, creating boolean) returns void
language plpgsql set search_path = '' as $$
declare k text; v jsonb;
begin
    if fields is null or jsonb_typeof(fields) <> 'object' then
        raise exception 'INVALID_HYDRANT_FIELDS' using errcode = '22023';
    end if;
    for k, v in select * from jsonb_each(fields) loop
        if k not in ('hydrant_type_id','latitude','longitude','address','location_description','status','notes','inspection_interval_months')
            or (creating and k = 'hydrant_type_id') then
            raise exception 'INVALID_HYDRANT_FIELDS' using errcode = '22023';
        end if;
        if k in ('latitude','longitude','inspection_interval_months') then
            if jsonb_typeof(v) not in ('number','null') then
                raise exception 'INVALID_HYDRANT_FIELDS' using errcode = '22023';
            end if;
        elsif jsonb_typeof(v) not in ('string','null') then
            raise exception 'INVALID_HYDRANT_FIELDS' using errcode = '22023';
        end if;
    end loop;
end;
$$;

-- Audit excludes free-form text and location values. Changed field names record
-- master edits without copying user-entered notes/addresses into security logs.
create function private.hydrant_audit_data(h public.hydrants) returns jsonb
language sql immutable set search_path = '' as $$
    select jsonb_build_object('code',h.code,'version',h.version,'status',h.status,
        'active',h.active,'hydrant_type_id',h.hydrant_type_id,
        'inspection_interval_months',h.inspection_interval_months);
$$;
create function private.audit_hydrant_change(before_row public.hydrants, after_row public.hydrants, event text)
returns void language plpgsql security definer set search_path = '' as $$
declare changed jsonb;
begin
    if before_row.id is not null and before_row.version = after_row.version then return; end if;
    select coalesce(jsonb_agg(k order by k),'[]'::jsonb) into changed
    from jsonb_object_keys(to_jsonb(after_row) - array['updated_at','updated_by','version']) k
    where (to_jsonb(before_row)->k) is distinct from (to_jsonb(after_row)->k);
    perform private.write_audit(after_row.organization_id, auth.uid(), event, 'hydrants', after_row.id,
        case when before_row.id is null then null else private.hydrant_audit_data(before_row) end,
        private.hydrant_audit_data(after_row) || jsonb_build_object('changed_fields',changed));
end;
$$;

create function public.create_hydrant(organization uuid, hydrant_type uuid, fields jsonb default '{}'::jsonb,
    hydrant_id uuid default gen_random_uuid())
returns public.hydrants language plpgsql volatile security definer set search_path = '' as $$
declare actor uuid; h public.hydrants;
begin
    actor := private.authorize_hydrant_write(organization, array['FIREFIGHTER','MANAGER','ADMIN']::text[]);
    perform private.validate_hydrant_fields(fields, true);
    select * into h from jsonb_populate_record(null::public.hydrants, fields);
    insert into public.hydrants(id, organization_id, hydrant_type_id, latitude, longitude,
        address, location_description, status, notes, inspection_interval_months, created_by, updated_by)
    values (hydrant_id, organization, hydrant_type, h.latitude, h.longitude, h.address,
        h.location_description, case when fields ? 'status' then h.status else 'UNKNOWN' end,
        h.notes, h.inspection_interval_months, actor, actor);
    perform private.assign_hydrant_code(organization, hydrant_id, actor);
    select * into h from public.hydrants where id = hydrant_id;
    perform private.audit_hydrant_change(null::public.hydrants, h, 'HYDRANT_CREATED');
    return h;
end;
$$;

create function public.change_hydrant_status(organization uuid, hydrant_id uuid, new_status text, expected_version bigint)
returns public.hydrants language plpgsql volatile security definer set search_path = '' as $$
declare before_row public.hydrants; after_row public.hydrants;
begin
    before_row := private.lock_hydrant_change(organization, hydrant_id,
        array['FIREFIGHTER','MANAGER','ADMIN']::text[], expected_version);
    update public.hydrants set status = new_status, updated_by = auth.uid()
        where id = hydrant_id returning * into after_row;
    perform private.audit_hydrant_change(before_row, after_row, 'HYDRANT_STATUS_CHANGED');
    return after_row;
end;
$$;

create function public.update_hydrant(organization uuid, hydrant_id uuid, changes jsonb, expected_version bigint)
returns public.hydrants language plpgsql volatile security definer set search_path = '' as $$
declare before_row public.hydrants; patched public.hydrants; after_row public.hydrants;
begin
    before_row := private.lock_hydrant_change(organization, hydrant_id, array['MANAGER','ADMIN']::text[], expected_version);
    perform private.validate_hydrant_fields(changes, false);
    select * into patched from jsonb_populate_record(before_row, changes);
    update public.hydrants set hydrant_type_id = patched.hydrant_type_id, latitude = patched.latitude,
        longitude = patched.longitude, address = patched.address, location_description = patched.location_description,
        status = patched.status, notes = patched.notes, inspection_interval_months = patched.inspection_interval_months,
        updated_by = auth.uid() where id = hydrant_id returning * into after_row;
    -- A combined master/status edit emits both semantic events, one row version.
    if (to_jsonb(before_row) - array['status','version','updated_at','updated_by'])
        is distinct from (to_jsonb(after_row) - array['status','version','updated_at','updated_by']) then
        perform private.audit_hydrant_change(before_row, after_row, 'HYDRANT_UPDATED');
    end if;
    if before_row.status is distinct from after_row.status then
        perform private.audit_hydrant_change(before_row, after_row, 'HYDRANT_STATUS_CHANGED');
    end if;
    return after_row;
end;
$$;

create function public.set_hydrant_active(organization uuid, hydrant_id uuid, is_active boolean, expected_version bigint)
returns public.hydrants language plpgsql volatile security definer set search_path = '' as $$
declare before_row public.hydrants; after_row public.hydrants;
begin
    before_row := private.lock_hydrant_change(organization, hydrant_id, array['MANAGER','ADMIN']::text[], expected_version);
    update public.hydrants set active = is_active, updated_by = auth.uid()
        where id = hydrant_id returning * into after_row;
    perform private.audit_hydrant_change(before_row, after_row,
        case when is_active then 'HYDRANT_REACTIVATED' else 'HYDRANT_DEACTIVATED' end);
    return after_row;
end;
$$;

create function public.create_hydrant_type(organization uuid, type_code text, type_name text,
    type_id uuid default gen_random_uuid())
returns public.hydrant_types language plpgsql volatile security definer set search_path = '' as $$
declare actor uuid; t public.hydrant_types;
begin
    actor := private.authorize_hydrant_write(organization, array['ADMIN']::text[]);
    insert into public.hydrant_types(id,organization_id,code,name) values(type_id,organization,type_code,type_name)
        returning * into t;
    perform private.write_audit(organization, actor, 'HYDRANT_TYPE_CREATED', 'hydrant_types', t.id,
        null, jsonb_build_object('code',t.code,'active',t.active));
    return t;
end;
$$;

create function public.update_hydrant_type(organization uuid, type_id uuid, changes jsonb)
returns public.hydrant_types language plpgsql volatile security definer set search_path = '' as $$
declare actor uuid; before_row public.hydrant_types; patched public.hydrant_types;
    after_row public.hydrant_types; k text; v jsonb; event text;
begin
    actor := private.authorize_hydrant_write(organization, array['ADMIN']::text[]);
    select * into before_row from public.hydrant_types where id = type_id and organization_id = organization for update;
    if not found then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    if changes is null or jsonb_typeof(changes) <> 'object' then
        raise exception 'INVALID_TYPE_FIELDS' using errcode = '22023';
    end if;
    for k,v in select * from jsonb_each(changes) loop
        if k not in ('code','name','active') or (k = 'active' and jsonb_typeof(v) <> 'boolean')
            or (k in ('code','name') and jsonb_typeof(v) <> 'string') then
            raise exception 'INVALID_TYPE_FIELDS' using errcode = '22023';
        end if;
    end loop;
    select * into patched from jsonb_populate_record(before_row, changes);
    if (patched.code,patched.name,patched.active) is not distinct from (before_row.code,before_row.name,before_row.active) then
        return before_row;
    end if;
    update public.hydrant_types set code = patched.code, name = patched.name, active = patched.active
        where id = type_id returning * into after_row;
    event := case when before_row.active and not after_row.active then 'HYDRANT_TYPE_DEACTIVATED'
        else 'HYDRANT_TYPE_UPDATED' end;
    perform private.write_audit(organization, actor, event, 'hydrant_types', type_id,
        jsonb_build_object('code',before_row.code,'active',before_row.active),
        jsonb_build_object('code',after_row.code,'active',after_row.active,'name_changed',before_row.name <> after_row.name));
    return after_row;
end;
$$;

-- Explicit ACLs, including service_role: BYPASSRLS does not confer table grants
-- or EXECUTE. No privileged client/server-key shortcut is added.
alter function private.has_any_organization_membership() owner to postgres;
alter function private.authorize_hydrant_write(uuid,text[]) owner to postgres;
alter function private.lock_hydrant_change(uuid,uuid,text[],bigint) owner to postgres;
alter function private.validate_hydrant_fields(jsonb,boolean) owner to postgres;
alter function private.hydrant_audit_data(public.hydrants) owner to postgres;
alter function private.audit_hydrant_change(public.hydrants,public.hydrants,text) owner to postgres;
revoke all on function private.has_any_organization_membership(), private.authorize_hydrant_write(uuid,text[]),
    private.lock_hydrant_change(uuid,uuid,text[],bigint), private.validate_hydrant_fields(jsonb,boolean),
    private.hydrant_audit_data(public.hydrants), private.audit_hydrant_change(public.hydrants,public.hydrants,text)
    from public, anon, authenticated, service_role;
grant execute on function private.has_any_organization_membership() to authenticated;
alter function public.create_hydrant(uuid,uuid,jsonb,uuid) owner to postgres;
alter function public.change_hydrant_status(uuid,uuid,text,bigint) owner to postgres;
alter function public.update_hydrant(uuid,uuid,jsonb,bigint) owner to postgres;
alter function public.set_hydrant_active(uuid,uuid,boolean,bigint) owner to postgres;
alter function public.create_hydrant_type(uuid,text,text,uuid) owner to postgres;
alter function public.update_hydrant_type(uuid,uuid,jsonb) owner to postgres;
revoke all on function public.create_hydrant(uuid,uuid,jsonb,uuid), public.change_hydrant_status(uuid,uuid,text,bigint),
    public.update_hydrant(uuid,uuid,jsonb,bigint), public.set_hydrant_active(uuid,uuid,boolean,bigint),
    public.create_hydrant_type(uuid,text,text,uuid), public.update_hydrant_type(uuid,uuid,jsonb)
    from public, anon, authenticated, service_role;
grant execute on function public.create_hydrant(uuid,uuid,jsonb,uuid), public.change_hydrant_status(uuid,uuid,text,bigint),
    public.update_hydrant(uuid,uuid,jsonb,bigint), public.set_hydrant_active(uuid,uuid,boolean,bigint),
    public.create_hydrant_type(uuid,text,text,uuid), public.update_hydrant_type(uuid,uuid,jsonb) to authenticated;
