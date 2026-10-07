-- M14.4: owned inventory and immutable-identity operational episodes.
create table public.operational_vehicle_categories(code text primary key check(code ~ '^[A-Z][A-Z0-9_]{0,63}$'),names jsonb not null check(jsonb_typeof(names)='object' and octet_length(names::text)<=4096 and names ? 'sl' and names ? 'de' and jsonb_typeof(names->'sl')='string' and jsonb_typeof(names->'de')='string' and coalesce(length(btrim(names->>'sl')),0)>0 and coalesce(length(btrim(names->>'de')),0)>0),active boolean not null default true);
create table public.operational_capabilities(code text primary key check(code ~ '^[A-Z][A-Z0-9_]{0,63}$'),names jsonb not null check(jsonb_typeof(names)='object' and octet_length(names::text)<=4096 and names ? 'sl' and names ? 'de' and jsonb_typeof(names->'sl')='string' and jsonb_typeof(names->'de')='string' and coalesce(length(btrim(names->>'sl')),0)>0 and coalesce(length(btrim(names->>'de')),0)>0),active boolean not null default true);
create table public.operational_resource_types(code text primary key check(code ~ '^[A-Z][A-Z0-9_]{0,63}$'),names jsonb not null check(jsonb_typeof(names)='object' and octet_length(names::text)<=4096 and names ? 'sl' and names ? 'de' and jsonb_typeof(names->'sl')='string' and jsonb_typeof(names->'de')='string' and coalesce(length(btrim(names->>'sl')),0)>0 and coalesce(length(btrim(names->>'de')),0)>0),active boolean not null default true);
create table public.operational_units_of_measure(code text primary key check(code ~ '^[A-Z][A-Z0-9_]{0,63}$'),names jsonb not null check(jsonb_typeof(names)='object' and octet_length(names::text)<=4096 and names ? 'sl' and names ? 'de' and jsonb_typeof(names->'sl')='string' and jsonb_typeof(names->'de')='string' and coalesce(length(btrim(names->>'sl')),0)>0 and coalesce(length(btrim(names->>'de')),0)>0),active boolean not null default true);
insert into public.operational_vehicle_categories values('OTHER','{"sl":"Drugo","de":"Sonstige"}',true);
insert into public.operational_resource_types values('OTHER','{"sl":"Drugo","de":"Sonstige"}',true);
insert into public.operational_units_of_measure values('EACH','{"sl":"Kos","de":"Stück"}',true);
create table public.operational_vehicles(
 id uuid primary key,organization_id uuid not null references public.organizations(id),callsign text not null check(length(btrim(callsign)) between 1 and 80),name text not null check(length(btrim(name)) between 1 and 200),
 category_code text not null references public.operational_vehicle_categories(code),registration text check(length(registration)<=80),active boolean not null default true,
 availability text not null check(availability in ('AVAILABLE','UNAVAILABLE')),seats integer not null check(seats>=0),water_litres integer not null check(water_litres>=0),created_by uuid not null references public.profiles(id),updated_by uuid not null references public.profiles(id),created_at timestamptz not null default clock_timestamp(),updated_at timestamptz not null default clock_timestamp(),version bigint not null default 1 check(version>0),unique(id,organization_id));
create table public.operational_units(
 id uuid primary key,organization_id uuid not null references public.organizations(id),callsign text not null check(length(btrim(callsign)) between 1 and 80),name text not null check(length(btrim(name)) between 1 and 200),
 unit_kind text not null check(unit_kind in ('VEHICLE_CREW','RESCUE_TEAM','DRONE_TEAM','MEDICAL_TEAM','OTHER')),vehicle_id uuid,active boolean not null default true,created_by uuid not null references public.profiles(id),updated_by uuid not null references public.profiles(id),created_at timestamptz not null default clock_timestamp(),updated_at timestamptz not null default clock_timestamp(),version bigint not null default 1 check(version>0),unique(id,organization_id),
 foreign key(vehicle_id,organization_id) references public.operational_vehicles(id,organization_id));
