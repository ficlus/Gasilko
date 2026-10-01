-- M8.1. Configuration is maintained by trusted database operators, not the Web runtime.
-- Geographic administrative_areas remain geography; this graph relates organizations.
create table public.organization_types (
    id uuid primary key default gen_random_uuid(),
    country_id uuid references public.countries(id) on delete restrict,
    code text not null check (code ~ '^[A-Z][A-Z0-9_]*$'),
    names jsonb not null check (jsonb_typeof(names)='object' and names <> '{}'::jsonb),
    display_order integer not null default 0,
    legacy_type text not null check (legacy_type in ('MUNICIPALITY','FIRE_DEPARTMENT','WATER_UTILITY','OTHER')),
    active boolean not null default true,
    system_managed boolean not null default true
);
create unique index organization_types_scope_code on public.organization_types
    (coalesce(country_id,'00000000-0000-0000-0000-000000000000'::uuid),code);

-- Preserve the legacy type contract used by existing onboarding and Android.
insert into public.organization_types(code,names,legacy_type) values
    ('MUNICIPALITY','{"sl":"Občina","de":"Gemeinde"}','MUNICIPALITY'),
    ('FIRE_DEPARTMENT','{"sl":"Gasilska organizacija","de":"Feuerwehrorganisation"}','FIRE_DEPARTMENT'),
    ('WATER_UTILITY','{"sl":"Vodovodno podjetje","de":"Wasserversorger"}','WATER_UTILITY'),
    ('OTHER','{"sl":"Druga organizacija","de":"Andere Organisation"}','OTHER');
alter table public.organizations add column organization_type_id uuid references public.organization_types(id) on delete restrict;
update public.organizations o set organization_type_id=t.id from public.organization_types t
    where t.country_id is null and t.code=o.type;
alter table public.organizations alter column organization_type_id set not null;
create index organizations_configured_type_idx on public.organizations(organization_type_id);

create table public.organization_relationship_types (
    code text primary key check (code ~ '^[A-Z][A-Z0-9_]*$'),
    names jsonb not null check (jsonb_typeof(names)='object' and names <> '{}'::jsonb),
    inherits_read boolean not null default false,
    hierarchical boolean not null default false,
    path_priority integer not null default 100,
    active boolean not null default true,
    check (not inherits_read or hierarchical)
);
create table public.organization_type_relationship_rules (
    id uuid primary key default gen_random_uuid(),
    parent_type_id uuid not null references public.organization_types(id) on delete restrict,
    child_type_id uuid not null references public.organization_types(id) on delete restrict,
    relationship_type text not null references public.organization_relationship_types(code) on delete restrict,
    active boolean not null default true,
    unique(parent_type_id,child_type_id,relationship_type)
);
create table public.organization_relationships (
    id uuid primary key default gen_random_uuid(),
    parent_organization_id uuid not null references public.organizations(id) on delete restrict,
    child_organization_id uuid not null references public.organizations(id) on delete restrict,
    relationship_type text not null references public.organization_relationship_types(code) on delete restrict,
    valid_from timestamptz not null default statement_timestamp(),
    valid_to timestamptz,
    active boolean not null default true,
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    check (parent_organization_id <> child_organization_id),
    check (valid_to is null or valid_to > valid_from)
);
-- Close/deactivate the previous relationship before recording its successor.
create unique index organization_relationships_one_active on public.organization_relationships
    (parent_organization_id,child_organization_id,relationship_type) where active;
create index organization_relationships_child_idx on public.organization_relationships(child_organization_id,relationship_type) where active;
create index organization_relationships_kind_idx on public.organization_relationships(relationship_type) where active;

