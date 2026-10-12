-- M14.5D: command intent, navigation plans and position observations remain separate.
create table public.incident_navigation_sessions (
 id uuid primary key, incident_id uuid not null references public.incidents(id),
 task_id uuid not null, task_assignment_id uuid not null,
 incident_unit_id uuid not null, acting_organization_id uuid not null references public.organizations(id),
 created_by uuid not null references public.profiles(id),
 executor_id uuid references public.profiles(id), executor_organization_id uuid references public.organizations(id),
 status text not null default 'PLANNED' check(status in ('PLANNED','ACTIVE','PAUSED','ARRIVED_REPORTED','STOPPED','CANCELLED','SUPERSEDED')),
 version bigint not null default 1 check(version>0), event_sequence bigint not null default 0,
 current_route_id uuid, created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp(), finished_at timestamptz,
 unique(id,incident_id),
 foreign key(task_id,incident_id) references public.incident_tasks(id,incident_id),
 foreign key(task_assignment_id,incident_id) references public.incident_task_assignments(id,incident_id),
 foreign key(incident_unit_id,incident_id) references public.incident_units(id,incident_id),
 check(status not in ('ACTIVE','PAUSED','ARRIVED_REPORTED') or (executor_id is not null and executor_organization_id is not null))
);
create unique index navigation_one_active_unit on public.incident_navigation_sessions(incident_unit_id) where status='ACTIVE';
create unique index navigation_one_open_assignment on public.incident_navigation_sessions(task_assignment_id) where status in ('PLANNED','ACTIVE','PAUSED');
create index navigation_incident_page on public.incident_navigation_sessions(incident_id,created_at desc,id);
create index navigation_executor on public.incident_navigation_sessions(executor_id,executor_organization_id) where status in ('ACTIVE','PAUSED');
create table public.incident_navigation_routes (
 id uuid primary key, session_id uuid not null references public.incident_navigation_sessions(id),
 revision integer not null check(revision>0),
 origin_snapshot jsonb not null, destination_snapshot jsonb not null,
 provider text not null check(provider in ('OSRM','GraphHopper')), profile text not null check(profile='car'),
 distance_m double precision not null check(distance_m>=0 and distance_m<'Infinity'::double precision),
 duration_s double precision not null check(duration_s>=0 and duration_s<'Infinity'::double precision),
 route_geometry jsonb not null check(octet_length(route_geometry::text)<=3000000),
 navigation_steps jsonb, snapped_origin jsonb not null, snapped_destination jsonb not null,
 calculated_at timestamptz not null default clock_timestamp(), operation_id uuid not null unique,
 unique(session_id,revision),unique(id,session_id)
);
alter table public.incident_navigation_sessions add constraint navigation_current_route_fk
 foreign key(current_route_id,id) references public.incident_navigation_routes(id,session_id) deferrable initially deferred;
create table public.incident_navigation_events (
 id uuid primary key default gen_random_uuid(), session_id uuid not null references public.incident_navigation_sessions(id),
 event_sequence bigint not null, event_type text not null,
 actor_user_id uuid references public.profiles(id), operation_id uuid not null unique,
 previous_state text,new_state text,route_revision integer,
 payload jsonb not null default '{}' check(octet_length(payload::text)<=16000),
 created_at timestamptz not null default clock_timestamp(),unique(session_id,event_sequence)
);
-- Durable preparation reservations bound to the authenticated request. No geometry is accepted here.
create table private.incident_navigation_preparations (
 operation_id uuid primary key, actor_user_id uuid not null references public.profiles(id),
 organization_id uuid not null references public.organizations(id), incident_id uuid not null references public.incidents(id),
 request jsonb not null, input jsonb not null,
 created_at timestamptz not null default clock_timestamp()
);
create index navigation_preparation_rate on private.incident_navigation_preparations(actor_user_id,created_at desc);
revoke all on private.incident_navigation_preparations from public,anon,authenticated,service_role;

create function private.navigation_point(p jsonb) returns boolean
language sql immutable set search_path='' as $$
 select case when jsonb_typeof(p)='array' and jsonb_array_length(p)=2
 and jsonb_typeof(p->0)='number' and jsonb_typeof(p->1)='number'
 then (p->>0)::numeric between -180 and 180 and (p->>1)::numeric between -90 and 90 else false end;
