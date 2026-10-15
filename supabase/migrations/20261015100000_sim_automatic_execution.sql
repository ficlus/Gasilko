-- M14.5H1. Forward-only; apply after M14.5E/F3. No scheduler or environment changes.
begin;

alter table public.simulation_scenarios add column automatic_execution boolean not null default false;
alter table public.simulation_scenarios add column automatic_profile text not null default 'NORMAL'
 check(automatic_profile in ('NORMAL','SLOW_RESPONSE','NO_RESPONSE','BREAKDOWN','COMMUNICATION_LOSS','ROUTE_BLOCKED'));

-- One execution policy, shared by enrollment and every worker transition.
create function private.automation_policy(p_behavior text) returns text
language sql immutable set search_path='' as $$
 select case p_behavior when 'MOVE_TO' then 'ROAD' when 'WITHDRAW_TO' then 'ROAD'
 when 'HOLD_POSITION' then 'VIRTUAL' when 'REQUEST_STATUS' then 'VIRTUAL' else 'MANUAL' end;
$$;

create table private.simulation_automation_jobs (
 id uuid primary key default gen_random_uuid(),
 scenario_id uuid not null, incident_id uuid not null, task_id uuid not null,
 assignment_id uuid not null unique, incident_unit_id uuid not null,
 action_version_id uuid not null references public.operational_action_definition_versions(id),
 behavior text not null, profile text not null check(profile in ('NORMAL','SLOW_RESPONSE','NO_RESPONSE','BREAKDOWN','COMMUNICATION_LOSS','ROUTE_BLOCKED')),
 approved_by uuid not null references public.profiles(id), organization_id uuid not null references public.organizations(id),
 state text not null check(state in ('QUEUED','PLANNING','RETRY','BLOCKED','UNSUPPORTED','STARTED','CANCELLED')),
 version bigint not null default 1, attempts integer not null default 0,
 next_attempt_at timestamptz not null default clock_timestamp(),
 lease_token uuid, lease_until timestamptz, input jsonb,
 session_id uuid not null default gen_random_uuid(), route_operation uuid not null default gen_random_uuid(),
 run_id uuid not null default gen_random_uuid(),
 navigation_session_id uuid, agent_run_id uuid,
 error_code text, error_detail jsonb not null default '{}',
 created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 foreign key(scenario_id,incident_id) references public.simulation_scenarios(id,incident_id),
 foreign key(task_id,incident_id) references public.incident_tasks(id,incident_id),
 foreign key(assignment_id,incident_id) references public.incident_task_assignments(id,incident_id),
 foreign key(incident_unit_id,incident_id) references public.incident_units(id,incident_id),
 foreign key(navigation_session_id,incident_id) references public.incident_navigation_sessions(id,incident_id),
 foreign key(agent_run_id,scenario_id,incident_unit_id) references public.simulation_agent_runs(id,scenario_id,incident_unit_id)
);
create index simulation_automation_due on private.simulation_automation_jobs(next_attempt_at,created_at,id)
 where state in ('QUEUED','RETRY','PLANNING');
create index simulation_automation_scope on private.simulation_automation_jobs(scenario_id,created_at desc,id);
revoke all on private.simulation_automation_jobs from public,anon,authenticated,service_role;
create trigger simulation_automation_no_delete before delete on private.simulation_automation_jobs for each row execute function private.audit_immutable();
create trigger simulation_automation_no_truncate before truncate on private.simulation_automation_jobs for each statement execute function private.audit_immutable();

-- Actor-explicit validation of the original command, without setting JWT claims.
create function private.automation_authorized(j private.simulation_automation_jobs) returns boolean
language sql volatile security definer set search_path='' as $$
 select private.agent_controller(j.scenario_id) and exists(
 select 1 from public.incident_role_assignments r join public.incident_units u on u.id=j.incident_unit_id
 where r.incident_id=j.incident_id and r.user_id=j.approved_by and r.organization_id=j.organization_id
 and private.incident_assignment_effective(r.id)
 and (r.role='INCIDENT_COMMANDER' or (r.role='AGENCY_COMMANDER' and r.organization_id=u.organization_id)
 or (r.role='SECTOR_COMMANDER' and r.sector_id=u.sector_id)));
$$;

