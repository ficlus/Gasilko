-- M14.6D: explicit training-only operational effects. Apply after M14.6C.2.
begin;
create table private.simulation_water_resources(
 id uuid primary key default gen_random_uuid(),scenario_id uuid not null references public.simulation_scenarios(id),
 incident_unit_id uuid not null,source_version_id uuid not null references public.simulation_scenario_template_versions(id),
 unit_key text not null,capacity_l numeric(12,3) not null check(capacity_l between 0 and 100000),
 remaining_l numeric(12,3) not null check(remaining_l>=0 and remaining_l<=capacity_l),
 pump_lpm numeric(10,3) not null check(pump_lpm between 0 and 5000),
 range_m numeric not null check(range_m between 1 and 100),efficiency numeric not null check(efficiency between 0.000001 and 0.001),
 version bigint not null default 1,unique(id,scenario_id),unique(scenario_id,incident_unit_id),
 foreign key(scenario_id,incident_unit_id) references public.simulation_unit_positions(scenario_id,incident_unit_id)
);
create table private.simulation_water_connections(
 id uuid primary key,scenario_id uuid not null references public.simulation_scenarios(id),
 source_type text not null default 'SIM_TANK' check(source_type='SIM_TANK'),
 source_id uuid not null,consumer_id uuid not null,flow_lpm numeric(10,3) not null check(flow_lpm>0 and flow_lpm<=5000),
 active boolean not null default true,version bigint not null default 1,
 actor uuid not null references public.profiles(id),operation_id uuid not null,
 created_second bigint not null,ended_second bigint,
 foreign key(source_id,scenario_id) references private.simulation_water_resources(id,scenario_id),
 foreign key(consumer_id,scenario_id) references private.simulation_water_resources(id,scenario_id),check(source_id<>consumer_id)
);
-- Deliberately one-hop, one source/consumer, not an unrestricted graph.
create unique index simulation_water_one_consumer on private.simulation_water_connections(consumer_id) where active;
create unique index simulation_water_one_source on private.simulation_water_connections(source_id) where active;
alter table private.simulation_hazard_models add constraint simulation_hazard_model_scope unique(id,scenario_id);
create table private.simulation_operational_executions(
 id uuid primary key,scenario_id uuid not null references public.simulation_scenarios(id),
 resource_id uuid not null,model_id uuid not null references private.simulation_hazard_models(id),
 assignment_id uuid references public.incident_task_assignments(id),action_version_id uuid references public.operational_action_definition_versions(id),
 kernel text not null default 'APPLY_WATER' check(kernel='APPLY_WATER'),kernel_version integer not null default 1 check(kernel_version=1),
 target jsonb not null,flow_lpm numeric(10,3) not null check(flow_lpm>0 and flow_lpm<=5000),
 duration_seconds integer not null check(duration_seconds between 5 and 3600 and duration_seconds%5=0),
 actor uuid not null references public.profiles(id),organization_id uuid not null references public.organizations(id),operation_id uuid not null unique,
 state text not null check(state in ('PENDING','ACTIVE','BLOCKED','COMPLETED','CANCELLED')),
 reason text,position_version bigint not null,start_step bigint not null,last_step bigint not null,
 active_seconds integer not null default 0,delivered_l numeric(14,3) not null default 0,
 version bigint not null default 1,ended_second bigint,
 foreign key(resource_id,scenario_id) references private.simulation_water_resources(id,scenario_id),
 foreign key(model_id,scenario_id) references private.simulation_hazard_models(id,scenario_id)
);
create unique index simulation_water_one_execution on private.simulation_operational_executions(resource_id)
 where state in ('PENDING','ACTIVE','BLOCKED');
create unique index simulation_water_assignment_once on private.simulation_operational_executions(assignment_id) where assignment_id is not null;
create index simulation_operational_due on private.simulation_operational_executions(model_id,last_step,id) where state in ('PENDING','ACTIVE');
create table private.simulation_operational_history(
 id bigint generated always as identity primary key,scenario_id uuid not null references public.simulation_scenarios(id),
 execution_id uuid references private.simulation_operational_executions(id),operation_id uuid not null,
 kind text not null,sim_second bigint not null,actor uuid references public.profiles(id),data jsonb not null check(octet_length(data::text)<=4096),
 recorded_at timestamptz not null default clock_timestamp(),unique(execution_id,sim_second,kind)
);
create index simulation_operational_history_page on private.simulation_operational_history(scenario_id,id desc);
do $security$
declare tab text;
begin
 foreach tab in array array['simulation_water_resources','simulation_water_connections','simulation_operational_executions','simulation_operational_history'] loop
  execute format('alter table private.%I enable row level security',tab);
  execute format('revoke all on private.%I from public,anon,authenticated,service_role',tab);
  execute format('create trigger %I before delete or truncate on private.%I for each statement execute function private.audit_immutable()',tab||'_retain',tab);
 end loop;
end; $security$;
create trigger simulation_operational_history_immutable before update on private.simulation_operational_history for each row execute function private.audit_immutable();
revoke all on sequence private.simulation_operational_history_id_seq from public,anon,authenticated,service_role;

