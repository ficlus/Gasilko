-- M14.5E: simulator-owned execution only. No task/navigation transitions or JWT impersonation.
create table public.simulation_scenario_clock (
 scenario_id uuid primary key references public.simulation_scenarios(id),
 seconds bigint not null default 0 check(seconds between 0 and 31536000),
 scale integer not null default 1 check(scale in (1,5,10)),
 tick bigint not null default 0, version bigint not null default 1,
 anchor timestamptz not null default clock_timestamp(), last_tick_at timestamptz,
 last_runner_at timestamptz, last_error text, behind boolean not null default false,
 last_control_at timestamptz, event_sequence bigint not null default 0
);
create table public.simulation_agent_runs (
 id uuid primary key, scenario_id uuid not null, incident_id uuid not null,
 incident_unit_id uuid not null, task_assignment_id uuid not null,
 navigation_session_id uuid, route_id uuid,
 behavior text not null, profile text not null check(profile in ('NORMAL','SLOW_RESPONSE','NO_RESPONSE','BREAKDOWN','COMMUNICATION_LOSS','ROUTE_BLOCKED')),
 configuration jsonb not null check(octet_length(configuration::text)<4096),
 status text not null default 'WAITING_TO_ACK' check(status in ('WAITING_TO_ACK','SIM_ACKNOWLEDGED','SIM_IN_PROGRESS','SIM_ARRIVED','SIM_COMPLETED','SIM_BLOCKED','SIM_UNABLE','SIM_PAUSED','SIM_SIGNAL_LOST','SIM_CANCELLED')),
 failure text, signal_until bigint, acknowledged boolean not null default false,
 started boolean not null default false, ack_due bigint not null, start_due bigint not null,
 arrived_at bigint, completion_delay integer not null check(completion_delay between 0 and 3600),
 progress_m double precision not null default 0 check(progress_m>=0 and progress_m<'Infinity'::float8),
 length_m double precision not null default 0 check(length_m>=0 and length_m<'Infinity'::float8),
 speed_mps double precision not null default 0 check(speed_mps between 0 and 100),
 baseline_mps double precision not null default 0 check(baseline_mps between 0 and 100),
 last_sim bigint not null, last_sample bigint not null, position_version bigint not null,
 version bigint not null default 1, last_tick bigint not null default 0,
 created_by uuid not null references public.profiles(id), organization_id uuid not null references public.organizations(id),
 created_at timestamptz not null default clock_timestamp(), finished_at timestamptz,
 foreign key(scenario_id,incident_id) references public.simulation_scenarios(id,incident_id),
 foreign key(incident_unit_id,incident_id) references public.incident_units(id,incident_id),
 foreign key(task_assignment_id,incident_id) references public.incident_task_assignments(id,incident_id),
 foreign key(navigation_session_id,incident_id) references public.incident_navigation_sessions(id,incident_id),
 foreign key(route_id,navigation_session_id) references public.incident_navigation_routes(id,session_id),
 check((behavior in ('MOVE_TO','WITHDRAW_TO'))=(route_id is not null and navigation_session_id is not null)),
 unique(id,scenario_id), unique(id,scenario_id,incident_unit_id)
);
create unique index simulation_agent_movement_owner on public.simulation_agent_runs(incident_unit_id)
 where route_id is not null and status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE');
create unique index simulation_agent_assignment_owner on public.simulation_agent_runs(task_assignment_id)
 where status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE');
