-- M14.0: storage and read/authorization primitives, not incident workflows.
-- No client/service-role mutations are granted. M14.1 must add audited,
-- idempotent, locked command RPCs before any operational data can be created.

create table public.incident_types (
    id uuid primary key default gen_random_uuid(),
    code text not null unique check (code ~ '^[A-Z][A-Z0-9_]{0,63}$'),
    names jsonb not null check (jsonb_typeof(names) = 'object'
        and jsonb_typeof(names -> 'sl') = 'string' and length(btrim(names ->> 'sl')) > 0
        and jsonb_typeof(names -> 'de') = 'string' and length(btrim(names ->> 'de')) > 0
        and names ? 'sl' and names ? 'de' and octet_length(names::text) <= 4096),
    active boolean not null default true,
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp()
);
-- Stable configuration only; no sample incidents, organizations or commanders.
insert into public.incident_types (id, code, names) values
    ('14000000-0000-4000-8000-000000000001', 'OTHER', '{"sl":"Drugo","de":"Sonstiges"}');

create table public.incidents (
    id uuid primary key default gen_random_uuid(),
    reference_number text check (length(btrim(reference_number)) between 1 and 80),
    reference_year smallint not null check (reference_year between 2000 and 9999),
    title text not null check (length(btrim(title)) between 1 and 200),
    summary text not null default '' check (length(summary) <= 10000),
    incident_type_id uuid not null references public.incident_types(id) on delete restrict,
    severity text not null default 'UNKNOWN' check (severity in ('UNKNOWN','MINOR','MAJOR','CRITICAL')),
    priority text not null default 'NORMAL' check (priority in ('LOW','NORMAL','HIGH','CRITICAL')),
    status text not null default 'DRAFT' check (status in ('DRAFT','ACTIVE','STABILIZED','CLOSED','CANCELLED')),
    created_organization_id uuid not null references public.organizations(id) on delete restrict,
    lead_organization_id uuid not null references public.organizations(id) on delete restrict,
    created_by uuid not null references public.profiles(id) on delete restrict,
    latitude double precision,
    longitude double precision,
    address text check (length(address) <= 1000),
    started_at timestamptz,
    declared_at timestamptz,
    stabilized_at timestamptz,
    closed_at timestamptz,
    cancelled_at timestamptz,
    timezone text not null default 'Europe/Ljubljana' check (length(timezone) between 1 and 100),
    metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object' and octet_length(metadata::text) <= 8192),
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    version bigint not null default 1 check (version > 0),
    revision bigint not null default 0 check (revision >= 0),
    timeline_sequence bigint not null default 0 check (timeline_sequence >= 0),
    constraint incidents_coordinates check ((latitude is null and longitude is null) or
        (latitude is not null and longitude is not null and latitude between -90 and 90 and longitude between -180 and 180)),
    constraint incidents_status_times check (
        (status = 'DRAFT' and declared_at is null and stabilized_at is null and closed_at is null and cancelled_at is null) or
        (status = 'ACTIVE' and declared_at is not null and stabilized_at is null and closed_at is null and cancelled_at is null) or
        (status = 'STABILIZED' and declared_at is not null and stabilized_at is not null and closed_at is null and cancelled_at is null) or
        (status = 'CLOSED' and declared_at is not null and stabilized_at is not null and closed_at is not null and cancelled_at is null) or
        (status = 'CANCELLED' and declared_at is null and stabilized_at is null and closed_at is null and cancelled_at is not null)),
    constraint incidents_time_order check ((started_at is null or declared_at is null or started_at <= declared_at)
        and (stabilized_at is null or stabilized_at >= declared_at)
        and (closed_at is null or closed_at >= stabilized_at))
);
create unique index incidents_reference_unique on public.incidents(created_organization_id, reference_year, reference_number)
    where reference_number is not null;
create index incidents_creator_list_idx on public.incidents(created_organization_id, updated_at desc, id);
create index incidents_lead_list_idx on public.incidents(lead_organization_id, status, updated_at desc, id);