create function private.validate_operational_config(d jsonb) returns void
language plpgsql stable security definer set search_path='' as $config$
declare cfg jsonb:=d->'operational';r jsonb;b jsonb;ids text[]:='{}';versions text[]:='{}';
begin
 if cfg is null then return;end if;
 perform private.sim_template_keys(cfg,array['schema_version','resources','bindings']);
 if cfg->'schema_version' is distinct from '1'::jsonb or jsonb_typeof(cfg->'resources') is distinct from 'array'
 or jsonb_array_length(cfg->'resources')>30 or jsonb_typeof(cfg->'bindings') is distinct from 'array' or jsonb_array_length(cfg->'bindings')>16 then raise exception 'INVALID_TEMPLATE';end if;
 for r in select value from jsonb_array_elements(cfg->'resources') loop
  perform private.sim_template_keys(r,array['unit_key','capacity_l','initial_l','pump_lpm','range_m','efficiency']);
  if r->>'unit_key'=any(ids) or not exists(select 1 from jsonb_array_elements(d->'virtual_units') u where u->>'id'=r->>'unit_key') then raise exception 'INVALID_TEMPLATE';end if;
  ids:=array_append(ids,r->>'unit_key');
  perform private.hazard_number(r->'capacity_l',0,100000);
  perform private.hazard_number(r->'initial_l',0,(r->>'capacity_l')::numeric);
  perform private.hazard_number(r->'pump_lpm',0,5000);
  perform private.hazard_number(r->'range_m',1,100);
  perform private.hazard_number(r->'efficiency',0.000001,0.001);
 end loop;
 for b in select value from jsonb_array_elements(cfg->'bindings') loop
  perform private.sim_template_keys(b,array['action_version_id','kernel','flow_lpm','duration_seconds']);
  if b->>'kernel' is distinct from 'APPLY_WATER' or b->>'action_version_id'=any(versions)
   or not exists(select 1 from public.operational_action_definition_versions v join public.operational_action_definitions a on a.id=v.definition_id
    where v.id=(b->>'action_version_id')::uuid and v.native_behavior='NONE'
    and (a.owner_organization_id is null or private.incident_acting_member(a.owner_organization_id))) then raise exception 'INVALID_TEMPLATE';end if;
  versions:=array_append(versions,b->>'action_version_id');
  perform private.hazard_number(b->'flow_lpm',0.001,5000);
  perform private.hazard_number(b->'duration_seconds',5,3600);
  if (b->>'duration_seconds')::numeric%5<>0 then raise exception 'INVALID_TEMPLATE';end if;
 end loop;
end; $config$;

create or replace function private.validate_simulation_template_pre_operations(d jsonb,ready boolean) returns void
language plpgsql immutable set search_path='' as $workflow$
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
exception when raise_exception or invalid_text_representation or numeric_value_out_of_range or invalid_parameter_value then
 raise exception 'INVALID_TEMPLATE';
end; $workflow$;
create or replace function private.validate_simulation_template(d jsonb,ready boolean) returns void
language plpgsql stable security definer set search_path='' as $wrapper$
begin
 if octet_length(d::text)>48000 then raise exception 'INVALID_TEMPLATE';end if;
 perform private.validate_simulation_template_pre_operations(d-'operational',ready);
 perform private.validate_operational_config(d);
end; $wrapper$;

