-- M1.5: trusted review, serialized membership changes and append-only audit.
create table public.audit_log (
    id uuid primary key default gen_random_uuid(),
    organization_id uuid,
    user_id uuid not null,
    action text not null,
    entity_type text not null,
    entity_id uuid,
    old_data jsonb,
    new_data jsonb,
    created_at timestamptz not null default clock_timestamp()
);
create index audit_organization_time_idx on public.audit_log(organization_id, created_at desc, id);
alter table public.audit_log enable row level security;
revoke all on public.audit_log from public, anon, authenticated, service_role;
grant select on public.audit_log to authenticated, service_role;
create policy audit_admin_read on public.audit_log for select to authenticated
    using (private.has_organization_role(organization_id, array['ADMIN']::text[]));

create function private.audit_immutable() returns trigger
language plpgsql set search_path = '' as $$
begin
    raise exception 'Audit history is append-only' using errcode = '42501';
end;
$$;
revoke all on function private.audit_immutable() from public, anon, authenticated, service_role;
create trigger audit_no_change before update or delete on public.audit_log
    for each row execute function private.audit_immutable();
create trigger audit_no_truncate before truncate on public.audit_log
    for each statement execute function private.audit_immutable();

-- An actual write, rather than an advisory lock alone, also rejects stale
-- REPEATABLE READ snapshots. All membership writes use this same serialization row.
create table private.organization_security_locks (organization_id uuid primary key, revision bigint not null default 0);
revoke all on private.organization_security_locks from public, anon, authenticated, service_role;
create function private.lock_organization(org uuid) returns void
language sql volatile security definer set search_path = '' as $$
    insert into private.organization_security_locks(organization_id) values (org)
    on conflict (organization_id) do update set revision = private.organization_security_locks.revision + 1;
$$;
revoke all on function private.lock_organization(uuid) from public, anon, authenticated, service_role;

create function private.write_audit(org uuid, actor uuid, event text, kind text, entity uuid, before_data jsonb, after_data jsonb)
returns void language sql security definer set search_path = '' as $$
    insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,old_data,new_data)
    values (org,actor,event,kind,entity,before_data,after_data);
$$;
revoke all on function private.write_audit(uuid,uuid,text,text,uuid,jsonb,jsonb) from public, anon, authenticated, service_role;

create function private.guard_membership() returns trigger
language plpgsql volatile security definer set search_path = '' as $$
declare
    org uuid := coalesce(new.organization_id,old.organization_id);
    caller_role text;
    actor uuid := auth.uid();
begin
    if tg_op = 'UPDATE' and (new.user_id <> old.user_id or new.organization_id <> old.organization_id) then
        raise exception 'Membership identity is immutable' using errcode = '23514';
    end if;
    perform private.lock_organization(org);
    -- Recheck live authority after serialization: RLS's statement snapshot alone
    -- must not authorize a reviewer concurrently removed/demoted by another writer.
    if current_setting('role',true) in ('authenticated','anon') then
        perform 1 from public.profiles where id=actor and account_status='ACTIVE' for share;
        if not found then raise exception 'Not authorized' using errcode='42501'; end if;
        select role into caller_role from public.user_organizations where user_id=actor and organization_id=org;
        if caller_role is distinct from 'ADMIN' and not (
            caller_role='MANAGER'
            and (tg_op='INSERT' or old.role='FIREFIGHTER')
            and (tg_op='DELETE' or new.role='FIREFIGHTER')
        ) then raise exception 'Not authorized' using errcode='42501'; end if;
        if caller_role is null then raise exception 'Not authorized' using errcode='42501'; end if;
    end if;
    if tg_op <> 'INSERT' and old.role='ADMIN' and (tg_op='DELETE' or new.role<>'ADMIN')
       and exists(select 1 from public.organizations where id=org and active)
       and not exists(select 1 from public.user_organizations where organization_id=org and role='ADMIN' and user_id<>old.user_id) then
        raise exception 'Last ADMIN cannot be removed or demoted' using errcode='23514';
    end if;
    if tg_op='DELETE' then return old; end if;
    return new;
end;
$$;
revoke all on function private.guard_membership() from public, anon, authenticated, service_role;
create trigger memberships_guard before insert or update or delete on public.user_organizations
    for each row execute function private.guard_membership();

create function private.audit_membership() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
    actor uuid;
    source text;
    event text;
    before_data jsonb;
    after_data jsonb;
begin
    if tg_op='UPDATE' and old.role=new.role then return new; end if;
    if current_setting('role',true)='authenticated' then actor:=auth.uid(); source:='authenticated';
    else
        actor:=coalesce(nullif(current_setting('gasilko.audit_actor',true),'')::uuid,'00000000-0000-0000-0000-000000000000'::uuid);
        source:='trusted_database';
    end if;
    event:=case tg_op when 'INSERT' then 'MEMBERSHIP_CREATED' when 'UPDATE' then 'MEMBERSHIP_ROLE_CHANGED' else 'MEMBERSHIP_REMOVED' end;
    if tg_op<>'INSERT' then before_data:=jsonb_build_object('user_id',old.user_id,'role',old.role); end if;
    after_data:=jsonb_build_object('actor_source',source,'database_principal',session_user);
    if tg_op<>'DELETE' then after_data:=after_data||jsonb_build_object('user_id',new.user_id,'role',new.role); end if;
    perform private.write_audit(coalesce(new.organization_id,old.organization_id),actor,event,'user_organizations',coalesce(new.user_id,old.user_id),before_data,after_data);
    return coalesce(new,old);
end;
$$;
revoke all on function private.audit_membership() from public, anon, authenticated, service_role;
create trigger memberships_audit after insert or update or delete on public.user_organizations
    for each row execute function private.audit_membership();