create table public.organization_positions (
    id uuid primary key default gen_random_uuid(),
    country_id uuid references public.countries(id) on delete restrict,
    organization_type_id uuid references public.organization_types(id) on delete restrict,
    code text not null check (code ~ '^[A-Z][A-Z0-9_]*$'),
    names jsonb not null check (jsonb_typeof(names)='object' and names <> '{}'::jsonb),
    classification text not null check (classification in ('ORGANIZATIONAL','OPERATIONAL')),
    suggested_role text check (suggested_role in ('FIREFIGHTER','MANAGER','ADMIN')),
    active boolean not null default true,
    system_managed boolean not null default true
);
create unique index organization_positions_scope_code on public.organization_positions
    (coalesce(country_id,'00000000-0000-0000-0000-000000000000'::uuid),
     coalesce(organization_type_id,'00000000-0000-0000-0000-000000000000'::uuid),code);
create table public.organization_member_positions (
    id uuid primary key default gen_random_uuid(),
    organization_id uuid not null references public.organizations(id) on delete restrict,
    user_id uuid not null references public.profiles(id) on delete restrict,
    position_id uuid not null references public.organization_positions(id) on delete restrict,
    valid_from timestamptz not null default statement_timestamp(),
    valid_to timestamptz,
    active boolean not null default true,
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    check (valid_to is null or valid_to > valid_from)
);
-- Membership existence is checked on assignment and on reads, rather than an FK
-- that would prevent the established M1 membership-removal flow and lose history.
create unique index organization_member_positions_one_active on public.organization_member_positions
    (organization_id,user_id,position_id) where active;
create index organization_member_positions_user_idx on public.organization_member_positions(user_id,organization_id);
create index organization_member_positions_position_idx on public.organization_member_positions(position_id);

-- Actual row writes serialize graph/config changes, including stale RR/serializable
-- transactions. An advisory lock alone would not invalidate their old snapshots.
create table private.organization_structure_lock (id boolean primary key check (id), revision bigint not null default 0);
insert into private.organization_structure_lock(id) values(true);
revoke all on private.organization_structure_lock from public,anon,authenticated,service_role;
create function private.lock_organization_structure() returns trigger
language plpgsql security definer set search_path='' as $$
begin
    update private.organization_structure_lock set revision=revision+1 where id;
    return new;
end;
$$;
revoke all on function private.lock_organization_structure() from public,anon,authenticated,service_role;

create function private.organization_graph_has_cycle(kind text) returns boolean
language sql volatile security definer set search_path='' as $$
    with recursive reach(origin,node) as (
        select parent_organization_id,child_organization_id from public.organization_relationships
        where relationship_type=kind and active
        union
        select w.origin,r.child_organization_id from reach w join public.organization_relationships r
            on r.parent_organization_id=w.node where r.relationship_type=kind and r.active
    ) select exists(select 1 from reach where origin=node);
$$;
revoke all on function private.organization_graph_has_cycle(text) from public,anon,authenticated,service_role;
create function private.validate_organization_graph() returns trigger
language plpgsql security definer set search_path='' as $$
declare kind text; hierarchical boolean;
begin
    if tg_table_name='organization_relationship_types' then
        kind:=new.code; hierarchical:=new.hierarchical;
    else
        kind:=new.relationship_type;
        select t.hierarchical into hierarchical from public.organization_relationship_types t where t.code=kind;
    end if;
    -- Validate all active edges, including scheduled edges, not only today's graph.
    if hierarchical and private.organization_graph_has_cycle(kind) then
        raise exception 'Organization relationship cycle' using errcode='23514';
    end if;
    return new;
end;
$$;
revoke all on function private.validate_organization_graph() from public,anon,authenticated,service_role;
create trigger organization_graph_cycle after insert or update on public.organization_relationships
    for each row execute function private.validate_organization_graph();
create trigger organization_graph_kind_cycle after insert or update on public.organization_relationship_types
    for each row execute function private.validate_organization_graph();