create index simulation_agent_scenario on public.simulation_agent_runs(scenario_id,incident_unit_id,created_at,id);
create table public.simulation_agent_events (
 id bigint generated always as identity primary key, scenario_id uuid not null references public.simulation_scenarios(id),
 sequence bigint not null, run_id uuid, event_type text not null,
 actor_origin text not null check(actor_origin in ('HUMAN_CONTROLLER','SIMULATION_ENGINE')),
 actor_user_id uuid references public.profiles(id), operation_id uuid not null,
 sim_seconds bigint not null, payload jsonb not null default '{}' check(octet_length(payload::text)<8192),
 created_at timestamptz not null default clock_timestamp(),
 foreign key(run_id,scenario_id) references public.simulation_agent_runs(id,scenario_id),
 unique(scenario_id,sequence),
 check((actor_origin='HUMAN_CONTROLLER')=(actor_user_id is not null))
);
create table public.simulation_event_injections (
 id uuid primary key, scenario_id uuid not null, run_id uuid not null,
 event_type text not null check(event_type in ('SIM_BREAKDOWN','SIM_ROAD_BLOCKED','SIM_SIGNAL_LOSS','SIM_NO_RESPONSE','SIM_HOLD','SIM_RESUME')),
 trigger_type text not null check(trigger_type in ('TIME','AFTER_ACK','PROGRESS','EXECUTION_START')),
 trigger_value double precision not null check(trigger_value>=0 and trigger_value<=31536000),
 duration integer not null default 30 check(duration between 1 and 3600),
 fired_at bigint, enabled boolean not null default true,
 created_by uuid not null references public.profiles(id), created_at timestamptz not null default clock_timestamp(),
 foreign key(run_id,scenario_id) references public.simulation_agent_runs(id,scenario_id),
 check(trigger_type<>'PROGRESS' or trigger_value<=1)
);
create index simulation_injections_due on public.simulation_event_injections(run_id) where enabled and fired_at is null;
create table private.simulation_paths (
 route_id uuid primary key references public.incident_navigation_routes(id),
 points jsonb not null, cumulative double precision[] not null, length_m double precision not null
);
create table private.simulation_tick_receipts (
 scenario_id uuid not null references public.simulation_scenarios(id), tick bigint not null,
 operation_id uuid not null unique, result jsonb not null, primary key(scenario_id,tick)
);
-- A capability row exists only inside a guarded publisher transaction.
create table private.simulation_engine_writes(run_id uuid primary key, transaction_id bigint not null);
alter table public.simulation_unit_positions alter column updated_by drop not null;
alter table public.simulation_unit_positions add column actor_origin text not null default 'HUMAN_MANUAL'
 check(actor_origin in ('HUMAN_MANUAL','SIMULATION_ENGINE'));
alter table public.simulation_unit_positions add column engine_run_id uuid;
alter table public.simulation_unit_positions add constraint simulation_engine_run_fk
 foreign key(engine_run_id,scenario_id,incident_unit_id) references public.simulation_agent_runs(id,scenario_id,incident_unit_id);
alter table public.simulation_unit_positions add constraint simulation_position_actor
 check((actor_origin='HUMAN_MANUAL' and updated_by is not null and engine_run_id is null)
 or(actor_origin='SIMULATION_ENGINE' and updated_by is null and engine_run_id is not null));

