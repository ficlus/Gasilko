-- M14.6A: definitions are not live incidents. Apply manually after H2.
begin;
create table public.simulation_scenario_templates (
 id uuid primary key, organization_id uuid references public.organizations(id),
 code text unique, revision bigint not null default 1 check(revision>0),
 archived boolean not null default false, created_by uuid references public.profiles(id),
 created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 check((organization_id is null and code is not null and created_by is null) or
       (organization_id is not null and code is null and created_by is not null))
);
create table public.simulation_scenario_template_versions (
 id uuid primary key, template_id uuid not null references public.simulation_scenario_templates(id),
 version integer not null check(version>0), state text not null check(state in ('DRAFT','PUBLISHED')),
 schema_version integer not null default 1 check(schema_version=1),
 definition jsonb not null check(octet_length(definition::text)<=48000),
 created_by uuid references public.profiles(id), created_at timestamptz not null default clock_timestamp(),
 published_at timestamptz, unique(template_id,version),
 check((state='PUBLISHED')=(published_at is not null))
);
create unique index simulation_template_one_draft on public.simulation_scenario_template_versions(template_id) where state='DRAFT';
create index simulation_template_org_page on public.simulation_scenario_templates(organization_id,id);
create table private.simulation_template_receipts (
 operation_id uuid primary key, actor uuid not null references public.profiles(id),
 organization_id uuid not null references public.organizations(id), request jsonb not null,
 result jsonb not null, created_at timestamptz not null default clock_timestamp()
);
create table private.simulation_template_instances (
 scenario_id uuid primary key references public.simulation_scenarios(id),
 source_version_id uuid not null references public.simulation_scenario_template_versions(id),
 definition jsonb not null, organization_id uuid not null references public.organizations(id),
 created_by uuid not null references public.profiles(id), created_at timestamptz not null default clock_timestamp(),
 state text not null default 'WAITING_COMMAND' check(state in ('WAITING_COMMAND','INITIALIZING','READY')),
 object_ids jsonb not null default '{}', unit_ids jsonb not null default '{}', initialized_at timestamptz
);
alter table public.simulation_scenario_templates enable row level security;
alter table public.simulation_scenario_template_versions enable row level security;
alter table private.simulation_template_receipts enable row level security;
alter table private.simulation_template_instances enable row level security;
revoke all on public.simulation_scenario_templates,public.simulation_scenario_template_versions,
 private.simulation_template_receipts,private.simulation_template_instances from public,anon,authenticated,service_role;

create function private.simulation_template_immutable() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'INVALID_TRANSITION'; end if;
 if tg_table_name='simulation_scenario_template_versions' then
  if old.state='PUBLISHED' or (new.id,new.template_id,new.version,new.schema_version,new.created_by,new.created_at)
   is distinct from (old.id,old.template_id,old.version,old.schema_version,old.created_by,old.created_at)
   then raise exception 'INVALID_TRANSITION'; end if;
 elsif tg_table_name='simulation_template_instances' then
  if (new.scenario_id,new.source_version_id,new.definition,new.organization_id,new.created_by,new.created_at)
   is distinct from (old.scenario_id,old.source_version_id,old.definition,old.organization_id,old.created_by,old.created_at)
   or not(old.state='WAITING_COMMAND' and new.state='INITIALIZING' or old.state='INITIALIZING' and new.state='READY') then raise exception 'INVALID_TRANSITION'; end if;
 else
  if old.organization_id is null or (new.id,new.organization_id,new.code,new.created_by,new.created_at)
   is distinct from (old.id,old.organization_id,old.code,old.created_by,old.created_at)
   then raise exception 'INVALID_TRANSITION'; end if;
 end if;
 return new;
end; $$;
create trigger simulation_template_history before update or delete on public.simulation_scenario_templates for each row execute function private.simulation_template_immutable();
create trigger simulation_template_version_history before update or delete on public.simulation_scenario_template_versions for each row execute function private.simulation_template_immutable();
create trigger simulation_template_instance_history before update or delete on private.simulation_template_instances for each row execute function private.simulation_template_immutable();

-- Exact object keys, including required fields. There is no opaque executable extension bag.
create function private.simulation_template_provenance_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.simulation_scenarios s
  join public.simulation_scenario_template_versions v on v.id=new.source_version_id
  join public.simulation_scenario_templates t on t.id=v.template_id
  where s.id=new.scenario_id and s.organization_id=new.organization_id and s.created_by=new.created_by
  and s.status='DRAFT' and t.organization_id=new.organization_id and not t.archived
  and v.definition=new.definition) then raise exception 'VALIDATION_FAILED';end if;
 return new;