create table public.incident_participants (
    id uuid primary key default gen_random_uuid(),
    incident_id uuid not null references public.incidents(id) on delete restrict,
    organization_id uuid not null references public.organizations(id) on delete restrict,
    agency_role text not null default 'SUPPORT' check (agency_role in ('LEAD','SUPPORT','LIAISON')),
    status text not null default 'REQUESTED' check (status in ('REQUESTED','ACTIVE','RELEASED','DECLINED','CANCELLED')),
    source text not null check (source in ('CREATOR','INVITATION','REQUEST','EXTERNAL')),
    requested_by uuid not null references public.profiles(id) on delete restrict,
    requested_at timestamptz not null default statement_timestamp(),
    accepted_by uuid references public.profiles(id) on delete restrict,
    accepted_at timestamptz,
    ended_by uuid references public.profiles(id) on delete restrict,
    ended_at timestamptz,
    end_reason text check (length(btrim(end_reason)) between 1 and 2000),
    updated_at timestamptz not null default statement_timestamp(),
    version bigint not null default 1 check (version > 0),
    unique (id, incident_id, organization_id),
    unique (id, incident_id),
    constraint incident_participants_times check (
        (status = 'REQUESTED' and accepted_by is null and accepted_at is null and ended_by is null and ended_at is null and end_reason is null) or
        (status = 'ACTIVE' and accepted_by is not null and accepted_at is not null and ended_by is null and ended_at is null and end_reason is null) or
        (status = 'RELEASED' and accepted_by is not null and accepted_at is not null and ended_by is not null and ended_at is not null and end_reason is not null) or
        (status in ('DECLINED','CANCELLED') and accepted_by is null and accepted_at is null and ended_by is not null and ended_at is not null and end_reason is not null)),
    check ((accepted_at is null or accepted_at >= requested_at) and
        (ended_at is null or ended_at >= coalesce(accepted_at, requested_at)))
);
-- At most one live episode, including an outstanding invitation; rejoining
-- creates a new row, never rewrites a released participation episode.
create unique index incident_participants_live_unique on public.incident_participants(incident_id, organization_id)
    where status in ('REQUESTED','ACTIVE');
create unique index incident_participants_lead_unique on public.incident_participants(incident_id)
    where status = 'ACTIVE' and agency_role = 'LEAD';
create index incident_participants_org_idx on public.incident_participants(organization_id, status, incident_id);