create function private.automation_event(j private.simulation_automation_jobs,p_event text,p_actor uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare v_time bigint;
begin
 select seconds into v_time from public.simulation_scenario_clock where scenario_id=j.scenario_id;
 perform private.agent_event(j.scenario_id,null,p_event,coalesce(v_time,0),gen_random_uuid(),p_actor,
 jsonb_build_object('job_id',j.id,'task_id',j.task_id,'unit_id',j.incident_unit_id,'state',j.state,'error',j.error_code));
end; $$;

create function private.automation_enroll() returns trigger
language plpgsql security definer set search_path='' as $$
declare s public.simulation_scenarios;t public.incident_tasks;v public.operational_action_definition_versions;j private.simulation_automation_jobs;
begin
 -- Same incident lock as task acceptance and the setting command: no time-window race.
 if new.recipient_type<>'INCIDENT_UNIT' then return null;end if;
 select * into s from public.simulation_scenarios where incident_id=new.incident_id for update;
 if not found or not s.automatic_execution or s.status not in ('DRAFT','RUNNING','PAUSED') or not private.simulation_enabled() then return null;end if;
 select * into t from public.incident_tasks where id=new.task_id;
 select * into v from public.operational_action_definition_versions where id=t.action_definition_version_id;
 insert into public.simulation_scenario_clock(scenario_id) values(s.id) on conflict do nothing;
 insert into private.simulation_automation_jobs(scenario_id,incident_id,task_id,assignment_id,incident_unit_id,
 action_version_id,behavior,profile,approved_by,organization_id,state,error_code)
 values(s.id,new.incident_id,new.task_id,new.id,new.incident_unit_id,v.id,v.native_behavior,s.automatic_profile,t.issued_by,t.issuing_organization_id,
 case when private.automation_policy(v.native_behavior)='MANUAL' then 'UNSUPPORTED' else 'QUEUED' end,
 case when private.automation_policy(v.native_behavior)='MANUAL' then 'AUTO_MANUAL' end) returning * into j;
 perform private.automation_event(j,'SIM_AUTO_'||j.state);
 return null;
end; $$;
-- In the authorized task transaction. Rollback also rolls back jobs; no historical backfill.
create trigger simulation_automation_enrollment after insert on public.incident_task_assignments
 for each row execute function private.automation_enroll();

create function private.automation_error(p_job uuid,p_code text,p_detail jsonb default '{}') returns void
language plpgsql security definer set search_path='' as $$
declare j private.simulation_automation_jobs;retryable boolean;
begin
 select * into j from private.simulation_automation_jobs where id=p_job for update;
 retryable:=p_code in ('ROUTE_PROVIDER','AUTO_TIMEOUT','STALE_VERSION') and j.attempts<5;
 update private.simulation_automation_jobs set state=case when retryable then 'RETRY' else 'BLOCKED' end,
 error_code=p_code,error_detail=p_detail,lease_token=null,lease_until=null,
 next_attempt_at=clock_timestamp()+make_interval(secs=>least(300,5*power(2,least(j.attempts,6))::integer)),
 version=version+1,updated_at=clock_timestamp() where id=j.id returning * into j;
 perform private.automation_event(j,'SIM_AUTO_'||j.state);
end; $$;

-- Shared START validation/insertion for human-confirmed and constrained automation callers.
-- Caller must hold agent_locks and validate human authority or the persisted automation job.
create function private.agent_start(p_scenario uuid,p_organization_id uuid,p_actor uuid,p_event_actor uuid,p_operation uuid,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.simulation_scenarios;c public.simulation_scenario_clock;r public.simulation_agent_runs;
 a public.incident_task_assignments;n public.incident_navigation_sessions;route public.incident_navigation_routes;p public.simulation_unit_positions;
 behavior_value text;len float8:=0;mult float8;ack integer;start_delay integer;completion integer;fault float8;duration integer;
 profile_value text;run_id uuid;random_value bigint;event_value text;
begin
 select * into s from public.simulation_scenarios where id=p_scenario;
 select * into c from public.simulation_scenario_clock where scenario_id=s.id;
 if s.status<>'RUNNING' or not private.agent_controller(s.id) then raise exception 'INVALID_SIMULATION_STATE';end if;
 if (select count(*) from public.simulation_agent_runs where scenario_id=s.id)>=1000 or
 (select count(*) from public.simulation_agent_runs where scenario_id=s.id and status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE'))>=100 then raise exception 'SIM_LIMIT';end if;
 select * into a from public.incident_task_assignments where id=(p_payload->>'assignment_id')::uuid and incident_id=s.incident_id for update;
 if not found or a.recipient_type<>'INCIDENT_UNIT' or not private.navigation_live(a.id) then raise exception 'INVALID_SIMULATION_UNIT';end if;
 select coalesce(v.native_behavior,'GENERIC') into behavior_value from public.incident_tasks t join public.operational_action_definition_versions v on v.id=t.action_definition_version_id where t.id=a.task_id;
 if private.automation_policy(behavior_value)='ROAD' and exists(
 select 1 from public.simulation_agent_runs held join private.simulation_automation_jobs job on job.agent_run_id=held.id
 where held.incident_unit_id=a.incident_unit_id and held.behavior='HOLD_POSITION'
 and held.status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE')) then raise exception 'SIM_RUN_EXISTS';end if;
 select * into p from public.simulation_unit_positions where scenario_id=s.id and incident_unit_id=a.incident_unit_id and active for update;
 if not found or p.version is distinct from (p_payload->>'position_version')::bigint then raise exception 'STALE_VERSION';end if;
 if behavior_value in ('MOVE_TO','WITHDRAW_TO') then
 select * into n from public.incident_navigation_sessions where id=(p_payload->>'session_id')::uuid and task_assignment_id=a.id and incident_unit_id=a.incident_unit_id for update;
 if not found or n.status not in ('PLANNED','ACTIVE','PAUSED') or n.current_route_id is distinct from (p_payload->>'route_id')::uuid then raise exception 'SIM_ROUTE_REQUIRED';end if;
 select * into route from public.incident_navigation_routes where id=n.current_route_id;
 if route.origin_snapshot->>'source' is distinct from 'SIMULATED_POSITION' or
 route.origin_snapshot->>'scenario_id' is distinct from s.id::text or route.origin_snapshot->>'incident_unit_id' is distinct from p.incident_unit_id::text or
 route.origin_snapshot->>'version' is distinct from p.version::text then raise exception 'STALE_VERSION';end if;
 len:=private.agent_path(route.id);
 if private.agent_distance(jsonb_build_array(p.longitude,p.latitude),route.origin_snapshot->'coordinate')>0.1 or
 private.agent_distance(jsonb_build_array(p.longitude,p.latitude),route.snapped_origin)>5 or
 private.agent_distance(jsonb_build_array(p.longitude,p.latitude),route.route_geometry->'coordinates'->0)>5 then raise exception 'SIM_ACCESS_GAP';end if;
 elsif p_payload->>'route_id' is not null or p_payload->>'session_id' is not null then raise exception 'VALIDATION_FAILED';end if;
 run_id:=(p_payload->>'run_id')::uuid;profile_value:=p_payload->>'profile';
 random_value:=('x'||substr(md5(s.seed::text||':'||run_id::text||':'||profile_value),1,8))::bit(32)::bigint;
 ack:=coalesce((p_payload->>'ack_delay')::integer,case when profile_value='SLOW_RESPONSE' then 15 else 2+mod(random_value,4)::integer end);
 start_delay:=coalesce((p_payload->>'start_delay')::integer,case when profile_value='SLOW_RESPONSE' then 10 else 2 end);
 completion:=coalesce((p_payload->>'completion_delay')::integer,5);mult:=coalesce((p_payload->>'speed_factor')::float8,1);
 fault:=coalesce((p_payload->>'fault_progress')::float8,0.25+mod(random_value,50)/100.0);
 duration:=coalesce((p_payload->>'signal_duration')::integer,30);
 if ack not between 0 and 600 or start_delay not between 0 and 600 or completion not between 0 and 3600
 or not(mult between 0.1 and 3) or not(fault between 0.01 and 0.99) or duration not between 1 and 3600 then raise exception 'VALIDATION_FAILED';end if;
 insert into public.simulation_agent_runs(id,scenario_id,incident_id,incident_unit_id,task_assignment_id,navigation_session_id,route_id,
 behavior,profile,configuration,ack_due,start_due,completion_delay,length_m,baseline_mps,last_sim,last_sample,position_version,created_by,organization_id)
 values(run_id,s.id,s.incident_id,a.incident_unit_id,a.id,n.id,route.id,behavior_value,profile_value,
 jsonb_build_object('seed',s.seed,'choice',random_value,'ack_delay',ack,'start_delay',start_delay,'completion_delay',completion,'speed_factor',mult,'fault_progress',fault,'signal_duration',duration),
 c.seconds+ack,c.seconds+ack+start_delay,completion,len,case when len>0 then least(100,len/nullif(route.duration_s,0)*mult) else 0 end,
 c.seconds,c.seconds,p.version,p_actor,p_organization_id) returning * into r;
 perform private.agent_event(s.id,r.id,'SIM_RUN_CREATED',c.seconds,p_operation,p_event_actor,r.configuration);
 if profile_value='NO_RESPONSE' then
 r:=private.agent_failure(r,'SIM_NO_RESPONSE',1,c.seconds,p_operation);perform private.agent_save(r);
 elsif profile_value in ('BREAKDOWN','COMMUNICATION_LOSS','ROUTE_BLOCKED') then
 event_value:=case profile_value when 'BREAKDOWN' then 'SIM_BREAKDOWN' when 'COMMUNICATION_LOSS' then 'SIM_SIGNAL_LOSS' else 'SIM_ROAD_BLOCKED' end;
 insert into public.simulation_event_injections(id,scenario_id,run_id,event_type,trigger_type,trigger_value,duration,created_by)
 values(md5(run_id::text||':profile')::uuid,s.id,run_id,event_value,case when len>0 then 'PROGRESS' else 'EXECUTION_START' end,case when len>0 then fault else 0 end,duration,p_actor);
 end if;
 return jsonb_build_object('id',run_id);

end; $$;

-- Route validation/storage is shared; callers own authorization and snapshot validation.
create function private.navigation_store_route(p_actor uuid,p_organization_id uuid,p_request jsonb,p_input jsonb,p_route jsonb,p_system boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.incident_navigation_sessions;route_id uuid:=gen_random_uuid();rev integer;result_value jsonb;
 op uuid:=(p_request->>'operation_id')::uuid;point_value jsonb;previous text;
begin
 if p_route->>'provider' is null or (p_route->>'distance_m')::float8 is null or (p_route->>'duration_s')::float8 is null
 or not((p_route->>'distance_m')::float8>=0 and (p_route->>'distance_m')::float8<'Infinity'::float8)
 or not((p_route->>'duration_s')::float8>=0 and (p_route->>'duration_s')::float8<'Infinity'::float8) then raise exception 'ROUTE_PROVIDER';end if;
  if p_route->>'provider' not in ('OSRM','GraphHopper') or p_route->>'profile' is distinct from 'car'
  or p_route->'geometry'->>'type' is distinct from 'LineString'
  or jsonb_typeof(p_route->'geometry'->'coordinates') is distinct from 'array'
  or octet_length(p_route::text)>3500000 then raise exception 'ROUTE_PROVIDER';end if;
  if jsonb_array_length(p_route->'geometry'->'coordinates') not between 2 and 50000 then raise exception 'ROUTE_LIMIT';end if;
  for point_value in select value from jsonb_array_elements(p_route->'geometry'->'coordinates') loop
   if not coalesce(private.navigation_point(point_value),false) then raise exception 'ROUTE_COORDINATES';end if;
  end loop;
  if not coalesce(private.navigation_point(p_route->'snapped_origin'),false) or not coalesce(private.navigation_point(p_route->'snapped_destination'),false) then raise exception 'ROUTE_COORDINATES';end if;
  select * into s from public.incident_navigation_sessions where id=(p_request->>'session_id')::uuid for update;
  previous:=s.status;
  if not found then
   insert into public.incident_navigation_sessions(id,incident_id,task_id,task_assignment_id,incident_unit_id,acting_organization_id,created_by,event_sequence)
   values((p_request->>'session_id')::uuid,(p_input->>'incident_id')::uuid,(p_input->>'task_id')::uuid,(p_input->>'assignment_id')::uuid,
   (p_input->>'incident_unit_id')::uuid,p_organization_id,p_actor,0) returning * into s;
  end if;
  select coalesce(max(revision),0)+1 into rev from public.incident_navigation_routes where session_id=s.id;
  insert into public.incident_navigation_routes(id,session_id,revision,origin_snapshot,destination_snapshot,provider,profile,distance_m,duration_s,
  route_geometry,navigation_steps,snapped_origin,snapped_destination,operation_id)
  values(route_id,s.id,rev,p_input->'origin',p_input->'destination',p_route->>'provider','car',(p_route->>'distance_m')::double precision,
  (p_route->>'duration_s')::double precision,p_route->'geometry',p_route->'steps',p_route->'snapped_origin',p_route->'snapped_destination',op);
  update public.incident_navigation_sessions set current_route_id=route_id,version=version+1,event_sequence=event_sequence+1,updated_at=clock_timestamp() where id=s.id;
  perform private.navigation_event(s.id,op,case when p_system then null else p_actor end,case when rev=1 then 'NAV_PREPARED' else 'NAV_RECALCULATED' end,previous);
  result_value:=jsonb_build_object('id',s.id,'version',(s.version+1)::text,'route_id',route_id);

 return result_value;
end; $$;

create or replace function public.incident_navigation_commit(p_actor uuid,p_organization_id uuid,p_request jsonb,p_input jsonb,p_route jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare old_claims text:=current_setting('request.jwt.claims',true);old_sub text:=current_setting('request.jwt.claim.sub',true);
 prepared jsonb;s public.incident_navigation_sessions;route_id uuid:=gen_random_uuid();rev integer;result_value jsonb;
 op uuid:=(p_request->>'operation_id')::uuid;request_value jsonb;point_value jsonb;previous text;
begin
 if auth.role() is distinct from 'service_role' or p_actor is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',p_actor::text,true);
 prepared:=public.incident_navigation_prepare(p_organization_id,p_request);
 if coalesce((prepared->>'acknowledged')::boolean,false) then result_value:=prepared->'result';
 else
  if prepared->'input' is distinct from p_input then raise exception 'STALE_VERSION';end if;
  result_value:=private.navigation_store_route(p_actor,p_organization_id,p_request,p_input,p_route);
  select * into s from public.incident_navigation_sessions where id=(result_value->>'id')::uuid;
  request_value:=jsonb_build_object('command','NAV_ROUTE','org',p_organization_id,'payload',p_request);
  insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
  values(op,p_actor,p_organization_id,s.incident_id,'NAV_ROUTE',request_value,result_value);
 end if;
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);
 return result_value;
end; $$;


-- Recheck all execution authority/state using persisted identities. No auth.uid substitution.
create function private.automation_input(j private.simulation_automation_jobs) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.simulation_scenarios;a public.incident_task_assignments;t public.incident_tasks;
 p public.simulation_unit_positions;n public.incident_navigation_sessions;v public.operational_action_definition_versions;
begin
 select * into s from public.simulation_scenarios where id=j.scenario_id;
 if not private.automation_authorized(j) then raise exception 'NOT_AUTHORIZED';end if;
 if s.status<>'RUNNING' then raise exception 'AUTO_SCENARIO_PAUSED';end if;
 select * into a from public.incident_task_assignments where id=j.assignment_id and incident_id=j.incident_id for update;
 if not found or a.task_id<>j.task_id or a.incident_unit_id is distinct from j.incident_unit_id or a.recipient_type<>'INCIDENT_UNIT' or not private.navigation_live(a.id) then raise exception 'AUTO_TASK_ENDED';end if;
 select * into t from public.incident_tasks where id=j.task_id for share;
 select * into v from public.operational_action_definition_versions where id=t.action_definition_version_id;
 if v.id<>j.action_version_id or v.native_behavior<>j.behavior or private.automation_policy(j.behavior)='MANUAL'
 or not(a.recipient_type=any(v.recipient_types)) or not(t.target_type=any(v.target_types)) then raise exception 'AUTO_MANUAL';end if;
 perform 1 from public.incident_units where id=j.incident_unit_id for update;
 select * into p from public.simulation_unit_positions where scenario_id=s.id and incident_unit_id=j.incident_unit_id and active for update;
 if not found then raise exception 'NAV_POSITION_UNAVAILABLE';end if;
 -- REQUEST_STATUS is observational; other automatic actions never replace/pause another run.
 if j.behavior<>'REQUEST_STATUS' and exists(select 1 from public.simulation_agent_runs r
 where r.incident_unit_id=j.incident_unit_id and r.id<>j.run_id and r.status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE')) then raise exception 'SIM_RUN_EXISTS';end if;
 if exists(select 1 from public.simulation_agent_runs r where r.task_assignment_id=a.id and r.id<>j.run_id) then raise exception 'SIM_RUN_EXISTS';end if;
 if private.automation_policy(j.behavior)='ROAD' then
  if t.target_type not in ('COORDINATE','HYDRANT','INCIDENT_MAP_OBJECT') or t.target_geometry_snapshot->>'type' is distinct from 'Point'
   or not coalesce(private.navigation_point(t.target_geometry_snapshot->'coordinates'),false) then raise exception 'NAV_INVALID_TARGET';end if;
  select * into n from public.incident_navigation_sessions where task_assignment_id=a.id and status in ('PLANNED','ACTIVE','PAUSED') for update;
  if found and n.status<>'PLANNED' then raise exception 'NAV_INVALID_STATE';end if;
  if n.id is null and exists(select 1 from public.incident_navigation_sessions where id=j.session_id) then raise exception 'NAV_INVALID_STATE';end if;
  if n.id is null and (select count(*) from public.incident_navigation_sessions where incident_id=j.incident_id and status in ('PLANNED','ACTIVE','PAUSED'))>=500 then raise exception 'NAV_LIMIT';end if;
 end if;
 return jsonb_build_object('incident_id',j.incident_id,'task_id',t.id,'task_version',t.version::text,
 'assignment_id',a.id,'assignment_version',a.version::text,'incident_unit_id',p.incident_unit_id,
 'session_id',coalesce(n.id,j.session_id),'session_version',coalesce(n.version,0)::text,'scenario_version',s.version::text,
 'origin',jsonb_build_object('source','SIMULATED_POSITION','scenario_id',s.id,'incident_unit_id',p.incident_unit_id,
 'version',p.version::text,'observed_at',p.observed_at,'coordinate',jsonb_build_array(p.longitude,p.latitude)),
 'destination',jsonb_build_object('target_type',t.target_type,'target_entity_id',t.target_entity_id,'geometry',t.target_geometry_snapshot,'label',t.target_label_snapshot));
end; $$;

create function private.automation_start(p_job uuid,p_input jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare j private.simulation_automation_jobs;n public.incident_navigation_sessions;answer jsonb;current_input jsonb;
begin
 select * into j from private.simulation_automation_jobs where id=p_job for update;
 current_input:=private.automation_input(j);
 if current_input is distinct from p_input then raise exception 'STALE_VERSION';end if;
 if exists(select 1 from public.simulation_agent_runs where id=j.run_id and task_assignment_id=j.assignment_id) then
  update private.simulation_automation_jobs set agent_run_id=j.run_id,state='STARTED',lease_token=null,lease_until=null where id=j.id;return;
 end if;
 if private.automation_policy(j.behavior)='ROAD' then
  select * into n from public.incident_navigation_sessions where id=(current_input->>'session_id')::uuid for update;
  if n.current_route_id is null then raise exception 'SIM_ROUTE_REQUIRED';end if;
 end if;
 answer:=private.agent_start(j.scenario_id,j.organization_id,j.approved_by,null,j.id,
 jsonb_build_object('run_id',j.run_id,'assignment_id',j.assignment_id,'position_version',current_input->'origin'->>'version',
 'session_id',n.id,'route_id',n.current_route_id,'profile',j.profile));
 update private.simulation_automation_jobs set state='STARTED',agent_run_id=j.run_id,navigation_session_id=n.id,
 lease_token=null,lease_until=null,error_code=null,error_detail='{}',version=version+1,updated_at=clock_timestamp()
 where id=j.id returning * into j;
 perform private.automation_event(j,'SIM_AUTO_STARTED');
end; $$;

-- One claimed route per invocation; leases fence delayed/overlapping HTTP results.
create function public.simulation_automation_claim() returns jsonb
language plpgsql security definer set search_path='' as $$
declare candidate record;j private.simulation_automation_jobs;v_input jsonb;n public.incident_navigation_sessions;
 route public.incident_navigation_routes;v_error text;gap float8;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'NOT_AUTHORIZED';end if;
 perform set_config('lock_timeout','2s',true);
 if not private.simulation_enabled() then return null;end if;
 for candidate in select q.id,q.scenario_id from private.simulation_automation_jobs q
 join public.simulation_scenarios s on s.id=q.scenario_id and s.status='RUNNING'
 where q.state in ('QUEUED','RETRY','PLANNING') and q.next_attempt_at<=clock_timestamp()
 and (q.lease_until is null or q.lease_until<clock_timestamp())
 order by q.next_attempt_at,q.created_at,q.id limit 5 loop
  -- Match the existing runner lock order; never lock a job before its scenario.
  if not pg_try_advisory_xact_lock(hashtextextended(candidate.scenario_id::text,1451)) then continue;end if;
  perform private.agent_locks(candidate.scenario_id);
  select * into j from private.simulation_automation_jobs where id=candidate.id for update skip locked;
  if not found or j.state not in ('QUEUED','RETRY','PLANNING') or j.lease_until>clock_timestamp() then continue;end if;
  if j.attempts>=5 then perform private.automation_error(j.id,'AUTO_RETRY_LIMIT');continue;end if;
  update private.simulation_automation_jobs set attempts=attempts+1 where id=j.id returning * into j;
  begin
   v_input:=private.automation_input(j);
   if private.automation_policy(j.behavior)='VIRTUAL' then perform private.automation_start(j.id,v_input);return jsonb_build_object('started',true);end if;
   select * into n from public.incident_navigation_sessions where id=(v_input->>'session_id')::uuid;
   if n.current_route_id is not null then
    select * into route from public.incident_navigation_routes where id=n.current_route_id;
    if route.origin_snapshot=v_input->'origin' and route.destination_snapshot=v_input->'destination' then
     update private.simulation_automation_jobs set navigation_session_id=n.id,session_id=n.id where id=j.id;
     gap:=greatest(private.agent_distance(v_input->'origin'->'coordinate',route.snapped_origin),
      private.agent_distance(v_input->'origin'->'coordinate',route.route_geometry->'coordinates'->0));
     if gap>5 then
      perform private.automation_error(j.id,'SIM_ACCESS_GAP',jsonb_build_object('distance_m',gap,'snapped_origin',route.snapped_origin));
      return jsonb_build_object('state','BLOCKED');
     end if;
     perform private.automation_start(j.id,v_input);return jsonb_build_object('started',true);
    end if;
   end if;
   update private.simulation_automation_jobs set state='PLANNING',input=v_input,session_id=(v_input->>'session_id')::uuid,
    lease_token=gen_random_uuid(),lease_until=clock_timestamp()+interval '60 seconds',error_code=null,error_detail='{}',
    version=version+1,updated_at=clock_timestamp() where id=j.id returning * into j;
   perform private.automation_event(j,'SIM_AUTO_PLANNING');
   return jsonb_build_object('id',j.id,'lease',j.lease_token,'origin',v_input->'origin'->'coordinate','destination',v_input->'destination'->'geometry'->'coordinates');
  exception when others then
   v_error:=case when sqlerrm in ('NOT_AUTHORIZED','AUTO_TASK_ENDED','AUTO_SCENARIO_PAUSED','AUTO_MANUAL','NAV_POSITION_UNAVAILABLE',
   'SIM_RUN_EXISTS','NAV_INVALID_STATE','NAV_INVALID_TARGET','NAV_LIMIT','STALE_VERSION','SIM_ACCESS_GAP','SIM_ROUTE_REQUIRED','SIM_LIMIT') then sqlerrm else 'AUTO_INTERNAL' end;
   perform private.automation_error(j.id,v_error);
  end;
 end loop;
 return null;
end; $$;

create function public.simulation_automation_finish(p_job uuid,p_lease uuid,p_route jsonb default null,p_error text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j private.simulation_automation_jobs;v_input jsonb;answer jsonb;v_error text;gap float8;route public.incident_navigation_routes;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'NOT_AUTHORIZED';end if;
 perform set_config('lock_timeout','2s',true);
 select * into j from private.simulation_automation_jobs where id=p_job;
 if not found then raise exception 'NOT_AUTHORIZED';end if;
 perform private.agent_locks(j.scenario_id);
 select * into j from private.simulation_automation_jobs where id=p_job for update;
 if j.state='STARTED' then return jsonb_build_object('state','STARTED');end if;
 if j.state<>'PLANNING' or j.lease_token is distinct from p_lease or j.lease_until<=clock_timestamp() then return jsonb_build_object('state','STALE_LEASE');end if;
 begin
  v_input:=private.automation_input(j);
  if v_input is distinct from j.input then raise exception 'STALE_VERSION';end if;
  if p_error is not null then
   v_error:=case when p_error in ('ROUTE_PROVIDER','ROUTE_CONFIGURATION','ROUTE_UNREACHABLE','ROUTE_LIMIT','ROUTE_COORDINATES','AUTO_TIMEOUT') then p_error else 'AUTO_INTERNAL' end;
   perform private.automation_error(j.id,v_error);return jsonb_build_object('state','FAILED');
  end if;
  answer:=private.navigation_store_route(j.approved_by,j.organization_id,
   jsonb_build_object('session_id',j.session_id,'operation_id',j.route_operation),v_input,p_route,true);
  update private.simulation_automation_jobs set navigation_session_id=j.session_id where id=j.id;
  -- Keep the real route available for explicit road-access correction, even when START is blocked.
  select * into route from public.incident_navigation_routes where id=(answer->>'route_id')::uuid;
  gap:=greatest(private.agent_distance(v_input->'origin'->'coordinate',route.snapped_origin),
   private.agent_distance(v_input->'origin'->'coordinate',route.route_geometry->'coordinates'->0));
  perform private.automation_event(j,'SIM_AUTO_ROUTE_READY');
  if gap>5 then
   perform private.automation_error(j.id,'SIM_ACCESS_GAP',jsonb_build_object('distance_m',gap,'snapped_origin',route.snapped_origin));
   return jsonb_build_object('state','BLOCKED');
  end if;
  -- Session version changed only by the validated route commit above.
  v_input:=private.automation_input(j);
  begin
   perform private.automation_start(j.id,v_input);
  exception when others then
   v_error:=case when sqlerrm in ('STALE_VERSION','SIM_ROUTE_REQUIRED','SIM_RUN_EXISTS','SIM_ACCESS_GAP','SIM_LIMIT','NOT_AUTHORIZED') then sqlerrm else 'AUTO_INTERNAL' end;
   perform private.automation_error(j.id,v_error);
  end;
 exception when others then
  v_error:=case when sqlerrm in ('NOT_AUTHORIZED','AUTO_TASK_ENDED','AUTO_SCENARIO_PAUSED','STALE_VERSION','NAV_POSITION_UNAVAILABLE','NAV_INVALID_STATE',
   'SIM_RUN_EXISTS','NAV_INVALID_TARGET','ROUTE_PROVIDER','ROUTE_LIMIT','ROUTE_COORDINATES') then sqlerrm else 'AUTO_INTERNAL' end;
  perform private.automation_error(j.id,v_error);
 end;
 return (select jsonb_build_object('state',state) from private.simulation_automation_jobs where id=j.id);
end; $$;

create function private.automation_retry(p_scenario uuid,p_payload jsonb,p_actor uuid) returns void
language plpgsql security definer set search_path='' as $$
declare j private.simulation_automation_jobs;
begin
 select * into j from private.simulation_automation_jobs where id=(p_payload->>'job_id')::uuid and scenario_id=p_scenario for update;
 if not found or j.version is distinct from (p_payload->>'version')::bigint then raise exception 'STALE_VERSION';end if;
 if j.state not in ('BLOCKED','RETRY') or j.agent_run_id is not null then raise exception 'INVALID_SIMULATION_STATE';end if;
 -- A stopped/superseded session remains historical; explicit retry may prepare a new session for the same job.
 if exists(select 1 from public.incident_navigation_sessions where id=j.session_id and status in ('STOPPED','CANCELLED','SUPERSEDED','ARRIVED_REPORTED')) then
  update private.simulation_automation_jobs set session_id=gen_random_uuid(),navigation_session_id=null,route_operation=gen_random_uuid()
  where id=j.id returning * into j;
 end if;
 perform private.automation_input(j);
 update private.simulation_automation_jobs set state='QUEUED',attempts=0,lease_token=null,lease_until=null,input=null,
 error_code=null,error_detail='{}',next_attempt_at=clock_timestamp(),version=version+1,updated_at=clock_timestamp(),
 -- Explicit correction/recalculation starts a new route attempt, not a new logical job.
 route_operation=case when navigation_session_id is null then route_operation else gen_random_uuid() end
 where id=j.id returning * into j;
 perform private.automation_event(j,'SIM_AUTO_RETRY',p_actor);
end; $$;

create or replace function public.simulation_agent_command(p_scenario uuid,p_organization_id uuid,p_operation uuid,p_version bigint,p_action text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.simulation_scenarios;c public.simulation_scenario_clock;r public.simulation_agent_runs;
 a public.incident_task_assignments;n public.incident_navigation_sessions;route public.incident_navigation_routes;p public.simulation_unit_positions;
 saved private.incident_operation_receipts;request_value jsonb;result_value jsonb;behavior_value text;len float8:=0;mult float8;ack integer;start_delay integer;completion integer;fault float8;duration integer;
 profile_value text;run_id uuid;random_value bigint;event_value text;
begin
 if auth.uid() is null or not private.is_active_user() or p_operation is null or jsonb_typeof(p_payload) is distinct from 'object'
 or octet_length(p_payload::text)>8192 then raise exception 'NOT_AUTHORIZED';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 perform private.agent_locks(p_scenario);
 select * into s from public.simulation_scenarios where id=p_scenario;
 if not private.simulation_controller(s.id,p_organization_id) then raise exception 'NOT_AUTHORIZED';end if;
 request_value:=jsonb_build_object('scenario',s.id,'org',p_organization_id,'version',p_version,'action',p_action,'payload',p_payload);
 select * into saved from private.incident_operation_receipts where operation_id=p_operation;
 if found then
 if saved.actor_user_id<>auth.uid() or saved.request is distinct from request_value then raise exception 'OPERATION_REUSED';end if;
 return saved.result;end if;
 select * into c from public.simulation_scenario_clock where scenario_id=s.id;
 if c.version is distinct from p_version then raise exception 'STALE_VERSION';end if;
 if s.status='FINISHED' or (c.event_sequence>=49000 and p_action not in ('STOP','STOP_ALL')) then raise exception 'SIM_LIMIT';end if;
 if c.last_control_at>clock_timestamp()-interval '500 milliseconds' then raise exception 'SIM_RATE_LIMIT';end if;
 if p_action='AUTOMATION' then
 if jsonb_typeof(p_payload->'enabled') is distinct from 'boolean' or p_payload->>'profile' is null or
 p_payload->>'profile' not in ('NORMAL','SLOW_RESPONSE','NO_RESPONSE','BREAKDOWN','COMMUNICATION_LOSS','ROUTE_BLOCKED')
 then raise exception 'VALIDATION_FAILED';end if;
 update public.simulation_scenarios set automatic_execution=(p_payload->>'enabled')::boolean,automatic_profile=p_payload->>'profile',
 version=version+1,updated_at=clock_timestamp() where id=s.id;
 perform private.write_audit(p_organization_id,auth.uid(),'SIM_AUTOMATION_SETTING','simulation_scenarios',s.id,
 jsonb_build_object('enabled',s.automatic_execution,'profile',s.automatic_profile),p_payload);
 elsif p_action='AUTOMATION_RETRY' then
 perform private.automation_retry(s.id,p_payload,auth.uid());
 elsif p_action='STEP' then
 result_value:=private.agent_tick(s.id,(p_payload->>'tick')::bigint,p_operation,true);
 elsif p_action='SCALE' then
 if coalesce((p_payload->>'scale')::integer,0) not in (1,5,10) then raise exception 'VALIDATION_FAILED';end if;
 update public.simulation_scenario_clock set scale=(p_payload->>'scale')::integer,anchor=clock_timestamp() where scenario_id=s.id;
 elsif p_action='START' then
 result_value:=private.agent_start(s.id,p_organization_id,auth.uid(),auth.uid(),p_operation,p_payload);
 elsif p_action='STOP_ALL' then
 for r in select * from public.simulation_agent_runs where scenario_id=s.id and status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE') order by id for update loop
 if r.route_id is not null and r.started and r.failure is distinct from 'SIM_SIGNAL_LOSS' and
 exists(select 1 from public.simulation_unit_positions sp where sp.scenario_id=s.id and sp.incident_unit_id=r.incident_unit_id and sp.active and sp.version=r.position_version)
 then r.position_version:=private.agent_publish(r,0);end if;
 r.status:='SIM_CANCELLED';r.speed_mps:=0;r.finished_at:=clock_timestamp();perform private.agent_save(r);
 perform private.agent_event(s.id,r.id,'SIM_CANCELLED',c.seconds,p_operation,auth.uid());end loop;
 elsif p_action in ('PAUSE','RESUME','STOP','CLEAR','INJECT') then
 select * into r from public.simulation_agent_runs where id=(p_payload->>'run_id')::uuid and scenario_id=s.id for update;
 if not found or r.version is distinct from (p_payload->>'version')::bigint then raise exception 'STALE_VERSION';end if;
 if r.status in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE') then raise exception 'INVALID_SIMULATION_STATE';end if;
 if p_action='INJECT' then
 if (select count(*) from public.simulation_event_injections where scenario_id=s.id)>=1000 then raise exception 'SIM_LIMIT';end if;
 if p_payload->>'trigger_type'='PROGRESS' and r.route_id is null then raise exception 'SIM_ROUTE_REQUIRED';end if;
 insert into public.simulation_event_injections(id,scenario_id,run_id,event_type,trigger_type,trigger_value,duration,created_by)
 values((p_payload->>'event_id')::uuid,s.id,r.id,p_payload->>'event_type',p_payload->>'trigger_type',
 (p_payload->>'trigger_value')::float8,coalesce((p_payload->>'duration')::integer,30),auth.uid());
 perform private.agent_event(s.id,r.id,'SIM_EVENT_SCHEDULED',c.seconds,p_operation,auth.uid(),p_payload);
 else
 if p_action='STOP' then
 r.status:='SIM_CANCELLED';r.speed_mps:=0;r.finished_at:=clock_timestamp();
 perform private.agent_event(s.id,r.id,'SIM_CANCELLED',c.seconds,p_operation,auth.uid());
 else
 if p_action in ('RESUME','CLEAR') and not private.agent_valid(r) then raise exception 'SIM_ROUTE_REQUIRED';end if;
 r:=private.agent_failure(r,case when p_action='PAUSE' then 'SIM_HOLD' else 'SIM_RESUME' end,1,c.seconds,p_operation,auth.uid());
 end if;
 if r.route_id is not null and r.started and r.failure is distinct from 'SIM_SIGNAL_LOSS' and
 exists(select 1 from public.simulation_unit_positions sp where sp.scenario_id=s.id and sp.incident_unit_id=r.incident_unit_id and sp.active and sp.version=r.position_version)
 then r.position_version:=private.agent_publish(r,0);end if;
 r.last_sim:=c.seconds;perform private.agent_save(r);
 end if;
 else raise exception 'VALIDATION_FAILED';end if;
 perform private.agent_event(s.id,null,'SIM_CONTROL_'||p_action,c.seconds,p_operation,auth.uid());
 update public.simulation_scenario_clock set version=version+1,last_control_at=clock_timestamp() where scenario_id=s.id returning version into c.version;
 result_value:=coalesce(result_value,'{}')||jsonb_build_object('version',c.version::text);
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,auth.uid(),p_organization_id,s.incident_id,'SIM_AGENT_'||p_action,request_value,result_value);
 return result_value;
exception when unique_violation then raise exception 'SIM_RUN_EXISTS';
end; $$;


create function private.automation_cancel() returns trigger
language plpgsql security definer set search_path='' as $$
declare j private.simulation_automation_jobs;
begin
 if new.status not in ('COMPLETED','UNABLE','CANCELLED') then return null;end if;
 for j in update private.simulation_automation_jobs set state='CANCELLED',lease_token=null,lease_until=null,
 error_code='AUTO_TASK_ENDED',version=version+1,updated_at=clock_timestamp()
 where assignment_id=new.id and state not in ('CANCELLED','STARTED')
 returning * loop perform private.automation_event(j,'SIM_AUTO_CANCELLED');end loop;
 return null;
end; $$;
create trigger simulation_automation_cancel after update of status on public.incident_task_assignments
 for each row execute function private.automation_cancel();

create function private.automation_scenario_end() returns trigger
language plpgsql security definer set search_path='' as $
declare j private.simulation_automation_jobs;
begin
 if new.status<>'FINISHED' then return null;end if;
 for j in update private.simulation_automation_jobs set state='CANCELLED',lease_token=null,lease_until=null,
 error_code='AUTO_TASK_ENDED',version=version+1,updated_at=clock_timestamp()
 where scenario_id=new.id and state not in ('STARTED','CANCELLED')
 returning * loop perform private.automation_event(j,'SIM_AUTO_CANCELLED');end loop;
 return null;
end; $;
create trigger simulation_automation_scenario_end after update of status on public.simulation_scenarios
 for each row execute function private.automation_scenario_end();

create function private.automation_projection(p_scenario uuid,p_unit uuid,p_page integer) returns jsonb
language sql volatile security definer set search_path='' as $$
 select jsonb_build_object('enabled',s.automatic_execution,'profile',s.automatic_profile,
 'jobs',coalesce((select jsonb_agg(q.dto order by q.created_at desc,q.id) from(
 select j.id,j.created_at,jsonb_build_object('id',j.id,'version',j.version::text,'unit_id',j.incident_unit_id,'callsign',ou.callsign,
 'task_id',j.task_id,'assignment_id',j.assignment_id,'behavior',j.behavior,'profile',j.profile,'state',j.state,
 'attempts',j.attempts,'next_attempt_at',j.next_attempt_at,'updated_at',j.updated_at,
 'error',j.error_code,'detail',j.error_detail,'session_id',j.navigation_session_id,'run_id',j.agent_run_id,
 'run_state',r.status,'navigation_state',n.status,'route_id',nr.id,'distance_m',nr.distance_m,'duration_s',nr.duration_s,
 'remaining_s',case when r.baseline_mps>0 then greatest(0,(r.length_m-r.progress_m)/r.baseline_mps) end,
 'position_version',p.version::text,'label_sl',v.label_sl,'label_de',v.label_de,'target',t.target_label_snapshot) dto
 from private.simulation_automation_jobs j
 join public.incident_units u on u.id=j.incident_unit_id join public.operational_units ou on ou.id=u.unit_id
 join public.incident_tasks t on t.id=j.task_id join public.operational_action_definition_versions v on v.id=j.action_version_id
 left join public.simulation_agent_runs r on r.id=j.agent_run_id
 left join public.incident_navigation_sessions n on n.id=j.navigation_session_id
 left join public.incident_navigation_routes nr on nr.id=n.current_route_id
 left join public.simulation_unit_positions p on p.scenario_id=j.scenario_id and p.incident_unit_id=j.incident_unit_id and p.active
 where j.scenario_id=p_scenario and (p_unit is null or j.incident_unit_id=p_unit)
 order by j.created_at desc,j.id limit 25 offset p_page*25)q),'[]'),
 'more',(select count(*)>25*(p_page+1) from private.simulation_automation_jobs where scenario_id=p_scenario and (p_unit is null or incident_unit_id=p_unit)))
 from public.simulation_scenarios s where s.id=p_scenario;
$$;

create or replace function public.simulation_agents_read(p_scenario uuid,p_organization_id uuid,p_unit uuid default null,p_page integer default 0,p_before bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.simulation_scenarios;c public.simulation_scenario_clock;runs jsonb;assignments jsonb;events jsonb;
begin
 select * into s from public.simulation_scenarios where id=p_scenario;
 if not found or not private.simulation_visible(s.incident_id,p_organization_id) then raise exception 'NOT_AUTHORIZED';end if;
 if not private.simulation_enabled() then raise exception 'SIMULATION_DISABLED';end if;
 if p_page is null or p_page not between 0 and 1000 then raise exception 'VALIDATION_FAILED';end if;
 select * into c from public.simulation_scenario_clock where scenario_id=s.id;
 select coalesce(jsonb_agg(q.dto order by q.created_at desc,q.id),'[]') into runs from(
 select r.id,r.created_at,to_jsonb(r)||jsonb_build_object('version',r.version::text,'position_version',r.position_version::text,
 'callsign',ou.callsign,'operational_status',a.status,'target',t.target_label_snapshot,'navigation_status',n.status) dto
 from public.simulation_agent_runs r join public.incident_task_assignments a on a.id=r.task_assignment_id
 join public.incident_tasks t on t.id=a.task_id join public.incident_units u on u.id=r.incident_unit_id
 join public.operational_units ou on ou.id=u.unit_id left join public.incident_navigation_sessions n on n.id=r.navigation_session_id
 where r.scenario_id=s.id and (p_unit is null or r.incident_unit_id=p_unit)
 order by r.created_at desc,r.id limit 25 offset p_page*25) q;
 select coalesce(jsonb_agg(q.dto order by q.issued_at desc,q.id),'[]') into assignments from(
 select a.id,t.issued_at,jsonb_build_object('id',a.id,'unit_id',a.incident_unit_id,'callsign',ou.callsign,
 'behavior',v.native_behavior,'label_sl',v.label_sl,'label_de',v.label_de,'status',a.status,'target',t.target_label_snapshot,
 'position_version',sp.version::text,'session_id',n.id,'route_id',nr.id,'distance_m',nr.distance_m,'duration_s',nr.duration_s,
 'snapped_origin',nr.snapped_origin,'access_gap',case when nr.id is not null then private.agent_distance(jsonb_build_array(sp.longitude,sp.latitude),nr.snapped_origin) end,
 'origin_current',nr.origin_snapshot->>'version'=sp.version::text) dto
 from public.incident_task_assignments a join public.incident_tasks t on t.id=a.task_id
 join public.operational_action_definition_versions v on v.id=t.action_definition_version_id
 join public.incident_units u on u.id=a.incident_unit_id join public.operational_units ou on ou.id=u.unit_id
 join public.simulation_unit_positions sp on sp.incident_unit_id=u.id and sp.scenario_id=s.id and sp.active
 left join public.incident_navigation_sessions n on n.task_assignment_id=a.id and n.status in ('PLANNED','ACTIVE','PAUSED')
 left join public.incident_navigation_routes nr on nr.id=n.current_route_id
 where a.incident_id=s.incident_id and a.recipient_type='INCIDENT_UNIT' and a.status not in ('COMPLETED','UNABLE','CANCELLED') and t.status='OPEN'
 and (p_unit is null or a.incident_unit_id=p_unit) order by t.issued_at desc,a.id limit 25 offset p_page*25) q;
 select coalesce(jsonb_agg(q.dto order by q.sequence desc),'[]') into events from(
 select e.sequence,to_jsonb(e)||jsonb_build_object('sequence',e.sequence::text) dto from public.simulation_agent_events e
 where e.scenario_id=s.id and(p_before is null or e.sequence<p_before) order by e.sequence desc limit 50) q;
 return jsonb_build_object('automation',private.automation_projection(s.id,p_unit,p_page),'can_control',private.simulation_controller(s.id,p_organization_id) and s.status<>'FINISHED',
 'clock',case when c.scenario_id is null then jsonb_build_object('seconds',0,'scale',1,'version','1','tick','0') else to_jsonb(c)||jsonb_build_object('version',c.version::text,'tick',c.tick::text) end,
 'runs',runs,'assignments',assignments,'events',events,'more',jsonb_array_length(runs)=25 or jsonb_array_length(assignments)=25,
 'signals',coalesce((select jsonb_object_agg(incident_unit_id::text,'SIM_SIGNAL_LOST') from public.simulation_agent_runs where scenario_id=s.id and status='SIM_SIGNAL_LOST'),'{}'),
 'counts',(select jsonb_build_object('total',count(*),'moving',count(*) filter(where status='SIM_IN_PROGRESS' and route_id is not null),
 'waiting',count(*) filter(where status='WAITING_TO_ACK'),'blocked',count(*) filter(where status in ('SIM_BLOCKED','SIM_PAUSED','SIM_SIGNAL_LOST')),
 'active',count(*) filter(where status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE'))) from public.simulation_agent_runs where scenario_id=s.id),
 'injections',coalesce((select jsonb_agg(q) from(select id,run_id,event_type,trigger_type,trigger_value,duration,fired_at from public.simulation_event_injections
 where scenario_id=s.id order by created_at desc,id limit 50)q),'[]'));
end; $$;

create or replace function private.agent_valid(r public.simulation_agent_runs) returns boolean
language sql volatile security definer set search_path='' as $$
 select not exists(select 1 from private.simulation_automation_jobs j where j.agent_run_id=r.id and not private.automation_authorized(j)) and private.agent_controller(r.scenario_id) and private.navigation_live(r.task_assignment_id)
 and exists(select 1 from public.simulation_unit_positions p where p.scenario_id=r.scenario_id and p.incident_unit_id=r.incident_unit_id and p.active
 and (r.route_id is null or p.version=r.position_version))
 and (r.route_id is null or exists(select 1 from public.incident_navigation_sessions n where n.id=r.navigation_session_id
 and n.current_route_id=r.route_id and (n.status in ('PLANNED','ACTIVE','PAUSED') or
 (n.status='STOPPED' and exists(select 1 from public.incident_navigation_events e where e.session_id=n.id and e.event_sequence=n.event_sequence
 and e.event_type='NAV_INVALIDATED' and e.payload->>'cause'='simulation_scenarios')))));
$$;


create or replace function private.agent_tick(p_scenario uuid,p_tick bigint,p_operation uuid,p_manual boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.simulation_scenario_clock;s public.simulation_scenarios;r public.simulation_agent_runs;other public.simulation_agent_runs;
 ev public.simulation_event_injections;now_sim bigint;delta integer;elapsed float8;sec integer;answer jsonb;old_progress float8;old_failure text;boundary float8;publish boolean;
begin
 perform private.agent_locks(p_scenario);
 select result into answer from private.simulation_tick_receipts where scenario_id=p_scenario and tick=p_tick;
 if found then return answer;end if;
 select * into c from public.simulation_scenario_clock where scenario_id=p_scenario;
 select * into s from public.simulation_scenarios where id=p_scenario;
 if c.tick is distinct from p_tick then raise exception 'STALE_VERSION';end if;
 if s.status<>'RUNNING' or not private.agent_controller(s.id) then raise exception 'INVALID_SIMULATION_STATE';end if;
 if c.tick>=100000 or c.seconds>=31535950 or c.event_sequence>=49000 then raise exception 'SIM_LIMIT';end if;
 elapsed:=greatest(0,extract(epoch from clock_timestamp()-c.anchor));
 if not p_manual and elapsed<1 then return jsonb_build_object('due',false);end if;
 delta:=case when p_manual then c.scale else least(50,floor(least(5,elapsed))::integer*c.scale) end;
 -- Deterministic one-simulated-second substeps: bounded to 50, no wall-time jump.
 for sec in 1..delta loop
 now_sim:=c.seconds+sec;
 for r in select * from public.simulation_agent_runs where scenario_id=s.id
 and status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE') order by id for update loop
  select * into r from public.simulation_agent_runs where id=r.id for update;
  if r.status in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE') then continue;end if;
  if not private.agent_valid(r) then
   if r.route_id is not null and r.started and r.failure is distinct from 'SIM_SIGNAL_LOSS' and exists(select 1 from public.simulation_unit_positions sp where sp.scenario_id=r.scenario_id and sp.incident_unit_id=r.incident_unit_id and sp.active and sp.version=r.position_version) then r.position_version:=private.agent_publish(r,0);end if;
   r.status:='SIM_CANCELLED';r.speed_mps:=0;r.finished_at:=clock_timestamp();
   perform private.agent_event(s.id,r.id,'SIM_INVALIDATED',now_sim,p_operation);
   perform private.agent_save(r);continue;
  end if;
  old_progress:=r.progress_m;old_failure:=r.failure;publish:=false;
  if r.signal_until is not null and now_sim>=r.signal_until then r:=private.agent_failure(r,'SIM_RESUME',1,now_sim,p_operation);publish:=true;end if;
  for ev in select * from public.simulation_event_injections where run_id=r.id and enabled and fired_at is null and
   ((trigger_type='TIME' and trigger_value<=now_sim) or
   (trigger_type='AFTER_ACK' and r.acknowledged and trigger_value<=now_sim-r.ack_due) or
   (trigger_type='EXECUTION_START' and r.started) or
   (trigger_type='PROGRESS' and r.length_m>0 and trigger_value<=r.progress_m/r.length_m))
   order by created_at,id for update loop
    r:=private.agent_failure(r,ev.event_type,ev.duration,now_sim,p_operation);publish:=true;
    update public.simulation_event_injections set fired_at=now_sim where id=ev.id;
  end loop;
  if r.failure is not null and r.failure<>'SIM_SIGNAL_LOSS' then
   if not r.acknowledged then r.ack_due:=r.ack_due+1;end if;
   if not r.started then r.start_due:=r.start_due+1;end if;
   if r.arrived_at is not null then r.arrived_at:=r.arrived_at+1;end if;
  else
   if not r.acknowledged and now_sim>=r.ack_due then
    r.acknowledged:=true;
    perform private.agent_event(s.id,r.id,'SIM_ACKNOWLEDGED',now_sim,p_operation);
   end if;
   if r.acknowledged and not r.started and now_sim>=r.start_due then
    r.started:=true;
    perform private.agent_event(s.id,r.id,'SIM_IN_PROGRESS',now_sim,p_operation);
    if r.behavior='HOLD_POSITION' and not exists(select 1 from private.simulation_automation_jobs j where j.agent_run_id=r.id) then
     for other in select * from public.simulation_agent_runs where scenario_id=s.id and incident_unit_id=r.incident_unit_id
     and id<>r.id and route_id is not null and status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE') order by id for update loop
      other:=private.agent_failure(other,'SIM_HOLD',1,now_sim,p_operation);
      if other.started and other.failure<>'SIM_SIGNAL_LOSS' and private.agent_valid(other) then other.position_version:=private.agent_publish(other,0);end if;
      perform private.agent_save(other);
     end loop;
    elsif r.behavior='REQUEST_STATUS' then
     perform private.agent_event(s.id,r.id,'SIM_STATUS_REPORT',now_sim,p_operation,null,
      jsonb_build_object('runs',coalesce((select jsonb_agg(jsonb_build_object('id',q.id,'status',q.status,'progress_m',q.progress_m))
      from public.simulation_agent_runs q where q.scenario_id=s.id and q.incident_unit_id=r.incident_unit_id and q.status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE')),'[]')));
    end if;
   end if;
   if r.started and r.arrived_at is null then
    if r.route_id is not null then
     boundary:=r.length_m;
     select least(boundary,coalesce(min(trigger_value*r.length_m),boundary)) into boundary from public.simulation_event_injections
      where run_id=r.id and enabled and fired_at is null and trigger_type='PROGRESS' and trigger_value*r.length_m>r.progress_m;
     r.progress_m:=least(boundary,r.progress_m+r.baseline_mps);
     r.speed_mps:=case when r.progress_m<r.length_m then r.baseline_mps else 0 end;
    end if;
    if r.route_id is null or r.progress_m>=r.length_m then
     r.arrived_at:=now_sim;r.speed_mps:=0;
     perform private.agent_event(s.id,r.id,'SIM_ARRIVED',now_sim,p_operation,null,jsonb_build_object('road_endpoint_only',r.route_id is not null));
    end if;
   end if;
   if r.arrived_at is not null and now_sim>=r.arrived_at+r.completion_delay and r.failure is null then
    r.status:='SIM_COMPLETED';r.finished_at:=clock_timestamp();r.speed_mps:=0;publish:=true;
    perform private.agent_event(s.id,r.id,'SIM_COMPLETED',now_sim,p_operation);
   end if;
  end if;
  if r.status<>'SIM_COMPLETED' then
   r.status:=case when r.failure='SIM_SIGNAL_LOSS' then 'SIM_SIGNAL_LOST' when r.failure='SIM_HOLD' then 'SIM_PAUSED'
   when r.failure is not null then 'SIM_BLOCKED' when r.arrived_at is not null then 'SIM_ARRIVED' when r.started then 'SIM_IN_PROGRESS'
   when r.acknowledged then 'SIM_ACKNOWLEDGED' else 'WAITING_TO_ACK' end;
  end if;
  -- Only the final substep publishes: no per-frame or repeated geometry requests.
  if r.route_id is not null and r.started and r.failure is distinct from 'SIM_SIGNAL_LOSS' and
   (sec=delta or publish or r.status='SIM_COMPLETED') then
   r.position_version:=private.agent_publish(r,r.speed_mps);
  end if;
  if r.started and now_sim-r.last_sample>=60 then
   perform private.agent_event(s.id,r.id,'SIM_PROGRESS',now_sim,p_operation,null,jsonb_build_object('progress_m',r.progress_m,'status',r.status));
   r.last_sample:=now_sim;
  end if;
  r.last_sim:=now_sim;r.last_tick:=c.tick+1;perform private.agent_save(r);
 end loop;
 end loop;
 update public.simulation_scenario_clock set seconds=c.seconds+delta,tick=c.tick+1,anchor=clock_timestamp(),last_tick_at=clock_timestamp(),
 last_runner_at=case when p_manual then last_runner_at else clock_timestamp() end,last_error=null,behind=not p_manual and elapsed>15 where scenario_id=s.id;
 answer:=jsonb_build_object('tick',(c.tick+1)::text,'seconds',c.seconds+delta);
 insert into private.simulation_tick_receipts values(s.id,c.tick,p_operation,answer);
 return answer;
end; $$;


-- Forward-only SIM event feed for the existing F4 coordinator. No execution side effects.
create function public.simulation_automation_feed(p_incident uuid,p_organization_id uuid,p_after bigint default null) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare s public.simulation_scenarios;v_high bigint;v_events jsonb;
begin
 if not private.simulation_visible(p_incident,p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident;
 if not found or not private.simulation_enabled() then return jsonb_build_object('high','0','cursor','0','events','[]'::jsonb);end if;
 select coalesce(max(sequence),0) into v_high from public.simulation_agent_events where scenario_id=s.id;
 if p_after is null then return jsonb_build_object('high',v_high::text,'cursor',v_high::text,'events','[]'::jsonb);end if;
 select coalesce(jsonb_agg(q.dto order by q.sequence),'[]') into v_events from(
 select e.sequence,jsonb_build_object('sequence',e.sequence::text,'id','sim:'||s.id||':'||e.sequence,'code',e.event_type,
 'created_at',e.created_at,'unit_id',coalesce(r.incident_unit_id,(e.payload->>'unit_id')::uuid)) dto
 from public.simulation_agent_events e left join public.simulation_agent_runs r on r.id=e.run_id
 where e.scenario_id=s.id and e.sequence>p_after and e.event_type<>'SIM_PROGRESS'
 order by e.sequence limit 50)q;
 return jsonb_build_object('high',v_high::text,'cursor',case when jsonb_array_length(v_events)=50 then v_events->49->>'sequence' else v_high::text end,'events',v_events);
end; $$;

-- All new worker entry points are job-scoped and service-role only. Internal helpers are not RPCs.
do $$
declare f regprocedure;
begin
 for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='private' and (p.proname like 'automation_%' or p.proname in ('agent_start','navigation_store_route')) loop
 execute format('revoke all on function %s from public,anon,authenticated,service_role',f);end loop;
end; $$;
revoke all on function public.simulation_automation_claim(),public.simulation_automation_finish(uuid,uuid,jsonb,text),
 public.simulation_automation_feed(uuid,uuid,bigint) from public,anon,authenticated,service_role;
grant execute on function public.simulation_automation_claim(),public.simulation_automation_finish(uuid,uuid,jsonb,text) to service_role;
grant execute on function public.simulation_automation_feed(uuid,uuid,bigint) to authenticated;
commit;