create function private.agent_controller(p_scenario uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select private.simulation_enabled() and exists(
 select 1 from public.simulation_scenarios s
 join private.simulation_operators op on op.user_id=s.created_by and op.organization_id=s.organization_id
 join public.profiles p on p.id=s.created_by and p.account_status='ACTIVE'
 join public.organizations o on o.id=s.organization_id and o.active
 join public.user_organizations m on m.user_id=s.created_by and m.organization_id=s.organization_id
 join public.incidents i on i.id=s.incident_id and i.status in ('ACTIVE','STABILIZED')
 where s.id=p_scenario and s.status in ('RUNNING','PAUSED') and exists(
 select 1 from public.incident_role_assignments a where a.incident_id=s.incident_id and a.user_id=s.created_by
 and a.organization_id=s.organization_id and a.role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER')
 and private.incident_assignment_effective(a.id)));
$$;
create function private.agent_locks(p_scenario uuid) returns void
language plpgsql security definer set search_path='' as $$
declare s public.simulation_scenarios; v uuid;
begin
 perform 1 from private.simulation_environment where singleton and enabled and environment_kind='TRAINING' for share;
 if not found then raise exception 'SIMULATION_DISABLED';end if;
 select * into s from public.simulation_scenarios where id=p_scenario;
 if not found then raise exception 'NOT_AUTHORIZED';end if;
 for v in select distinct organization_id from public.incident_participants where incident_id=s.incident_id order by organization_id loop
 perform private.lock_organization(v);perform 1 from public.organizations where id=v for share;end loop;
 for v in select distinct person from(select s.created_by person union all select user_id from public.incident_role_assignments where incident_id=s.incident_id and status='ACTIVE') q order by person loop
 perform 1 from public.profiles where id=v for share;end loop;
 perform 1 from private.simulation_operators where user_id=s.created_by and organization_id=s.organization_id for share;
 perform 1 from public.incidents where id=s.incident_id for update;
 perform 1 from public.simulation_scenarios where id=s.id for update;
 insert into public.simulation_scenario_clock(scenario_id) values(s.id) on conflict do nothing;
 perform 1 from public.simulation_scenario_clock where scenario_id=s.id for update;
end; $$;
create function private.agent_event(p_scenario uuid,p_run uuid,p_type text,p_time bigint,p_operation uuid,p_actor uuid default null,p_payload jsonb default '{}') returns void
language plpgsql security definer set search_path='' as $$
declare seq bigint;
begin
 update public.simulation_scenario_clock set event_sequence=event_sequence+1 where scenario_id=p_scenario and event_sequence<50000 returning event_sequence into seq;
 if seq is null then raise exception 'SIM_LIMIT';end if;
 insert into public.simulation_agent_events(scenario_id,sequence,run_id,event_type,sim_seconds,operation_id,actor_origin,actor_user_id,payload)
 values(p_scenario,seq,p_run,p_type,p_time,p_operation,case when p_actor is null then 'SIMULATION_ENGINE' else 'HUMAN_CONTROLLER' end,p_actor,p_payload);
end; $$;
create function private.agent_distance(a jsonb,b jsonb) returns double precision
language sql immutable set search_path='' as $$
 select 12742017.6*asin(sqrt(least(1.0,greatest(0.0,
 power(sin(radians((b->>1)::float8-(a->>1)::float8)/2),2)+
 cos(radians((a->>1)::float8))*cos(radians((b->>1)::float8))*power(sin(radians((b->>0)::float8-(a->>0)::float8)/2),2)))));
$$;
create function private.agent_path(p_route uuid) returns double precision
language plpgsql security definer set search_path='' as $$
declare r public.incident_navigation_routes; pts jsonb; c float8[]:=array[0.0]::float8[]; n integer; j integer; d float8;
begin
 select length_m into d from private.simulation_paths where route_id=p_route;if found then return d;end if;
 select * into r from public.incident_navigation_routes where id=p_route;pts:=r.route_geometry->'coordinates';
 if r.route_geometry->>'type' is distinct from 'LineString' or jsonb_typeof(pts) is distinct from 'array' then raise exception 'SIM_ROUTE_REQUIRED';end if;
 n:=jsonb_array_length(pts);if n not between 2 and 50000 or r.duration_s<=0 then raise exception 'SIM_ROUTE_REQUIRED';end if;
 for j in 0..n-1 loop
 if not coalesce(private.navigation_point(pts->j),false) then raise exception 'SIM_ROUTE_REQUIRED';end if;
 if j>0 then
 d:=private.agent_distance(pts->(j-1),pts->j);
 if d>20000000 then raise exception 'SIM_ROUTE_REQUIRED';end if;
 c:=array_append(c,c[j]+d);
 end if;end loop;
 if c[n]<=0 or c[n]>20000000 then raise exception 'SIM_ROUTE_REQUIRED';end if;
 insert into private.simulation_paths values(p_route,pts,c,c[n]);return c[n];
end; $$;
create function private.agent_point(p_route uuid,p_progress float8) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p private.simulation_paths; lo integer:=2;hi integer;mid integer; f float8;d float8;
 a jsonb;b jsonb;lat1 float8;lat2 float8;lon1 float8;lon2 float8;x float8;y float8;z float8;aa float8;bb float8;heading float8;
begin
 select * into p from private.simulation_paths where route_id=p_route;
 if not found then raise exception 'SIM_ROUTE_REQUIRED';end if;
 hi:=array_length(p.cumulative,1);
 while lo<hi loop mid:=(lo+hi)/2;if p.cumulative[mid]<p_progress then lo:=mid+1;else hi:=mid;end if;end loop;
 while lo<array_length(p.cumulative,1) and p.cumulative[lo]-p.cumulative[lo-1]<0.000001 loop lo:=lo+1;end loop;
 a:=p.points->(lo-2);b:=p.points->(lo-1);d:=p.cumulative[lo]-p.cumulative[lo-1];
 f:=case when d<0.000001 then 1 else greatest(0,least(1,(p_progress-p.cumulative[lo-1])/d)) end;
 lat1:=radians((a->>1)::float8);lat2:=radians((b->>1)::float8);lon1:=radians((a->>0)::float8);lon2:=radians((b->>0)::float8);
 heading:=degrees(atan2(sin(lon2-lon1)*cos(lat2),cos(lat1)*sin(lat2)-sin(lat1)*cos(lat2)*cos(lon2-lon1)));
 heading:=heading-360*floor(heading/360);
 d:=d/6371008.8;
 if d<0.000000001 then return jsonb_build_object('point',b,'heading',heading);end if;
 aa:=sin((1-f)*d)/sin(d);bb:=sin(f*d)/sin(d);
 x:=aa*cos(lat1)*cos(lon1)+bb*cos(lat2)*cos(lon2);y:=aa*cos(lat1)*sin(lon1)+bb*cos(lat2)*sin(lon2);z:=aa*sin(lat1)+bb*sin(lat2);
 return jsonb_build_object('point',jsonb_build_array(degrees(atan2(y,x)),degrees(atan2(z,sqrt(x*x+y*y)))),'heading',heading);
end; $$;
create function private.agent_position_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.updated_by is not null then
  new.actor_origin:='HUMAN_MANUAL';new.engine_run_id:=null;
  if exists(select 1 from public.simulation_agent_runs r where r.scenario_id=new.scenario_id and r.incident_unit_id=new.incident_unit_id
  and r.route_id is not null and r.status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE'))
  then raise exception 'SIM_STOP_BEFORE_EDIT';end if;
 elsif new.actor_origin<>'SIMULATION_ENGINE' or not exists(select 1 from private.simulation_engine_writes w
 where w.run_id=new.engine_run_id and w.transaction_id=txid_current()) then raise exception 'NOT_AUTHORIZED';end if;
 return new;
end; $$;
create trigger simulation_agent_position_guard before insert or update on public.simulation_unit_positions for each row execute function private.agent_position_guard();
create function private.agent_publish(r public.simulation_agent_runs,p_speed float8) returns bigint
language plpgsql security definer set search_path='' as $$
declare p jsonb;v bigint;
begin
 p:=private.agent_point(r.route_id,r.progress_m);
 insert into private.simulation_engine_writes values(r.id,txid_current());
 update public.simulation_unit_positions set longitude=(p->'point'->>0)::float8,latitude=(p->'point'->>1)::float8,
 heading_degrees=(p->>'heading')::float8,speed_mps=p_speed,observed_at=clock_timestamp(),updated_by=null,
 actor_origin='SIMULATION_ENGINE',engine_run_id=r.id,version=version+1
 where scenario_id=r.scenario_id and incident_unit_id=r.incident_unit_id and active and version=r.position_version returning version into v;
 delete from private.simulation_engine_writes where run_id=r.id;
 if v is null then raise exception 'STALE_VERSION';end if;return v;
end; $$;
create function private.agent_valid(r public.simulation_agent_runs) returns boolean
language sql volatile security definer set search_path='' as $$
 select private.agent_controller(r.scenario_id) and private.navigation_live(r.task_assignment_id)
 and exists(select 1 from public.simulation_unit_positions p where p.scenario_id=r.scenario_id and p.incident_unit_id=r.incident_unit_id and p.active
 and (r.route_id is null or p.version=r.position_version))
 and (r.route_id is null or exists(select 1 from public.incident_navigation_sessions n where n.id=r.navigation_session_id
 and n.current_route_id=r.route_id and (n.status in ('PLANNED','ACTIVE','PAUSED') or
 (n.status='STOPPED' and exists(select 1 from public.incident_navigation_events e where e.session_id=n.id and e.event_sequence=n.event_sequence
 and e.event_type='NAV_INVALIDATED' and e.payload->>'cause'='simulation_scenarios')))));
$$;

create function private.agent_failure(r public.simulation_agent_runs,p_type text,p_duration integer,p_time bigint,p_op uuid,p_actor uuid default null) returns public.simulation_agent_runs
language plpgsql security definer set search_path='' as $$
begin
 if p_type='SIM_RESUME' then
  r.failure:=null;r.signal_until:=null;
  r.status:=case when r.arrived_at is not null then 'SIM_ARRIVED' when r.started then 'SIM_IN_PROGRESS' when r.acknowledged then 'SIM_ACKNOWLEDGED' else 'WAITING_TO_ACK' end;
 else
  r.failure:=p_type;r.signal_until:=case when p_type='SIM_SIGNAL_LOSS' then p_time+p_duration end;
  r.status:=case p_type when 'SIM_SIGNAL_LOSS' then 'SIM_SIGNAL_LOST' when 'SIM_HOLD' then 'SIM_PAUSED' else 'SIM_BLOCKED' end;
  if p_type<>'SIM_SIGNAL_LOSS' then r.speed_mps:=0;end if;
 end if;
 perform private.agent_event(r.scenario_id,r.id,p_type,p_time,p_op,p_actor,jsonb_build_object('duration',p_duration));
 return r;
end; $$;
create function private.agent_save(r public.simulation_agent_runs) returns void
language plpgsql security definer set search_path='' as $$
begin
 update public.simulation_agent_runs set status=r.status,failure=r.failure,signal_until=r.signal_until,
 acknowledged=r.acknowledged,started=r.started,ack_due=r.ack_due,start_due=r.start_due,arrived_at=r.arrived_at,
 progress_m=r.progress_m,speed_mps=r.speed_mps,last_sim=r.last_sim,last_sample=r.last_sample,
 position_version=r.position_version,version=version+1,last_tick=r.last_tick,finished_at=r.finished_at where id=r.id;
end; $$;
create function private.agent_tick(p_scenario uuid,p_tick bigint,p_operation uuid,p_manual boolean) returns jsonb
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
    if r.behavior='HOLD_POSITION' then
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

create function private.agent_identity() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' and (new.id,new.scenario_id,new.incident_id,new.incident_unit_id,new.task_assignment_id,new.navigation_session_id,new.route_id,
 new.behavior,new.profile,new.configuration,new.created_by,new.organization_id,new.created_at,new.baseline_mps,new.length_m,new.completion_delay)
 is distinct from (old.id,old.scenario_id,old.incident_id,old.incident_unit_id,old.task_assignment_id,old.navigation_session_id,old.route_id,
 old.behavior,old.profile,old.configuration,old.created_by,old.organization_id,old.created_at,old.baseline_mps,old.length_m,old.completion_delay)
 then raise exception 'INVALID_SIMULATION_STATE';end if;
 if not exists(select 1 from public.incident_task_assignments a where a.id=new.task_assignment_id and a.incident_id=new.incident_id
 and a.incident_unit_id=new.incident_unit_id and a.recipient_type='INCIDENT_UNIT') or
 (new.route_id is not null and not exists(select 1 from public.incident_navigation_sessions n where n.id=new.navigation_session_id
 and n.task_assignment_id=new.task_assignment_id and n.incident_unit_id=new.incident_unit_id))
 then raise exception 'INVALID_SIMULATION_UNIT';end if;
 return new;
end; $$;
create trigger simulation_agent_identity before insert or update on public.simulation_agent_runs for each row execute function private.agent_identity();

create function public.simulation_agent_command(p_scenario uuid,p_organization_id uuid,p_operation uuid,p_version bigint,p_action text,p_payload jsonb) returns jsonb
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
 if p_action='STEP' then
 result_value:=private.agent_tick(s.id,(p_payload->>'tick')::bigint,p_operation,true);
 elsif p_action='SCALE' then
 if coalesce((p_payload->>'scale')::integer,0) not in (1,5,10) then raise exception 'VALIDATION_FAILED';end if;
 update public.simulation_scenario_clock set scale=(p_payload->>'scale')::integer,anchor=clock_timestamp() where scenario_id=s.id;
 elsif p_action='START' then
 if s.status<>'RUNNING' or not private.agent_controller(s.id) then raise exception 'INVALID_SIMULATION_STATE';end if;
 if (select count(*) from public.simulation_agent_runs where scenario_id=s.id)>=1000 or
 (select count(*) from public.simulation_agent_runs where scenario_id=s.id and status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE'))>=100 then raise exception 'SIM_LIMIT';end if;
 select * into a from public.incident_task_assignments where id=(p_payload->>'assignment_id')::uuid and incident_id=s.incident_id for update;
 if not found or a.recipient_type<>'INCIDENT_UNIT' or not private.navigation_live(a.id) then raise exception 'INVALID_SIMULATION_UNIT';end if;
 select coalesce(v.native_behavior,'GENERIC') into behavior_value from public.incident_tasks t join public.operational_action_definition_versions v on v.id=t.action_definition_version_id where t.id=a.task_id;
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
 c.seconds+ack,c.seconds+ack+start_delay,completion,len,case when len>0 then least(100,len/route.duration_s*mult) else 0 end,
 c.seconds,c.seconds,p.version,auth.uid(),p_organization_id) returning * into r;
 perform private.agent_event(s.id,r.id,'SIM_RUN_CREATED',c.seconds,p_operation,auth.uid(),r.configuration);
 if profile_value='NO_RESPONSE' then
 r:=private.agent_failure(r,'SIM_NO_RESPONSE',1,c.seconds,p_operation);perform private.agent_save(r);
 elsif profile_value in ('BREAKDOWN','COMMUNICATION_LOSS','ROUTE_BLOCKED') then
 event_value:=case profile_value when 'BREAKDOWN' then 'SIM_BREAKDOWN' when 'COMMUNICATION_LOSS' then 'SIM_SIGNAL_LOSS' else 'SIM_ROAD_BLOCKED' end;
 insert into public.simulation_event_injections(id,scenario_id,run_id,event_type,trigger_type,trigger_value,duration,created_by)
 values(md5(run_id::text||':profile')::uuid,s.id,run_id,event_value,case when len>0 then 'PROGRESS' else 'EXECUTION_START' end,case when len>0 then fault else 0 end,duration,auth.uid());
 end if;
 result_value:=jsonb_build_object('id',run_id);
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

create function private.agent_scenario_boundary() returns trigger
language plpgsql security definer set search_path='' as $$
declare r public.simulation_agent_runs;c public.simulation_scenario_clock;
begin
 if new.status=old.status then return null;end if;
 update public.simulation_scenario_clock set anchor=clock_timestamp(),version=version+1 where scenario_id=new.id returning * into c;
 if not found then return null;end if;
 if new.status in ('PAUSED','FINISHED') then
 for r in select * from public.simulation_agent_runs where scenario_id=new.id and status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE') order by id for update loop
 if r.route_id is not null and r.started and r.failure is distinct from 'SIM_SIGNAL_LOSS' and
 exists(select 1 from public.simulation_unit_positions p where p.scenario_id=new.id and p.incident_unit_id=r.incident_unit_id and p.active and p.version=r.position_version)
 then r.position_version:=private.agent_publish(r,0);end if;
 r.speed_mps:=0;
 if new.status='FINISHED' then r.status:='SIM_CANCELLED';r.finished_at:=clock_timestamp();end if;
 perform private.agent_save(r);
 perform private.agent_event(new.id,r.id,'SIM_SCENARIO_'||new.status,c.seconds,gen_random_uuid(),auth.uid());
 end loop;end if;
 return null;
end; $$;
create trigger simulation_agent_scenario_boundary after update of status on public.simulation_scenarios for each row execute function private.agent_scenario_boundary();

create function public.simulation_runner_batch() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then raise exception 'NOT_AUTHORIZED';end if;
 if not private.simulation_enabled() then return '[]';end if;
 return coalesce((select jsonb_agg(q.dto) from(select jsonb_build_object('scenario',c.scenario_id,'tick',c.tick::text,
 'operation',md5(c.scenario_id::text||':'||c.tick::text)::uuid) dto from public.simulation_scenario_clock c
 join public.simulation_scenarios s on s.id=c.scenario_id and s.status='RUNNING'
 where c.anchor<clock_timestamp()-interval '1 second' and c.tick<100000 and c.event_sequence<49000
 order by c.anchor,c.scenario_id limit 5) q),'[]');
end; $$;
create function public.simulation_runner_tick(p_scenario uuid,p_tick bigint,p_operation uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then raise exception 'NOT_AUTHORIZED';end if;
 begin
 return private.agent_tick(p_scenario,p_tick,p_operation,false);
 exception when others then
 update public.simulation_scenario_clock set anchor=clock_timestamp(),last_error=case when sqlerrm in
 ('SIMULATION_DISABLED','INVALID_SIMULATION_STATE','SIM_LIMIT','STALE_VERSION','SIM_ROUTE_REQUIRED') then sqlerrm else 'SIM_RUNNER_ERROR' end
 where scenario_id=p_scenario;
 return jsonb_build_object('error',case when sqlerrm in ('SIMULATION_DISABLED','INVALID_SIMULATION_STATE','SIM_LIMIT','STALE_VERSION','SIM_ROUTE_REQUIRED') then sqlerrm else 'SIM_RUNNER_ERROR' end);
 end;
end; $$;

create function public.simulation_agents_read(p_scenario uuid,p_organization_id uuid,p_unit uuid default null,p_page integer default 0,p_before bigint default null) returns jsonb
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
 return jsonb_build_object('can_control',private.simulation_controller(s.id,p_organization_id) and s.status<>'FINISHED',
 'clock',case when c.scenario_id is null then jsonb_build_object('seconds',0,'scale',1,'version','1','tick','0') else to_jsonb(c)||jsonb_build_object('version',c.version::text,'tick',c.tick::text) end,
 'runs',runs,'assignments',assignments,'events',events,'more',jsonb_array_length(runs)=25 or jsonb_array_length(assignments)=25,
 'signals',coalesce((select jsonb_object_agg(incident_unit_id::text,'SIM_SIGNAL_LOST') from public.simulation_agent_runs where scenario_id=s.id and status='SIM_SIGNAL_LOST'),'{}'),
 'counts',(select jsonb_build_object('total',count(*),'moving',count(*) filter(where status='SIM_IN_PROGRESS' and route_id is not null),
 'waiting',count(*) filter(where status='WAITING_TO_ACK'),'blocked',count(*) filter(where status in ('SIM_BLOCKED','SIM_PAUSED','SIM_SIGNAL_LOST')),
 'active',count(*) filter(where status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE'))) from public.simulation_agent_runs where scenario_id=s.id),
 'injections',coalesce((select jsonb_agg(q) from(select id,run_id,event_type,trigger_type,trigger_value,duration,fired_at from public.simulation_event_injections
 where scenario_id=s.id order by created_at desc,id limit 50)q),'[]'));
end; $$;
-- RPC-only, including reads; preserve history.
do $$
declare t text;
begin
 foreach t in array array['simulation_scenario_clock','simulation_agent_runs','simulation_agent_events','simulation_event_injections'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 execute format('create trigger %I before delete on public.%I for each row execute function private.audit_immutable()',t||'_no_delete',t);
 execute format('create trigger %I before truncate on public.%I for each statement execute function private.audit_immutable()',t||'_no_truncate',t);
 end loop;
end; $$;
create trigger simulation_agent_events_immutable before update on public.simulation_agent_events for each row execute function private.audit_immutable();
revoke all on private.simulation_paths,private.simulation_tick_receipts,private.simulation_engine_writes from public,anon,authenticated,service_role;
do $$
declare f regprocedure;
begin
 for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='private' and p.proname like 'agent_%' loop
 execute format('revoke all on function %s from public,anon,authenticated,service_role',f);
 end loop;
end; $$;
revoke all on function public.simulation_agent_command(uuid,uuid,uuid,bigint,text,jsonb),public.simulation_agents_read(uuid,uuid,uuid,integer,bigint),
 public.simulation_runner_batch(),public.simulation_runner_tick(uuid,bigint,uuid) from public,anon,authenticated,service_role;
grant execute on function public.simulation_agent_command(uuid,uuid,uuid,bigint,text,jsonb),public.simulation_agents_read(uuid,uuid,uuid,integer,bigint) to authenticated;
grant execute on function public.simulation_runner_batch(),public.simulation_runner_tick(uuid,bigint,uuid) to service_role;

create function private.agent_injection_identity() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if (new.id,new.scenario_id,new.run_id,new.event_type,new.trigger_type,new.trigger_value,new.duration,new.enabled,new.created_by,new.created_at)
 is distinct from (old.id,old.scenario_id,old.run_id,old.event_type,old.trigger_type,old.trigger_value,old.duration,old.enabled,old.created_by,old.created_at)
 or old.fired_at is not null or new.fired_at is null then raise exception 'INVALID_SIMULATION_STATE';end if;
 return new;
end; $$;
revoke all on function private.agent_injection_identity() from public,anon,authenticated,service_role;
create trigger simulation_injection_identity before update on public.simulation_event_injections for each row execute function private.agent_injection_identity();
