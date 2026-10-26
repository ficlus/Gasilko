-- M14.6D hardening after PRs #79/#80; forward-only, never rewrite applied migrations.
begin;

-- Factor the existing M14.5A relationship predicate. Effective role validation
-- already checks the named actor's active profile, org membership and participation.
-- No JWT impersonation and no public arbitrary-actor API.
create function private.can_issue_task_as(p_actor uuid,p_incident uuid,p_org uuid,p_type text,p_recipient uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select exists(
 select 1 from public.incident_units u
 join public.incident_participants ip on ip.id=u.participation_id and ip.status='ACTIVE'
 join public.organizations o on o.id=u.organization_id and o.active
 join public.incident_role_assignments r on r.incident_id=u.incident_id and r.organization_id=p_org and r.user_id=p_actor
 where u.incident_id=p_incident and
 ((p_type='INCIDENT_UNIT' and u.id=p_recipient) or (p_type='INCIDENT_CREW_MEMBER' and exists(
 select 1 from public.incident_crew_members c where c.id=p_recipient and c.unit_assignment_id=u.id)))
 and private.incident_assignment_effective(r.id) and (
 r.role='INCIDENT_COMMANDER' or (r.role='AGENCY_COMMANDER' and r.organization_id=u.organization_id)
 or (r.role='SECTOR_COMMANDER' and r.sector_id=u.sector_id)
 or (r.role='UNIT_LEADER' and p_type='INCIDENT_CREW_MEMBER' and r.unit_assignment_id=u.id)));
$$;

create or replace function private.can_issue_task(p_incident uuid,p_org uuid,p_type text,p_recipient uuid) returns boolean
language sql volatile security definer set search_path='' as $authority$
 select private.incident_acting_member(p_org)
  and private.can_issue_task_as(auth.uid(),p_incident,p_org,p_type,p_recipient);
$authority$;
revoke all on function private.can_issue_task_as(uuid,uuid,uuid,text,uuid) from public,anon,authenticated,service_role;

-- Unknown historical visibility stays private; no old history is rewritten.
alter table private.simulation_operational_history add column shared_at_record boolean not null default false;
-- Legacy connections have no trustworthy position baseline: explicitly reconnect.
alter table private.simulation_water_connections add column source_position_version bigint,
 add column consumer_position_version bigint;

create function private.operational_connection_available(p_connection uuid) returns boolean
language sql stable security definer set search_path='' as $supply$
 select exists(select 1 from private.simulation_water_connections wc
 join private.simulation_water_resources sr on sr.id=wc.source_id and sr.scenario_id=wc.scenario_id
 join private.simulation_water_resources cr on cr.id=wc.consumer_id and cr.scenario_id=wc.scenario_id
 join public.simulation_unit_positions sp on sp.scenario_id=wc.scenario_id and sp.incident_unit_id=sr.incident_unit_id
 join public.simulation_unit_positions cp on cp.scenario_id=wc.scenario_id and cp.incident_unit_id=cr.incident_unit_id
 where wc.id=p_connection and wc.active and sp.version=wc.source_position_version and cp.version=wc.consumer_position_version
 and private.operational_available(sr.id) and private.operational_available(cr.id)
 and private.agent_distance(jsonb_build_array(sp.longitude,sp.latitude),jsonb_build_array(cp.longitude,cp.latitude))<=100);
$supply$;
revoke all on function private.operational_connection_available(uuid) from public,anon,authenticated,service_role;

create or replace function private.validate_operational_config(d jsonb) returns void
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
  if exists(select 1 from (values ((r->>'capacity_l')::numeric),((r->>'initial_l')::numeric),((r->>'pump_lpm')::numeric)) as quantities(amount)
   where amount<>trunc(amount,3)) then raise exception 'INVALID_TEMPLATE';end if;
  perform private.hazard_number(r->'range_m',1,100);
  perform private.hazard_number(r->'efficiency',0.000001,0.001);
 end loop;
 for b in select value from jsonb_array_elements(cfg->'bindings') loop
  perform private.sim_template_keys(b,array['action_version_id','kernel','flow_lpm','duration_seconds']);
  if b->>'kernel' is distinct from 'APPLY_WATER' or b->>'action_version_id'=any(versions)
   or not exists(select 1 from public.operational_action_definition_versions v join public.operational_action_definitions a on a.id=v.definition_id
    where v.id=(b->>'action_version_id')::uuid and v.native_behavior='NONE' and 'INCIDENT_UNIT'=any(v.recipient_types)
    and (a.owner_organization_id is null or private.incident_acting_member(a.owner_organization_id))) then raise exception 'INVALID_TEMPLATE';end if;
  versions:=array_append(versions,b->>'action_version_id');
  perform private.hazard_number(b->'flow_lpm',0.012,5000);
  perform private.hazard_number(b->'duration_seconds',5,3600);
  if (b->>'flow_lpm')::numeric<>trunc((b->>'flow_lpm')::numeric,3) or (b->>'duration_seconds')::numeric%5<>0 then raise exception 'INVALID_TEMPLATE';end if;
 end loop;
end; $config$;

create or replace function private.operational_log(p_scenario uuid,p_execution uuid,p_operation uuid,p_kind text,p_second bigint,p_actor uuid,p_data jsonb) returns void
language plpgsql security definer set search_path='' as $log$
declare visible boolean;
begin
 select sc.status<>'DRAFT' and case when p_execution is null then p_kind in ('REFILLED','CONNECTED','DISCONNECTED')
  else exists(select 1 from private.simulation_operational_executions ex join private.simulation_hazard_models hm on hm.id=ex.model_id
   where ex.id=p_execution and ex.scenario_id=p_scenario and hm.revealed) end
 into visible from public.simulation_scenarios sc where sc.id=p_scenario;
 insert into private.simulation_operational_history(scenario_id,execution_id,operation_id,kind,sim_second,actor,data,shared_at_record)
 values(p_scenario,p_execution,p_operation,p_kind,p_second,p_actor,p_data,coalesce(visible,false));
 -- Coarse lifecycle only; never publish private model IDs/geometry into the shared timeline.
 if p_kind<>'DELIVERY' then perform private.agent_event(p_scenario,null,'OPERATIONAL_'||p_kind,p_second,p_operation,p_actor,'{}');end if;
end; $log$;

create or replace function public.simulation_operational_command(p_organization_id uuid,p_incident_id uuid,p_operation uuid,p_action text,p_expected_version bigint,p_payload jsonb) returns jsonb
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
 if p_action not in ('STOP_ACTIVITY','DISCONNECT_SUPPLY') and (select count(*) from private.simulation_operational_history where scenario_id=s.id)>=20000 then raise exception 'SIM_LIMIT';end if;
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
  if p_action<>'DISCONNECT_SUPPLY' and not private.operational_available(r.id) then raise exception 'OP_RESOURCE_UNAVAILABLE';end if;
  -- Inventory/connection changes must not rewrite the inputs of an unprocessed past step.
  if p_action<>'DISCONNECT_SUPPLY' and exists(select 1 from private.simulation_operational_executions e join private.simulation_hazard_models h on h.id=e.model_id
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
   flow_value:=private.hazard_number(p_payload->'flow_lpm',0.012,r.pump_lpm);
   if flow_value<>trunc(flow_value,3) then raise exception 'VALIDATION_FAILED';end if;
   duration_value:=private.hazard_number(p_payload->'duration_seconds',5,3600);
   if (p_payload->>'duration_seconds')::numeric%5<>0 then raise exception 'VALIDATION_FAILED';end if;
   if p_payload->>'assignment_id' is not null then
    select * into a from public.incident_task_assignments where id=(p_payload->>'assignment_id')::uuid and incident_id=s.incident_id and incident_unit_id=r.incident_unit_id;
    if not found or a.recipient_type is distinct from 'INCIDENT_UNIT' or a.status not in ('ISSUED','ACKNOWLEDGED','IN_PROGRESS') then raise exception 'OP_TASK_UNAVAILABLE';end if;
    select * into t from public.incident_tasks where id=a.task_id and status='OPEN';
    if not found or not private.task_recipient_eligible(s.incident_id,a.recipient_type,r.incident_unit_id)
     or not private.can_issue_task_as(t.issued_by,t.incident_id,t.issuing_organization_id,a.recipient_type,r.incident_unit_id)
     then raise exception 'OP_TASK_UNAVAILABLE';end if;
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
   if quantity<>trunc(quantity,3) then raise exception 'VALIDATION_FAILED';end if;
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
    or exists(select 1 from private.simulation_operational_executions where (resource_id=src.id and state in ('PENDING','ACTIVE','BLOCKED')) or (resource_id=r.id and state in ('PENDING','ACTIVE'))) then raise exception 'OP_RESOURCE_BUSY';end if;
   if (select count(*) from private.simulation_water_connections where scenario_id=s.id and active)>=8
    or (select count(*) from private.simulation_water_connections where scenario_id=s.id)>=128 then raise exception 'SIM_LIMIT';end if;
   select * into source_pos from public.simulation_unit_positions where scenario_id=s.id and incident_unit_id=src.incident_unit_id;
   xy:=private.hazard_xy(jsonb_build_array(source_pos.longitude,source_pos.latitude),jsonb_build_array(pos.longitude,pos.latitude));
   if sqrt(power((xy->>0)::numeric,2)+power((xy->>1)::numeric,2))>100 then raise exception 'OP_OUT_OF_RANGE';end if;
   flow_value:=private.hazard_number(p_payload->'flow_lpm',0.012,least(src.pump_lpm,r.pump_lpm));
   if flow_value<>trunc(flow_value,3) then raise exception 'VALIDATION_FAILED';end if;
   insert into private.simulation_water_connections(id,scenario_id,source_id,consumer_id,flow_lpm,actor,operation_id,created_second,source_position_version,consumer_position_version)
   values(new_id,s.id,src.id,r.id,flow_value,auth.uid(),p_operation,clock_value,source_pos.version,pos.version);
   update private.simulation_water_resources set version=version+1 where id=src.id;
   perform private.operational_log(s.id,null,p_operation,'CONNECTED',clock_value,auth.uid(),jsonb_build_object('connection_id',new_id,'source_id',src.id,'consumer_id',r.id,'flow_lpm',flow_value));
  else
   select * into c from private.simulation_water_connections where consumer_id=r.id and active for update;
   if not found then raise exception 'INVALID_TRANSITION';end if;
   update private.simulation_water_connections set active=false,version=version+1,ended_second=clock_value where id=c.id;
   update private.simulation_water_resources set version=version+1 where id=c.source_id;
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

create or replace function private.operational_step(p_model uuid,p_step bigint) returns void
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
   if t.status is distinct from 'OPEN' or a.recipient_type is distinct from 'INCIDENT_UNIT'
    or a.incident_id is distinct from t.incident_id or a.incident_unit_id is distinct from r.incident_unit_id
    or a.status not in ('ISSUED','ACKNOWLEDGED','IN_PROGRESS')
    or not private.task_recipient_eligible(t.incident_id,a.recipient_type,r.incident_unit_id)
    or not private.can_issue_task_as(t.issued_by,t.incident_id,t.issuing_organization_id,a.recipient_type,r.incident_unit_id)
    then why:='TASK_UNAVAILABLE';end if;
   ack:=a.status in ('ACKNOWLEDGED','IN_PROGRESS') or exists(
    select 1 from public.simulation_agent_runs run join public.simulation_scenarios scenario on scenario.id=run.scenario_id
    where run.task_assignment_id=a.id and run.scenario_id=e.scenario_id and run.acknowledged and scenario.automatic_execution
    and run.status in ('SIM_ACKNOWLEDGED','SIM_IN_PROGRESS','SIM_ARRIVED','SIM_COMPLETED'));
   if why is null and not ack and p_step-e.start_step>=720 then why:='ACK_TIMEOUT';end if;
   if why is null and not ack then
    update private.simulation_operational_executions set reason='AWAITING_ACK',last_step=p_step,version=version+1 where id=e.id;
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
   if not private.operational_connection_available(c.id) or sqrt(power((distance_xy->>0)::numeric,2)+power((distance_xy->>1)::numeric,2))>100 then why:='SUPPLY_UNAVAILABLE';end if;
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
  if delivered<=0 then
   update private.simulation_operational_executions set state='BLOCKED',reason='FLOW_BELOW_PRECISION',last_step=p_step,version=version+1 where id=e.id;
   perform private.operational_log(e.scenario_id,e.id,e.operation_id,'BLOCKED',p_step*5,null,'{"reason":"FLOW_BELOW_PRECISION"}');continue;
  end if;
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

create or replace function public.simulation_operations_read(p_organization_id uuid,p_incident_id uuid,p_before bigint default null) returns jsonb
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
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'source_id',c.source_id,'consumer_id',c.consumer_id,'flow_lpm',c.flow_lpm,'version',c.version::text,'available',private.operational_connection_available(c.id)) order by c.id),'[]')
 into connections from private.simulation_water_connections c where c.scenario_id=s.id and c.active;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.id::bigint desc),'[]') into history_value from(
 select h.id::text id,h.kind,h.sim_second,
 case when controller then h.data else jsonb_strip_nulls(jsonb_build_object(
  'delivered_l',h.data->'delivered_l','liters',h.data->'liters','flow_lpm',h.data->'flow_lpm',
  'reason',case when h.kind<>'REFILLED' and h.data->>'reason' in
   ('HISTORY_LIMIT','RESOURCE_UNAVAILABLE','TARGET_UNAVAILABLE','TASK_UNAVAILABLE','ACK_TIMEOUT','OUT_OF_RANGE',
    'SUPPLY_UNAVAILABLE','WATER_DEPLETED','NO_ACTIVE_CELLS','DURATION','SUPPLY_DISCONNECTED','FLOW_BELOW_PRECISION',
    'SIMULATION_RESET','SIMULATION_FINISHED') then h.data->'reason' end)) end data,h.recorded_at from private.simulation_operational_history h
 left join private.simulation_operational_executions e on e.id=h.execution_id left join private.simulation_hazard_models m on m.id=e.model_id
 where h.scenario_id=s.id and (p_before is null or h.id<p_before) and (controller or (s.status<>'DRAFT' and h.shared_at_record and (
  h.execution_id is not null and m.revealed
  or h.execution_id is null and h.kind in ('REFILLED','CONNECTED','DISCONNECTED'))))
 order by h.id desc limit 50) q;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.id),'[]') into assignments from(
 select a.id,r.id resource_id,t.title,a.status,t.target_geometry_snapshot->'coordinates' target,
 b.value->'flow_lpm' flow_lpm,b.value->'duration_seconds' duration_seconds
 from public.incident_task_assignments a join public.incident_tasks t on t.id=a.task_id
 join private.simulation_water_resources r on r.incident_unit_id=a.incident_unit_id and r.scenario_id=s.id
 join private.simulation_template_instances instance on instance.scenario_id=s.id
 cross join lateral jsonb_array_elements(coalesce(instance.definition#>'{operational,bindings}','[]')) b(value)
 where controller and a.recipient_type='INCIDENT_UNIT'
 and private.task_recipient_eligible(t.incident_id,a.recipient_type,r.incident_unit_id)
 and private.can_issue_task_as(t.issued_by,t.incident_id,t.issuing_organization_id,a.recipient_type,r.incident_unit_id)
 and a.incident_id=s.incident_id and a.status in ('ISSUED','ACKNOWLEDGED','IN_PROGRESS') and t.status='OPEN'
 and b.value->>'action_version_id'=t.action_definition_version_id::text and t.target_geometry_snapshot->>'type'='Point'
 and not exists(select 1 from private.simulation_operational_executions e where e.assignment_id=a.id)
 order by a.id limit 100) q;
 return jsonb_build_object('scenario_id',s.id,'status',s.status,'seconds',coalesce(seconds_value,0),'observed_at',statement_timestamp(),
 'can_control',controller and private.agent_controller(s.id) and s.status in ('RUNNING','PAUSED'),'resources',resources,'executions',executions,'connections',connections,'history',history_value,'assignments',assignments);
end; $read$;

commit;
