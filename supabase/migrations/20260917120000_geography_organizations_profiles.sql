-- M1.1 only. No memberships, access requests, or client access policies.
create table public.countries (
    id uuid primary key default gen_random_uuid(),
    code char(2) not null unique,
    name text not null,
    active boolean not null default true,
    constraint countries_code_format check (code::text ~ '^[A-Z]{2}$'),
    constraint countries_name_not_blank check (btrim(name) <> '')
);

create table public.administrative_areas (
    id uuid primary key default gen_random_uuid(),
    country_id uuid not null references public.countries(id) on delete restrict,
    parent_id uuid,
    name text not null,
    area_type text not null,
    boundary jsonb,
    active boolean not null default true,
    -- Also indexes country lookup; required for the same-country parent FK.
    constraint administrative_areas_country_id_id_key unique (country_id, id),
    constraint administrative_areas_parent_fk foreign key (country_id, parent_id)
        references public.administrative_areas(country_id, id) on delete restrict,
    constraint administrative_areas_not_self_parent check (parent_id is distinct from id),
    constraint administrative_areas_name_not_blank check (btrim(name) <> ''),
    constraint administrative_areas_type_not_blank check (btrim(area_type) <> '')
);
create index administrative_areas_parent_id_idx on public.administrative_areas(parent_id);

-- Serialize structural edits within a country so concurrent reparenting cannot
-- each validate against the other's old ancestry. A row UPDATE (even with the
-- same value) also causes stale REPEATABLE READ/SERIALIZABLE writers to abort.
-- This is invoker-security: geography maintenance is trusted-backend only.
create function public.validate_administrative_area_hierarchy()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    update public.countries set id = id where id = new.country_id;
    if new.parent_id is not null and exists (
        with recursive ancestors as (
            select id, parent_id from public.administrative_areas where id = new.parent_id
            union
            select area.id, area.parent_id
            from public.administrative_areas area
            join ancestors ancestor on area.id = ancestor.parent_id
        )
        select 1 from ancestors where id = new.id
    ) then
        raise exception 'Administrative hierarchy cannot contain a cycle'
            using errcode = '23514', constraint = 'administrative_areas_acyclic';
    end if;
    return new;
end;
$$;
revoke all on function public.validate_administrative_area_hierarchy() from public, anon, authenticated;
create trigger administrative_areas_validate_hierarchy
before insert or update of id, country_id, parent_id on public.administrative_areas
for each row execute function public.validate_administrative_area_hierarchy();

create table public.organizations (
    id uuid primary key default gen_random_uuid(),
    administrative_area_id uuid references public.administrative_areas(id) on delete restrict,
    name text not null,
    code text not null unique,
    type text not null,
    inspection_interval_months integer not null default 12,
    default_language text,
    active boolean not null default true,
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    constraint organizations_name_not_blank check (btrim(name) <> ''),
    -- A globally unique canonical code can safely identify a future code prefix.
    constraint organizations_code_format check (code ~ '^[A-Z0-9][A-Z0-9_-]*$'),
    constraint organizations_type_check check (type in ('MUNICIPALITY', 'FIRE_DEPARTMENT', 'WATER_UTILITY', 'OTHER')),
    constraint organizations_interval_positive check (inspection_interval_months > 0),
    constraint organizations_language_check check (default_language in ('sl', 'de'))
);
create index organizations_administrative_area_id_idx on public.organizations(administrative_area_id);

create table public.profiles (
    id uuid primary key references auth.users(id) on delete restrict,
    display_name text,
    email text,
    account_status text not null default 'PENDING_APPROVAL',
    preferred_language text,
    start_screen text not null default 'DASHBOARD',
    inspection_mode text not null default 'GUIDED',
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    constraint profiles_account_status_check check (account_status in ('PENDING_APPROVAL', 'ACTIVE', 'SUSPENDED', 'REJECTED')),
    constraint profiles_language_check check (preferred_language in ('sl', 'de')),
    constraint profiles_start_screen_check check (start_screen in ('DASHBOARD', 'MAP', 'INSPECTIONS')),
    constraint profiles_inspection_mode_check check (inspection_mode in ('QUICK', 'GUIDED', 'CLASSIC'))
);

create function public.maintain_record_timestamps()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if tg_op = 'INSERT' then
        new.created_at := statement_timestamp();
    else
        new.created_at := old.created_at;
    end if;
    new.updated_at := statement_timestamp();
    return new;
end;
$$;
revoke all on function public.maintain_record_timestamps() from public, anon, authenticated;
create trigger organizations_maintain_timestamps
before insert or update on public.organizations
for each row execute function public.maintain_record_timestamps();
create trigger profiles_maintain_timestamps
before insert or update on public.profiles
for each row execute function public.maintain_record_timestamps();

alter table public.countries enable row level security;
alter table public.administrative_areas enable row level security;
alter table public.organizations enable row level security;
alter table public.profiles enable row level security;

-- Supabase default privileges must not accidentally expose new application data.
-- M1.2 must introduce narrowly scoped grants AND policies together.
revoke all on table public.countries, public.administrative_areas,
    public.organizations, public.profiles from public, anon, authenticated;
grant select, insert, update, delete on table public.countries,
    public.administrative_areas, public.organizations, public.profiles to service_role;

comment on table public.profiles is 'Application profile; auth identity alone grants no application access. Provisioned by trusted backend in later tasks.';
comment on column public.organizations.code is 'Globally unique canonical uppercase identifier across countries and active/inactive organizations; not a hydrant sequence.';
