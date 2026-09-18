-- M2.1 only: trusted database foundation; no client CRUD authorization yet.
create table public.hydrant_types (
    id uuid primary key default gen_random_uuid(),
    organization_id uuid references public.organizations(id) on delete restrict,
    code text not null check (code ~ '^[A-Z0-9][A-Z0-9_]*$'),
    name text not null check (name ~ '[^[:space:]]'),
    active boolean not null default true,
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    unique nulls not distinct (organization_id, code)
);

create table public.hydrants (
    id uuid primary key default gen_random_uuid(),
    code text unique,
    organization_id uuid not null references public.organizations(id) on delete restrict,
    hydrant_type_id uuid not null references public.hydrant_types(id) on delete restrict,
    latitude numeric(9,6),
    longitude numeric(9,6),
    address text,
    location_description text,
    status text not null default 'UNKNOWN'
        check (status in ('WORKING','NOT_WORKING','NEEDS_INSPECTION','UNKNOWN')),
    notes text,
    inspection_interval_months integer check (inspection_interval_months > 0),
    active boolean not null default true,
    version bigint not null default 1 check (version > 0),
    created_by uuid not null references public.profiles(id) on delete restrict,
    created_at timestamptz not null default statement_timestamp(),
    updated_by uuid not null references public.profiles(id) on delete restrict,
    updated_at timestamptz not null default statement_timestamp(),
    constraint hydrants_coordinate_pair check ((latitude is null) = (longitude is null)),
    constraint hydrants_latitude check (latitude between -90 and 90),
    constraint hydrants_longitude check (longitude between -180 and 180),
    constraint hydrants_location check (
        latitude is not null or coalesce(address ~ '[^[:space:]]', false)
        or coalesce(location_description ~ '[^[:space:]]', false)
    )
);
-- Organization roster/filter scans; type and actor indexes also support FK checks.
create index hydrants_organization_active_status_idx on public.hydrants(organization_id, active, status);
create index hydrants_type_idx on public.hydrants(hydrant_type_id);
create index hydrants_created_by_idx on public.hydrants(created_by);
create index hydrants_updated_by_idx on public.hydrants(updated_by);

-- A prefix is permanently reserved at the organization's first allocation.
create table private.hydrant_code_counters (
    organization_id uuid primary key references public.organizations(id) on delete restrict,
    code_prefix text not null unique,
    last_value integer not null default 0 check (last_value between 0 and 999999)
);
-- Deliberately no hydrant FK: even trusted physical deletion cannot release codes/UUIDs.
create table private.hydrant_code_assignments (
    hydrant_id uuid primary key,
    organization_id uuid not null references private.hydrant_code_counters(organization_id) on delete restrict,
    code text not null unique
);
create index hydrant_code_assignments_organization_idx on private.hydrant_code_assignments(organization_id);
revoke all on public.hydrant_types, public.hydrants,
    private.hydrant_code_counters, private.hydrant_code_assignments
    from public, anon, authenticated, service_role;
alter table public.hydrant_types enable row level security;
alter table public.hydrants enable row level security;

create function private.guard_hydrant_type() returns trigger
language plpgsql set search_path = '' as $$
begin
    if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id then
        raise exception 'Hydrant type identity and ownership are immutable' using errcode = '23514';
    end if;
    return new;
end;
$$;
create trigger hydrant_type_identity before update on public.hydrant_types
    for each row execute function private.guard_hydrant_type();
create trigger hydrant_type_timestamps before insert or update on public.hydrant_types
    for each row execute function public.maintain_record_timestamps();

create function private.guard_hydrant() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
    type_owner uuid;
    type_active boolean;
begin
    if tg_op = 'INSERT' then
        if new.code is not null then
            raise exception 'Use the private code allocator after insert' using errcode = '23514';
        end if;
        if exists (select 1 from private.hydrant_code_assignments where hydrant_id = new.id) then
            raise exception 'Previously assigned hydrant UUID cannot be recreated' using errcode = '23514';
        end if;
        new.version := 1;
        new.created_at := statement_timestamp();
        new.updated_at := statement_timestamp();
    else
        if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id
            or new.created_by is distinct from old.created_by then
            raise exception 'Hydrant identity, ownership and creator are immutable' using errcode = '23514';
        end if;
        if new.code is distinct from old.code then
            if old.code is not null or not exists (
                select 1 from private.hydrant_code_assignments a
                where a.hydrant_id = new.id and a.organization_id = new.organization_id and a.code = new.code
            ) then
                raise exception 'Assigned hydrant code is protected' using errcode = '23514';
            end if;
        end if;
        new.created_at := old.created_at;
        if (to_jsonb(new) - array['version','created_at','updated_at','updated_by'])
            is distinct from (to_jsonb(old) - array['version','created_at','updated_at','updated_by']) then
            new.version := old.version + 1;
            new.updated_at := statement_timestamp();
        else
            new.version := old.version;
            new.updated_at := old.updated_at;
            new.updated_by := old.updated_by;
        end if;
    end if;
    if tg_op = 'INSERT' or new.hydrant_type_id is distinct from old.hydrant_type_id then
        -- SHARE also serializes activation/deactivation against new references.
        select t.organization_id, t.active into type_owner, type_active
        from public.hydrant_types t where t.id = new.hydrant_type_id for share;
        if not found then
            raise exception 'Unknown hydrant type' using errcode = '23503';
        end if;
        if type_owner is not null and type_owner <> new.organization_id then
            raise exception 'Hydrant type belongs to another organization' using errcode = '23514';
        end if;
        if not type_active then
            raise exception 'Inactive hydrant type cannot be newly assigned' using errcode = '23514';
        end if;
    end if;
    return new;
end;
$$;
create trigger hydrant_integrity before insert or update on public.hydrants
    for each row execute function private.guard_hydrant();

create function private.assign_hydrant_code(organization uuid, hydrant uuid, actor uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
    result text;
    prefix text;
    sequence_number integer;
begin
    -- Explicit organization scope and row lock make same-UUID retries idempotent.
    select h.code into result from public.hydrants h
        where h.id = hydrant and h.organization_id = organization for update;
    if not found then
        raise exception 'Hydrant not found in organization' using errcode = '22023';
    end if;
    if result is not null then return result; end if;
    if actor is null or not exists (select 1 from public.profiles where id = actor) then
        raise exception 'Valid actor profile required' using errcode = '23503';
    end if;
    select o.code into prefix from public.organizations o where o.id = organization for share;
    insert into private.hydrant_code_counters(organization_id, code_prefix)
        values (organization, prefix) on conflict (organization_id) do nothing;
    update private.hydrant_code_counters c set last_value = c.last_value + 1
        where c.organization_id = organization and c.last_value < 999999
        returning c.code_prefix, c.last_value into prefix, sequence_number;
    if not found then
        raise exception 'Hydrant code sequence exhausted' using errcode = '22003';
    end if;
    result := prefix || '-H-' || lpad(sequence_number::text, 6, '0');
    insert into private.hydrant_code_assignments(hydrant_id, organization_id, code)
        values (hydrant, organization, result);
    update public.hydrants set code = result, updated_by = actor where id = hydrant;
    return result;
end;
$$;
alter function private.guard_hydrant_type() owner to postgres;
alter function private.guard_hydrant() owner to postgres;
alter function private.assign_hydrant_code(uuid, uuid, uuid) owner to postgres;
revoke all on function private.guard_hydrant_type(), private.guard_hydrant(),
    private.assign_hydrant_code(uuid, uuid, uuid) from public, anon, authenticated, service_role;