create function private.validate_organization_template_scope() returns trigger
language plpgsql security definer set search_path='' as $$
declare parent_country uuid; child_country uuid;
begin
    if tg_table_name='organization_type_relationship_rules' then
        select country_id into parent_country from public.organization_types where id=new.parent_type_id;
        select country_id into child_country from public.organization_types where id=new.child_type_id;
        if parent_country is not null and child_country is not null and parent_country<>child_country then
            raise exception 'Organization template countries differ' using errcode='23514';
        end if;
    elsif tg_table_name='organization_positions' then
        if new.organization_type_id is not null then
            select country_id into parent_country from public.organization_types where id=new.organization_type_id;
            if new.country_id is distinct from parent_country then
                raise exception 'Position and organization type scopes differ' using errcode='23514';
            end if;
        end if;
    end if;
    if tg_op='UPDATE' then
        if tg_table_name in ('organization_types','organization_positions') and
            ((to_jsonb(new)->'country_id') is distinct from (to_jsonb(old)->'country_id') or
             (to_jsonb(new)->'code') is distinct from (to_jsonb(old)->'code') or
             (to_jsonb(new)->'legacy_type') is distinct from (to_jsonb(old)->'legacy_type') or
             (to_jsonb(new)->'organization_type_id') is distinct from (to_jsonb(old)->'organization_type_id')) then
            raise exception 'Template identity/scope is immutable; deactivate and add a definition' using errcode='23514';
        end if;
        if tg_table_name='organization_type_relationship_rules' then
            if new.parent_type_id<>old.parent_type_id or new.child_type_id<>old.child_type_id or new.relationship_type<>old.relationship_type then
                raise exception 'Rule identity is immutable' using errcode='23514';
            end if;
        end if;
    end if;
    return new;
end;
$$;
revoke all on function private.validate_organization_template_scope() from public,anon,authenticated,service_role;
create trigger organization_types_scope before insert or update on public.organization_types
    for each row execute function private.validate_organization_template_scope();
create trigger organization_positions_scope before insert or update on public.organization_positions
    for each row execute function private.validate_organization_template_scope();
create trigger organization_rules_scope before insert or update on public.organization_type_relationship_rules
    for each row execute function private.validate_organization_template_scope();

create function private.validate_organization_relationship() returns trigger
language plpgsql security definer set search_path='' as $$
begin
    if exists (
        select 1 from public.organizations p join public.organizations c on c.id=new.child_organization_id
        join public.organization_types pt on pt.id=p.organization_type_id
        join public.organization_types ct on ct.id=c.organization_type_id
        left join public.administrative_areas pa on pa.id=p.administrative_area_id
        left join public.administrative_areas ca on ca.id=c.administrative_area_id
        where p.id=new.parent_organization_id and coalesce(pt.country_id,pa.country_id)<>coalesce(ct.country_id,ca.country_id)
    ) then raise exception 'Organization relationship countries differ' using errcode='23514'; end if;
    if new.active and not exists (
        select 1 from public.organizations p join public.organizations c on c.id=new.child_organization_id
        join public.organization_type_relationship_rules r on r.parent_type_id=p.organization_type_id
            and r.child_type_id=c.organization_type_id and r.relationship_type=new.relationship_type and r.active
        join public.organization_relationship_types rt on rt.code=r.relationship_type and rt.active
        where p.id=new.parent_organization_id
    ) then raise exception 'Organization relationship not allowed by template' using errcode='23514'; end if;
    return new;
end;
$$;
revoke all on function private.validate_organization_relationship() from public,anon,authenticated,service_role;
create trigger organization_relationship_validate before insert or update on public.organization_relationships
    for each row execute function private.validate_organization_relationship();

