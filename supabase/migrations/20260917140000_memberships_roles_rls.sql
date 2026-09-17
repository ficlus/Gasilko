-- M1.2: database authorization only. No signup, access-request or approval flow.
create table public.user_organizations (
    user_id uuid not null references public.profiles(id) on delete restrict,
    organization_id uuid not null references public.organizations(id) on delete restrict,
    role text not null,
    created_at timestamptz not null default statement_timestamp(),
    primary key (user_id, organization_id),
    constraint user_organizations_role_check check (role in ('FIREFIGHTER', 'MANAGER', 'ADMIN'))
);
-- PK covers current-user membership/role checks. Reverse index covers rosters
-- and organization FK checks; no global role or speculative status index.
create index user_organizations_organization_id_idx
    on public.user_organizations(organization_id);
alter table public.user_organizations enable row level security;
revoke all on public.user_organizations from public, anon, authenticated;
grant select, insert, update, delete on public.user_organizations to service_role;

-- Not an API-exposed schema. The two definer helpers avoid recursive RLS between
-- profiles and memberships. Only boolean answers for auth.uid() are returned.
create schema private authorization postgres;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create function private.is_active_user()
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.profiles p
        where p.id = (select auth.uid()) and p.account_status = 'ACTIVE'
    );
$$;
alter function private.is_active_user() owner to postgres;

create function private.has_organization_role(org_id uuid, roles text[])
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.user_organizations m
        join public.profiles p on p.id = m.user_id
        where m.user_id = (select auth.uid())
          and m.organization_id = org_id
          and m.role = any(roles)
          and p.account_status = 'ACTIVE'
    );
$$;
alter function private.has_organization_role(uuid, text[]) owner to postgres;

create function private.is_organization_member(org_id uuid)
returns boolean
language sql stable security invoker
set search_path = ''
as $$
    select private.has_organization_role(org_id, array['FIREFIGHTER', 'MANAGER', 'ADMIN']::text[]);
$$;
revoke all on function private.is_active_user(),
    private.has_organization_role(uuid, text[]), private.is_organization_member(uuid)
    from public, anon, authenticated;
grant execute on function private.is_active_user(),
    private.has_organization_role(uuid, text[]), private.is_organization_member(uuid)
    to authenticated;

-- Geography is non-secret reference data, including inactive historical areas.
-- Any authenticated identity (even without a profile/membership) can read it.
-- No anonymous access and no client mutations are granted.
grant select on public.countries, public.administrative_areas to authenticated;
create policy countries_authenticated_read on public.countries
    for select to authenticated using ((select auth.uid()) is not null);
create policy administrative_areas_authenticated_read on public.administrative_areas
    for select to authenticated using ((select auth.uid()) is not null);

grant select on public.profiles to authenticated;
grant update (display_name, preferred_language, start_screen, inspection_mode)
    on public.profiles to authenticated;
create policy profiles_active_self_read on public.profiles
    for select to authenticated
    using (id = (select auth.uid()) and (select private.is_active_user()));
create policy profiles_active_self_update on public.profiles
    for update to authenticated
    using (id = (select auth.uid()) and (select private.is_active_user()))
    with check (id = (select auth.uid()) and (select private.is_active_user()));

-- Organization settings/creation/deletion remain trusted-backend only in M1.2.
grant select on public.organizations to authenticated;
create policy organizations_active_member_read on public.organizations
    for select to authenticated using (private.is_organization_member(id));

grant select, delete on public.user_organizations to authenticated;
grant insert (user_id, organization_id, role) on public.user_organizations to authenticated;
-- Identity and created_at are not writable by clients. RLS checks role changes.
grant update (role) on public.user_organizations to authenticated;

create policy memberships_active_read on public.user_organizations
    for select to authenticated
    using (
        ((select private.is_active_user()) and user_id = (select auth.uid()))
        or private.has_organization_role(organization_id, array['MANAGER', 'ADMIN']::text[])
    );
create policy memberships_scoped_insert on public.user_organizations
    for insert to authenticated
    with check (
        private.has_organization_role(organization_id, array['ADMIN']::text[])
        or (role = 'FIREFIGHTER' and private.has_organization_role(organization_id, array['MANAGER']::text[]))
    );
create policy memberships_scoped_update on public.user_organizations
    for update to authenticated
    using (
        private.has_organization_role(organization_id, array['ADMIN']::text[])
        or (role = 'FIREFIGHTER' and private.has_organization_role(organization_id, array['MANAGER']::text[]))
    )
    with check (
        private.has_organization_role(organization_id, array['ADMIN']::text[])
        or (role = 'FIREFIGHTER' and private.has_organization_role(organization_id, array['MANAGER']::text[]))
    );
create policy memberships_scoped_delete on public.user_organizations
    for delete to authenticated
    using (
        private.has_organization_role(organization_id, array['ADMIN']::text[])
        or (role = 'FIREFIGHTER' and private.has_organization_role(organization_id, array['MANAGER']::text[]))
    );

comment on table public.user_organizations is 'Organization-scoped roles; effective protected access also requires profiles.account_status = ACTIVE. No global application role.';
comment on function private.has_organization_role(uuid, text[]) is 'Read-only RLS recursion boundary. Always checks current auth.uid against authoritative profile and membership; accepts no target-user identity.';