create function private.operational_initialize() returns trigger
language plpgsql security definer set search_path='' as $initialize$
declare r jsonb;unit_id uuid;
begin
 if new.state<>'READY' or old.state='READY' then return new;end if;
 for r in select value from jsonb_array_elements(coalesce(new.definition#>'{operational,resources}','[]')) loop
  unit_id:=(new.unit_ids->>(r->>'unit_key'))::uuid;
  if unit_id is null then raise exception 'INVALID_TEMPLATE';end if;
  insert into private.simulation_water_resources(scenario_id,incident_unit_id,source_version_id,unit_key,capacity_l,remaining_l,pump_lpm,range_m,efficiency)
  values(new.scenario_id,unit_id,new.source_version_id,r->>'unit_key',(r->>'capacity_l')::numeric,(r->>'initial_l')::numeric,(r->>'pump_lpm')::numeric,(r->>'range_m')::numeric,(r->>'efficiency')::numeric);
 end loop;return new;
end; $initialize$;
create trigger simulation_operational_initialize after update on private.simulation_template_instances for each row execute function private.operational_initialize();

create function private.operational_available(p_resource uuid) returns boolean
language sql stable security definer set search_path='' as $available$
 select exists(select 1 from private.simulation_water_resources r
 join public.simulation_unit_positions p on p.scenario_id=r.scenario_id and p.incident_unit_id=r.incident_unit_id and p.active
 join public.incident_units u on u.id=r.incident_unit_id and u.status not in ('RELEASED','UNAVAILABLE')
 where r.id=p_resource and p.speed_mps=0 and not exists(select 1 from public.simulation_agent_runs a where a.scenario_id=r.scenario_id and a.incident_unit_id=r.incident_unit_id and a.route_id is not null and a.status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE','SIM_ARRIVED')));
$available$;
create function private.operational_log(p_scenario uuid,p_execution uuid,p_operation uuid,p_kind text,p_second bigint,p_actor uuid,p_data jsonb) returns void
language plpgsql security definer set search_path='' as $log$
begin
 insert into private.simulation_operational_history(scenario_id,execution_id,operation_id,kind,sim_second,actor,data)
 values(p_scenario,p_execution,p_operation,p_kind,p_second,p_actor,p_data);
 -- Coarse lifecycle only; never publish private model IDs/geometry into the shared timeline.
 if p_kind<>'DELIVERY' then perform private.agent_event(p_scenario,null,'OPERATIONAL_'||p_kind,p_second,p_operation,p_actor,'{}');end if;
end; $log$;

create function public.simulation_operational_command(p_organization_id uuid,p_incident_id uuid,p_operation uuid,p_action text,p_expected_version bigint,p_payload jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $command$
declare s public.simulation_scenarios;r private.simulation_water_resources;src private.simulation_water_resources;
 m private.simulation_hazard_models;x private.simulation_operational_executions;c private.simulation_water_connections;
 pos public.simulation_unit_positions;source_pos public.simulation_unit_positions;a public.incident_task_assignments;t public.incident_tasks;
 receipt private.simulation_template_receipts;req jsonb;result_value jsonb;cfg jsonb;b jsonb;point_value jsonb;
 clock_value bigint;step_value bigint;flow_value numeric;duration_value integer;quantity numeric;new_id uuid:=gen_random_uuid();xy jsonb;
begin
 if not private.simulation_operator(p_organization_id) or not private.simulation_visible(p_incident_id,p_organization_id) then raise exception 'NOT_AUTHORIZED';end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id and organization_id=p_organization_id;
 if not found or p_operation is null or p_expected_version is null or jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>4096 then raise exception 'VALIDATION_FAILED';end if;
 perform private.agent_locks(s.id);
 req:=jsonb_build_object('kind','OPERATIONAL_V1','incident',p_incident_id,'action',p_action,'expected',p_expected_version,'payload',p_payload);
 select * into receipt from private.simulation_template_receipts where operation_id=p_operation;
 if found then
  if receipt.actor<>auth.uid() or receipt.organization_id<>p_organization_id or receipt.request<>req then raise exception 'OPERATION_REUSED';end if;
  return receipt.result;
 end if;
 select * into s from public.simulation_scenarios where id=s.id;
 if not private.simulation_controller(s.id,p_organization_id) or not private.simulation_template_editor(p_organization_id) or not private.agent_controller(s.id) then raise exception 'NOT_AUTHORIZED';end if;
 if s.status not in ('RUNNING','PAUSED') then raise exception 'INVALID_SIMULATION_STATE';end if;
 select seconds into clock_value from public.simulation_scenario_clock where scenario_id=s.id;
 step_value:=least(5760,clock_value/5);
 if (select count(*) from private.simulation_operational_history where scenario_id=s.id)>=20000 then raise exception 'SIM_LIMIT';end if;
 if p_action in ('STOP_ACTIVITY','RESUME_ACTIVITY') then
  select * into x from private.simulation_operational_executions where id=(p_payload->>'execution_id')::uuid and scenario_id=s.id for update;
  if not found then raise exception 'VALIDATION_FAILED';end if;
  if x.version<>p_expected_version then raise exception 'STALE_VERSION';end if;
  if x.state not in ('PENDING','ACTIVE','BLOCKED') then raise exception 'INVALID_TRANSITION';end if;
  if p_action='RESUME_ACTIVITY' then
   if x.state<>'BLOCKED' or x.active_seconds>=x.duration_seconds or step_value>=5760 then raise exception 'INVALID_TRANSITION';end if;
   select * into r from private.simulation_water_resources where id=x.resource_id for update;
   if not private.operational_available(r.id) then raise exception 'OP_RESOURCE_UNAVAILABLE';end if;
   select * into pos from public.simulation_unit_positions where scenario_id=s.id and incident_unit_id=r.incident_unit_id;
   update private.simulation_operational_executions set state='PENDING',reason=null,start_step=step_value,last_step=step_value,position_version=pos.version,version=version+1 where id=x.id;
   perform private.operational_log(s.id,x.id,p_operation,'RESUMED',clock_value,auth.uid(),'{}');
  else
   update private.simulation_operational_executions set state='CANCELLED',reason='STOPPED',ended_second=clock_value,version=version+1 where id=x.id;
   perform private.operational_log(s.id,x.id,p_operation,'STOPPED',clock_value,auth.uid(),'{}');
  end if;
  new_id:=x.id;
 elsif p_action in ('APPLY_WATER','REFILL','CONNECT_SUPPLY','DISCONNECT_SUPPLY') then
  select * into r from private.simulation_water_resources where id=(p_payload->>'resource_id')::uuid and scenario_id=s.id for update;
  if not found then raise exception 'VALIDATION_FAILED';end if;
  if r.version<>p_expected_version then raise exception 'STALE_VERSION';end if;
  if not private.operational_available(r.id) then raise exception 'OP_RESOURCE_UNAVAILABLE';end if;
  -- Inventory/connection changes must not rewrite the inputs of an unprocessed past step.
  if exists(select 1 from private.simulation_operational_executions e join private.simulation_hazard_models h on h.id=e.model_id
   where e.scenario_id=s.id and e.state in ('PENDING','ACTIVE') and h.last_step<step_value) then raise exception 'OP_CATCHUP_REQUIRED';end if;
  select * into pos from public.simulation_unit_positions where scenario_id=s.id and incident_unit_id=r.incident_unit_id;
  if p_action='APPLY_WATER' then
   if r.pump_lpm<=0 then raise exception 'OP_CAPABILITY_REQUIRED';end if;
   if (select count(*) from private.simulation_operational_executions where scenario_id=s.id)>=128
    or (select count(*) from private.simulation_operational_executions where scenario_id=s.id and state in ('PENDING','ACTIVE','BLOCKED'))>=8
    or step_value>=5760 then raise exception 'SIM_LIMIT';end if;
   if exists(select 1 from private.simulation_operational_executions where resource_id=r.id and state in ('PENDING','ACTIVE','BLOCKED'))
    or exists(select 1 from private.simulation_water_connections where source_id=r.id and active) then raise exception 'OP_RESOURCE_BUSY';end if;
   select * into m from private.simulation_hazard_models where id=(p_payload->>'model_id')::uuid and scenario_id=s.id for update;
   if not found or not m.revealed or not (m.configuration->>'enabled')::boolean then raise exception 'OP_TARGET_UNAVAILABLE';end if;
   if m.last_step<step_value or m.last_error is not null or m.version>=9980 then raise exception 'OP_CATCHUP_REQUIRED';end if;
   point_value:=p_payload->'target';
   perform private.sim_template_position(point_value,true);
   flow_value:=private.hazard_number(p_payload->'flow_lpm',0.001,r.pump_lpm);
   duration_value:=private.hazard_number(p_payload->'duration_seconds',5,3600);
   if (p_payload->>'duration_seconds')::numeric%5<>0 then raise exception 'VALIDATION_FAILED';end if;
   if p_payload->>'assignment_id' is not null then
    select * into a from public.incident_task_assignments where id=(p_payload->>'assignment_id')::uuid and incident_id=s.incident_id and incident_unit_id=r.incident_unit_id;
    if not found or a.status not in ('ISSUED','ACKNOWLEDGED','IN_PROGRESS') then raise exception 'OP_TASK_UNAVAILABLE';end if;
    select * into t from public.incident_tasks where id=a.task_id and status='OPEN';
    if not found then raise exception 'OP_TASK_UNAVAILABLE';end if;
    select definition->'operational' into cfg from private.simulation_template_instances where scenario_id=s.id;
    select value into b from jsonb_array_elements(coalesce(cfg->'bindings','[]')) where value->>'action_version_id'=t.action_definition_version_id::text;
    if b is null or b->>'kernel'<>'APPLY_WATER' or t.target_type not in ('COORDINATE','INCIDENT_MAP_OBJECT','HYDRANT')
     or t.target_geometry_snapshot->>'type' is distinct from 'Point'
     or point_value is distinct from t.target_geometry_snapshot->'coordinates'
     or flow_value<>(b->>'flow_lpm')::numeric or duration_value<>(b->>'duration_seconds')::integer then raise exception 'OP_TASK_UNAVAILABLE';end if;
   end if;
   xy:=private.hazard_xy(point_value,jsonb_build_array(pos.longitude,pos.latitude));
   if sqrt(power((xy->>0)::numeric,2)+power((xy->>1)::numeric,2))>r.range_m then raise exception 'OP_OUT_OF_RANGE';end if;
   xy:=private.hazard_xy(point_value,m.configuration->'center');
   if not exists(select 1 from jsonb_array_elements(m.state) cell
    where sqrt(power((cell->>'x')::numeric*(m.configuration->>'cell_m')::numeric-(xy->>0)::numeric,2)+power((cell->>'y')::numeric*(m.configuration->>'cell_m')::numeric-(xy->>1)::numeric,2))<=25) then raise exception 'OP_TARGET_UNAVAILABLE';end if;
   insert into private.simulation_operational_executions(id,scenario_id,resource_id,model_id,assignment_id,action_version_id,target,flow_lpm,duration_seconds,actor,organization_id,operation_id,state,position_version,start_step,last_step)
   values(new_id,s.id,r.id,m.id,a.id,t.action_definition_version_id,point_value,flow_value,duration_value,auth.uid(),p_organization_id,p_operation,'PENDING',pos.version,step_value,step_value);
   perform private.operational_log(s.id,new_id,p_operation,'ARMED',clock_value,auth.uid(),jsonb_build_object('resource_id',r.id,'assignment_id',a.id,'kernel','APPLY_WATER','source_version_id',r.source_version_id));
  elsif p_action='REFILL' then
   quantity:=private.hazard_number(p_payload->'liters',0.001,r.capacity_l-r.remaining_l);
   perform private.sim_template_text(p_payload->'reason',500,true);
   update private.simulation_water_resources set remaining_l=remaining_l+quantity where id=r.id;
   perform private.operational_log(s.id,null,p_operation,'REFILLED',clock_value,auth.uid(),jsonb_build_object('resource_id',r.id,'liters',quantity,'reason',p_payload->'reason','policy','INSTRUCTOR_SIM_ONLY'));
   new_id:=r.id;
  elsif p_action='CONNECT_SUPPLY' then
   select * into src from private.simulation_water_resources where id=(p_payload->>'source_id')::uuid and scenario_id=s.id for update;
   if not found or src.id=r.id or src.capacity_l=0 or r.pump_lpm=0 then raise exception 'OP_CAPABILITY_REQUIRED';end if;
   if src.version is distinct from (p_payload->>'source_version')::bigint then raise exception 'STALE_VERSION';end if;
   if not private.operational_available(src.id) then raise exception 'OP_RESOURCE_UNAVAILABLE';end if;
   if exists(select 1 from private.simulation_water_connections where active and (source_id in (src.id,r.id) or consumer_id in (src.id,r.id)))
    or exists(select 1 from private.simulation_operational_executions where resource_id in (src.id,r.id) and state in ('PENDING','ACTIVE','BLOCKED')) then raise exception 'OP_RESOURCE_BUSY';end if;
   if (select count(*) from private.simulation_water_connections where scenario_id=s.id and active)>=8
    or (select count(*) from private.simulation_water_connections where scenario_id=s.id)>=128 then raise exception 'SIM_LIMIT';end if;
   select * into source_pos from public.simulation_unit_positions where scenario_id=s.id and incident_unit_id=src.incident_unit_id;
   xy:=private.hazard_xy(jsonb_build_array(source_pos.longitude,source_pos.latitude),jsonb_build_array(pos.longitude,pos.latitude));
   if sqrt(power((xy->>0)::numeric,2)+power((xy->>1)::numeric,2))>100 then raise exception 'OP_OUT_OF_RANGE';end if;
   flow_value:=private.hazard_number(p_payload->'flow_lpm',0.001,least(src.pump_lpm,r.pump_lpm));
   insert into private.simulation_water_connections(id,scenario_id,source_id,consumer_id,flow_lpm,actor,operation_id,created_second)
   values(new_id,s.id,src.id,r.id,flow_value,auth.uid(),p_operation,clock_value);
   update private.simulation_water_resources set version=version+1 where id=src.id;
   perform private.operational_log(s.id,null,p_operation,'CONNECTED',clock_value,auth.uid(),jsonb_build_object('connection_id',new_id,'source_id',src.id,'consumer_id',r.id,'flow_lpm',flow_value));
  else
   select * into c from private.simulation_water_connections where consumer_id=r.id and active for update;
   if not found then raise exception 'INVALID_TRANSITION';end if;
   update private.simulation_water_connections set active=false,version=version+1,ended_second=clock_value where id=c.id;
   -- Never silently fall back from a disconnected external supply to a tank.
   for x in select * from private.simulation_operational_executions where resource_id=r.id and state in ('PENDING','ACTIVE') loop
    update private.simulation_operational_executions set state='BLOCKED',reason='SUPPLY_DISCONNECTED',version=version+1 where id=x.id;
    perform private.operational_log(s.id,x.id,p_operation,'BLOCKED',clock_value,auth.uid(),'{"reason":"SUPPLY_DISCONNECTED"}');
   end loop;
   perform private.operational_log(s.id,null,p_operation,'DISCONNECTED',clock_value,auth.uid(),jsonb_build_object('connection_id',c.id));
   new_id:=c.id;
  end if;
  update private.simulation_water_resources set version=version+1 where id=r.id;
 else raise exception 'VALIDATION_FAILED';
 end if;
 result_value:=jsonb_build_object('id',new_id,'operation_id',p_operation);
 insert into private.simulation_template_receipts(operation_id,actor,organization_id,request,result) values(p_operation,auth.uid(),p_organization_id,req,result_value);
 perform private.write_audit(p_organization_id,auth.uid(),'SIM_OPERATIONAL_COMMAND','simulation_scenarios',s.id,null,jsonb_build_object('operation_id',p_operation,'action',p_action,'id',new_id));
 return result_value;
end; $command$;

create function private.operational_step(p_model uuid,p_step bigint) returns void
language plpgsql security definer set search_path='' as $step$
declare m private.simulation_hazard_models;e private.simulation_operational_executions;
 r private.simulation_water_resources;src private.simulation_water_resources;c private.simulation_water_connections;
 pos public.simulation_unit_positions;sp public.simulation_unit_positions;a public.incident_task_assignments;t public.incident_tasks;
 xy jsonb;distance_xy jsonb;cells integer;delivered numeric;rate numeric;reduction numeric;why text;next_state text;ack boolean;
begin
 select * into m from private.simulation_hazard_models where id=p_model for update;
 for e in select * from private.simulation_operational_executions where model_id=p_model and state in ('PENDING','ACTIVE') and last_step<p_step order by id limit 8 for update loop
  why:=null;delivered:=0;
  if (select count(*) from private.simulation_operational_history where scenario_id=e.scenario_id)>=19900 then why:='HISTORY_LIMIT';end if;
  select * into r from private.simulation_water_resources where id=e.resource_id for update;
  select * into pos from public.simulation_unit_positions where scenario_id=e.scenario_id and incident_unit_id=r.incident_unit_id;
  if not private.operational_available(r.id) or pos.version<>e.position_version then why:='RESOURCE_UNAVAILABLE';end if;
  if not m.revealed or not (m.configuration->>'enabled')::boolean then why:='TARGET_UNAVAILABLE';end if;
  if e.assignment_id is not null then
   select * into a from public.incident_task_assignments where id=e.assignment_id;
   select * into t from public.incident_tasks where id=a.task_id;
   if t.status<>'OPEN' or a.status not in ('ISSUED','ACKNOWLEDGED','IN_PROGRESS')
    or not exists(select 1 from public.incident_role_assignments role join public.incident_units u on u.id=r.incident_unit_id
     where role.incident_id=t.incident_id and role.user_id=t.issued_by and role.organization_id=t.issuing_organization_id
     and private.incident_assignment_effective(role.id)
     and (role.role='INCIDENT_COMMANDER' or role.role='AGENCY_COMMANDER' and role.organization_id=u.organization_id or role.role='SECTOR_COMMANDER' and role.sector_id=u.sector_id)) then why:='TASK_UNAVAILABLE';end if;
   ack:=a.status in ('ACKNOWLEDGED','IN_PROGRESS') or exists(
    select 1 from public.simulation_agent_runs run join public.simulation_scenarios scenario on scenario.id=run.scenario_id
    where run.task_assignment_id=a.id and run.scenario_id=e.scenario_id and run.acknowledged and scenario.automatic_execution
    and run.status in ('SIM_ACKNOWLEDGED','SIM_IN_PROGRESS','SIM_ARRIVED','SIM_COMPLETED'));
   if why is null and not ack and p_step-e.start_step>=720 then why:='ACK_TIMEOUT';end if;
   if why is null and not ack then
    update private.simulation_operational_executions set last_step=p_step,version=version+1 where id=e.id;
    continue;
   end if;
  end if;
  distance_xy:=private.hazard_xy(e.target,jsonb_build_array(pos.longitude,pos.latitude));
  if sqrt(power((distance_xy->>0)::numeric,2)+power((distance_xy->>1)::numeric,2))>r.range_m then why:='OUT_OF_RANGE';end if;
  select * into c from private.simulation_water_connections where consumer_id=r.id and active;
  if found then
   select * into src from private.simulation_water_resources where id=c.source_id for update;
   select * into sp from public.simulation_unit_positions where scenario_id=e.scenario_id and incident_unit_id=src.incident_unit_id;
   distance_xy:=private.hazard_xy(jsonb_build_array(sp.longitude,sp.latitude),jsonb_build_array(pos.longitude,pos.latitude));
   if not private.operational_available(src.id) or sqrt(power((distance_xy->>0)::numeric,2)+power((distance_xy->>1)::numeric,2))>100 then why:='SUPPLY_UNAVAILABLE';end if;
   rate:=least(e.flow_lpm,r.pump_lpm,src.pump_lpm,c.flow_lpm);
  else src:=r;rate:=least(e.flow_lpm,r.pump_lpm);
  end if;
  if src.remaining_l<=0 then why:='WATER_DEPLETED';end if;
  xy:=private.hazard_xy(e.target,m.configuration->'center');
  select count(*) into cells from jsonb_array_elements(m.state) cell where (cell->>'intensity')::numeric>0
   and sqrt(power((cell->>'x')::numeric*(m.configuration->>'cell_m')::numeric-(xy->>0)::numeric,2)+power((cell->>'y')::numeric*(m.configuration->>'cell_m')::numeric-(xy->>1)::numeric,2))<=25;
  if why is not null then
   update private.simulation_operational_executions set state='BLOCKED',reason=why,last_step=p_step,version=version+1 where id=e.id;
   perform private.operational_log(e.scenario_id,e.id,e.operation_id,'BLOCKED',p_step*5,null,jsonb_build_object('reason',why));continue;
  end if;
  if cells=0 then
   update private.simulation_operational_executions set state='COMPLETED',reason='NO_ACTIVE_CELLS',last_step=p_step,ended_second=p_step*5,version=version+1 where id=e.id;
   perform private.operational_log(e.scenario_id,e.id,e.operation_id,'COMPLETED',p_step*5,null,'{"reason":"NO_ACTIVE_CELLS"}');continue;
  end if;
  -- Floor to millilitres. A five-second step is delivered only once, atomically with hazard history.
  delivered:=trunc(least(src.remaining_l,rate*least(5,e.duration_seconds-e.active_seconds)/60),3);
  reduction:=delivered*r.efficiency/cells;
  select jsonb_agg(case when (cell->>'intensity')::numeric>0 and sqrt(
   power((cell->>'x')::numeric*(m.configuration->>'cell_m')::numeric-(xy->>0)::numeric,2)+
   power((cell->>'y')::numeric*(m.configuration->>'cell_m')::numeric-(xy->>1)::numeric,2))<=25
   then cell||jsonb_build_object('intensity',round(greatest(0,(cell->>'intensity')::numeric-reduction),6))
   else cell end order by cell->>'id') into m.state from jsonb_array_elements(m.state) cell;
  update private.simulation_water_resources set remaining_l=remaining_l-delivered,version=version+1 where id=src.id;
  update private.simulation_hazard_models set state=m.state where id=m.id;
  next_state:=case when e.active_seconds+5>=e.duration_seconds then 'COMPLETED' when src.remaining_l-delivered<0.001 then 'BLOCKED' else 'ACTIVE' end;
  update private.simulation_operational_executions set state=next_state,reason=case when next_state='BLOCKED' then 'WATER_DEPLETED' end,
   last_step=p_step,active_seconds=active_seconds+5,delivered_l=delivered_l+delivered,version=version+1,
   ended_second=case when next_state='COMPLETED' then p_step*5 end where id=e.id;
  if e.state='PENDING' then perform private.operational_log(e.scenario_id,e.id,e.operation_id,'STARTED',p_step*5,null,'{}');end if;
  perform private.operational_log(e.scenario_id,e.id,e.operation_id,'DELIVERY',p_step*5,null,
   jsonb_build_object('source_id',src.id,'resource_id',r.id,'assignment_id',e.assignment_id,'action_version_id',e.action_version_id,
   'model_id',m.id,'model_version',m.version,'delivered_l',delivered,'flow_lpm',rate,'kernel_version',1));
  if next_state<>'ACTIVE' then perform private.operational_log(e.scenario_id,e.id,e.operation_id,next_state,p_step*5,null,jsonb_build_object('reason',case when next_state='BLOCKED' then 'WATER_DEPLETED' else 'DURATION' end));end if;
 end loop;
end; $step$;

create function private.operational_lifecycle() returns trigger
language plpgsql security definer set search_path='' as $lifecycle$
declare e private.simulation_operational_executions;sec bigint;
begin
 select seconds into sec from public.simulation_scenario_clock where scenario_id=new.scenario_id;
 for e in select * from private.simulation_operational_executions where scenario_id=new.scenario_id and state in ('PENDING','ACTIVE','BLOCKED') order by id for update loop
  update private.simulation_operational_executions set state='CANCELLED',reason=new.event_type,ended_second=coalesce(sec,0),version=version+1 where id=e.id;
  perform private.operational_log(new.scenario_id,e.id,new.operation_id,'CANCELLED',coalesce(sec,0),new.actor_user_id,jsonb_build_object('reason',new.event_type));
 end loop;
 update private.simulation_water_connections set active=false,ended_second=coalesce(sec,0),version=version+1 where scenario_id=new.scenario_id and active;
 return new;
end; $lifecycle$;
create trigger simulation_operational_lifecycle after insert on public.simulation_events for each row
 when(new.event_type in ('SIMULATION_RESET','SIMULATION_FINISHED')) execute function private.operational_lifecycle();

create or replace function public.simulation_hazard_batch() returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='100ms' as $$
declare q record;m private.simulation_hazard_models;s public.simulation_scenarios;
 target bigint;n integer;steps integer:=0;failed integer:=0;v jsonb;started timestamptz:=clock_timestamp();one timestamptz;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'NOT_AUTHORIZED';end if;
 if not private.simulation_enabled() then return jsonb_build_object('steps',0);end if;
 -- Locks are acquired in the same order as agents/events. No model lock before
 -- agent_locks; concurrent invocations recheck the durable cursor after waiting.
 for q in select m.id,m.scenario_id from private.simulation_hazard_models m
 join public.simulation_scenarios s on s.id=m.scenario_id
 where s.status='RUNNING' and m.last_error is null and m.last_step<5760
 order by m.last_scan_at nulls first,m.id limit 4 loop
  exit when clock_timestamp()-started>interval '2 seconds';
  one:=clock_timestamp();
  begin
   perform private.agent_locks(q.scenario_id);
   select * into s from public.simulation_scenarios where id=q.scenario_id;
   update private.simulation_hazard_models set last_scan_at=clock_timestamp() where id=q.id;
   if s.status<>'RUNNING' or not private.simulation_event_authority(s.id)
    or not exists(select 1 from private.simulation_template_instances where scenario_id=s.id and state='READY') then continue;end if;
   select * into m from private.simulation_hazard_models where id=q.id for update;
   if m.last_error is not null then continue;end if;
   if m.version>=9980 then
    update private.simulation_hazard_models set version=version+1,last_error='HAZARD_HISTORY_LIMIT' where id=m.id;
    perform private.hazard_record(m.id,'LIMIT',null,'{"error":"HAZARD_HISTORY_LIMIT"}',true);continue;
   end if;
   select least(5760,seconds/5) into target from public.simulation_scenario_clock where scenario_id=s.id;
   perform private.hazard_apply(m.id);
   for n in 1..10 loop
    select * into m from private.simulation_hazard_models where id=q.id;
    exit when m.last_step>=target or m.version>=9980 or clock_timestamp()-started>interval '2 seconds' or exists(
     select 1 from private.simulation_hazard_effects e where e.model_id=m.id and e.effective_step<=m.last_step
     and not exists(select 1 from private.simulation_hazard_history h where h.model_id=m.id and h.operation_id=e.operation_id));
    v:=private.hazard_step(m.configuration,m.state,(m.last_step+1-m.started_step)*5);
    if m.state is distinct from v then
     update private.simulation_hazard_models set last_step=last_step+1,version=version+1,state=v where id=m.id returning * into m;
    else
     update private.simulation_hazard_models set last_step=last_step+1,version=version+1 where id=m.id returning * into m;
    end if;
    perform private.operational_step(m.id,m.last_step);
    select state into v from private.simulation_hazard_models where id=m.id;
    perform private.hazard_record(m.id,case when exists(select 1 from private.simulation_operational_history h where h.scenario_id=s.id and h.kind='DELIVERY' and h.sim_second=m.last_step*5 and h.data->>'model_id'=m.id::text) then 'STEP_WITH_OPERATIONS' else 'STEP' end,null,jsonb_build_object('burning',(select count(*) from jsonb_array_elements(v) c where (c->>'intensity')::numeric>0)),m.last_step%60=0 or m.last_step=5760);
    perform private.hazard_apply(m.id);steps:=steps+1;
   end loop;
   update private.simulation_hazard_models set last_scan_at=clock_timestamp(),processing_ms=round(extract(epoch from clock_timestamp()-one)*1000) where id=q.id;
  exception
   when lock_not_available or deadlock_detected or serialization_failure then failed:=failed+1;
   when others then
    -- This subtransaction rolls back its state/effect/history together.
    update private.simulation_hazard_models set last_error='HAZARD_PROCESSING_FAILED',last_scan_at=clock_timestamp(),version=version+1 where id=q.id;
    perform private.hazard_record(q.id,'ERROR',null,jsonb_build_object('error','HAZARD_PROCESSING_FAILED'),false);
    failed:=failed+1;
  end;
 end loop;
 return jsonb_build_object('steps',steps,'failed',failed,'duration_ms',round(extract(epoch from clock_timestamp()-started)*1000));
end $$;

create function public.simulation_operational_actions(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $actions$
begin
 if not private.simulation_template_editor(p_organization_id) then raise exception 'NOT_AUTHORIZED';end if;
 return coalesce((select jsonb_agg(to_jsonb(q) order by q.label_sl,q.id) from(
 select v.id,v.label_sl,v.label_de,v.version_number from public.operational_action_definition_versions v
 join public.operational_action_definitions d on d.current_version_id=v.id
 where d.active and v.active_for_new_commands and v.native_behavior='NONE'
 and 'INCIDENT_UNIT'=any(v.recipient_types) and (d.owner_organization_id is null or d.owner_organization_id=p_organization_id)
 order by v.label_sl,v.id limit 100) q),'[]');
end; $actions$;

create function public.simulation_operations_read(p_organization_id uuid,p_incident_id uuid,p_before bigint default null) returns jsonb
language plpgsql stable security definer set search_path='' as $read$
declare s public.simulation_scenarios;controller boolean;resources jsonb;executions jsonb;connections jsonb;history_value jsonb;assignments jsonb;seconds_value bigint;
begin
 if not private.simulation_visible(p_incident_id,p_organization_id) then raise exception 'NOT_AUTHORIZED';end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id;
 if not found then return null;end if;
 controller:=coalesce(private.simulation_controller(s.id,p_organization_id) and private.simulation_template_editor(p_organization_id),false);
 select seconds into seconds_value from public.simulation_scenario_clock where scenario_id=s.id;
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'unit_id',r.incident_unit_id,'name',ou.callsign,'capacity_l',r.capacity_l,'remaining_l',r.remaining_l,
 'pump_lpm',r.pump_lpm,'range_m',r.range_m,'version',r.version::text,'source_version_id',r.source_version_id,'available',private.operational_available(r.id),
 'position',case when p.active then jsonb_build_array(p.longitude,p.latitude) end) order by r.id),'[]') into resources
 from private.simulation_water_resources r join public.incident_units u on u.id=r.incident_unit_id
 join public.operational_units ou on ou.id=u.unit_id join public.simulation_unit_positions p on p.scenario_id=s.id and p.incident_unit_id=u.id
 where r.scenario_id=s.id;
 select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'resource_id',e.resource_id,'model_id',e.model_id,'assignment_id',e.assignment_id,
 'state',e.state,'reason',e.reason,'target',e.target,'flow_lpm',e.flow_lpm,'duration_seconds',e.duration_seconds,'active_seconds',e.active_seconds,
 'delivered_l',e.delivered_l,'version',e.version::text,'last_step',e.last_step) order by e.id),'[]') into executions
 from private.simulation_operational_executions e join private.simulation_hazard_models m on m.id=e.model_id
 where e.scenario_id=s.id and (controller or m.revealed and s.status<>'DRAFT');
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'source_id',c.source_id,'consumer_id',c.consumer_id,'flow_lpm',c.flow_lpm,'version',c.version::text) order by c.id),'[]')
 into connections from private.simulation_water_connections c where c.scenario_id=s.id and c.active;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.id::bigint desc),'[]') into history_value from(
 select h.id::text id,h.kind,h.sim_second,h.data,h.recorded_at from private.simulation_operational_history h
 left join private.simulation_operational_executions e on e.id=h.execution_id left join private.simulation_hazard_models m on m.id=e.model_id
 where h.scenario_id=s.id and (p_before is null or h.id<p_before) and (controller or h.execution_id is null or m.revealed and s.status<>'DRAFT')
 order by h.id desc limit 50) q;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.id),'[]') into assignments from(
 select a.id,r.id resource_id,t.title,a.status,t.target_geometry_snapshot->'coordinates' target,
 b.value->'flow_lpm' flow_lpm,b.value->'duration_seconds' duration_seconds
 from public.incident_task_assignments a join public.incident_tasks t on t.id=a.task_id
 join private.simulation_water_resources r on r.incident_unit_id=a.incident_unit_id and r.scenario_id=s.id
 join private.simulation_template_instances instance on instance.scenario_id=s.id
 cross join lateral jsonb_array_elements(coalesce(instance.definition#>'{operational,bindings}','[]')) b(value)
 where controller and a.incident_id=s.incident_id and a.status in ('ISSUED','ACKNOWLEDGED','IN_PROGRESS') and t.status='OPEN'
 and b.value->>'action_version_id'=t.action_definition_version_id::text and t.target_geometry_snapshot->>'type'='Point'
 and not exists(select 1 from private.simulation_operational_executions e where e.assignment_id=a.id)
 order by a.id limit 100) q;
 return jsonb_build_object('scenario_id',s.id,'status',s.status,'seconds',coalesce(seconds_value,0),'observed_at',statement_timestamp(),
 'can_control',controller and s.status in ('RUNNING','PAUSED'),'resources',resources,'executions',executions,'connections',connections,'history',history_value,'assignments',assignments);
end; $read$;

do $grants$
declare fn record;
begin
 for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='private' and p.proname in ('validate_operational_config','validate_simulation_template_pre_operations','operational_initialize','operational_available','operational_log','operational_step','operational_lifecycle') loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',fn.signature);
 end loop;
end; $grants$;
revoke all on function public.simulation_operational_command(uuid,uuid,uuid,text,bigint,jsonb),public.simulation_operations_read(uuid,uuid,bigint),public.simulation_operational_actions(uuid) from public,anon,authenticated,service_role;
grant execute on function public.simulation_operational_command(uuid,uuid,uuid,text,bigint,jsonb),public.simulation_operations_read(uuid,uuid,bigint),public.simulation_operational_actions(uuid) to authenticated;
create function private.operational_template_scope() returns trigger
language plpgsql security definer set search_path='' as $scope$
declare org uuid;
begin
 select organization_id into org from public.simulation_scenario_templates where id=new.template_id;
 if exists(select 1 from jsonb_array_elements(coalesce(new.definition#>'{operational,bindings}','[]')) b
 join public.operational_action_definition_versions v on v.id=(b->>'action_version_id')::uuid
 join public.operational_action_definitions a on a.id=v.definition_id
 where a.owner_organization_id is not null and a.owner_organization_id is distinct from org) then raise exception 'INVALID_TEMPLATE';end if;
 return new;
end; $scope$;
create trigger simulation_operational_template_scope before insert or update on public.simulation_scenario_template_versions for each row execute function private.operational_template_scope();
revoke all on function private.operational_template_scope() from public,anon,authenticated,service_role;

commit;