create function private.validate_configured_organization() returns trigger
language plpgsql security definer set search_path='' as $$
declare t public.organization_types; area_country uuid;
begin
    update private.organization_structure_lock set revision=revision+1 where id;
    if new.organization_type_id is null then
        select id into new.organization_type_id from public.organization_types where country_id is null and code=new.type;
    elsif tg_op='UPDATE' and new.type<>old.type and new.organization_type_id=old.organization_type_id
        and exists(select 1 from public.organization_types where id=old.organization_type_id and country_id is null and code=old.type) then
        select id into new.organization_type_id from public.organization_types where country_id is null and code=new.type;
    end if;
    select * into t from public.organization_types where id=new.organization_type_id;
    select country_id into area_country from public.administrative_areas where id=new.administrative_area_id;
    if t.id is null or t.legacy_type<>new.type or (t.country_id is not null and area_country is not null and t.country_id<>area_country) then
        raise exception 'Organization type/scope mismatch' using errcode='23514';
    end if;
    if exists (
        select 1 from public.organization_relationships e
        join public.organizations p on p.id=e.parent_organization_id
        join public.organizations c on c.id=e.child_organization_id
        where e.active and (p.id=new.id or c.id=new.id) and not exists (
            select 1 from public.organization_type_relationship_rules r where r.active and r.relationship_type=e.relationship_type
                and r.parent_type_id=case when p.id=new.id then new.organization_type_id else p.organization_type_id end
                and r.child_type_id=case when c.id=new.id then new.organization_type_id else c.organization_type_id end
        )
    ) then raise exception 'Close incompatible relationships before changing organization type' using errcode='23514'; end if;
    return new;
end;
$$;
revoke all on function private.validate_configured_organization() from public,anon,authenticated,service_role;
create trigger organizations_configured_type before insert or update of type,organization_type_id,administrative_area_id on public.organizations
    for each row execute function private.validate_configured_organization();

create function private.validate_position_assignment() returns trigger
language plpgsql security definer set search_path='' as $$
begin
    perform private.lock_organization(new.organization_id);
    if tg_op='UPDATE' and (new.organization_id<>old.organization_id or new.user_id<>old.user_id or new.position_id<>old.position_id) then
        raise exception 'Position assignment identity is immutable' using errcode='23514';
    end if;
    if new.active and not exists (
        select 1 from public.user_organizations m join public.profiles u on u.id=m.user_id and u.account_status='ACTIVE'
        join public.organizations o on o.id=m.organization_id and o.active
        join public.organization_types t on t.id=o.organization_type_id
        left join public.administrative_areas a on a.id=o.administrative_area_id
        join public.organization_positions p on p.id=new.position_id and p.active
        where m.user_id=new.user_id and m.organization_id=new.organization_id
            and (p.organization_type_id is null or p.organization_type_id=o.organization_type_id)
            and (p.country_id is null or p.country_id=coalesce(t.country_id,a.country_id))
    ) then raise exception 'Position requires an active membership in the matching organization scope' using errcode='23514'; end if;
    return new;
end;
$$;
revoke all on function private.validate_position_assignment() from public,anon,authenticated,service_role;
create trigger member_position_validate before insert or update on public.organization_member_positions
    for each row execute function private.validate_position_assignment();

-- Authoritative read graph. Every hop requires an enabled read-inheriting type,
-- enabled type rule, live interval, and active organizations/country templates.
create function private.organization_read_edges()
returns table(parent_id uuid,child_id uuid,relationship_type text,path_priority integer)
language sql stable security definer set search_path='' as $$
    select p.id,c.id,e.relationship_type,rt.path_priority
    from public.organization_relationships e
    join public.organization_relationship_types rt on rt.code=e.relationship_type and rt.active and rt.inherits_read
    join public.organizations p on p.id=e.parent_organization_id and p.active
    join public.organizations c on c.id=e.child_organization_id and c.active
    join public.organization_types pt on pt.id=p.organization_type_id and pt.active
    join public.organization_types ct on ct.id=c.organization_type_id and ct.active
    join public.organization_type_relationship_rules r on r.parent_type_id=pt.id and r.child_type_id=ct.id
        and r.relationship_type=rt.code and r.active
    where e.active and e.valid_from<=statement_timestamp() and (e.valid_to is null or e.valid_to>statement_timestamp())
        and (pt.country_id is null or exists(select 1 from public.countries where id=pt.country_id and active))
        and (ct.country_id is null or exists(select 1 from public.countries where id=ct.country_id and active));
