-- M2.5 read-only, literal substring search. Invoker privileges retain table RLS.
create index hydrants_organization_id_idx on public.hydrants(organization_id, id);

create function public.search_hydrants(
    organization uuid, search_text text default '', type_id uuid default null,
    status_filter text default null, active_filter text default 'active',
    after_id uuid default null, page_size integer default 50
) returns setof public.hydrants
language plpgsql stable security invoker set search_path = '' as $$
declare caller_role text; needle text;
begin
    if auth.uid() is null or public.get_my_account_status() is distinct from 'ACTIVE' then
        raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    select m.role into caller_role from public.user_organizations m
        where m.user_id = auth.uid() and m.organization_id = organization;
    if caller_role is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    needle := lower(regexp_replace(coalesce(search_text, ''), '^\s+|\s+$', '', 'g'));
    if length(needle) > 200 or page_size is null or page_size not between 1 and 100
        or active_filter is null or active_filter not in ('active','inactive','all')
        or (status_filter is not null and status_filter not in ('WORKING','NOT_WORKING','NEEDS_INSPECTION','UNKNOWN')) then
        raise exception 'INVALID_HYDRANT_QUERY' using errcode = '22023';
    end if;
    -- A manipulated firefighter filter can never expose inactive rows.
    return query select h.* from public.hydrants h
    where h.organization_id = organization
        and (caller_role <> 'FIREFIGHTER' or h.active)
        and (active_filter = 'all' or h.active = (active_filter = 'active'))
        and (type_id is null or h.hydrant_type_id = type_id)
        and (status_filter is null or h.status = status_filter)
        and (after_id is null or h.id > after_id)
        and (needle = '' or strpos(lower(coalesce(h.code,'')), needle) > 0
            or strpos(lower(coalesce(h.address,'')), needle) > 0
            or strpos(lower(coalesce(h.location_description,'')), needle) > 0)
    order by h.id limit page_size;
end;
$$;
revoke all on function public.search_hydrants(uuid,text,uuid,text,text,uuid,integer) from public, anon, service_role;
grant execute on function public.search_hydrants(uuid,text,uuid,text,text,uuid,integer) to authenticated;
comment on function public.search_hydrants(uuid,text,uuid,text,text,uuid,integer) is
    'M2.5 invoker/RLS literal case-insensitive substring search, AND filters, UUID keyset pages (1..100). No writes.';