create table public.incident_role_assignments (
    id uuid primary key default gen_random_uuid(),
    incident_id uuid not null references public.incidents(id) on delete restrict,
    participation_id uuid not null,
    organization_id uuid not null,
    user_id uuid not null references public.profiles(id) on delete restrict,
    role text not null check (role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER','AGENCY_COMMANDER','OPERATOR','RESPONDER')),
    parent_assignment_id uuid,
    status text not null default 'ACTIVE' check (status in ('ACTIVE','ENDED','REVOKED')),
    valid_from timestamptz not null default statement_timestamp(),
    valid_until timestamptz,
    assigned_by uuid not null references public.profiles(id) on delete restrict,
    ended_by uuid references public.profiles(id) on delete restrict,
    ended_at timestamptz,
    end_reason text check (length(btrim(end_reason)) between 1 and 2000),
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    version bigint not null default 1 check (version > 0),
    unique (id, incident_id),
    foreign key (participation_id, incident_id, organization_id)
        references public.incident_participants(id, incident_id, organization_id) on delete restrict,
    foreign key (parent_assignment_id, incident_id)
        references public.incident_role_assignments(id, incident_id) on delete restrict,
    check (parent_assignment_id is distinct from id),
    check (role <> 'INCIDENT_COMMANDER' or parent_assignment_id is null),
    check (valid_until is null or valid_until > valid_from),
    check ((status = 'ACTIVE' and ended_by is null and ended_at is null and end_reason is null) or
        (status in ('ENDED','REVOKED') and ended_by is not null and ended_at is not null and end_reason is not null)),
    check (ended_at is null or ended_at >= valid_from)
);
-- Expired assignments must be explicitly ended before a successor is inserted.
-- NOW() cannot safely form a partial uniqueness predicate.
create unique index incident_roles_commander_unique on public.incident_role_assignments(incident_id)
    where status = 'ACTIVE' and role = 'INCIDENT_COMMANDER';
create unique index incident_roles_agency_unique on public.incident_role_assignments(incident_id, organization_id)
    where status = 'ACTIVE' and role = 'AGENCY_COMMANDER';
create unique index incident_roles_live_unique on public.incident_role_assignments(incident_id, organization_id, user_id, role)
    where status = 'ACTIVE';
create index incident_roles_user_idx on public.incident_role_assignments(user_id, incident_id) where status = 'ACTIVE';
create index incident_roles_participation_idx on public.incident_role_assignments(participation_id, incident_id, organization_id);
create index incident_roles_parent_idx on public.incident_role_assignments(parent_assignment_id, incident_id) where parent_assignment_id is not null;

create table public.incident_timeline (
    id uuid primary key default gen_random_uuid(),
    incident_id uuid not null references public.incidents(id) on delete restrict,
    sequence bigint not null check (sequence > 0),
    revision bigint not null check (revision > 0),
    operation_id uuid not null,
    event_ordinal smallint not null check (event_ordinal > 0),
    event_code text not null check (event_code ~ '^[A-Z][A-Z0-9_]{0,79}$'),
    actor_user_id uuid not null references public.profiles(id) on delete restrict,
    actor_organization_id uuid not null references public.organizations(id) on delete restrict,
    participation_id uuid,
    assignment_id uuid,
    recorded_at timestamptz not null default clock_timestamp(),
    occurred_at timestamptz,
    data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object' and octet_length(data::text) <= 16384),
    unique (incident_id, sequence),
    unique (incident_id, operation_id, event_ordinal),
    foreign key (participation_id, incident_id) references public.incident_participants(id, incident_id) on delete restrict,
    foreign key (assignment_id, incident_id) references public.incident_role_assignments(id, incident_id) on delete restrict,
    check (num_nonnulls(participation_id, assignment_id) <= 1)
);

-- No duplication of profiles, membership roles, hierarchy or positions.
-- Inherited hierarchy readers get no incident access merely through ancestry.
create function private.can_read_incident(p_incident_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
    select private.is_active_user() and exists (
        select 1 from public.incidents i
        where i.id = p_incident_id and (
            (i.status = 'DRAFT' and private.has_organization_role(i.created_organization_id,
                array['MANAGER','ADMIN']::text[]) and exists (
                    select 1 from public.organizations o where o.id = i.created_organization_id and o.active))
            or (i.status <> 'DRAFT' and exists (
                select 1 from public.incident_participants ip
                join public.organizations o on o.id = ip.organization_id and o.active
                where ip.incident_id = i.id and private.is_organization_member(ip.organization_id)
                  and (ip.status = 'ACTIVE' or (i.status in ('CLOSED','CANCELLED') and ip.status = 'RELEASED'))))
        )
    );
$$;

-- Caller-bound advisory capabilities for the specified acting organization.
-- Never a substitute for live authorization under locks at command commit.
create function private.has_incident_capability(p_incident_id uuid, p_acting_organization_id uuid, p_capability text)
returns boolean language sql stable security definer set search_path = '' as $$
    select private.can_read_incident(p_incident_id)
        and private.is_organization_member(p_acting_organization_id)
        and exists (
            select 1 from public.incident_role_assignments a
            join public.incident_participants ip on ip.id = a.participation_id and ip.status = 'ACTIVE'
            join public.organizations o on o.id = a.organization_id and o.active
            join public.incidents i on i.id = a.incident_id and i.status in ('ACTIVE','STABILIZED')
            where a.incident_id = p_incident_id and a.organization_id = p_acting_organization_id
              and a.user_id = (select auth.uid()) and a.status = 'ACTIVE'
              and (a.role <> 'INCIDENT_COMMANDER' or a.organization_id = i.lead_organization_id)
              and a.valid_from <= statement_timestamp()
              and (a.valid_until is null or a.valid_until > statement_timestamp())
              and (
                  (a.role = 'INCIDENT_COMMANDER' and p_capability in
                    ('EDIT_SUMMARY','INVITE_ORGANIZATION','ASSIGN_INCIDENT_ROLE','CHANGE_LIFECYCLE','TRANSFER_COMMAND'))
                  or (a.role = 'DEPUTY_COMMANDER' and p_capability in ('EDIT_SUMMARY','INVITE_ORGANIZATION'))
              )
        );
$$;
revoke all on function private.can_read_incident(uuid), private.has_incident_capability(uuid,uuid,text)
    from public, anon, authenticated, service_role;
grant execute on function private.can_read_incident(uuid), private.has_incident_capability(uuid,uuid,text) to authenticated;

alter table public.incident_types enable row level security;
alter table public.incidents enable row level security;
alter table public.incident_participants enable row level security;
alter table public.incident_role_assignments enable row level security;
alter table public.incident_timeline enable row level security;
revoke all on public.incident_types, public.incidents, public.incident_participants,
    public.incident_role_assignments, public.incident_timeline from public, anon, authenticated, service_role;
grant select on public.incident_types, public.incidents, public.incident_participants,
    public.incident_role_assignments, public.incident_timeline to authenticated;
create policy incident_types_read on public.incident_types for select to authenticated using ((select private.is_active_user()));
create policy incidents_read on public.incidents for select to authenticated using (private.can_read_incident(id));
create policy incident_participants_read on public.incident_participants for select to authenticated using (private.can_read_incident(incident_id));
create policy incident_roles_read on public.incident_role_assignments for select to authenticated using (private.can_read_incident(incident_id));
create policy incident_timeline_read on public.incident_timeline for select to authenticated using (private.can_read_incident(incident_id));

create trigger incident_types_no_delete before delete on public.incident_types for each row execute function private.audit_immutable();
create trigger incident_types_no_truncate before truncate on public.incident_types for each statement execute function private.audit_immutable();
create trigger incidents_no_delete before delete on public.incidents for each row execute function private.audit_immutable();
create trigger incidents_no_truncate before truncate on public.incidents for each statement execute function private.audit_immutable();
create trigger incident_participants_no_delete before delete on public.incident_participants for each row execute function private.audit_immutable();
create trigger incident_participants_no_truncate before truncate on public.incident_participants for each statement execute function private.audit_immutable();
create trigger incident_roles_no_delete before delete on public.incident_role_assignments for each row execute function private.audit_immutable();
create trigger incident_roles_no_truncate before truncate on public.incident_role_assignments for each statement execute function private.audit_immutable();
create trigger incident_timeline_no_change before update or delete on public.incident_timeline for each row execute function private.audit_immutable();
create trigger incident_timeline_no_truncate before truncate on public.incident_timeline for each statement execute function private.audit_immutable();

-- Explicit DTO rather than SELECT * as a long-lived mobile protocol.
-- Not-found and unauthorized deliberately share the same result.
create function public.incident_context(p_incident_id uuid, p_acting_organization_id uuid)
returns jsonb language sql stable security invoker set search_path = '' as $$
    select jsonb_build_object(
        'contract_version', 1, 'id', i.id, 'reference_number', i.reference_number,
        'title', i.title, 'summary', i.summary, 'incident_type_id', i.incident_type_id,
        'severity', i.severity, 'priority', i.priority, 'status', i.status,
        'lead_organization_id', i.lead_organization_id, 'created_organization_id', i.created_organization_id,
        'latitude', i.latitude, 'longitude', i.longitude, 'address', i.address,
        'timezone', i.timezone, 'version', i.version, 'revision', i.revision,
        'timeline_sequence', i.timeline_sequence, 'updated_at', i.updated_at,
        'acting_organization_id', p_acting_organization_id,
        'capabilities', coalesce((select jsonb_agg(c.code order by c.code)
            from unnest(array['EDIT_SUMMARY','INVITE_ORGANIZATION','ASSIGN_INCIDENT_ROLE','CHANGE_LIFECYCLE','TRANSFER_COMMAND']) as c(code)
            where private.has_incident_capability(i.id, p_acting_organization_id, c.code)), '[]'::jsonb))
    from public.incidents i
    where i.id = p_incident_id and private.is_organization_member(p_acting_organization_id)
        and exists (select 1 from public.organizations o where o.id = p_acting_organization_id and o.active)
        and ((i.status = 'DRAFT' and i.created_organization_id = p_acting_organization_id) or exists (
            select 1 from public.incident_participants ip where ip.incident_id = i.id
                and ip.organization_id = p_acting_organization_id
                and (ip.status = 'ACTIVE' or (i.status in ('CLOSED','CANCELLED') and ip.status = 'RELEASED'))));
$$;

create function public.incident_timeline_page(p_incident_id uuid, p_acting_organization_id uuid,
    p_after_sequence bigint default 0, p_limit integer default 100)
returns jsonb language sql stable security invoker set search_path = '' as $$
    select case when public.incident_context(p_incident_id, p_acting_organization_id) is null then null else
        jsonb_build_object('contract_version', 1, 'incident_id', p_incident_id,
            'events', coalesce((select jsonb_agg(e.dto order by e.sequence) from (
                select t.sequence, jsonb_build_object('id',t.id,'sequence',t.sequence,'revision',t.revision,
                    'operation_id',t.operation_id,'event_ordinal',t.event_ordinal,'event_code',t.event_code,
                    'actor_user_id',t.actor_user_id,'actor_organization_id',t.actor_organization_id,
                    'participation_id',t.participation_id,'assignment_id',t.assignment_id,
                    'recorded_at',t.recorded_at,'occurred_at',t.occurred_at,'data',t.data) as dto
                from public.incident_timeline t where t.incident_id = p_incident_id
                    and t.sequence > greatest(coalesce(p_after_sequence,0),0)
                order by t.sequence limit least(greatest(coalesce(p_limit,100),1),200)
            ) e), '[]'::jsonb),
            'high_watermark', (select i.timeline_sequence from public.incidents i where i.id = p_incident_id)) end;
$$;
revoke all on function public.incident_context(uuid,uuid), public.incident_timeline_page(uuid,uuid,bigint,integer)
    from public, anon, authenticated, service_role;
grant execute on function public.incident_context(uuid,uuid), public.incident_timeline_page(uuid,uuid,bigint,integer) to authenticated;

comment on table public.incidents is 'M14.0 aggregate foundation; no public mutation API until M14.1. See docs/SPEC-M14-INCIDENT-OPERATIONS.md.';
comment on table public.incident_role_assignments is 'Incident authority is explicit and caller/org scoped, never inherited from organization hierarchy or position. Sector/unit scopes arrive with their FK-backed entities.';
comment on table public.incident_timeline is 'Append-only operational evidence, separate from audit_log and notification_events. Sequence allocated under incident row lock by future trusted commands.';