$$;
revoke all on function private.organization_read_edges() from public,anon,authenticated,service_role;

create function private.web_admin_scope()
returns table(organization_id uuid,direct_role text,effective_access text)
language sql stable security definer set search_path='' as $$
    with recursive accessible(id) as (
        select m.organization_id from public.user_organizations m
        join public.profiles p on p.id=m.user_id and p.account_status='ACTIVE'
        join public.organizations o on o.id=m.organization_id and o.active
        where m.user_id=(select auth.uid()) and m.role in ('ADMIN','MANAGER')
        union
        select e.child_id from accessible a join private.organization_read_edges() e on e.parent_id=a.id
    )
    select a.id,m.role,case when m.role in ('ADMIN','MANAGER') then m.role else 'READ_ONLY' end
    from accessible a left join public.user_organizations m on m.organization_id=a.id and m.user_id=(select auth.uid());
$$;
revoke all on function private.web_admin_scope() from public,anon,authenticated,service_role;

create function private.can_read_organization(org uuid) returns boolean
language sql stable security definer set search_path='' as $$
    select (exists(select 1 from public.organizations where id=org and active) and private.is_organization_member(org))
        or exists(select 1 from private.web_admin_scope() where organization_id=org);
$$;
create function private.can_manage_organization(org uuid) returns boolean
language sql stable security definer set search_path='' as $$
    select exists(select 1 from public.organizations where id=org and active)
        and private.has_organization_role(org,array['MANAGER','ADMIN']::text[]);
$$;
revoke all on function private.can_read_organization(uuid),private.can_manage_organization(uuid) from public,anon,authenticated,service_role;
grant execute on function private.can_read_organization(uuid),private.can_manage_organization(uuid) to authenticated;
-- Do not replace is_organization_member/has_organization_role: existing mutation
-- RPCs depend on their EXACT membership semantics. Domain RLS adoption is M8.2+.
create policy organizations_inherited_read on public.organizations for select to authenticated
    using (private.can_read_organization(id));

create function private.audit_organization_configuration() returns trigger
language plpgsql security definer set search_path='' as $$
declare before_data jsonb; after_data jsonb:=to_jsonb(new); org uuid; actor uuid;
begin
    if tg_op='UPDATE' then before_data:=to_jsonb(old); if before_data=after_data then return new; end if; end if;
    actor:=coalesce(auth.uid(),nullif(current_setting('gasilko.audit_actor',true),'')::uuid,'00000000-0000-0000-0000-000000000000'::uuid);
    org:=coalesce((after_data->>'organization_id')::uuid,(after_data->>'parent_organization_id')::uuid);
    if tg_table_name='organizations' then org:=new.id; end if;
    perform private.write_audit(org,actor,'ORGANIZATION_CONFIGURATION_'||tg_op,tg_table_name,
        (after_data->>'id')::uuid,before_data,after_data||jsonb_build_object('database_principal',session_user));
    return new;
end;
$$;
revoke all on function private.audit_organization_configuration() from public,anon,authenticated,service_role;
create trigger organizations_type_audit after update of organization_type_id on public.organizations
    for each row when (old.organization_type_id is distinct from new.organization_type_id)
    execute function private.audit_organization_configuration();

