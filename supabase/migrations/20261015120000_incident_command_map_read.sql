-- M14.5H2: bounded read projection only. No execution, routing or task mutations.
begin;
create function public.incident_command_map_read(
 p_organization_id uuid,p_incident_id uuid,p_after uuid default null,p_known_routes uuid[] default '{}'
) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare s public.simulation_scenarios;q record;dto jsonb;items jsonb:='[]';bytes integer:=0;cursor_value uuid:=p_after;more_value boolean:=false;
begin
 if not private.incident_acting_member(p_organization_id) or not private.can_read_incident(p_incident_id)
 or not private.simulation_visible(p_incident_id,p_organization_id) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 if coalesce(cardinality(p_known_routes),0)>1000 then raise exception 'VALIDATION_FAILED';end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id;
 if s.id is not null and not private.simulation_enabled() then raise exception 'SIMULATION_DISABLED';end if;
 -- Keyset pages are assignments, not one request per route/unit. Authorization is
 -- rechecked even when a caller already holds an immutable geometry in memory.
 for q in
 select a.id,a.task_id,a.incident_unit_id unit_id,a.status,a.version,t.title,t.priority,
 t.target_label_snapshot target,t.target_type,t.target_entity_id,t.target_geometry_snapshot target_geometry,
 v.label_sl,v.label_de,v.native_behavior,ou.callsign,n.id session_id,n.status navigation_state,
 case when nr.id is not null then (to_jsonb(nr)-'navigation_steps'-'operation_id') end route,
 case when r.id is not null then jsonb_build_object('id',r.id,'route_id',r.route_id,'version',r.version::text,
  'status',r.status,'progress_m',r.progress_m,'length_m',r.length_m,
  'remaining_s',case when r.status='SIM_IN_PROGRESS' and r.speed_mps>0 and r.baseline_mps>0 then greatest(0,(r.length_m-r.progress_m)/r.baseline_mps) end,
  'sample',r.last_sample::text) end run,
 case when j.id is not null then jsonb_build_object('id',j.id,'state',j.state,'error',j.error_code) end automation
 from public.incident_task_assignments a
 join public.incident_tasks t on t.id=a.task_id
 join public.operational_action_definition_versions v on v.id=t.action_definition_version_id
 join public.incident_units u on u.id=a.incident_unit_id
 join public.operational_units ou on ou.id=u.unit_id
 left join lateral (
  select x.* from public.simulation_agent_runs x
  where x.task_assignment_id=a.id and x.scenario_id=s.id
   and x.status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE') and private.agent_valid(x)
  order by x.created_at desc,x.id desc limit 1
 )r on true
 left join lateral (
  select x.* from public.incident_navigation_sessions x
  where x.task_assignment_id=a.id and private.navigation_live(a.id)
   and (x.status in ('PLANNED','ACTIVE','PAUSED') or (x.id=r.navigation_session_id and x.current_route_id=r.route_id))
   and (s.id is null or x.id=r.navigation_session_id or (
    not exists(select 1 from public.simulation_agent_runs old_run where old_run.route_id=x.current_route_id)
    and exists(select 1 from public.incident_navigation_routes origin
     where origin.id=x.current_route_id and (
      origin.origin_snapshot->>'source'='MANUAL_PLANNING_POINT' or (
       origin.origin_snapshot->>'source'='SIMULATED_POSITION' and exists(
        select 1 from public.simulation_unit_positions sp where sp.scenario_id=s.id
        and sp.incident_unit_id=a.incident_unit_id and sp.active
        and origin.origin_snapshot->>'version'=sp.version::text))))
    and not exists(select 1 from private.simulation_automation_jobs invalid_job
     where invalid_job.assignment_id=a.id and not private.automation_authorized(invalid_job))
   ))
   and (s.id is not null or x.status='PLANNED' or
    private.navigation_executor_valid(x.executor_id,x.executor_organization_id,x.incident_id,x.incident_unit_id))
  order by (x.id=r.navigation_session_id) desc nulls last,x.created_at desc,x.id desc limit 1
 )n on true
 left join public.incident_navigation_routes nr on nr.id=n.current_route_id
 left join lateral (
  select x.* from private.simulation_automation_jobs x
  where x.assignment_id=a.id and x.scenario_id=s.id order by x.created_at desc,x.id desc limit 1
 )j on true
 where a.incident_id=p_incident_id and a.recipient_type='INCIDENT_UNIT'
  and t.status='OPEN' and a.status not in ('COMPLETED','UNABLE','CANCELLED')
  and (p_after is null or a.id>p_after)
  and private.task_recipient_eligible(p_incident_id,'INCIDENT_UNIT',a.incident_unit_id)
  and private.navigation_visible(p_incident_id,p_organization_id,a.incident_unit_id)
 order by a.id limit 25
 loop
  dto:=to_jsonb(q)||jsonb_build_object('version',q.version::text);
  if q.route is not null and (q.route->>'id')::uuid=any(coalesce(p_known_routes,'{}')) then
   dto:=jsonb_set(dto,'{route}',q.route-'route_geometry');
  end if;
  -- A single stored route is already limited to 3 MB. Bound every response
  -- without truncating a route, silently simplifying it or skipping a row.
  if bytes+octet_length(dto::text)>4000000 and jsonb_array_length(items)>0 then more_value:=true;exit;end if;
  items:=items||jsonb_build_array(dto);bytes:=bytes+octet_length(dto::text);cursor_value:=q.id;
 end loop;
 return jsonb_build_object('rows',items,'cursor',cursor_value,
  'more',more_value or jsonb_array_length(items)=25,
  'simulation',s.id is not null,'automation',case when s.id is not null then s.automatic_execution end,
  'observed_at',statement_timestamp());
end; $$;
revoke all on function public.incident_command_map_read(uuid,uuid,uuid,uuid[]) from public,anon,authenticated,service_role;
grant execute on function public.incident_command_map_read(uuid,uuid,uuid,uuid[]) to authenticated;
commit;