create table public.operational_resources(
 id uuid primary key,organization_id uuid not null references public.organizations(id),name text not null check(length(btrim(name)) between 1 and 200),
 resource_type_code text not null references public.operational_resource_types(code),unit_of_measure_code text not null references public.operational_units_of_measure(code),
 total_quantity numeric not null check(total_quantity>=0 and total_quantity<1000000000000 and scale(total_quantity)<=3),active boolean not null default true,created_by uuid not null references public.profiles(id),updated_by uuid not null references public.profiles(id),created_at timestamptz not null default clock_timestamp(),updated_at timestamptz not null default clock_timestamp(),version bigint not null default 1 check(version>0),unique(id,organization_id));
create table public.operational_vehicle_capabilities(vehicle_id uuid not null references public.operational_vehicles(id),capability_code text not null references public.operational_capabilities(code),active boolean not null default true,primary key(vehicle_id,capability_code));
create unique index operational_vehicle_callsign_unique on public.operational_vehicles(organization_id,callsign) where active;
create table public.operational_unit_capabilities(unit_id uuid not null references public.operational_units(id),capability_code text not null references public.operational_capabilities(code),active boolean not null default true,primary key(unit_id,capability_code));
create unique index operational_unit_callsign_unique on public.operational_units(organization_id,callsign) where active;
create table public.incident_units(
 id uuid primary key,incident_id uuid not null references public.incidents(id),participation_id uuid not null,organization_id uuid not null,unit_id uuid not null,sector_id uuid,
 status text not null check(status in ('REQUESTED','DISPATCHED','EN_ROUTE','ON_SCENE','ASSIGNED','RETURNING','RELEASED','UNAVAILABLE')),
 assigned_by uuid not null references public.profiles(id),assigned_at timestamptz not null default clock_timestamp(),status_changed_at timestamptz not null default clock_timestamp(),
 released_by uuid references public.profiles(id),released_at timestamptz,end_reason text check(length(btrim(end_reason)) between 1 and 2000),
 version bigint not null default 1 check(version>0),changed_revision bigint not null check(changed_revision>0),unique(id,incident_id),unique(id,incident_id,organization_id),
 foreign key(participation_id,incident_id,organization_id) references public.incident_participants(id,incident_id,organization_id),
 foreign key(unit_id,organization_id) references public.operational_units(id,organization_id),foreign key(sector_id,incident_id) references public.incident_sectors(id,incident_id),
 check((status in ('RELEASED','UNAVAILABLE') and released_at is not null and released_by is not null) or (status not in ('RELEASED','UNAVAILABLE') and released_at is null and released_by is null)),
 check(status<>'UNAVAILABLE' or end_reason is not null));
create unique index incident_unit_live_unique on public.incident_units(unit_id) where status not in ('RELEASED','UNAVAILABLE');
create table public.incident_crew_members(
 id uuid primary key,incident_id uuid not null references public.incidents(id),unit_assignment_id uuid not null,user_id uuid not null references public.profiles(id),membership_organization_id uuid not null,
 crew_role text not null check(crew_role in ('LEADER','DRIVER','RESPONDER','SPECIALIST')),joined_at timestamptz not null default clock_timestamp(),left_at timestamptz,
 status text not null default 'ACTIVE' check(status in ('ACTIVE','LEFT')),added_by uuid not null references public.profiles(id),left_by uuid references public.profiles(id),
 version bigint not null default 1 check(version>0),changed_revision bigint not null check(changed_revision>0),unique(id,incident_id),
 foreign key(unit_assignment_id,incident_id,membership_organization_id) references public.incident_units(id,incident_id,organization_id),
 check((status='LEFT' and left_at is not null and left_by is not null) or (status='ACTIVE' and left_at is null and left_by is null)));