do $$
declare tab text;
begin
    foreach tab in array array['organization_types','organization_relationship_types','organization_type_relationship_rules',
        'organization_relationships','organization_positions','organization_member_positions'] loop
        execute format('alter table public.%I enable row level security',tab);
        execute format('revoke all on public.%I from public,anon,authenticated,service_role',tab);
        execute format('grant select on public.%I to authenticated',tab);
        execute format('grant select,insert,update on public.%I to service_role',tab);
        execute format('create trigger a_structure_lock before insert or update on public.%I for each row execute function private.lock_organization_structure()',tab);
        execute format('create trigger configuration_audit after insert or update on public.%I for each row execute function private.audit_organization_configuration()',tab);
        execute format('create trigger configuration_no_delete before delete on public.%I for each row execute function private.audit_immutable()',tab);
        execute format('create trigger configuration_no_truncate before truncate on public.%I for each statement execute function private.audit_immutable()',tab);
    end loop;
    foreach tab in array array['organization_types','organization_relationship_types','organization_type_relationship_rules','organization_positions'] loop
        execute format('create policy configuration_authenticated_read on public.%I for select to authenticated using ((select auth.uid()) is not null)',tab);
    end loop;
    foreach tab in array array['organization_relationships','organization_member_positions'] loop
        execute format('create trigger maintain_timestamps before insert or update on public.%I for each row execute function public.maintain_record_timestamps()',tab);
    end loop;
end;
$$;
create policy organization_relationship_read on public.organization_relationships for select to authenticated using (
    private.can_read_organization(parent_organization_id) and private.can_read_organization(child_organization_id));
create policy organization_member_positions_read on public.organization_member_positions for select to authenticated using (
    private.can_manage_organization(organization_id) or
    (user_id=(select auth.uid()) and private.can_read_organization(organization_id)));

-- Country templates are data. No existing organization is guessed to be a PGD,
-- PIGD or federation, and no live hierarchy or membership is invented/backfilled.
insert into public.countries(code,name) values('SI','Slovenija') on conflict(code) do nothing;
insert into public.organization_types(country_id,code,names,display_order,legacy_type)
select c.id,v.code,jsonb_build_object('sl',v.sl,'de',v.de),v.ord,'FIRE_DEPARTMENT'
from public.countries c cross join (values
    ('NATIONAL','Gasilska zveza Slovenije (GZS)','Slowenischer Feuerwehrverband (GZS)',0),
    ('REGION','Gasilska regija','Feuerwehrregion',1),
    ('UNION','Gasilska zveza (GZ)','Feuerwehrverband (GZ)',2),
    ('VOLUNTEER_BRIGADE','Prostovoljno gasilsko društvo (PGD)','Freiwillige Feuerwehr (PGD)',3),
    ('INDUSTRIAL_BRIGADE','Prostovoljno industrijsko gasilsko društvo (PIGD)','Freiwillige Betriebsfeuerwehr (PIGD)',3)
) v(code,sl,de,ord) where c.code='SI';
insert into public.organization_relationship_types(code,names,inherits_read,hierarchical,path_priority) values
    ('ADMINISTRATIVE','{"sl":"Upravna povezava","de":"Verwaltungsbeziehung"}',true,true,0),
    ('OPERATIONAL','{"sl":"Operativna povezava","de":"Operative Beziehung"}',false,true,10),
    ('MEMBER_OF','{"sl":"Članstvo","de":"Mitgliedschaft"}',false,true,20),
    ('SUPERVISES','{"sl":"Nadzor","de":"Aufsicht"}',false,true,30),
    ('MUTUAL_AID','{"sl":"Medsebojna pomoč","de":"Gegenseitige Hilfe"}',false,false,40);
insert into public.organization_type_relationship_rules(parent_type_id,child_type_id,relationship_type)
select p.id,c.id,'ADMINISTRATIVE' from (values
    ('NATIONAL','REGION'),('REGION','UNION'),('UNION','VOLUNTEER_BRIGADE'),('UNION','INDUSTRIAL_BRIGADE')
) v(parent_code,child_code)
join public.countries country on country.code='SI'
join public.organization_types p on p.country_id=country.id and p.code=v.parent_code
join public.organization_types c on c.country_id=country.id and c.code=v.child_code;