$$;
create function private.navigation_training_valid(p_incident uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select not exists(select 1 from public.simulation_scenarios s where s.incident_id=p_incident
 and (not private.simulation_enabled() or s.status not in ('DRAFT','RUNNING')));
$$;
create function private.navigation_visible(p_incident uuid,p_org uuid,p_unit uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select private.simulation_visible(p_incident,p_org)
 and (not exists(select 1 from public.simulation_scenarios where incident_id=p_incident) or private.simulation_enabled())
 and exists(select 1 from public.incident_units u where u.id=p_unit and u.incident_id=p_incident
 and (u.organization_id=p_org or private.can_issue_task(p_incident,p_org,'INCIDENT_UNIT',p_unit)
 or exists(select 1 from public.simulation_scenarios s where s.incident_id=p_incident and private.simulation_controller(s.id,p_org))));
$$;
create function private.navigation_planner(p_incident uuid,p_org uuid,p_unit uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select private.navigation_visible(p_incident,p_org,p_unit) and
 (private.can_issue_task(p_incident,p_org,'INCIDENT_UNIT',p_unit)
 or private.can_execute_task(p_incident,p_org,'INCIDENT_UNIT',p_unit)
 or exists(select 1 from public.simulation_scenarios s join public.simulation_unit_positions p on p.scenario_id=s.id
 where s.incident_id=p_incident and p.incident_unit_id=p_unit and p.active and private.simulation_controller(s.id,p_org)));
$$;
-- Explicit actor variant only for invalidation of previously authenticated executors.
create function private.navigation_executor_valid(p_actor uuid,p_org uuid,p_incident uuid,p_unit uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select private.task_recipient_eligible(p_incident,'INCIDENT_UNIT',p_unit)
 and exists(select 1 from public.incident_role_assignments r where r.incident_id=p_incident
 and r.unit_assignment_id=p_unit and r.role='UNIT_LEADER' and r.organization_id=p_org
 and r.user_id=p_actor and private.incident_assignment_effective(r.id));
$$;
create function private.navigation_live(p_assignment uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select exists(select 1 from public.incident_task_assignments a join public.incident_tasks t on t.id=a.task_id
 join public.incidents i on i.id=a.incident_id
 where a.id=p_assignment and a.recipient_type='INCIDENT_UNIT' and a.status not in ('COMPLETED','UNABLE','CANCELLED')
 and t.status='OPEN' and i.status in ('ACTIVE','STABILIZED')
 and private.task_recipient_eligible(a.incident_id,'INCIDENT_UNIT',a.incident_unit_id)
 and private.navigation_training_valid(a.incident_id));
$$;
create function private.navigation_storage_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' and ((new.id,new.incident_id,new.task_id,new.task_assignment_id,new.incident_unit_id,new.acting_organization_id,new.created_by,new.created_at)
 is distinct from (old.id,old.incident_id,old.task_id,old.task_assignment_id,old.incident_unit_id,old.acting_organization_id,old.created_by,old.created_at)
 or new.version<>old.version+1 or old.status in ('STOPPED','CANCELLED','SUPERSEDED','ARRIVED_REPORTED')) then raise exception 'NAV_INVALID_STATE'; end if;
 if not exists(select 1 from public.incident_task_assignments a where a.id=new.task_assignment_id
 and a.incident_id=new.incident_id and a.task_id=new.task_id and a.incident_unit_id=new.incident_unit_id
 and a.recipient_type='INCIDENT_UNIT') then raise exception 'NAV_INVALID_ASSIGNMENT'; end if;
 return new;
end; $$;
create trigger navigation_identity before insert or update on public.incident_navigation_sessions for each row execute function private.navigation_storage_guard();

create function private.navigation_event(p_session uuid,p_operation uuid,p_actor uuid,p_event text,p_previous text,p_payload jsonb default '{}') returns void
language plpgsql security definer set search_path='' as $$
declare s public.incident_navigation_sessions;revision_value integer;
begin
 select * into s from public.incident_navigation_sessions where id=p_session;
 select revision into revision_value from public.incident_navigation_routes where id=s.current_route_id;
 insert into public.incident_navigation_events(session_id,event_sequence,event_type,actor_user_id,operation_id,previous_state,new_state,route_revision,payload)
 values(s.id,s.event_sequence,p_event,p_actor,p_operation,p_previous,s.status,revision_value,p_payload);
 perform private.write_audit(s.acting_organization_id,coalesce(p_actor,s.created_by),p_event,'incident_navigation_sessions',s.id,
 jsonb_build_object('status',p_previous),jsonb_build_object('status',s.status,'operation_id',p_operation,'revision',revision_value,'system',p_actor is null));
end; $$;

-- Reads project loss of validity immediately, including time-based role expiry. Writes also recheck.
-- Owning-domain changes synchronously stop active guidance, without touching task status.
create function private.navigation_invalidate() returns trigger
language plpgsql security definer set search_path='' as $$
declare s public.incident_navigation_sessions;scope_value jsonb:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
 for s in select n.* from public.incident_navigation_sessions n
 where n.status in ('PLANNED','ACTIVE','PAUSED') and
 case
 when tg_table_name='incidents' then n.incident_id=(scope_value->>'id')::uuid
 when tg_table_name in ('incident_task_assignments','incident_units','incident_participants','incident_role_assignments','simulation_scenarios','simulation_unit_positions')
 then n.incident_id=(scope_value->>'incident_id')::uuid
 when tg_table_name='profiles' then n.executor_id=(scope_value->>'id')::uuid
 when tg_table_name='organizations' then n.executor_organization_id=(scope_value->>'id')::uuid or n.acting_organization_id=(scope_value->>'id')::uuid
 when tg_table_name in ('user_organizations','simulation_operators') then n.executor_id=(scope_value->>'user_id')::uuid or n.created_by=(scope_value->>'user_id')::uuid
 else true end
 order by n.id for update loop
  if not private.navigation_live(s.task_assignment_id) or
   (s.status in ('ACTIVE','PAUSED') and not private.navigation_executor_valid(s.executor_id,s.executor_organization_id,s.incident_id,s.incident_unit_id)) then
   update public.incident_navigation_sessions set status='STOPPED',version=version+1,event_sequence=event_sequence+1,updated_at=clock_timestamp(),finished_at=clock_timestamp() where id=s.id;
   perform private.navigation_event(s.id,gen_random_uuid(),null,'NAV_INVALIDATED',s.status,jsonb_build_object('cause',tg_table_name));
  end if;
 end loop;
 return null;
end; $$;
create trigger navigation_assignment_invalidation after update on public.incident_task_assignments for each row execute function private.navigation_invalidate();
create trigger navigation_incident_invalidation after update on public.incidents for each row execute function private.navigation_invalidate();
create trigger navigation_unit_invalidation after update on public.incident_units for each row execute function private.navigation_invalidate();
create trigger navigation_participant_invalidation after update on public.incident_participants for each row execute function private.navigation_invalidate();
create trigger navigation_role_invalidation after update or delete on public.incident_role_assignments for each row execute function private.navigation_invalidate();
create trigger navigation_profile_invalidation after update on public.profiles for each row execute function private.navigation_invalidate();
create trigger navigation_membership_invalidation after update or delete on public.user_organizations for each row execute function private.navigation_invalidate();
create trigger navigation_org_invalidation after update on public.organizations for each row execute function private.navigation_invalidate();
create trigger navigation_scenario_invalidation after update on public.simulation_scenarios for each row execute function private.navigation_invalidate();
create trigger navigation_environment_invalidation after update on private.simulation_environment for each row execute function private.navigation_invalidate();
create trigger navigation_operator_invalidation after update or delete on private.simulation_operators for each row execute function private.navigation_invalidate();

-- Serialize like the existing incident commands: organization/profile, incident, unit/assignment/session.
create function private.navigation_locks(p_incident uuid,p_org uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v uuid;
begin
 if exists(select 1 from public.simulation_scenarios where incident_id=p_incident) then
  perform 1 from private.simulation_environment where singleton for share;
  perform 1 from private.simulation_operators where organization_id=p_org and user_id=auth.uid() for share;
 end if;
 for v in select distinct x from (select p_org x union all select organization_id from public.incident_participants where incident_id=p_incident) q order by x loop
 perform private.lock_organization(v);perform 1 from public.organizations where id=v for share;end loop;
 for v in select distinct x from (select auth.uid() x union all select user_id from public.incident_role_assignments where incident_id=p_incident and status='ACTIVE') q order by x loop
 perform 1 from public.profiles where id=v for share;end loop;
 perform 1 from public.incidents where id=p_incident for update;
 if not private.incident_acting_member(p_org) or not private.can_read_incident(p_incident) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
end; $$;
create function private.navigation_input(p_org uuid,p_request jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.incident_task_assignments;t public.incident_tasks;u public.incident_units;
 s public.incident_navigation_sessions;sc public.simulation_scenarios;p public.simulation_unit_positions;
 origin_value jsonb;destination_value jsonb;incident_value uuid:=(p_request->>'incident_id')::uuid;
begin
 perform private.navigation_locks(incident_value,p_org);
 select * into a from public.incident_task_assignments where id=(p_request->>'assignment_id')::uuid and incident_id=incident_value for update;
 if not found or a.recipient_type<>'INCIDENT_UNIT' then raise exception 'NAV_INVALID_ASSIGNMENT';end if;
 select * into u from public.incident_units where id=a.incident_unit_id for update;
 select * into t from public.incident_tasks where id=a.task_id for share;
 if not private.navigation_planner(incident_value,p_org,u.id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if not private.navigation_live(a.id) then raise exception 'NAV_INVALID_STATE';end if;
 if a.version is distinct from (p_request->>'assignment_version')::bigint or t.version is distinct from (p_request->>'task_version')::bigint then raise exception 'STALE_VERSION';end if;
 if not exists(select 1 from public.operational_action_definition_versions v where v.id=t.action_definition_version_id and v.native_behavior in ('MOVE_TO','WITHDRAW_TO')) then raise exception 'NAV_INVALID_ASSIGNMENT';end if;
 if t.target_type not in ('COORDINATE','HYDRANT','INCIDENT_MAP_OBJECT') or t.target_geometry_snapshot->>'type' is distinct from 'Point'
 or not coalesce(private.navigation_point(t.target_geometry_snapshot->'coordinates'),false) then raise exception 'NAV_INVALID_TARGET';end if;
 destination_value:=jsonb_build_object('target_type',t.target_type,'target_entity_id',t.target_entity_id,
 'geometry',t.target_geometry_snapshot,'label',t.target_label_snapshot);
 select * into s from public.incident_navigation_sessions where id=(p_request->>'session_id')::uuid for update;
 if found then
  if s.task_assignment_id<>a.id or s.incident_id<>incident_value or s.status not in ('PLANNED','ACTIVE','PAUSED') then raise exception 'NAV_INVALID_STATE';end if;
  if s.version is distinct from (p_request->>'version')::bigint then raise exception 'STALE_VERSION';end if;
 else
  if (p_request->>'version')::bigint is distinct from 0 then raise exception 'STALE_VERSION';end if;
  if exists(select 1 from public.incident_navigation_sessions where task_assignment_id=a.id and status in ('PLANNED','ACTIVE','PAUSED')) then raise exception 'NAV_SESSION_EXISTS';end if;
  if (select count(*) from public.incident_navigation_sessions where incident_id=incident_value and status in ('PLANNED','ACTIVE','PAUSED'))>=500 then raise exception 'NAV_LIMIT';end if;
 end if;
 select * into sc from public.simulation_scenarios where incident_id=incident_value for share;
 if found then
  perform 1 from private.simulation_environment where singleton for share;
  perform 1 from private.simulation_operators where user_id=auth.uid() and organization_id=p_org for share;
  if not private.simulation_enabled() or sc.status not in ('DRAFT','RUNNING') then raise exception 'SIMULATION_DISABLED';end if;
 end if;
 if p_request->'origin'->>'source'='SIMULATED_POSITION' then
  if sc.id is null or not private.simulation_controller(sc.id,p_org) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  select * into p from public.simulation_unit_positions where scenario_id=sc.id and incident_unit_id=u.id and active for share;
  if not found then raise exception 'NAV_POSITION_UNAVAILABLE';end if;
  origin_value:=jsonb_build_object('source','SIMULATED_POSITION','scenario_id',sc.id,'incident_unit_id',u.id,
  'version',p.version::text,'observed_at',p.observed_at,'coordinate',jsonb_build_array(p.longitude,p.latitude));
 elsif p_request->'origin'->>'source'='MANUAL_PLANNING_POINT' then
  if not coalesce(private.navigation_point(p_request->'origin'->'coordinate'),false) then raise exception 'ROUTE_COORDINATES';end if;
  origin_value:=jsonb_build_object('source','MANUAL_PLANNING_POINT','coordinate',p_request->'origin'->'coordinate','selected_by',auth.uid());
 elsif p_request->'origin'->>'source'='ACTUAL_POSITION' then raise exception 'NAV_POSITION_UNAVAILABLE';
 else raise exception 'VALIDATION_FAILED';end if;
 return jsonb_build_object('incident_id',incident_value,'incident_version',(select version::text from public.incidents where id=incident_value),
 'task_id',t.id,'task_version',t.version::text,'assignment_id',a.id,'assignment_version',a.version::text,
 'incident_unit_id',u.id,'unit_version',u.version::text,'session_version',coalesce(s.version,0)::text,
 'scenario_version',sc.version::text,'origin',origin_value,'destination',destination_value);
end; $$;
create function public.incident_navigation_prepare(p_organization_id uuid,p_request jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare op uuid:=(p_request->>'operation_id')::uuid;receipt private.incident_operation_receipts;prepared private.incident_navigation_preparations;input_value jsonb;request_value jsonb;
begin
 if auth.uid() is null or not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if op is null or p_organization_id is null or (p_request->>'incident_id')::uuid is null or (p_request->>'assignment_id')::uuid is null or (p_request->>'session_id')::uuid is null or (p_request->>'task_version')::bigint is null or (p_request->>'assignment_version')::bigint is null or (p_request->>'version')::bigint is null or jsonb_typeof(p_request) is distinct from 'object' or octet_length(p_request::text)>4096
 or exists(select 1 from jsonb_object_keys(p_request) k where k not in ('operation_id','incident_id','assignment_id','assignment_version','task_version','session_id','version','origin')) then raise exception 'VALIDATION_FAILED';end if;
 if jsonb_typeof(p_request->'origin') is distinct from 'object' or exists(select 1 from jsonb_object_keys(p_request->'origin') k where k not in ('source','coordinate')) or (p_request->'origin'->>'source'<>'MANUAL_PLANNING_POINT' and p_request->'origin' ? 'coordinate') then raise exception 'VALIDATION_FAILED';end if;
 perform pg_advisory_xact_lock(hashtextextended(op::text,141));
 perform private.navigation_locks((p_request->>'incident_id')::uuid,p_organization_id);
 request_value:=jsonb_build_object('command','NAV_ROUTE','org',p_organization_id,'payload',p_request);
 select * into receipt from private.incident_operation_receipts where operation_id=op;
 if found then
  if receipt.actor_user_id<>auth.uid() or receipt.request is distinct from request_value then raise exception 'OPERATION_REUSED';end if;
  return jsonb_build_object('acknowledged',true,'result',receipt.result);
 end if;
 input_value:=private.navigation_input(p_organization_id,p_request);
 select * into prepared from private.incident_navigation_preparations where operation_id=op;
 if found then
  if prepared.actor_user_id<>auth.uid() or prepared.organization_id<>p_organization_id or prepared.request is distinct from p_request then raise exception 'OPERATION_REUSED';end if;
  if prepared.input is distinct from input_value then raise exception 'STALE_VERSION';end if;
 else
  if (select count(*) from private.incident_navigation_preparations where actor_user_id=auth.uid() and created_at>clock_timestamp()-interval '1 minute')>=10 then raise exception 'NAV_LIMIT';end if;
  insert into private.incident_navigation_preparations(operation_id,actor_user_id,organization_id,incident_id,request,input,created_at) values(op,auth.uid(),p_organization_id,(p_request->>'incident_id')::uuid,p_request,input_value,clock_timestamp());
 end if;
 return jsonb_build_object('input',input_value);
end; $$;

-- Service-role only. Actor comes from Edge /auth/v1/user, never from the browser body.
-- Bind existing auth.uid()-based domain helpers to that verified principal transaction-locally.
create function public.incident_navigation_commit(p_actor uuid,p_organization_id uuid,p_request jsonb,p_input jsonb,p_route jsonb) returns jsonb
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
  perform private.navigation_event(s.id,op,p_actor,case when rev=1 then 'NAV_PREPARED' else 'NAV_RECALCULATED' end,previous);
  result_value:=jsonb_build_object('id',s.id,'version',(s.version+1)::text,'route_id',route_id);
  request_value:=jsonb_build_object('command','NAV_ROUTE','org',p_organization_id,'payload',p_request);
  insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
  values(op,p_actor,p_organization_id,s.incident_id,'NAV_ROUTE',request_value,result_value);
 end if;
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);
 return result_value;
end; $$;

create function public.incident_navigation_command(p_organization_id uuid,p_incident_id uuid,p_operation uuid,p_session_id uuid,p_expected_version bigint,p_action text,p_replacement_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.incident_navigation_sessions;a public.incident_task_assignments;cfg public.operational_action_definition_versions;
receipt private.incident_operation_receipts;request_value jsonb;result_value jsonb;next_state text;other public.incident_navigation_sessions;
planner boolean;executor boolean;
begin
 if auth.uid() is null or not private.is_active_user() or p_operation is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 perform private.navigation_locks(p_incident_id,p_organization_id);
 select * into s from public.incident_navigation_sessions where id=p_session_id and incident_id=p_incident_id for update;
 if not found or not private.navigation_visible(p_incident_id,p_organization_id,s.incident_unit_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 request_value:=jsonb_build_object('command','NAV_'||p_action,'org',p_organization_id,'incident',p_incident_id,'session',p_session_id,'version',p_expected_version,'replacement',p_replacement_id);
 select * into receipt from private.incident_operation_receipts where operation_id=p_operation;
 if found then
  if receipt.actor_user_id<>auth.uid() or receipt.request is distinct from request_value then raise exception 'OPERATION_REUSED';end if;
  return receipt.result;
 end if;
 if s.version is distinct from p_expected_version then raise exception 'STALE_VERSION';end if;
 if s.status not in ('PLANNED','ACTIVE','PAUSED') then raise exception 'NAV_INVALID_STATE';end if;
 planner:=private.navigation_planner(p_incident_id,p_organization_id,s.incident_unit_id);
 executor:=private.can_execute_task(p_incident_id,p_organization_id,'INCIDENT_UNIT',s.incident_unit_id);
 if not planner and not executor then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into a from public.incident_task_assignments where id=s.task_assignment_id for update;
 select v.* into cfg from public.operational_action_definition_versions v join public.incident_tasks t on t.action_definition_version_id=v.id where t.id=s.task_id;
 if p_action in ('CANCEL','SUPERSEDE') then
  if not planner then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  next_state:=case p_action when 'CANCEL' then 'CANCELLED' else 'SUPERSEDED' end;
  if p_action='SUPERSEDE' then
   select * into other from public.incident_navigation_sessions where id=p_replacement_id and incident_unit_id=s.incident_unit_id and incident_id=p_incident_id for update;
   if not found or other.id=s.id or other.status<>'PLANNED' or not private.navigation_live(other.task_assignment_id) then raise exception 'NAV_INVALID_STATE';end if;
  elsif p_replacement_id is not null then raise exception 'VALIDATION_FAILED';end if;
 else
  if not executor then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  if p_action<>'STOP' and not private.navigation_live(a.id) then raise exception 'NAV_INVALID_STATE';end if;
  if p_replacement_id is not null then raise exception 'VALIDATION_FAILED';end if;
  if p_action in ('START','RESUME','ARRIVE') and
   not(a.status in ('ACKNOWLEDGED','IN_PROGRESS') or (a.status='ISSUED' and not cfg.requires_acknowledgement))
   then raise exception 'NAV_ACK_REQUIRED';end if;
  next_state:=case
   when p_action='START' and s.status='PLANNED' then 'ACTIVE'
   when p_action='RESUME' and s.status='PAUSED' then 'ACTIVE'
   when p_action='PAUSE' and s.status='ACTIVE' then 'PAUSED'
   when p_action='ARRIVE' and s.status in ('ACTIVE','PAUSED') then 'ARRIVED_REPORTED'
   when p_action='STOP' and s.status in ('ACTIVE','PAUSED') then 'STOPPED' end;
  if next_state is null then raise exception 'NAV_INVALID_STATE';end if;
 end if;
 perform 1 from public.incident_units where id=s.incident_unit_id for update;
 if next_state='ACTIVE' then
  -- Time-expired authority has no trigger; reclaim its guidance slot explicitly under the unit lock.
  for other in select * from public.incident_navigation_sessions where incident_unit_id=s.incident_unit_id and status='ACTIVE' and id<>s.id for update loop
   if private.navigation_live(other.task_assignment_id) and private.navigation_executor_valid(other.executor_id,other.executor_organization_id,other.incident_id,other.incident_unit_id)
   then raise exception 'NAV_ACTIVE_EXISTS';end if;
   update public.incident_navigation_sessions set status='STOPPED',version=version+1,event_sequence=event_sequence+1,updated_at=clock_timestamp(),finished_at=clock_timestamp() where id=other.id;
   perform private.navigation_event(other.id,gen_random_uuid(),null,'NAV_INVALIDATED','ACTIVE');
  end loop;
 end if;
 update public.incident_navigation_sessions set status=next_state,version=version+1,event_sequence=event_sequence+1,updated_at=clock_timestamp(),
 executor_id=case when next_state='ACTIVE' then auth.uid() else executor_id end,
 executor_organization_id=case when next_state='ACTIVE' then p_organization_id else executor_organization_id end,
 finished_at=case when next_state in ('STOPPED','CANCELLED','SUPERSEDED','ARRIVED_REPORTED') then clock_timestamp() end where id=s.id;
 perform private.navigation_event(s.id,p_operation,auth.uid(),'NAV_'||p_action,s.status,jsonb_build_object('replacement_id',p_replacement_id));
 result_value:=jsonb_build_object('id',s.id,'version',(s.version+1)::text);
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,auth.uid(),p_organization_id,p_incident_id,'NAV_'||p_action,request_value,result_value);
 return result_value;
end; $$;

create function public.incident_navigation_read(p_organization_id uuid,p_incident_id uuid,p_assignment_id uuid default null,p_unit_id uuid default null,p_session_id uuid default null,p_page integer default 0,p_before_revision integer default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows_value jsonb;s public.incident_navigation_sessions;r public.incident_navigation_routes;detail jsonb;routes_value jsonb;
begin
 if not private.incident_acting_member(p_organization_id) or not private.can_read_incident(p_incident_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if p_page is null or p_page<0 or p_page>10000 then raise exception 'VALIDATION_FAILED';end if;
 select coalesce(jsonb_agg(q.dto order by q.issued_at desc,q.id),'[]') into rows_value from(
 select a.id,t.issued_at,jsonb_build_object('id',a.id,'task_id',t.id,'task_version',t.version::text,'version',a.version::text,'status',a.status,
 'unit_id',u.id,'callsign',ou.callsign,'label_sl',v.label_sl,'label_de',v.label_de,'target',t.target_label_snapshot,
 'can_plan',private.navigation_live(a.id) and private.navigation_planner(p_incident_id,p_organization_id,u.id),
 'can_execute',private.navigation_live(a.id) and private.can_execute_task(p_incident_id,p_organization_id,'INCIDENT_UNIT',u.id),
 'ack_ready',a.status in ('ACKNOWLEDGED','IN_PROGRESS') or (a.status='ISSUED' and not v.requires_acknowledgement),
 'sim_available',exists(select 1 from public.simulation_unit_positions sp join public.simulation_scenarios sc on sc.id=sp.scenario_id
 where sp.incident_unit_id=u.id and sp.active and sc.status in ('DRAFT','RUNNING') and private.simulation_controller(sc.id,p_organization_id)),
 'session_id',(select n.id from public.incident_navigation_sessions n where n.task_assignment_id=a.id order by n.created_at desc,n.id desc limit 1)) dto
 from public.incident_task_assignments a join public.incident_tasks t on t.id=a.task_id
 join public.operational_action_definition_versions v on v.id=t.action_definition_version_id
 join public.incident_units u on u.id=a.incident_unit_id join public.operational_units ou on ou.id=u.unit_id
 where a.incident_id=p_incident_id and a.recipient_type='INCIDENT_UNIT' and v.native_behavior in ('MOVE_TO','WITHDRAW_TO')
 and (p_assignment_id is null or a.id=p_assignment_id) and (p_unit_id is null or u.id=p_unit_id)
 and private.navigation_visible(p_incident_id,p_organization_id,u.id)
 order by t.issued_at desc,a.id offset p_page*25 limit 25) q;
 if p_assignment_id is not null then
  select * into s from public.incident_navigation_sessions where incident_id=p_incident_id and task_assignment_id=p_assignment_id
  and (p_session_id is null or id=p_session_id) order by created_at desc,id desc limit 1;
  if found then
   if not private.navigation_visible(p_incident_id,p_organization_id,s.incident_unit_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
   select * into r from public.incident_navigation_routes where id=s.current_route_id;
   detail:=to_jsonb(s)||jsonb_build_object('version',s.version::text,'event_sequence',s.event_sequence::text,
   'effective_status',case when s.status in ('ACTIVE','PAUSED') and
    (not private.navigation_live(s.task_assignment_id) or not private.navigation_executor_valid(s.executor_id,s.executor_organization_id,s.incident_id,s.incident_unit_id)) then 'STOPPED' else s.status end,
   'route',to_jsonb(r),'origin_stale',case when r.origin_snapshot->>'source'='SIMULATED_POSITION' then not exists(
    select 1 from public.simulation_unit_positions p where p.scenario_id=(r.origin_snapshot->>'scenario_id')::uuid
    and p.incident_unit_id=s.incident_unit_id and p.active and p.version::text=r.origin_snapshot->>'version') else false end);
   select coalesce(jsonb_agg(q.dto order by q.revision desc),'[]') into routes_value from(
    select nr.revision,to_jsonb(nr)-array['route_geometry','navigation_steps'] dto from public.incident_navigation_routes nr
    where nr.session_id=s.id and (p_before_revision is null or nr.revision<p_before_revision) order by nr.revision desc limit 20) q;
  end if;
 end if;
 return jsonb_build_object('rows',rows_value,'more',jsonb_array_length(rows_value)=25,'session',detail,'history',coalesce(routes_value,'[]'),
 'sessions',coalesce((select jsonb_agg(q.dto order by q.created_at desc) from(
 select n.created_at,jsonb_build_object('id',n.id,'status',n.status,'created_at',n.created_at) dto from public.incident_navigation_sessions n
 where n.task_assignment_id=p_assignment_id and private.navigation_visible(p_incident_id,p_organization_id,n.incident_unit_id)
 order by n.created_at desc,n.id desc limit 25) q),'[]'),
 'replacements',coalesce((select jsonb_agg(q.dto) from(select jsonb_build_object('id',n.id,'target',t.target_label_snapshot) dto from public.incident_navigation_sessions n join public.incident_tasks t on t.id=n.task_id where n.incident_unit_id=s.incident_unit_id and n.id<>s.id and n.status='PLANNED' order by n.created_at desc limit 25) q),'[]'),
 'events',coalesce((select jsonb_agg(q.dto order by q.event_sequence desc) from(
 select e.event_sequence,to_jsonb(e)||jsonb_build_object('event_sequence',e.event_sequence::text) dto from public.incident_navigation_events e
 where e.session_id=s.id order by e.event_sequence desc limit 50) q),'[]'));
end; $$;
-- A historical route is fetched individually rather than sending every geometry in the history page.
create function public.incident_navigation_route(p_organization_id uuid,p_incident_id uuid,p_route_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.incident_navigation_routes;s public.incident_navigation_sessions;
begin
 select * into r from public.incident_navigation_routes where id=p_route_id;
 select * into s from public.incident_navigation_sessions where id=r.session_id and incident_id=p_incident_id;
 if not found or not private.navigation_visible(p_incident_id,p_organization_id,s.incident_unit_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return to_jsonb(r);
end; $$;

-- Short provider lease prevents duplicate concurrent exact retries from multiplying calls.
alter table private.incident_navigation_preparations add column lease_until timestamptz;
create function public.incident_navigation_lease(p_actor uuid,p_operation uuid) returns void
language plpgsql security definer set search_path='' as $$
declare p private.incident_navigation_preparations;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into p from private.incident_navigation_preparations where operation_id=p_operation and actor_user_id=p_actor for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if p.lease_until>clock_timestamp() then raise exception 'NAV_BUSY';end if;
 update private.incident_navigation_preparations set lease_until=clock_timestamp()+interval '110 seconds' where operation_id=p_operation;
end; $$;

alter table public.incident_navigation_sessions enable row level security;
alter table public.incident_navigation_routes enable row level security;
alter table public.incident_navigation_events enable row level security;
-- RPC-only projections: no broad incident-reader policy can leak precise route origins.
revoke all on public.incident_navigation_sessions,public.incident_navigation_routes,public.incident_navigation_events from public,anon,authenticated,service_role;
create trigger navigation_sessions_no_delete before delete on public.incident_navigation_sessions for each row execute function private.audit_immutable();
create trigger navigation_sessions_no_truncate before truncate on public.incident_navigation_sessions for each statement execute function private.audit_immutable();
create trigger navigation_routes_immutable before update or delete on public.incident_navigation_routes for each row execute function private.audit_immutable();
create trigger navigation_routes_no_truncate before truncate on public.incident_navigation_routes for each statement execute function private.audit_immutable();
create trigger navigation_events_immutable before update or delete on public.incident_navigation_events for each row execute function private.audit_immutable();
create trigger navigation_events_no_truncate before truncate on public.incident_navigation_events for each statement execute function private.audit_immutable();

revoke all on function private.navigation_point(jsonb),private.navigation_training_valid(uuid),private.navigation_visible(uuid,uuid,uuid),
 private.navigation_planner(uuid,uuid,uuid),private.navigation_executor_valid(uuid,uuid,uuid,uuid),private.navigation_live(uuid),
 private.navigation_storage_guard(),private.navigation_event(uuid,uuid,uuid,text,text,jsonb),private.navigation_invalidate(),
 private.navigation_locks(uuid,uuid),private.navigation_input(uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.incident_navigation_prepare(uuid,jsonb),public.incident_navigation_commit(uuid,uuid,jsonb,jsonb,jsonb),
 public.incident_navigation_command(uuid,uuid,uuid,uuid,bigint,text,uuid),public.incident_navigation_read(uuid,uuid,uuid,uuid,uuid,integer,integer),
 public.incident_navigation_route(uuid,uuid,uuid),public.incident_navigation_lease(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.incident_navigation_prepare(uuid,jsonb),public.incident_navigation_command(uuid,uuid,uuid,uuid,bigint,text,uuid),
 public.incident_navigation_read(uuid,uuid,uuid,uuid,uuid,integer,integer),public.incident_navigation_route(uuid,uuid,uuid) to authenticated;
grant execute on function public.incident_navigation_commit(uuid,uuid,jsonb,jsonb,jsonb),public.incident_navigation_lease(uuid,uuid) to service_role;