create unique index incident_crew_live_unique on public.incident_crew_members(incident_id,user_id) where status='ACTIVE';
create table public.incident_resource_allocations(
 id uuid primary key,incident_id uuid not null references public.incidents(id),resource_id uuid not null,participant_id uuid not null,organization_id uuid not null,
 quantity numeric not null check(quantity>0 and quantity<1000000000000 and scale(quantity)<=3),unit_assignment_id uuid,
 status text not null check(status in ('RESERVED','DEPLOYED','RETURNED','CONSUMED','CANCELLED')),allocated_by uuid not null references public.profiles(id),allocated_at timestamptz not null default clock_timestamp(),
 ended_by uuid references public.profiles(id),ended_at timestamptz,version bigint not null default 1 check(version>0),changed_revision bigint not null check(changed_revision>0),unique(id,incident_id),
 foreign key(resource_id,organization_id) references public.operational_resources(id,organization_id),
 foreign key(participant_id,incident_id,organization_id) references public.incident_participants(id,incident_id,organization_id),
 foreign key(unit_assignment_id,incident_id,organization_id) references public.incident_units(id,incident_id,organization_id),
 check((status in ('RETURNED','CONSUMED','CANCELLED') and ended_at is not null and ended_by is not null) or (status in ('RESERVED','DEPLOYED') and ended_at is null and ended_by is null)));
create index incident_crew_unit_idx on public.incident_crew_members(unit_assignment_id,status,joined_at,id);
create index incident_allocations_resource_idx on public.incident_resource_allocations(resource_id,status);
create index incident_allocations_unit_idx on public.incident_resource_allocations(unit_assignment_id,status);
create index incident_units_participant_idx on public.incident_units(participation_id,status);
create index incident_units_sector_idx on public.incident_units(sector_id,status);
create index operational_vehicles_org_idx on public.operational_vehicles(organization_id,active,id);
create index operational_units_org_idx on public.operational_units(organization_id,active,id);
create index operational_resources_org_idx on public.operational_resources(organization_id,active,id);
create index incident_units_incident_idx on public.incident_units(incident_id,status,id);
create index incident_resource_allocations_incident_idx on public.incident_resource_allocations(incident_id,status,id);
alter table public.operational_vehicle_categories enable row level security;
revoke all on public.operational_vehicle_categories from public,anon,authenticated,service_role;
create trigger operational_vehicle_categories_no_delete before delete on public.operational_vehicle_categories for each row execute function private.audit_immutable();
create trigger operational_vehicle_categories_no_truncate before truncate on public.operational_vehicle_categories for each statement execute function private.audit_immutable();
alter table public.operational_capabilities enable row level security;
revoke all on public.operational_capabilities from public,anon,authenticated,service_role;
create trigger operational_capabilities_no_delete before delete on public.operational_capabilities for each row execute function private.audit_immutable();
create trigger operational_capabilities_no_truncate before truncate on public.operational_capabilities for each statement execute function private.audit_immutable();
alter table public.operational_resource_types enable row level security;
revoke all on public.operational_resource_types from public,anon,authenticated,service_role;
create trigger operational_resource_types_no_delete before delete on public.operational_resource_types for each row execute function private.audit_immutable();
create trigger operational_resource_types_no_truncate before truncate on public.operational_resource_types for each statement execute function private.audit_immutable();
alter table public.operational_units_of_measure enable row level security;
revoke all on public.operational_units_of_measure from public,anon,authenticated,service_role;
create trigger operational_units_of_measure_no_delete before delete on public.operational_units_of_measure for each row execute function private.audit_immutable();
create trigger operational_units_of_measure_no_truncate before truncate on public.operational_units_of_measure for each statement execute function private.audit_immutable();
alter table public.operational_vehicles enable row level security;
revoke all on public.operational_vehicles from public,anon,authenticated,service_role;
create trigger operational_vehicles_no_delete before delete on public.operational_vehicles for each row execute function private.audit_immutable();
create trigger operational_vehicles_no_truncate before truncate on public.operational_vehicles for each statement execute function private.audit_immutable();
alter table public.operational_units enable row level security;
revoke all on public.operational_units from public,anon,authenticated,service_role;
create trigger operational_units_no_delete before delete on public.operational_units for each row execute function private.audit_immutable();
create trigger operational_units_no_truncate before truncate on public.operational_units for each statement execute function private.audit_immutable();
alter table public.operational_resources enable row level security;
revoke all on public.operational_resources from public,anon,authenticated,service_role;
create trigger operational_resources_no_delete before delete on public.operational_resources for each row execute function private.audit_immutable();
create trigger operational_resources_no_truncate before truncate on public.operational_resources for each statement execute function private.audit_immutable();
alter table public.operational_vehicle_capabilities enable row level security;
revoke all on public.operational_vehicle_capabilities from public,anon,authenticated,service_role;
create trigger operational_vehicle_capabilities_no_delete before delete on public.operational_vehicle_capabilities for each row execute function private.audit_immutable();
create trigger operational_vehicle_capabilities_no_truncate before truncate on public.operational_vehicle_capabilities for each statement execute function private.audit_immutable();
alter table public.operational_unit_capabilities enable row level security;
revoke all on public.operational_unit_capabilities from public,anon,authenticated,service_role;
create trigger operational_unit_capabilities_no_delete before delete on public.operational_unit_capabilities for each row execute function private.audit_immutable();
create trigger operational_unit_capabilities_no_truncate before truncate on public.operational_unit_capabilities for each statement execute function private.audit_immutable();
alter table public.incident_units enable row level security;
revoke all on public.incident_units from public,anon,authenticated,service_role;
create trigger incident_units_no_delete before delete on public.incident_units for each row execute function private.audit_immutable();
create trigger incident_units_no_truncate before truncate on public.incident_units for each statement execute function private.audit_immutable();
alter table public.incident_crew_members enable row level security;
revoke all on public.incident_crew_members from public,anon,authenticated,service_role;
create trigger incident_crew_members_no_delete before delete on public.incident_crew_members for each row execute function private.audit_immutable();
create trigger incident_crew_members_no_truncate before truncate on public.incident_crew_members for each statement execute function private.audit_immutable();
alter table public.incident_resource_allocations enable row level security;
revoke all on public.incident_resource_allocations from public,anon,authenticated,service_role;
create trigger incident_resource_allocations_no_delete before delete on public.incident_resource_allocations for each row execute function private.audit_immutable();
create trigger incident_resource_allocations_no_truncate before truncate on public.incident_resource_allocations for each statement execute function private.audit_immutable();