insert into public.organization_positions(country_id,organization_type_id,code,names,classification)
select t.country_id,t.id,v.code,jsonb_build_object('sl',v.sl,'de',v.de),v.classification
from public.organization_types t join public.countries c on c.id=t.country_id and c.code='SI'
cross join (values
    ('PRESIDENT','Predsednik','Präsident','ORGANIZATIONAL'),
    ('VICE_PRESIDENT','Podpredsednik','Vizepräsident','ORGANIZATIONAL'),
    ('COMMANDER','Poveljnik','Kommandant','OPERATIONAL'),
    ('DEPUTY_COMMANDER','Namestnik poveljnika','Stellvertreter des Kommandanten','OPERATIONAL'),
    ('ASSISTANT_COMMANDER','Podpoveljnik','Unterkommandant','OPERATIONAL'),
    ('SECRETARY','Tajnik','Schriftführer','ORGANIZATIONAL'),
    ('TREASURER','Blagajnik','Kassier','ORGANIZATIONAL')
) v(code,sl,de,classification) where t.code in ('VOLUNTEER_BRIGADE','INDUSTRIAL_BRIGADE');
insert into public.organization_positions(country_id,organization_type_id,code,names,classification)
select t.country_id,t.id,v.code,jsonb_build_object('sl',v.sl,'de',v.de),v.classification
from public.organization_types t join public.countries c on c.id=t.country_id and c.code='SI'
join (values
    ('UNION','PRESIDENT','Predsednik GZ','Verbandspräsident','ORGANIZATIONAL'),
    ('UNION','VICE_PRESIDENT','Podpredsednik GZ','Vizepräsident des Verbandes','ORGANIZATIONAL'),
    ('UNION','COMMANDER','Poveljnik GZ','Verbandskommandant','OPERATIONAL'),
    ('UNION','DEPUTY_COMMANDER','Namestnik poveljnika GZ','Stellvertretender Verbandskommandant','OPERATIONAL'),
    ('REGION','PRESIDENT','Predsednik regijskega sveta','Präsident des Regionalrates','ORGANIZATIONAL'),
    ('REGION','VICE_PRESIDENT','Namestnik predsednika regijskega sveta','Stellvertretender Präsident des Regionalrates','ORGANIZATIONAL'),
    ('REGION','COMMANDER','Regijski poveljnik','Regionalkommandant','OPERATIONAL'),
    ('REGION','DEPUTY_COMMANDER','Namestnik regijskega poveljnika','Stellvertretender Regionalkommandant','OPERATIONAL'),
    ('NATIONAL','PRESIDENT','Predsednik GZS','Präsident des GZS','ORGANIZATIONAL'),
    ('NATIONAL','VICE_PRESIDENT','Podpredsednik GZS','Vizepräsident des GZS','ORGANIZATIONAL'),
    ('NATIONAL','COMMANDER','Poveljnik GZS','Kommandant des GZS','OPERATIONAL'),
    ('NATIONAL','DEPUTY_COMMANDER','Namestnik poveljnika GZS','Stellvertretender Kommandant des GZS','OPERATIONAL')
) v(kind,code,sl,de,classification) on v.kind=t.code;