create function public.list_reviewable_access_requests(after_id uuid default null)
returns table(id uuid, requester_name text, organization_id uuid, organization_name text, requested_role text, requested_at timestamptz, status text)
language sql stable security definer set search_path = '' as $$
    select r.id,p.display_name,r.organization_id,o.name,r.requested_role,r.requested_at,r.status
    from public.organization_access_requests r join public.profiles p on p.id=r.user_id
    join public.organizations o on o.id=r.organization_id
    where r.status='PENDING' and o.active and (after_id is null or r.id>after_id)
      and (private.has_organization_role(r.organization_id,array['ADMIN']::text[])
        or (r.requested_role='FIREFIGHTER' and private.has_organization_role(r.organization_id,array['MANAGER']::text[])))
    order by r.id limit 50;
$$;
revoke all on function public.list_reviewable_access_requests(uuid) from public, anon, authenticated;
grant execute on function public.list_reviewable_access_requests(uuid) to authenticated;

create function public.review_organization_access(request_id uuid, decision text)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare
    r public.organization_access_requests%rowtype;
    actor uuid:=auth.uid();
    target_state text;
begin
    if actor is null or decision is null or decision not in ('APPROVED','REJECTED') then return 'NOT_AUTHORIZED'; end if;
    select * into r from public.organization_access_requests where id=request_id;
    if not found then return 'NOT_AUTHORIZED'; end if;
    -- Applicant first, matching M1.4 creation. Then organization and request.
    select account_status into target_state from public.profiles where id=r.user_id for update;
    perform private.lock_organization(r.organization_id);
    perform 1 from public.profiles where id=actor and account_status='ACTIVE' for share;
    if not found then return 'NOT_AUTHORIZED'; end if;
    if not (private.has_organization_role(r.organization_id,array['ADMIN']::text[])
       or (r.requested_role='FIREFIGHTER' and private.has_organization_role(r.organization_id,array['MANAGER']::text[]))) then
        return 'NOT_AUTHORIZED';
    end if;
    select * into r from public.organization_access_requests where id=request_id for update;
    if r.status<>'PENDING' then return 'ALREADY_REVIEWED'; end if;
    perform 1 from public.organizations where id=r.organization_id and active for share;
    if not found then return 'UNAVAILABLE'; end if;
    if r.requested_role not in ('FIREFIGHTER','MANAGER') then return 'NOT_AUTHORIZED'; end if;
    if decision='APPROVED' then
        if target_state not in ('PENDING_APPROVAL','ACTIVE') or target_state is null then return 'INELIGIBLE'; end if;
        if exists(select 1 from public.user_organizations where user_id=r.user_id and organization_id=r.organization_id) then return 'ALREADY_MEMBER'; end if;
        insert into public.user_organizations(user_id,organization_id,role) values(r.user_id,r.organization_id,r.requested_role);
        if target_state='PENDING_APPROVAL' then
            update public.profiles set account_status='ACTIVE' where id=r.user_id;
            perform private.write_audit(r.organization_id,actor,'ACCOUNT_ACTIVATED','profiles',r.user_id,
                jsonb_build_object('account_status',target_state),jsonb_build_object('account_status','ACTIVE'));
        end if;
    end if;
    update public.organization_access_requests set status=decision,reviewed_by=actor,reviewed_at=clock_timestamp() where id=r.id;
    perform private.write_audit(r.organization_id,actor,'ACCESS_REQUEST_'||decision,'organization_access_requests',r.id,
        jsonb_build_object('status','PENDING'),jsonb_build_object('status',decision,'user_id',r.user_id,'requested_role',r.requested_role));
    return decision;
end;
$$;
revoke all on function public.review_organization_access(uuid,text) from public, anon, authenticated;
grant execute on function public.review_organization_access(uuid,text) to authenticated;

-- SQL administrator only. No exposed RPC, service-role or app EXECUTE grant.
create function private.bootstrap_first_admin(org uuid, target uuid, operator_id uuid)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare
    target_state text;
    prior_actor text:=current_setting('gasilko.audit_actor',true);
begin
    if not exists(select 1 from public.profiles where id=operator_id) then return 'INVALID_OPERATOR'; end if;
    select account_status into target_state from public.profiles where id=target for update;
    if target_state is null or target_state not in ('PENDING_APPROVAL','ACTIVE') then return 'INELIGIBLE'; end if;
    perform private.lock_organization(org);
    perform 1 from public.organizations where id=org and active for share;
    if not found then return 'UNAVAILABLE'; end if;
    if exists(select 1 from public.user_organizations where organization_id=org and role='ADMIN') then return 'ADMIN_EXISTS'; end if;
    perform set_config('gasilko.audit_actor',operator_id::text,true);
    insert into public.user_organizations(user_id,organization_id,role) values(target,org,'ADMIN')
        on conflict(user_id,organization_id) do update set role='ADMIN';
    perform set_config('gasilko.audit_actor',coalesce(prior_actor,''),true);
    if target_state='PENDING_APPROVAL' then
        update public.profiles set account_status='ACTIVE' where id=target;
        perform private.write_audit(org,operator_id,'ACCOUNT_ACTIVATED','profiles',target,
            jsonb_build_object('account_status',target_state),jsonb_build_object('account_status','ACTIVE'));
    end if;
    perform private.write_audit(org,operator_id,'FIRST_ADMIN_BOOTSTRAPPED','user_organizations',target,null,jsonb_build_object('role','ADMIN'));
    return 'BOOTSTRAPPED';
end;
$$;
revoke all on function private.bootstrap_first_admin(uuid,uuid,uuid) from public, anon, authenticated, service_role;
