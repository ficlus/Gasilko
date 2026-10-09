-- M14.5C: disabled-by-default, explicitly provisioned TRAINING environment.
-- No setting below is writable through authenticated/service-role application APIs.
create table private.simulation_environment (
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default false,
 environment_kind text not null default 'DISABLED' check(environment_kind in ('DISABLED','TRAINING')),
 check(not enabled or environment_kind='TRAINING')
);
insert into private.simulation_environment(singleton) values(true);
create table private.simulation_operators (
 organization_id uuid not null references public.organizations(id),
 user_id uuid not null references public.profiles(id),
 primary key(organization_id,user_id)
);
revoke all on private.simulation_environment,private.simulation_operators from public,anon,authenticated,service_role;

create table public.simulation_scenarios (
 id uuid primary key,
 incident_id uuid not null unique references public.incidents(id),
 organization_id uuid not null references public.organizations(id),
 title text not null check(length(btrim(title)) between 1 and 200),
 template text not null check(template in ('STRUCTURE_FIRE','WILDFIRE','TRAFFIC_ACCIDENT','SANDBOX')),
 seed integer not null check(seed between 0 and 2147483646),
 center_longitude double precision not null check(center_longitude between -180 and 180),
 center_latitude double precision not null check(center_latitude between -90 and 90),
 radius_m integer not null check(radius_m between 10 and 5000),
 status text not null default 'DRAFT' check(status in ('DRAFT','RUNNING','PAUSED','FINISHED')),
 version bigint not null default 1 check(version>0),
 event_sequence bigint not null default 0 check(event_sequence>=0),
 created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp(),
 unique(id,incident_id)
);
create table public.simulation_unit_positions (
 scenario_id uuid not null,
 incident_id uuid not null,
 incident_unit_id uuid not null,
 source text not null default 'SIMULATED' check(source='SIMULATED'),
 ordinal integer not null check(ordinal between 1 and 100),
 initial_longitude double precision not null check(initial_longitude between -180 and 180),
 initial_latitude double precision not null check(initial_latitude between -90 and 90),
 longitude double precision not null check(longitude between -180 and 180),
 latitude double precision not null check(latitude between -90 and 90),
 heading_degrees double precision not null default 0 check(heading_degrees>=0 and heading_degrees<360),
 speed_mps double precision not null default 0 check(speed_mps>=0 and speed_mps<=100),
 observed_at timestamptz not null default clock_timestamp(),
 updated_by uuid not null references public.profiles(id),
 active boolean not null default true,
 version bigint not null default 1 check(version>0),
 primary key(scenario_id,incident_unit_id),
 unique(scenario_id,ordinal),
 foreign key(scenario_id,incident_id) references public.simulation_scenarios(id,incident_id),
 foreign key(incident_unit_id,incident_id) references public.incident_units(id,incident_id)
);
create table public.simulation_events (
 id uuid primary key default gen_random_uuid(),
 scenario_id uuid not null references public.simulation_scenarios(id),
 sequence bigint not null check(sequence>0),
 event_type text not null check(event_type in ('SCENARIO_CREATED','UNITS_ADDED','POSITION_SET','POSITION_RESET','UNIT_REMOVED','SIMULATION_STARTED','SIMULATION_PAUSED','SIMULATION_RESUMED','SIMULATION_RESET','SIMULATION_FINISHED')),
 incident_unit_id uuid,
 payload jsonb not null check(jsonb_typeof(payload)='object' and octet_length(payload::text)<=32768),
 actor_user_id uuid not null references public.profiles(id),
 created_at timestamptz not null default clock_timestamp(),
 operation_id uuid not null unique,
 unique(scenario_id,sequence),
 foreign key(scenario_id,incident_unit_id) references public.simulation_unit_positions(scenario_id,incident_unit_id)
);
create table private.simulation_fixture_units (
 unit_id uuid primary key references public.operational_units(id),
 scenario_id uuid not null references public.simulation_scenarios(id)
);
revoke all on private.simulation_fixture_units from public,anon,authenticated,service_role;
create index simulation_scenarios_org on public.simulation_scenarios(organization_id,created_at desc,id);
create index simulation_positions_incident on public.simulation_unit_positions(incident_id,active,incident_unit_id);