create function public.web_admin_context(organization uuid default null) returns jsonb
language sql stable security definer set search_path='' as $$
    with recursive scope as materialized (select * from private.web_admin_scope()),
    selected as (
        select o.id from public.organizations o join scope s on s.organization_id=o.id
        where organization is null or o.id=organization
        order by (s.effective_access='READ_ONLY'),o.name,o.id limit 1
    ),
    -- Breadcrumbs expose only authorized ancestors. Priority comes from configuration;
    -- UUID tie breaks are deterministic. A visited path also bounds mixed-graph cycles.
    ancestry(id,path) as (
        select id,array[id] from selected
        union all
        select parent.parent_id,array_prepend(parent.parent_id,a.path) from ancestry a
        cross join lateral (
            select e.parent_id from private.organization_read_edges() e join scope s on s.organization_id=e.parent_id
            where e.child_id=a.id and not e.parent_id=any(a.path)
            order by e.path_priority,e.relationship_type,e.parent_id limit 1
        ) parent
    ),
    primary_path as (select path from ancestry order by cardinality(path) desc,path limit 1)
    select jsonb_build_object(
        'organizations',coalesce((select jsonb_agg(jsonb_build_object(
            'id',o.id,'name',o.name,'code',o.code,'type',jsonb_build_object('code',t.code,'names',t.names),
            'directRole',s.direct_role,'access',s.effective_access)
            order by (s.effective_access='READ_ONLY'),o.name,o.id)
            from scope s join public.organizations o on o.id=s.organization_id
            join public.organization_types t on t.id=o.organization_type_id),'[]'::jsonb),
        'selected',(select id from selected),
        'path',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'name',o.name) order by ids.ord)
            from primary_path p cross join lateral unnest(p.path) with ordinality ids(id,ord)
            join public.organizations o on o.id=ids.id),'[]'::jsonb),
        'positions',coalesce((select jsonb_agg(jsonb_build_object('code',p.code,'names',p.names) order by p.code,p.id)
            from public.organization_member_positions mp join public.organization_positions p on p.id=mp.position_id and p.active
            join public.user_organizations m on m.organization_id=mp.organization_id and m.user_id=mp.user_id
            join public.organizations o on o.id=m.organization_id
            join public.organization_types t on t.id=o.organization_type_id
            left join public.administrative_areas a on a.id=o.administrative_area_id
            where mp.organization_id=(select id from selected) and mp.user_id=(select auth.uid()) and mp.active
                and mp.valid_from<=statement_timestamp() and (mp.valid_to is null or mp.valid_to>statement_timestamp())
                and (p.organization_type_id is null or p.organization_type_id=o.organization_type_id)
                and (p.country_id is null or p.country_id=coalesce(t.country_id,a.country_id))),'[]'::jsonb)
    );
$$;
revoke all on function public.web_admin_context(uuid) from public,anon,authenticated,service_role;
grant execute on function public.web_admin_context(uuid) to authenticated;

-- Scope before pagination; filtering the old cross-organization 50-row result
-- in the browser could hide valid requests. The existing review mutation is reused.
create function public.list_organization_access_reviews(organization uuid,after_id uuid default null)
returns table(id uuid,requester_name text,organization_id uuid,organization_name text,requested_role text,requested_at timestamptz,status text)
language sql stable security definer set search_path='' as $$
    select r.id,p.display_name,r.organization_id,o.name,r.requested_role,r.requested_at,r.status
    from public.organization_access_requests r join public.profiles p on p.id=r.user_id
    join public.organizations o on o.id=r.organization_id
    where r.organization_id=organization and o.active and r.status='PENDING' and (after_id is null or r.id>after_id)
        and (private.has_organization_role(organization,array['ADMIN']::text[]) or
            (r.requested_role='FIREFIGHTER' and private.has_organization_role(organization,array['MANAGER']::text[])))
    order by r.id limit 50;
$$;
revoke all on function public.list_organization_access_reviews(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.list_organization_access_reviews(uuid,uuid) to authenticated;

-- Explicit ownership preserves the private definer/RLS recursion boundary.
do $$
declare fn regprocedure;
begin
    for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where (n.nspname='private' and p.proname in (
            'lock_organization_structure','organization_graph_has_cycle','validate_organization_graph',
            'validate_organization_template_scope','validate_organization_relationship','validate_configured_organization',
            'validate_position_assignment','organization_read_edges','web_admin_scope','can_read_organization',
            'can_manage_organization','audit_organization_configuration'))
        or (n.nspname='public' and p.proname in ('web_admin_context','list_organization_access_reviews')) loop
        execute format('alter function %s owner to postgres',fn);
    end loop;
end;
$$;

comment on column public.organization_positions.suggested_role is 'UI suggestion only. Positions never participate in authorization.';
comment on function private.can_manage_organization(uuid) is 'Exact active organization membership only; never inherits permissions from the graph.';
comment on function private.can_read_organization(uuid) is 'Direct active membership or configured inherited read from an active MANAGER/ADMIN ancestor. Opt-in primitive for future domain RLS.';
