create table public.organization_access_requests (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles(id) on delete restrict,
    organization_id uuid not null references public.organizations(id) on delete restrict,
    requested_role text not null check (requested_role in ('FIREFIGHTER','MANAGER')),
    status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED')),
    requested_at timestamptz not null default statement_timestamp(),
    reviewed_by uuid references public.profiles(id) on delete restrict,
    reviewed_at timestamptz,
    constraint request_review_consistent check (
        (status = 'PENDING' and reviewed_by is null and reviewed_at is null)
        or (status <> 'PENDING' and reviewed_by is not null and reviewed_at is not null)
    )
);
create unique index requests_one_pending_per_organization
    on public.organization_access_requests(user_id, organization_id) where status = 'PENDING';
create index requests_user_history_idx on public.organization_access_requests(user_id, requested_at desc, id);
create index requests_organization_idx on public.organization_access_requests(organization_id);
create index requests_reviewer_idx on public.organization_access_requests(reviewed_by) where reviewed_by is not null;
alter table public.organization_access_requests enable row level security;
revoke all on public.organization_access_requests from public, anon, authenticated;
grant select on public.organization_access_requests to authenticated;
grant select, insert, update, delete on public.organization_access_requests to service_role;
create policy requests_self_read on public.organization_access_requests for select to authenticated
    using (user_id = (select auth.uid()));

-- Deliberately limited discovery projection. Existing organizations RLS is untouched.
create function public.discover_organizations(country uuid, area uuid default null, after_id uuid default null)
returns table(id uuid, name text, code text, type text, administrative_area_id uuid)
language sql stable security definer set search_path = '' as $$
    with recursive selected_areas as (
        select a.id from public.administrative_areas a
        where a.country_id = country and a.active and (area is null or a.id = area)
        union
        select a.id from public.administrative_areas a join selected_areas s on a.parent_id = s.id
        where a.country_id = country and a.active
    )
    select o.id, o.name, o.code, o.type, o.administrative_area_id
    from public.organizations o join selected_areas a on a.id = o.administrative_area_id
    where o.active and (after_id is null or o.id > after_id)
      and exists (select 1 from public.countries c where c.id = country and c.active)
      and exists (select 1 from public.profiles p where p.id = (select auth.uid())
                  and p.account_status in ('PENDING_APPROVAL','ACTIVE'))
    order by o.id limit 50;
$$;
alter function public.discover_organizations(uuid, uuid, uuid) owner to postgres;
revoke all on function public.discover_organizations(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.discover_organizations(uuid, uuid, uuid) to authenticated;

create function public.request_organization_access(organization uuid, desired_role text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    actor uuid := auth.uid();
    account_state text;
    request_id uuid;
begin
    if actor is null then return jsonb_build_object('result','NOT_ALLOWED'); end if;
    select p.account_status into account_state from public.profiles p where p.id = actor for update;
    if account_state is null or account_state not in ('PENDING_APPROVAL','ACTIVE') then
        return jsonb_build_object('result','NOT_ALLOWED');
    end if;
    if desired_role is null or desired_role not in ('FIREFIGHTER','MANAGER') then
        return jsonb_build_object('result','INVALID_ROLE');
    end if;
    -- Lock selection against concurrent organization deactivation until commit.
    perform o.id from public.organizations o
    join public.administrative_areas a on a.id = o.administrative_area_id
    join public.countries c on c.id = a.country_id
    where o.id = organization and o.active and a.active and c.active for share of o, a, c;
    if not found then return jsonb_build_object('result','UNAVAILABLE'); end if;
    if exists (select 1 from public.user_organizations m where m.user_id = actor and m.organization_id = organization) then
        return jsonb_build_object('result','ALREADY_MEMBER');
    end if;
    insert into public.organization_access_requests(user_id,organization_id,requested_role)
    values (actor,organization,desired_role)
    on conflict (user_id,organization_id) where status = 'PENDING' do nothing
    returning id into request_id;
    if request_id is null then return jsonb_build_object('result','DUPLICATE_REQUEST'); end if;
    return jsonb_build_object('result','SUBMITTED','id',request_id);
end;
$$;
alter function public.request_organization_access(uuid,text) owner to postgres;
revoke all on function public.request_organization_access(uuid,text) from public, anon, authenticated;
grant execute on function public.request_organization_access(uuid,text) to authenticated;
comment on function public.request_organization_access(uuid,text) is 'Self-service request only. No caller-supplied identity/review fields. Never changes account status or membership. M1.5 must lock the applicant profile before review.';

create function public.list_my_access_requests(before_time timestamptz default null, before_id uuid default null)
returns table(id uuid, organization_id uuid, organization_name text, requested_role text, status text, requested_at timestamptz)
language sql stable security definer set search_path = '' as $$
    select r.id, r.organization_id, o.name, r.requested_role, r.status, r.requested_at
    from public.organization_access_requests r join public.organizations o on o.id = r.organization_id
    where r.user_id = (select auth.uid())
      and (before_time is null or (r.requested_at,r.id) < (before_time,before_id))
    order by r.requested_at desc, r.id desc limit 50;
$$;
alter function public.list_my_access_requests(timestamptz,uuid) owner to postgres;
revoke all on function public.list_my_access_requests(timestamptz,uuid) from public, anon, authenticated;
grant execute on function public.list_my_access_requests(timestamptz,uuid) to authenticated;