-- Identity is historical. Trusted commands may end an episode, never repurpose it.
create function private.guard_operational_episode() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_table_name='incident_units' then
  if (new.id,new.incident_id,new.participation_id,new.organization_id,new.unit_id,new.assigned_by,new.assigned_at)
   is distinct from (old.id,old.incident_id,old.participation_id,old.organization_id,old.unit_id,old.assigned_by,old.assigned_at)
   or old.status in ('RELEASED','UNAVAILABLE') then raise exception 'INVALID_UNIT'; end if;
 elsif tg_table_name='incident_crew_members' then
  if (new.id,new.incident_id,new.unit_assignment_id,new.user_id,new.membership_organization_id,new.crew_role,new.joined_at,new.added_by)
   is distinct from (old.id,old.incident_id,old.unit_assignment_id,old.user_id,old.membership_organization_id,old.crew_role,old.joined_at,old.added_by)
   or old.status<>'ACTIVE' or new.status<>'LEFT' then raise exception 'INVALID_CREW_MEMBER'; end if;
 elsif tg_table_name='incident_resource_allocations' then
  if (new.id,new.incident_id,new.resource_id,new.participant_id,new.organization_id,new.quantity,new.unit_assignment_id,new.allocated_by,new.allocated_at)
   is distinct from (old.id,old.incident_id,old.resource_id,old.participant_id,old.organization_id,old.quantity,old.unit_assignment_id,old.allocated_by,old.allocated_at)
   or old.status not in ('RESERVED','DEPLOYED') then raise exception 'INVALID_RESOURCE_STATUS'; end if;
 end if;
 if new.version<>old.version+1 or new.changed_revision<=old.changed_revision then raise exception 'STALE_VERSION'; end if;
 return new;
end; $$;
revoke all on function private.guard_operational_episode() from public,anon,authenticated,service_role;
create trigger incident_unit_identity before update on public.incident_units for each row execute function private.guard_operational_episode();
create trigger incident_crew_identity before update on public.incident_crew_members for each row execute function private.guard_operational_episode();
create trigger incident_allocation_identity before update on public.incident_resource_allocations for each row execute function private.guard_operational_episode();