end; $$;
create trigger simulation_template_provenance_scope before insert on private.simulation_template_instances for each row execute function private.simulation_template_provenance_guard();
create trigger simulation_template_receipts_immutable before update or delete on private.simulation_template_receipts for each row execute function private.audit_immutable();
create trigger simulation_templates_no_truncate before truncate on public.simulation_scenario_templates for each statement execute function private.audit_immutable();
create trigger simulation_template_versions_no_truncate before truncate on public.simulation_scenario_template_versions for each statement execute function private.audit_immutable();
create trigger simulation_template_instances_no_truncate before truncate on private.simulation_template_instances for each statement execute function private.audit_immutable();
create trigger simulation_template_receipts_no_truncate before truncate on private.simulation_template_receipts for each statement execute function private.audit_immutable();

create function private.sim_template_keys(v jsonb,keys text[]) returns void
language plpgsql immutable set search_path='' as $$
begin
 if jsonb_typeof(v) is distinct from 'object' or not(v ?& keys)
 or exists(select 1 from jsonb_object_keys(v) k where not(k=any(keys))) then raise exception 'VALIDATION_FAILED'; end if;
end; $$;
create function private.sim_template_text(v jsonb,max_length integer,required boolean default false) returns void
language plpgsql immutable set search_path='' as $$
begin
 if jsonb_typeof(v) is distinct from 'string' or length(v#>>'{}')>max_length
 or (required and length(btrim(v#>>'{}'))=0) then raise exception 'VALIDATION_FAILED'; end if;
end; $$;
create function private.sim_template_position(v jsonb,ready boolean) returns void
language plpgsql immutable set search_path='' as $$
begin
 if v='null'::jsonb and not ready then return; end if;
 if jsonb_typeof(v) is distinct from 'array' or jsonb_array_length(v)<>2
 or jsonb_typeof(v->0) is distinct from 'number' or jsonb_typeof(v->1) is distinct from 'number'
 or not((v->>0)::numeric between -180 and 180) or not((v->>1)::numeric between -90 and 90)
 then raise exception 'VALIDATION_FAILED'; end if;
end; $$;
create function private.validate_simulation_template(d jsonb,ready boolean) returns void
language plpgsql immutable set search_path='' as $$
declare v jsonb;m jsonb:=d->'metadata';w jsonb:=d->'world';cfg jsonb:=d->'simulation_defaults';ids text[]:=array['center','incident','bounds','drawing'];g jsonb;
begin
 if d is null or octet_length(d::text)>48000 then raise exception 'VALIDATION_FAILED'; end if;
 perform private.sim_template_keys(d,array['schema_version','metadata','world','initial_objects','virtual_units','briefings','simulation_defaults']);
 if d->'schema_version' is distinct from '1'::jsonb then raise exception 'VALIDATION_FAILED'; end if;
 perform private.sim_template_keys(m,array['title','description','category','difficulty','objectives','duration_minutes','initial_situation']);
 perform private.sim_template_text(m->'title',200,true);perform private.sim_template_text(m->'description',2000);
 perform private.sim_template_text(m->'initial_situation',4000);
 if coalesce(m->>'category','') not in ('STRUCTURE_FIRE','WILDFIRE','TRAFFIC_ACCIDENT','SANDBOX')
 or coalesce(m->>'difficulty','') not in ('BEGINNER','INTERMEDIATE','ADVANCED')
 or jsonb_typeof(m->'duration_minutes') is distinct from 'number'
 or (m->>'duration_minutes')::numeric<>trunc((m->>'duration_minutes')::numeric)
 or not((m->>'duration_minutes')::numeric between 5 and 480)
 or jsonb_typeof(m->'objectives') is distinct from 'array' or jsonb_array_length(m->'objectives')>20 then raise exception 'VALIDATION_FAILED'; end if;
 for v in select value from jsonb_array_elements(m->'objectives') loop perform private.sim_template_text(v,500,true);end loop;
 perform private.sim_template_keys(w,array['center','incident_location','radius_m']);
 perform private.sim_template_position(w->'center',ready);perform private.sim_template_position(w->'incident_location',ready);
 if jsonb_typeof(w->'radius_m') is distinct from 'number' or (w->>'radius_m')::numeric<>trunc((w->>'radius_m')::numeric)
 or not((w->>'radius_m')::numeric between 10 and 5000) then raise exception 'VALIDATION_FAILED'; end if;
 perform private.sim_template_keys(d->'briefings',array['commander','instructor']);
 perform private.sim_template_text(d#>'{briefings,commander}',4000);perform private.sim_template_text(d#>'{briefings,instructor}',4000);
 perform private.sim_template_keys(cfg,array['clock_scale','automatic_execution','response_profile']);
 if cfg->'clock_scale' not in ('1'::jsonb,'5'::jsonb,'10'::jsonb) or cfg->'automatic_execution' is distinct from 'false'::jsonb
 or coalesce(cfg->>'response_profile','') not in ('NORMAL','SLOW_RESPONSE','NO_RESPONSE','BREAKDOWN','COMMUNICATION_LOSS','ROUTE_BLOCKED') then raise exception 'VALIDATION_FAILED'; end if;
 if jsonb_typeof(d->'initial_objects') is distinct from 'array' or jsonb_array_length(d->'initial_objects')>40
 or jsonb_typeof(d->'virtual_units') is distinct from 'array' or jsonb_array_length(d->'virtual_units')>30 then raise exception 'VALIDATION_FAILED'; end if;
 for v in select value from jsonb_array_elements(d->'initial_objects') loop
  perform private.sim_template_keys(v,array['id','kind','label','description','geometry']);
  if coalesce(v->>'id','') !~ '^[a-zA-Z0-9_-]{1,64}$' or v->>'id'=any(ids) then raise exception 'VALIDATION_FAILED'; end if;
  ids:=array_append(ids,v->>'id');perform private.sim_template_text(v->'label',200,true);perform private.sim_template_text(v->'description',2000);
  if coalesce(v->>'kind','') not in ('COMMAND_POST','STAGING','TRIAGE_POINT','WATER_SOURCE','ACCESS_POINT','NOTE','HAZARD','PERIMETER') then raise exception 'VALIDATION_FAILED'; end if;
  g:=v->'geometry';
  if g='null'::jsonb and not ready then continue;end if;
  perform private.sim_template_keys(g,array['type','coordinates']);
  -- Bound designer geometry more tightly than general COP.
  if g->>'type'='Polygon' and (jsonb_array_length(g->'coordinates')<>1 or jsonb_array_length(g#>'{coordinates,0}')>33)
   or g->>'type'='LineString' and jsonb_array_length(g->'coordinates')>32 then raise exception 'VALIDATION_FAILED';end if;
  perform private.validate_incident_geometry(g,case v->>'kind' when 'HAZARD' then array['Point','Polygon']
   when 'PERIMETER' then array['LineString','Polygon'] else array['Point'] end);

 end loop;
 for v in select value from jsonb_array_elements(d->'virtual_units') loop
  perform private.sim_template_keys(v,array['id','position','heading','kind']);
  if coalesce(v->>'id','') !~ '^[a-zA-Z0-9_-]{1,64}$' or v->>'id'=any(ids) or v->>'kind' is distinct from 'OTHER'
  or jsonb_typeof(v->'heading') is distinct from 'number' or not((v->>'heading')::numeric>=0 and (v->>'heading')::numeric<360) then raise exception 'VALIDATION_FAILED';end if;
  ids:=array_append(ids,v->>'id');perform private.sim_template_position(v->'position',ready);
 end loop;
end; $$;

create function private.simulation_template_editor(org uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(private.simulation_enabled() and private.simulation_operator(org) and private.operational_inventory_manager(org),false);
$$;
-- Match the existing mutation lock order, including all live participants for initialization.
create function private.simulation_template_locks(org uuid,incident uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare x uuid;
begin
 perform 1 from private.simulation_environment where singleton and enabled and environment_kind='TRAINING' for share;
 if not found then raise exception 'SIMULATION_DISABLED';end if;
 for x in select distinct id from (select org id union all select organization_id from public.incident_participants where incident_id=incident) q order by id loop
  perform private.lock_organization(x);perform 1 from public.organizations where id=x for share;
 end loop;
 for x in select distinct id from (select auth.uid() id union all select user_id from public.incident_role_assignments where incident_id=incident and status='ACTIVE'
 union all select user_id from public.incident_crew_members where incident_id=incident and status='ACTIVE') q order by id loop
  perform 1 from public.profiles where id=x for share;
 end loop;
 perform 1 from private.simulation_operators where organization_id=org and user_id=auth.uid() for share;
 if not private.simulation_template_editor(org) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
end; $$;

create function public.simulation_template_list(p_organization_id uuid,p_query text default '',p_category text default '',p_status text default '',p_after uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.simulation_template_editor(p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if p_query is null or length(p_query)>100 or p_category is null or p_status is null or p_category not in ('','STRUCTURE_FIRE','WILDFIRE','TRAFFIC_ACCIDENT','SANDBOX')
 or p_status not in ('','BUILT_IN','ORGANIZATION','DRAFT','PUBLISHED','ARCHIVED') then raise exception 'VALIDATION_FAILED';end if;
 return coalesce((select jsonb_agg(q.dto order by q.id) from (
 select t.id,jsonb_build_object('id',t.id,'revision',t.revision::text,'builtin',t.organization_id is null,'archived',t.archived,
 'version_id',v.id,'version',v.version,'state',v.state,'title',v.definition#>>'{metadata,title}','category',v.definition#>>'{metadata,category}',
 'description',v.definition#>>'{metadata,description}') dto
 from public.simulation_scenario_templates t join lateral(select * from public.simulation_scenario_template_versions where template_id=t.id order by version desc limit 1) v on true
 where (t.organization_id is null or t.organization_id=p_organization_id) and (p_after is null or t.id>p_after)
 and (p_query='' or strpos(lower(v.definition#>>'{metadata,title}'),lower(p_query))>0)
 and (p_category='' or v.definition#>>'{metadata,category}'=p_category)
 and ((p_status='' and not t.archived) or p_status='ARCHIVED' and t.archived or not t.archived and
 (p_status='BUILT_IN' and t.organization_id is null or p_status='ORGANIZATION' and t.organization_id=p_organization_id or v.state=p_status))
 order by t.id limit 25) q),'[]');
end; $$;
create function public.simulation_template_read(p_organization_id uuid,p_template_id uuid,p_version_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare t public.simulation_scenario_templates;v public.simulation_scenario_template_versions;
begin
 if not private.simulation_template_editor(p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into t from public.simulation_scenario_templates where id=p_template_id and (organization_id is null or organization_id=p_organization_id);
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into v from public.simulation_scenario_template_versions where template_id=t.id and (p_version_id is null or id=p_version_id) order by version desc limit 1;
 if not found then raise exception 'VALIDATION_FAILED';end if;
 return jsonb_build_object('id',t.id,'revision',t.revision::text,'builtin',t.organization_id is null,'archived',t.archived,
 'version_id',v.id,'version',v.version,'state',v.state,'definition',v.definition);
end; $$;

-- One explicit mutation boundary. Existing incident receipts require a non-null incident;
-- definition receipts therefore live separately and never masquerade as incident mutations.
create function public.simulation_template_command(
 p_organization_id uuid,p_operation uuid,p_action text,p_template_id uuid,p_expected_version bigint,p_payload jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.simulation_scenario_templates;v public.simulation_scenario_template_versions;
 saved private.simulation_template_receipts;req jsonb;result_value jsonb;new_id uuid;new_version uuid;d jsonb;core jsonb;
 scenario uuid;allowed text[];
begin
 if auth.uid() is null or p_operation is null or p_expected_version is null or p_action is null
 or p_action not in ('CREATE','COPY','REVISE','SAVE','PUBLISH','ARCHIVE','START') or jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>50000 then raise exception 'VALIDATION_FAILED';end if;
 allowed:=case p_action when 'CREATE' then array['definition'] when 'SAVE' then array['definition','version_id']
 when 'COPY' then array['version_id'] when 'START' then array['version_id','incident_type_id'] else array[]::text[] end;
 perform private.sim_template_keys(p_payload,allowed);
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,146));
 perform private.simulation_template_locks(p_organization_id);
 req:=jsonb_build_object('action',p_action,'template',p_template_id,'expected',p_expected_version,'payload',p_payload);
 select * into saved from private.simulation_template_receipts where operation_id=p_operation;
 if found then
  if saved.actor<>auth.uid() or saved.organization_id<>p_organization_id or saved.request is distinct from req then raise exception 'OPERATION_REUSED';end if;
  return saved.result;
 end if;
 if p_action='CREATE' then
  if p_template_id is not null or p_expected_version<>0 then raise exception 'STALE_VERSION';end if;
  d:=p_payload->'definition';
 else
  select * into t from public.simulation_scenario_templates where id=p_template_id for update;
  if not found or (t.organization_id is not null and t.organization_id<>p_organization_id)
   or (t.organization_id is null and p_action<>'COPY') then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  if t.revision<>p_expected_version then raise exception 'STALE_VERSION';end if;
  if t.archived then raise exception 'INVALID_TRANSITION';end if;
  select * into v from public.simulation_scenario_template_versions where template_id=t.id
   and (not(p_payload?'version_id') or id=(p_payload->>'version_id')::uuid) order by version desc limit 1;
  if not found then raise exception 'VALIDATION_FAILED';end if;
  d:=v.definition;
 end if;
 if p_action in ('CREATE','COPY') then
  perform private.validate_simulation_template(d,false);
  new_id:=gen_random_uuid();new_version:=gen_random_uuid();
  insert into public.simulation_scenario_templates(id,organization_id,created_by) values(new_id,p_organization_id,auth.uid());
  insert into public.simulation_scenario_template_versions(id,template_id,version,state,definition,created_by)
   values(new_version,new_id,1,'DRAFT',d,auth.uid());
  result_value:=public.simulation_template_read(p_organization_id,new_id);
 elsif p_action='REVISE' then
  if v.state<>'PUBLISHED' then raise exception 'INVALID_TRANSITION';end if;
  insert into public.simulation_scenario_template_versions(id,template_id,version,state,definition,created_by)
   values(gen_random_uuid(),t.id,v.version+1,'DRAFT',d,auth.uid());
 elsif p_action='SAVE' then
  if v.state<>'DRAFT' then raise exception 'INVALID_TRANSITION';end if;
  d:=p_payload->'definition';perform private.validate_simulation_template(d,false);
  update public.simulation_scenario_template_versions set definition=d where id=v.id;
 elsif p_action='PUBLISH' then
  if v.state<>'DRAFT' then raise exception 'INVALID_TRANSITION';end if;
  perform private.validate_simulation_template(d,true);
  update public.simulation_scenario_template_versions set state='PUBLISHED',published_at=clock_timestamp() where id=v.id;
 elsif p_action='ARCHIVE' then
  update public.simulation_scenario_templates set archived=true where id=t.id;
 elsif p_action='START' then
  perform private.validate_simulation_template(d,true);
  scenario:=gen_random_uuid();
  -- Only commander-facing material crosses into the normal incident projection.
  core:=jsonb_build_object('title',d#>>'{metadata,title}','summary',(d#>>'{metadata,initial_situation}')||E'\n\n'||(d#>>'{briefings,commander}'),
   'incident_type_id',p_payload->>'incident_type_id','priority','NORMAL','severity','UNKNOWN',
   'longitude',d#>'{world,incident_location,0}','latitude',d#>'{world,incident_location,1}','address',null,'unknown_location_reason','');
  result_value:=public.simulation_create_scenario(gen_random_uuid(),p_organization_id,null,0,jsonb_build_object('core',core,'scenario',
   jsonb_build_object('id',scenario,'template',d#>>'{metadata,category}','seed',0,'radius_m',d#>'{world,radius_m}',
    'longitude',d#>'{world,center,0}','latitude',d#>'{world,center,1}')));
  insert into private.simulation_template_instances(scenario_id,source_version_id,definition,organization_id,created_by)
   values(scenario,v.id,d,p_organization_id,auth.uid());
  result_value:=result_value||jsonb_build_object('initialization','WAITING_COMMAND','source_version_id',v.id);
 end if;
 if p_action in ('REVISE','SAVE','PUBLISH','ARCHIVE') then
  update public.simulation_scenario_templates set revision=revision+1,updated_at=clock_timestamp() where id=t.id;
  result_value:=public.simulation_template_read(p_organization_id,t.id);
 end if;
 -- Do not put instructor definitions into broadly visible audit DTOs.
 perform private.write_audit(p_organization_id,auth.uid(),'SIM_TEMPLATE_'||p_action,'simulation_scenario_templates',coalesce(new_id,t.id),null,
  jsonb_build_object('operation_id',p_operation,'source_version',v.id,'scenario',scenario));
 insert into private.simulation_template_receipts(operation_id,actor,organization_id,request,result)
 values(p_operation,auth.uid(),p_organization_id,req,result_value);
 return result_value;
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation then raise exception 'VALIDATION_FAILED';
end; $$;

create or replace function private.simulation_initial_position(s public.simulation_scenarios,n integer) returns jsonb
language plpgsql stable set search_path='' as $$
declare salt integer:=case s.template when 'STRUCTURE_FIRE' then 11 when 'WILDFIRE' then 23 when 'TRAFFIC_ACCIDENT' then 37 else 53 end;
 x bigint; y bigint; bearing double precision; distance_value double precision; lat1 double precision; lon1 double precision; lat2 double precision; lon2 double precision;
begin
 -- Provenance is private and immutable; unrelated and later extra fixtures keep the original generator.
 if exists(select 1 from private.simulation_template_instances p where p.scenario_id=s.id
  and jsonb_array_length(p.definition->'virtual_units')>=n) then
  return (select p.definition->'virtual_units'->(n-1)->'position' from private.simulation_template_instances p where p.scenario_id=s.id);
 end if;
 x:=mod((s.seed::bigint+n::bigint*104729+salt)*48271,2147483647);
 y:=mod((x+1)*48271,2147483647);
 bearing:=2*pi()*x/2147483647.0;distance_value:=s.radius_m*sqrt(y/2147483647.0)/6371008.8;
 lat1:=radians(s.center_latitude);lon1:=radians(s.center_longitude);
 lat2:=asin(greatest(-1.0,least(1.0,sin(lat1)*cos(distance_value)+cos(lat1)*sin(distance_value)*cos(bearing))));
 lon2:=lon1+atan2(sin(bearing)*sin(distance_value)*cos(lat1),cos(distance_value)-sin(lat1)*sin(lat2));
 return jsonb_build_array(degrees(lon2)-360*floor((degrees(lon2)+180)/360),degrees(lat2));
end; $$;

-- Template-backed scenarios cannot run before protected initialization. The guard
-- also prevents manual fixture attachment from stealing the template's ordinals.
create function private.simulation_template_setup_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare state_value text;
begin
 if tg_table_name='simulation_scenarios' then
  select state into state_value from private.simulation_template_instances where scenario_id=new.id;
  if new.status='RUNNING' and state_value is not null and state_value<>'READY' then raise exception 'TEMPLATE_SETUP_REQUIRED';end if;
 else
  select state into state_value from private.simulation_template_instances where scenario_id=new.scenario_id;
  if state_value='WAITING_COMMAND' then raise exception 'TEMPLATE_SETUP_REQUIRED';end if;
 end if;
 return new;
end; $$;
create trigger simulation_template_start_guard before update on public.simulation_scenarios for each row execute function private.simulation_template_setup_guard();
create trigger simulation_template_position_guard before insert on public.simulation_unit_positions for each row execute function private.simulation_template_setup_guard();

create function public.simulation_template_initialization(p_organization_id uuid,p_incident_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare s public.simulation_scenarios;p private.simulation_template_instances;i public.incidents;
begin
 if not private.simulation_enabled() or not private.simulation_visible(p_incident_id,p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id;
 select * into p from private.simulation_template_instances where scenario_id=s.id;
 if not found then return null;end if;
 select * into i from public.incidents where id=p_incident_id;
 -- Intentionally no instructor briefing, objectives or full definition.
 return jsonb_build_object('state',p.state,'scenario_version',s.version::text,'incident_version',i.version::text,
 'objects',jsonb_array_length(p.definition->'initial_objects'),'units',jsonb_array_length(p.definition->'virtual_units'),
 'clock_scale',case when p.organization_id=p_organization_id and private.simulation_template_editor(p_organization_id) then p.definition#>'{simulation_defaults,clock_scale}' end,
 'response_profile',case when p.organization_id=p_organization_id and private.simulation_template_editor(p_organization_id) then p.definition#>>'{simulation_defaults,response_profile}' end,
 'can_initialize',p.state='WAITING_COMMAND' and i.status in ('ACTIVE','STABILIZED') and s.status='DRAFT'
 and private.simulation_template_editor(p_organization_id) and private.simulation_controller(s.id,p_organization_id)
 and (jsonb_array_length(p.definition->'virtual_units')=0 or private.can_manage_incident_unit(i.id,p_organization_id,p_organization_id,null,'DEPLOY'))
 and (jsonb_array_length(p.definition->'initial_objects')=0 or private.has_incident_capability(i.id,p_organization_id,'MANAGE_COP')));
end; $$;
create function public.simulation_template_initialize(
 p_organization_id uuid,p_incident_id uuid,p_operation uuid,p_expected_version bigint,p_incident_version bigint
) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.simulation_scenarios;i public.incidents;p private.simulation_template_instances;
 saved private.simulation_template_receipts;req jsonb;result_value jsonb;v jsonb;ignored jsonb;new_id uuid;pos public.simulation_unit_positions;
 object_map jsonb:='{}';unit_map jsonb:='{}';count_value integer;
begin
 if p_operation is null or p_expected_version is null or p_incident_version is null then raise exception 'VALIDATION_FAILED';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,146));
 perform private.simulation_template_locks(p_organization_id,p_incident_id);
 select * into i from public.incidents where id=p_incident_id for update;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id for update;
 if s.id is null or not private.simulation_controller(s.id,p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into p from private.simulation_template_instances where scenario_id=s.id and organization_id=p_organization_id for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 req:=jsonb_build_object('action','INITIALIZE','incident',p_incident_id,'expected',p_expected_version,'incident_version',p_incident_version);
 select * into saved from private.simulation_template_receipts where operation_id=p_operation;
 if found then
  if saved.actor<>auth.uid() or saved.organization_id<>p_organization_id or saved.request is distinct from req then raise exception 'OPERATION_REUSED';end if;
  return saved.result;
 end if;
 if p.state<>'WAITING_COMMAND' or s.status<>'DRAFT' or i.status not in ('ACTIVE','STABILIZED') then raise exception 'INVALID_TRANSITION';end if;
 if s.version<>p_expected_version or i.version<>p_incident_version then raise exception 'STALE_VERSION';end if;
 perform private.validate_simulation_template(p.definition,true);
 if exists(select 1 from public.simulation_unit_positions where scenario_id=s.id) then raise exception 'TEMPLATE_SETUP_REQUIRED';end if;
 -- INITIALIZING is never committed alone: any failure rolls back ALL children and this state.
 update private.simulation_template_instances set state='INITIALIZING' where scenario_id=s.id;
 count_value:=jsonb_array_length(p.definition->'virtual_units');
 if count_value>0 then
  ignored:=public.simulation_command(gen_random_uuid(),p_organization_id,i.id,s.version,'PROVISION',jsonb_build_object('count',count_value));
  for pos in select * from public.simulation_unit_positions where scenario_id=s.id order by ordinal loop
   v:=p.definition->'virtual_units'->(pos.ordinal-1);
   unit_map:=unit_map||jsonb_build_object(v->>'id',pos.incident_unit_id);
   select * into s from public.simulation_scenarios where id=s.id;
   ignored:=public.simulation_command(gen_random_uuid(),p_organization_id,i.id,s.version,'SET_POSITION',
    jsonb_build_object('unit_id',pos.incident_unit_id,'position_version',pos.version::text,
     'longitude',v#>'{position,0}','latitude',v#>'{position,1}','heading_degrees',v->'heading','speed_mps',0));
  end loop;
 end if;
 for v in select value from jsonb_array_elements(p.definition->'initial_objects') loop
  new_id:=gen_random_uuid();select * into i from public.incidents where id=p_incident_id;
  ignored:=public.incident_put_map_object(gen_random_uuid(),p_organization_id,i.id,i.version,
   jsonb_build_object('id',new_id,'version','0','kind',v->>'kind','label',v->>'label','description',v->>'description','geometry',v->'geometry','sector_id',null));
  object_map:=object_map||jsonb_build_object(v->>'id',new_id);
 end loop;
 update private.simulation_template_instances set state='READY',object_ids=object_map,unit_ids=unit_map,initialized_at=clock_timestamp() where scenario_id=s.id;
 result_value:=jsonb_build_object('incident_id',i.id,'state','READY','objects',object_map,'units',unit_map);
 insert into private.simulation_template_receipts(operation_id,actor,organization_id,request,result)
 values(p_operation,auth.uid(),p_organization_id,req,result_value);
 perform private.write_audit(p_organization_id,auth.uid(),'SIM_TEMPLATE_INITIALIZED','simulation_scenarios',s.id,null,jsonb_build_object('operation_id',p_operation,'objects',object_map,'units',unit_map));
 return result_value;
end; $$;

-- Portable built-ins deliberately have no actual-world location. A scoped copy is
-- placed by the instructor, then validated before publishing or preview-instance creation.
do $seed$
declare item record;t uuid;d jsonb;objects jsonb;units jsonb;
begin
 for item in select * from (values
 ('residential','STRUCTURE_FIRE','Stanovanjski požar / Wohnungsbrand','Reševanje in oskrba z vodo / Rettung und Wasserversorgung','BEGINNER',45,3,
 'Dim v zgornjem nadstropju; dostop za vozila še preverite. / Rauch im Obergeschoss; Fahrzeugzufahrt prüfen.',
 'Razdelitev nalog; vzpostavitev vodne oskrbe. / Aufgabenverteilung; Wasserversorgung aufbauen.'),
 ('warehouse','STRUCTURE_FIRE','Požar skladišča / Lagerhallenbrand','Vodenje več enot / Führung mehrerer Einheiten','ADVANCED',90,6,
 'Požar v skladišču; preverite nevarne snovi in varen dostop. / Hallenbrand; Gefahrstoffe und sichere Zufahrt prüfen.',
 'Zbirno mesto, varna območja in usklajevanje enot. / Bereitstellung, sichere Bereiche und Einheitenkoordination.'),
 ('forest-edge','WILDFIRE','Požar ob robu gozda / Waldbrand am Siedlungsrand','Zaščita naselja / Schutz der Siedlung','INTERMEDIATE',75,5,
 'Požar ogroža gozdni rob ob naselju. / Feuer am Waldrand nahe einer Siedlung.',
 'Dostopi, vodna oskrba in prioritete zaščite. / Zufahrten, Wasserversorgung und Schutzprioritäten.'),
 ('collision','TRAFFIC_ACCIDENT','Trčenje več vozil / Mehrfahrzeugunfall','Reševanje in triaža / Rettung und Triage','INTERMEDIATE',60,4,
 'Več vozil; število poškodovanih še ni potrjeno. / Mehrere Fahrzeuge; Verletztenzahl noch unbestätigt.',
 'Varovanje mesta in usklajevanje triaže. / Einsatzstelle sichern und Triage koordinieren.'),
 ('sandbox','SANDBOX','Prazna vaja / Leere Übung','Lastno območje za usposabljanje / Eigener Übungsraum','BEGINNER',30,0,
 'Določite začetno situacijo. / Ausgangslage festlegen.','Določite učne cilje. / Lernziele festlegen.')
 ) as x(code,category,title,description,difficulty,duration,unit_count,situation,objective) loop
  t:=gen_random_uuid();objects:='[]';units:='[]';
  if item.code<>'sandbox' then
   objects:=jsonb_build_array(
    jsonb_build_object('id','command','kind','COMMAND_POST','label','Poveljniško mesto / Führungsstelle','description','','geometry',null),
    jsonb_build_object('id','staging','kind','STAGING','label','Zbirno mesto / Bereitstellungsraum','description','','geometry',null),
    jsonb_build_object('id','access','kind','ACCESS_POINT','label','Dostop / Zufahrt','description','','geometry',null),
    jsonb_build_object('id','support','kind',case when item.code='collision' then 'TRIAGE_POINT' else 'WATER_SOURCE' end,
     'label',case when item.code='collision' then 'Triaža / Triage' else 'Vodna oskrba / Wasserversorgung' end,'description','','geometry',null));
  end if;
  for n in 1..item.unit_count loop units:=units||jsonb_build_array(jsonb_build_object('id','unit-'||n,'kind','OTHER','position',null,'heading',0));end loop;
  d:=jsonb_build_object('schema_version',1,'metadata',jsonb_build_object('title',item.title,'description',item.description,'category',item.category,
   'difficulty',item.difficulty,'objectives',jsonb_build_array(item.objective),'duration_minutes',item.duration,'initial_situation',item.situation),
   'world',jsonb_build_object('center',null,'incident_location',null,'radius_m',1000),'initial_objects',objects,'virtual_units',units,
   'briefings',jsonb_build_object('commander',item.situation,'instructor',item.objective),
   'simulation_defaults',jsonb_build_object('clock_scale',1,'automatic_execution',false,'response_profile','NORMAL'));
  perform private.validate_simulation_template(d,false);
  insert into public.simulation_scenario_templates(id,code) values(t,item.code);
  insert into public.simulation_scenario_template_versions(id,template_id,version,state,definition,published_at)
   values(gen_random_uuid(),t,1,'PUBLISHED',d,clock_timestamp());
 end loop;
end; $seed$;
revoke all on function private.simulation_template_immutable() from public,anon,authenticated,service_role;
revoke all on function private.sim_template_keys(jsonb,text[]) from public,anon,authenticated,service_role;
revoke all on function private.sim_template_text(jsonb,integer,boolean) from public,anon,authenticated,service_role;
revoke all on function private.sim_template_position(jsonb,boolean) from public,anon,authenticated,service_role;
revoke all on function private.validate_simulation_template(jsonb,boolean) from public,anon,authenticated,service_role;
revoke all on function private.simulation_template_editor(uuid) from public,anon,authenticated,service_role;
revoke all on function private.simulation_template_locks(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.simulation_template_setup_guard() from public,anon,authenticated,service_role;
revoke all on function public.simulation_template_list(uuid,text,text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.simulation_template_list(uuid,text,text,text,uuid) to authenticated;
revoke all on function public.simulation_template_read(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.simulation_template_read(uuid,uuid,uuid) to authenticated;
revoke all on function public.simulation_template_command(uuid,uuid,text,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.simulation_template_command(uuid,uuid,text,uuid,bigint,jsonb) to authenticated;
revoke all on function public.simulation_template_initialization(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.simulation_template_initialization(uuid,uuid) to authenticated;
revoke all on function public.simulation_template_initialize(uuid,uuid,uuid,bigint,bigint) from public,anon,authenticated,service_role;
grant execute on function public.simulation_template_initialize(uuid,uuid,uuid,bigint,bigint) to authenticated;
revoke all on function private.simulation_template_provenance_guard() from public,anon,authenticated,service_role;
commit;