create function private.simulation_enabled() returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce((select enabled and environment_kind='TRAINING' from private.simulation_environment where singleton),false);
$$;
create function private.simulation_operator(p_org uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select private.is_active_user() and private.incident_acting_member(p_org)
 and exists(select 1 from private.simulation_operators where organization_id=p_org and user_id=auth.uid());
$$;
create function private.simulation_controller(p_scenario uuid,p_org uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select private.simulation_enabled() and private.simulation_operator(p_org)
 and exists(select 1 from public.simulation_scenarios s where s.id=p_scenario and s.organization_id=p_org and s.created_by=auth.uid()
 and (private.incident_draft_manager(s.incident_id,p_org) or private.has_incident_capability(s.incident_id,p_org,'EDIT_SUMMARY')));
$$;
-- Metadata remains identifiable as training even after environment shutdown.
create function private.simulation_visible(p_incident uuid,p_org uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select private.incident_acting_member(p_org) and private.can_read_incident(p_incident)
 and exists(select 1 from public.incident_participants p join public.incidents i on i.id=p.incident_id
 where p.incident_id=p_incident and p.organization_id=p_org
 and (p.status='ACTIVE' or (p.status='RELEASED' and i.status in ('CLOSED','CANCELLED'))));
$$;
create function private.simulation_storage_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='simulation_scenarios' then
  if (new.id,new.incident_id,new.organization_id,new.title,new.template,new.seed,new.center_longitude,new.center_latitude,new.radius_m,new.created_by,new.created_at)
   is distinct from (old.id,old.incident_id,old.organization_id,old.title,old.template,old.seed,old.center_longitude,old.center_latitude,old.radius_m,old.created_by,old.created_at)
   or old.status='FINISHED' then raise exception 'INVALID_SIMULATION_STATE'; end if;
 else
  if (new.scenario_id,new.incident_id,new.incident_unit_id,new.source,new.ordinal,new.initial_longitude,new.initial_latitude)
   is distinct from (old.scenario_id,old.incident_id,old.incident_unit_id,old.source,old.ordinal,old.initial_longitude,old.initial_latitude)
   then raise exception 'INVALID_SIMULATION_STATE'; end if;
 end if;
 return new;
end; $$;
create trigger simulation_scenario_identity before update on public.simulation_scenarios for each row execute function private.simulation_storage_guard();
create trigger simulation_position_identity before update on public.simulation_unit_positions for each row execute function private.simulation_storage_guard();
create trigger simulation_events_immutable before update or delete on public.simulation_events for each row execute function private.audit_immutable();
create trigger simulation_events_no_truncate before truncate on public.simulation_events for each statement execute function private.audit_immutable();
create trigger simulation_scenarios_no_delete before delete on public.simulation_scenarios for each row execute function private.audit_immutable();
create trigger simulation_scenarios_no_truncate before truncate on public.simulation_scenarios for each statement execute function private.audit_immutable();
create trigger simulation_positions_no_delete before delete on public.simulation_unit_positions for each row execute function private.audit_immutable();
create trigger simulation_positions_no_truncate before truncate on public.simulation_unit_positions for each statement execute function private.audit_immutable();

-- Restrict fixtures to their training incident even when ordinary deployment APIs are used.
create function private.simulation_resource_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='incident_units' then
  if exists(select 1 from private.simulation_fixture_units f join public.simulation_scenarios s on s.id=f.scenario_id
   where f.unit_id=new.unit_id and (s.incident_id<>new.incident_id or not private.simulation_enabled()))
   then raise exception 'INVALID_SIMULATION_UNIT'; end if;
 elsif tg_table_name='operational_units' then
  if new.vehicle_id is not null and exists(select 1 from private.simulation_fixture_units f where f.unit_id=new.id)
   then raise exception 'INVALID_SIMULATION_UNIT'; end if;
 else
  if exists(select 1 from public.simulation_scenarios s where s.incident_id=new.incident_id)
   then raise exception 'SIMULATION_RESOURCE_DISABLED'; end if;
 end if;
 return new;
end; $$;
create trigger simulation_fixture_deployment before insert or update on public.incident_units for each row execute function private.simulation_resource_guard();
create trigger simulation_fixture_no_vehicle before update on public.operational_units for each row execute function private.simulation_resource_guard();
create trigger simulation_no_stock before insert or update on public.incident_resource_allocations for each row execute function private.simulation_resource_guard();

alter table public.simulation_scenarios enable row level security;
alter table public.simulation_unit_positions enable row level security;
alter table public.simulation_events enable row level security;
revoke all on public.simulation_scenarios,public.simulation_unit_positions,public.simulation_events from public,anon,authenticated,service_role;
grant select on public.simulation_scenarios,public.simulation_unit_positions,public.simulation_events to authenticated;
create policy simulation_scenarios_read on public.simulation_scenarios for select to authenticated using(private.can_read_incident(incident_id));
create policy simulation_positions_read on public.simulation_unit_positions for select to authenticated using(private.simulation_enabled() and private.can_read_incident(incident_id));
create policy simulation_events_read on public.simulation_events for select to authenticated using(private.simulation_enabled() and exists(select 1 from public.simulation_scenarios s where s.id=scenario_id and private.can_read_incident(s.incident_id)));

-- Stable fixture index/seed/template inputs; spherical starting points, NOT road/GPS observations.
create function private.simulation_initial_position(s public.simulation_scenarios,n integer) returns jsonb
language plpgsql immutable set search_path='' as $$
declare salt integer:=case s.template when 'STRUCTURE_FIRE' then 11 when 'WILDFIRE' then 23 when 'TRAFFIC_ACCIDENT' then 37 else 53 end;
 x bigint; y bigint; bearing double precision; distance_value double precision; lat1 double precision; lon1 double precision; lat2 double precision; lon2 double precision;
begin
 x:=mod((s.seed::bigint+n::bigint*104729+salt)*48271,2147483647);
 y:=mod((x+1)*48271,2147483647);
 bearing:=2*pi()*x/2147483647.0;distance_value:=s.radius_m*sqrt(y/2147483647.0)/6371008.8;
 lat1:=radians(s.center_latitude);lon1:=radians(s.center_longitude);
 lat2:=asin(greatest(-1.0,least(1.0,sin(lat1)*cos(distance_value)+cos(lat1)*sin(distance_value)*cos(bearing))));
 lon2:=lon1+atan2(sin(bearing)*sin(distance_value)*cos(lat1),cos(distance_value)-sin(lat1)*sin(lat2));
 return jsonb_build_array(degrees(lon2)-360*floor((degrees(lon2)+180)/360),degrees(lat2));
end; $$;

create function public.simulation_environment(p_acting_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.incident_acting_member(p_acting_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return jsonb_build_object('enabled',private.simulation_enabled(),'can_create',private.simulation_enabled() and private.simulation_operator(p_acting_organization_id) and private.operational_inventory_manager(p_acting_organization_id));
end; $$;
create function public.simulation_labels(p_acting_organization_id uuid,p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.incident_acting_member(p_acting_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_ids is null or cardinality(p_ids)>100 then raise exception 'VALIDATION_FAILED'; end if;
 return coalesce((select jsonb_object_agg(s.incident_id::text,jsonb_build_object('id',s.id,'title',s.title,'status',s.status,'version',s.version::text))
 from public.simulation_scenarios s where s.incident_id=any(p_ids) and private.simulation_visible(s.incident_id,p_acting_organization_id)),'{}');
end; $$;

create function public.simulation_create_scenario(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); saved private.incident_operation_receipts; request_value jsonb; result_value jsonb; core_result jsonb; s public.simulation_scenarios;
 cfg jsonb:=p_payload->'scenario'; incident uuid;
begin
 if actor is null or not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_operation is null or p_incident_id is not null or p_expected_version is distinct from 0 or jsonb_typeof(p_payload) is distinct from 'object'
 or octet_length(p_payload::text)>32768 or jsonb_typeof(cfg) is distinct from 'object'
 or exists(select 1 from jsonb_object_keys(p_payload) k where k not in ('core','scenario'))
 or exists(select 1 from jsonb_object_keys(cfg) k where k not in ('id','template','seed','radius_m','longitude','latitude')) then raise exception 'VALIDATION_FAILED'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 perform 1 from private.simulation_environment where singleton and enabled and environment_kind='TRAINING' for share;
 if not found then raise exception 'SIMULATION_DISABLED'; end if;
 perform private.lock_organization(p_acting_organization_id);
 perform 1 from public.organizations where id=p_acting_organization_id for share;
 perform 1 from public.profiles where id=actor for share;
 perform 1 from private.simulation_operators where organization_id=p_acting_organization_id and user_id=actor for share;
 if not found or not private.simulation_operator(p_acting_organization_id) or not private.operational_inventory_manager(p_acting_organization_id)
 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 request_value:=jsonb_build_object('command','SIM_CREATE','org',p_acting_organization_id,'payload',p_payload);
 select * into saved from private.incident_operation_receipts where operation_id=p_operation;
 if found then
  if saved.actor_user_id<>actor or saved.request is distinct from request_value then raise exception 'OPERATION_REUSED'; end if;
  return saved.result;
 end if;
 -- No enrollment API for pre-existing incidents. Creation and enrollment commit together.
 core_result:=public.incident_create_draft(gen_random_uuid(),p_acting_organization_id,null,0,p_payload->'core');
 incident:=(core_result->>'incident_id')::uuid;
 insert into public.simulation_scenarios(id,incident_id,organization_id,title,template,seed,center_longitude,center_latitude,radius_m,created_by,event_sequence)
 values((cfg->>'id')::uuid,incident,p_acting_organization_id,p_payload->'core'->>'title',cfg->>'template',(cfg->>'seed')::integer,
 (cfg->>'longitude')::double precision,(cfg->>'latitude')::double precision,(cfg->>'radius_m')::integer,actor,1) returning * into s;
 insert into public.simulation_events(scenario_id,sequence,event_type,payload,actor_user_id,operation_id)
 values(s.id,1,'SCENARIO_CREATED',jsonb_build_object('template',s.template,'seed',s.seed,'radius_m',s.radius_m,'center',jsonb_build_array(s.center_longitude,s.center_latitude)),actor,p_operation);
 result_value:=core_result||jsonb_build_object('scenario_id',s.id,'simulation_version',s.version::text,'operation_id',p_operation);
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,actor,p_acting_organization_id,incident,'SIM_CREATE',request_value,result_value);
 perform private.write_audit(p_acting_organization_id,actor,'SIMULATION_CREATED','simulation_scenarios',s.id,null,jsonb_build_object('operation_id',p_operation,'result',result_value));
 return result_value;
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation then raise exception 'VALIDATION_FAILED';
 when unique_violation then raise exception 'OPERATION_REUSED';
end; $$;

create function public.simulation_command(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_action text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); s public.simulation_scenarios; i public.incidents; position_row public.simulation_unit_positions;
 saved private.incident_operation_receipts; request_value jsonb; result_value jsonb; event_value text; event_payload jsonb:='{}';
 lock_org uuid; lock_person uuid; unit_id uuid; inventory_id uuid; unit_row public.incident_units;
 ids uuid[]; n integer; ordinal_value integer; coords jsonb; item jsonb; now_value timestamptz; ignored jsonb;
 allowed text[]; event_unit uuid; created_units jsonb:='[]';
begin
 if actor is null or not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_operation is null or p_acting_organization_id is null or p_incident_id is null or p_expected_version is null or jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>20000
 or p_action is null or p_action not in ('PROVISION','ATTACH','SET_POSITION','RESET_POSITION','REMOVE','START','PAUSE','RESUME','RESET','FINISH') then raise exception 'VALIDATION_FAILED'; end if;
 allowed:=case p_action when 'PROVISION' then array['count'] when 'ATTACH' then array['unit_ids']
 when 'SET_POSITION' then array['unit_id','position_version','longitude','latitude','heading_degrees','speed_mps']
 when 'RESET_POSITION' then array['unit_id','position_version'] when 'REMOVE' then array['unit_id','position_version'] else array[]::text[] end;
 if exists(select 1 from jsonb_object_keys(p_payload) k where not(k=any(allowed))) then raise exception 'VALIDATION_FAILED'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 perform 1 from private.simulation_environment where singleton and enabled and environment_kind='TRAINING' for share;
 if not found then raise exception 'SIMULATION_DISABLED'; end if;
 for lock_org in select distinct org from(select p_acting_organization_id org union all select organization_id from public.incident_participants where incident_id=p_incident_id) x order by org loop
  perform private.lock_organization(lock_org);perform 1 from public.organizations where id=lock_org for share;
 end loop;
 for lock_person in select distinct person from(select actor person union all select user_id from public.incident_role_assignments where incident_id=p_incident_id and status='ACTIVE'
 union all select user_id from public.incident_crew_members where incident_id=p_incident_id and status='ACTIVE') x order by person loop
  perform 1 from public.profiles where id=lock_person for share;
 end loop;
 perform 1 from private.simulation_operators where organization_id=p_acting_organization_id and user_id=actor for share;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into i from public.incidents where id=p_incident_id for update;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id for update;
 if not found or not private.simulation_controller(s.id,p_acting_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 request_value:=jsonb_build_object('command','SIM_'||p_action,'org',p_acting_organization_id,'incident',p_incident_id,'expected',p_expected_version,'payload',p_payload);
 select * into saved from private.incident_operation_receipts where operation_id=p_operation;
 if found then
  if saved.actor_user_id<>actor or saved.request is distinct from request_value then raise exception 'OPERATION_REUSED'; end if;
  return saved.result;
 end if;
 if s.status='FINISHED' or i.status in ('CLOSED','CANCELLED') then raise exception 'INVALID_SIMULATION_STATE'; end if;
 if s.version<>p_expected_version then raise exception 'STALE_VERSION'; end if;
 now_value:=clock_timestamp();
 if p_action in ('PROVISION','ATTACH') then
  if s.status not in ('DRAFT','PAUSED') or i.status not in ('ACTIVE','STABILIZED') then raise exception 'INVALID_SIMULATION_STATE'; end if;
  select coalesce(max(ordinal),0) into ordinal_value from public.simulation_unit_positions where scenario_id=s.id;
  if p_action='PROVISION' then
   n:=(p_payload->>'count')::integer;
   if n is null or n not between 1 and 30 or ordinal_value+n>100 then raise exception 'SIMULATION_LIMIT'; end if;
   -- Existing inventory manager AND live incident deployment authority are both required.
   if not private.operational_inventory_manager(p_acting_organization_id) or not private.can_manage_incident_unit(i.id,p_acting_organization_id,p_acting_organization_id,null,'DEPLOY')
   then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   ids:=array[]::uuid[];
   for k in 1..n loop
    inventory_id:=gen_random_uuid();unit_id:=gen_random_uuid();
    ignored:=private.operational_inventory_command('UNIT',p_acting_organization_id,gen_random_uuid(),
     jsonb_build_object('id',inventory_id,'version','0','callsign','SIM-'||left(s.id::text,8)||'-'||(ordinal_value+k),
     'name','SIM '||s.template||' '||(ordinal_value+k),'unit_kind','OTHER','vehicle_id',null,'active',true,'capabilities','[]'::jsonb));
    insert into private.simulation_fixture_units(unit_id,scenario_id) values(inventory_id,s.id);
    select * into i from public.incidents where id=p_incident_id;
    ignored:=private.incident_resource_command('DEPLOY',gen_random_uuid(),p_acting_organization_id,i.id,i.version,
     jsonb_build_object('id',unit_id,'unit_id',inventory_id,'sector_id',null));
    ids:=array_append(ids,unit_id);
   end loop;
  else
   if jsonb_typeof(p_payload->'unit_ids') is distinct from 'array' then raise exception 'VALIDATION_FAILED'; end if;
   select array_agg(value::uuid order by value::uuid) into ids from jsonb_array_elements_text(p_payload->'unit_ids');
   if ids is null or cardinality(ids) not between 1 and 100 or ordinal_value+cardinality(ids)>100 or cardinality(ids)<>(select count(distinct x) from unnest(ids) x)
   then raise exception 'SIMULATION_LIMIT'; end if;
  end if;
  foreach unit_id in array ids loop
   select * into unit_row from public.incident_units where id=unit_id and incident_id=s.incident_id for update;
   if not found or unit_row.status in ('RELEASED','UNAVAILABLE') or not private.can_manage_incident_unit(i.id,p_acting_organization_id,unit_row.organization_id,unit_id,'STATUS')
   then raise exception 'INVALID_SIMULATION_UNIT'; end if;
   if exists(select 1 from public.simulation_unit_positions where scenario_id=s.id and incident_unit_id=unit_id) then raise exception 'INVALID_SIMULATION_UNIT'; end if;
   ordinal_value:=ordinal_value+1;coords:=private.simulation_initial_position(s,ordinal_value);
   insert into public.simulation_unit_positions(scenario_id,incident_id,incident_unit_id,ordinal,initial_longitude,initial_latitude,longitude,latitude,updated_by,observed_at)
   values(s.id,s.incident_id,unit_id,ordinal_value,(coords->>0)::double precision,(coords->>1)::double precision,(coords->>0)::double precision,(coords->>1)::double precision,actor,now_value);
   created_units:=created_units||jsonb_build_array(jsonb_build_object('unit_id',unit_id,'ordinal',ordinal_value,'initial',coords));
  end loop;
  event_value:='UNITS_ADDED';event_payload:=jsonb_build_object('units',created_units,'provisioned',p_action='PROVISION');
 elsif p_action in ('SET_POSITION','RESET_POSITION','REMOVE') then
  event_unit:=(p_payload->>'unit_id')::uuid;
  select * into position_row from public.simulation_unit_positions where scenario_id=s.id and incident_unit_id=event_unit and active for update;
  if not found then raise exception 'INVALID_SIMULATION_UNIT'; end if;
  if position_row.version is distinct from (p_payload->>'position_version')::bigint then raise exception 'STALE_VERSION'; end if;
  select * into unit_row from public.incident_units where id=event_unit and incident_id=s.incident_id for update;
  if p_action<>'REMOVE' and (unit_row.status in ('RELEASED','UNAVAILABLE') or not private.can_manage_incident_unit(i.id,p_acting_organization_id,unit_row.organization_id,event_unit,'STATUS'))
  then raise exception 'INVALID_SIMULATION_UNIT'; end if;
  if p_action='SET_POSITION' then
   if s.status not in ('DRAFT','RUNNING') then raise exception 'INVALID_SIMULATION_STATE'; end if;
   update public.simulation_unit_positions set longitude=(p_payload->>'longitude')::double precision,latitude=(p_payload->>'latitude')::double precision,
    heading_degrees=(p_payload->>'heading_degrees')::double precision,speed_mps=(p_payload->>'speed_mps')::double precision,
    observed_at=now_value,updated_by=actor,version=version+1 where scenario_id=s.id and incident_unit_id=event_unit;
   event_value:='POSITION_SET';event_payload:=jsonb_build_object('before',jsonb_build_array(position_row.longitude,position_row.latitude),'after',jsonb_build_array(p_payload->'longitude',p_payload->'latitude'),'heading',p_payload->'heading_degrees','speed',p_payload->'speed_mps');
  elsif p_action='RESET_POSITION' then
   update public.simulation_unit_positions set longitude=initial_longitude,latitude=initial_latitude,heading_degrees=0,speed_mps=0,
    observed_at=now_value,updated_by=actor,version=version+1 where scenario_id=s.id and incident_unit_id=event_unit;
   event_value:='POSITION_RESET';event_payload:=jsonb_build_object('before',jsonb_build_array(position_row.longitude,position_row.latitude),'after',jsonb_build_array(position_row.initial_longitude,position_row.initial_latitude));
  else
   update public.simulation_unit_positions set active=false,updated_by=actor,observed_at=now_value,version=version+1 where scenario_id=s.id and incident_unit_id=event_unit;
   event_value:='UNIT_REMOVED';event_payload:=jsonb_build_object('last',jsonb_build_array(position_row.longitude,position_row.latitude));
  end if;
 elsif p_action='RESET' then
  if exists(select 1 from public.simulation_unit_positions p join public.incident_units u on u.id=p.incident_unit_id where p.scenario_id=s.id and p.active
   and (u.status in ('RELEASED','UNAVAILABLE') or not private.can_manage_incident_unit(i.id,p_acting_organization_id,u.organization_id,u.id,'STATUS')))
   then raise exception 'INVALID_SIMULATION_UNIT'; end if;
  select jsonb_build_object('positions',coalesce(jsonb_agg(jsonb_build_object('unit_id',incident_unit_id,'before',jsonb_build_array(longitude,latitude),'after',jsonb_build_array(initial_longitude,initial_latitude)) order by ordinal),'[]')) into event_payload
   from public.simulation_unit_positions where scenario_id=s.id and active;
  update public.simulation_unit_positions set longitude=initial_longitude,latitude=initial_latitude,heading_degrees=0,speed_mps=0,
   observed_at=now_value,updated_by=actor,version=version+1 where scenario_id=s.id and active;
  event_value:='SIMULATION_RESET';
 else
  if (p_action='START' and (s.status<>'DRAFT' or i.status not in ('ACTIVE','STABILIZED')))
   or (p_action='PAUSE' and s.status<>'RUNNING') or (p_action='RESUME' and s.status<>'PAUSED') then raise exception 'INVALID_SIMULATION_STATE'; end if;
  event_value:=case p_action when 'START' then 'SIMULATION_STARTED' when 'PAUSE' then 'SIMULATION_PAUSED' when 'RESUME' then 'SIMULATION_RESUMED' when 'FINISH' then 'SIMULATION_FINISHED' end;
 end if;
 update public.simulation_scenarios set version=version+1,event_sequence=event_sequence+1,updated_at=now_value,
  status=case p_action when 'START' then 'RUNNING' when 'PAUSE' then 'PAUSED' when 'RESUME' then 'RUNNING' when 'FINISH' then 'FINISHED' else status end
 where id=s.id returning * into s;
 insert into public.simulation_events(scenario_id,sequence,event_type,incident_unit_id,payload,actor_user_id,operation_id)
 values(s.id,s.event_sequence,event_value,event_unit,event_payload,actor,p_operation);
 result_value:=jsonb_build_object('incident_id',s.incident_id,'scenario_id',s.id,'version',s.version::text,'operation_id',p_operation);
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,actor,p_acting_organization_id,s.incident_id,'SIM_'||p_action,request_value,result_value);
 perform private.write_audit(p_acting_organization_id,actor,event_value,'simulation_scenarios',s.id,null,jsonb_build_object('operation_id',p_operation,'event',event_payload,'result',result_value));
 return result_value;
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation then raise exception 'INVALID_SIMULATION_POSITION';
 when unique_violation then raise exception 'OPERATION_REUSED';
end; $$;

create function public.simulation_read(p_incident_id uuid,p_acting_organization_id uuid,p_before_sequence bigint default null) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare s public.simulation_scenarios; positions_value jsonb; candidates_value jsonb; events_value jsonb;
begin
 if not private.simulation_visible(p_incident_id,p_acting_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id;
 if not found then return jsonb_build_object('enabled',private.simulation_enabled(),'scenario',null,'positions','[]'::jsonb,'candidates','[]'::jsonb,'events','[]'::jsonb,'can_control',false); end if;
 if not private.simulation_enabled() then return jsonb_build_object('enabled',false,'scenario',to_jsonb(s)||jsonb_build_object('version',s.version::text),'positions','[]'::jsonb,'candidates','[]'::jsonb,'events','[]'::jsonb,'can_control',false); end if;
 select coalesce(jsonb_agg(q.dto order by q.ordinal),'[]') into positions_value from(
  select p.ordinal,to_jsonb(p)||jsonb_build_object('version',p.version::text,'callsign',ou.callsign,'name',ou.name,'organization_id',u.organization_id,'organization_name',o.name,'sector_id',u.sector_id,'deployment_status',u.status,
   'can_command',private.task_recipient_eligible(p_incident_id,'INCIDENT_UNIT',u.id) and private.can_issue_task(p_incident_id,p_acting_organization_id,'INCIDENT_UNIT',u.id)) dto
  from public.simulation_unit_positions p join public.incident_units u on u.id=p.incident_unit_id join public.operational_units ou on ou.id=u.unit_id join public.organizations o on o.id=u.organization_id
  where p.scenario_id=s.id and p.active order by p.ordinal limit 100) q;
 select coalesce(jsonb_agg(q.dto order by q.name,q.id),'[]') into candidates_value from(
  select u.id,ou.callsign name,jsonb_build_object('id',u.id,'name',ou.callsign||' · '||ou.name) dto
  from public.incident_units u join public.operational_units ou on ou.id=u.unit_id
  where u.incident_id=p_incident_id and u.status not in ('RELEASED','UNAVAILABLE') and private.simulation_controller(s.id,p_acting_organization_id)
  and private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,u.organization_id,u.id,'STATUS')
  and not exists(select 1 from public.simulation_unit_positions p where p.scenario_id=s.id and p.incident_unit_id=u.id)
  order by name,u.id limit 100) q;
 select coalesce(jsonb_agg(q.dto order by q.sequence desc),'[]') into events_value from(
  select e.sequence,to_jsonb(e)||jsonb_build_object('sequence',e.sequence::text) dto from public.simulation_events e
  where e.scenario_id=s.id and (p_before_sequence is null or e.sequence<p_before_sequence) order by e.sequence desc limit 50) q;
 return jsonb_build_object('enabled',true,'scenario',to_jsonb(s)||jsonb_build_object('version',s.version::text,'event_sequence',s.event_sequence::text),
 'positions',positions_value,'candidates',candidates_value,'events',events_value,'can_control',s.status<>'FINISHED' and private.simulation_controller(s.id,p_acting_organization_id),
 'next_ordinal',(select coalesce(max(ordinal),0)+1 from public.simulation_unit_positions where scenario_id=s.id),'capacity_remaining',(select 100-coalesce(max(ordinal),0) from public.simulation_unit_positions where scenario_id=s.id),
 'can_provision',s.status in ('DRAFT','PAUSED') and private.simulation_controller(s.id,p_acting_organization_id) and private.operational_inventory_manager(p_acting_organization_id)
  and private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,p_acting_organization_id,null,'DEPLOY'));
end; $$;
create function public.simulation_overview(p_acting_organization_id uuid,p_page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.incident_acting_member(p_acting_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_page is null or p_page not between 0 and 10000 then raise exception 'VALIDATION_FAILED'; end if;
 if not private.simulation_enabled() then return '[]'::jsonb; end if;
 return coalesce((select jsonb_agg(q.dto order by q.created_at desc,q.id) from(
 select s.id,s.created_at,jsonb_build_object('id',s.id,'incident_id',s.incident_id,'title',s.title,'reference_number',i.reference_number,'status',s.status,'updated_at',s.updated_at,
 'created_by',coalesce(p.display_name,s.created_by::text),'unit_count',(select count(*) from public.simulation_unit_positions pos where pos.scenario_id=s.id and pos.active)) dto
 from public.simulation_scenarios s join public.incidents i on i.id=s.incident_id join public.profiles p on p.id=s.created_by
 where private.simulation_visible(s.incident_id,p_acting_organization_id) order by s.created_at desc,s.id limit 25 offset p_page*25) q),'[]');
end; $$;
revoke all on function private.simulation_enabled() from public,anon,authenticated,service_role;
revoke all on function private.simulation_operator(uuid) from public,anon,authenticated,service_role;
revoke all on function private.simulation_controller(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.simulation_visible(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.simulation_storage_guard() from public,anon,authenticated,service_role;
revoke all on function private.simulation_resource_guard() from public,anon,authenticated,service_role;
revoke all on function private.simulation_initial_position(public.simulation_scenarios,integer) from public,anon,authenticated,service_role;
grant execute on function private.simulation_enabled() to authenticated;
revoke all on function public.simulation_environment(uuid) from public,anon,authenticated,service_role;
grant execute on function public.simulation_environment(uuid) to authenticated;
revoke all on function public.simulation_labels(uuid,uuid[]) from public,anon,authenticated,service_role;
grant execute on function public.simulation_labels(uuid,uuid[]) to authenticated;
revoke all on function public.simulation_create_scenario(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.simulation_create_scenario(uuid,uuid,uuid,bigint,jsonb) to authenticated;
revoke all on function public.simulation_command(uuid,uuid,uuid,bigint,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.simulation_command(uuid,uuid,uuid,bigint,text,jsonb) to authenticated;
revoke all on function public.simulation_read(uuid,uuid,bigint) from public,anon,authenticated,service_role;
grant execute on function public.simulation_read(uuid,uuid,bigint) to authenticated;
revoke all on function public.simulation_overview(uuid,integer) from public,anon,authenticated,service_role;
grant execute on function public.simulation_overview(uuid,integer) to authenticated;

-- Minimal training classification for already-authorized inbox projections.
create function public.simulation_inbox_labels(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_ids is null or cardinality(p_ids)>200 then raise exception 'VALIDATION_FAILED'; end if;
 return coalesce((select jsonb_object_agg(s.incident_id::text,jsonb_build_object('id',s.id,'title',s.title,'status',s.status,'version',s.version::text))
 from public.simulation_scenarios s where s.incident_id=any(p_ids) and (
 private.can_read_incident(s.incident_id)
 or exists(select 1 from private.incident_command_consents c where c.incident_id=s.incident_id and c.user_id=auth.uid() and c.status in ('REQUESTED','ACCEPTED') and private.incident_acting_member(c.organization_id))
 or exists(select 1 from public.incident_participants p where p.incident_id=s.incident_id and p.status='REQUESTED'
 and private.operational_inventory_manager(p.organization_id)))),'{}');
end; $$;
revoke all on function public.simulation_inbox_labels(uuid[]) from public,anon,authenticated,service_role;
grant execute on function public.simulation_inbox_labels(uuid[]) to authenticated;
