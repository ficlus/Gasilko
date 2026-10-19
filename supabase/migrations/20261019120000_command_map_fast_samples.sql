begin;
-- B1 read-only bounded projection: no candidate/history/geometry fetch.
create function public.simulation_map_sample(p_incident_id uuid,p_acting_organization_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.simulation_scenarios;positions_value jsonb;runs_value jsonb;
begin
 if not private.simulation_visible(p_incident_id,p_acting_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if not private.simulation_enabled() then raise exception 'SIMULATION_DISABLED';end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id;
 if not found then raise exception 'NOT_AUTHORIZED';end if;
 select coalesce(jsonb_agg(q.dto order by q.ordinal),'[]') into positions_value from(
  select p.ordinal,jsonb_build_object('scenario_id',p.scenario_id,'incident_id',p.incident_id,'incident_unit_id',p.incident_unit_id,
   'source',p.source,'ordinal',p.ordinal,'initial_longitude',p.initial_longitude,'initial_latitude',p.initial_latitude,
   'longitude',p.longitude,'latitude',p.latitude,'heading_degrees',p.heading_degrees,'speed_mps',p.speed_mps,'observed_at',p.observed_at,'version',p.version::text,'callsign',ou.callsign,'name',ou.name,'organization_id',u.organization_id,'organization_name',o.name,'sector_id',u.sector_id,'deployment_status',u.status,
   'can_command',private.task_recipient_eligible(p_incident_id,'INCIDENT_UNIT',u.id) and private.can_issue_task(p_incident_id,p_acting_organization_id,'INCIDENT_UNIT',u.id)) dto
  from public.simulation_unit_positions p join public.incident_units u on u.id=p.incident_unit_id join public.operational_units ou on ou.id=u.unit_id join public.organizations o on o.id=u.organization_id
  where p.scenario_id=s.id and p.active order by p.ordinal limit 100) q;

 select coalesce(jsonb_agg(q.dto),'[]') into runs_value from (
  select jsonb_build_object('id',r.id,'unit_id',r.incident_unit_id,'assignment_id',r.task_assignment_id,
   'route_id',r.route_id,'version',r.version::text,'position_version',r.position_version::text,
   'status',r.status,'confirmed',r.status<>'SIM_SIGNAL_LOST','progress_m',r.progress_m,'length_m',r.length_m,
   'remaining_s',case when r.status='SIM_IN_PROGRESS' and r.baseline_mps>0 then greatest(0,(r.length_m-r.progress_m)/r.baseline_mps) end,
   'sample',p.observed_at) dto
  from public.simulation_agent_runs r
  join public.simulation_unit_positions p on p.scenario_id=r.scenario_id and p.incident_unit_id=r.incident_unit_id and p.active
  where r.scenario_id=s.id and r.status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE') and private.agent_valid(r)
   and private.navigation_visible(p_incident_id,p_acting_organization_id,r.incident_unit_id)
  order by r.incident_unit_id,r.id limit 100
 ) q;
 return jsonb_build_object('scenario_id',s.id,'scenario_version',s.version::text,'status',s.status,
  'motion_epoch',(select concat_ws(':',c.last_control_at,c.event_sequence) from public.simulation_scenario_clock c where c.scenario_id=s.id),
  'observed_at',statement_timestamp(),'positions',positions_value,'runs',runs_value);
end; $$;
revoke all on function public.simulation_map_sample(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.simulation_map_sample(uuid,uuid) to authenticated;

-- Membership fingerprint excludes routine position/progress revisions, so moving
-- units do not starve multi-page geometry reads. Only metadata, no private payload.
create function private.command_map_revision(p_incident uuid,p_organization uuid) returns text
language sql volatile security definer set search_path='' as $$
 select md5(coalesce(string_agg(q.value,'|' order by q.id),''))
 from (
  select a.id,concat_ws(':',a.id,a.version,t.version,u.version,private.navigation_live(a.id),
   (select p.version::text from public.simulation_unit_positions p where p.incident_unit_id=u.id and p.active and p.actor_origin='HUMAN_MANUAL'),
   (select string_agg(concat_ws(':',n.id,n.version,n.status,n.current_route_id,case when n.status<>'PLANNED' then private.navigation_executor_valid(n.executor_id,n.executor_organization_id,n.incident_id,n.incident_unit_id) end),',' order by n.id) from public.incident_navigation_sessions n where n.task_assignment_id=a.id),
   (select string_agg(concat_ws(':',r.id,r.status,private.agent_valid(r)),',' order by r.id) from public.simulation_agent_runs r where r.task_assignment_id=a.id and r.status not in ('SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE'))) value
  from public.incident_task_assignments a join public.incident_tasks t on t.id=a.task_id
  join public.incident_units u on u.id=a.incident_unit_id
  where a.incident_id=p_incident and a.recipient_type='INCIDENT_UNIT' and t.status='OPEN' and a.status not in ('COMPLETED','UNABLE','CANCELLED')
   and private.task_recipient_eligible(p_incident,'INCIDENT_UNIT',a.incident_unit_id)
   and private.navigation_visible(p_incident,p_organization,a.incident_unit_id)
  order by a.id limit 1001
 ) q;
$$;
revoke all on function private.command_map_revision(uuid,uuid) from public,anon,authenticated,service_role;
create or replace function public.incident_command_map_read(
 p_organization_id uuid,p_incident_id uuid,p_after uuid default null,p_known_routes uuid[] default '{}'
) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare s public.simulation_scenarios;q record;dto jsonb;items jsonb:='[]';bytes integer:=0;cursor_value uuid:=p_after;more_value boolean:=false;revision_value text;
begin
 if not private.incident_acting_member(p_organization_id) or not private.can_read_incident(p_incident_id)
 or not private.simulation_visible(p_incident_id,p_organization_id) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 if coalesce(cardinality(p_known_routes),0)>1000 then raise exception 'VALIDATION_FAILED';end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id;
 if s.id is not null and not private.simulation_enabled() then raise exception 'SIMULATION_DISABLED';end if;
 revision_value:=private.command_map_revision(p_incident_id,p_organization_id);
 -- Keyset pages are assignments, not one request per route/unit. Authorization is
 -- rechecked even when a caller already holds an immutable geometry in memory.
 for q in
 select a.id,a.task_id,a.incident_unit_id unit_id,a.status,a.version,t.title,t.priority,
 t.target_label_snapshot target,t.target_type,t.target_entity_id,t.target_geometry_snapshot target_geometry,
 v.label_sl,v.label_de,v.native_behavior,ou.callsign,n.id session_id,n.status navigation_state,
 case when nr.id is not null then (to_jsonb(nr)-'navigation_steps'-'operation_id') end route,
 case when r.id is not null then jsonb_build_object('id',r.id,'route_id',r.route_id,'version',r.version::text,
  'confirmed',r.status<>'SIM_SIGNAL_LOST','status',r.status,'progress_m',r.progress_m,'length_m',r.length_m,
  'remaining_s',case when r.status='SIM_IN_PROGRESS' and r.speed_mps>0 and r.baseline_mps>0 then greatest(0,(r.length_m-r.progress_m)/r.baseline_mps) end,
  'sample',r.last_sample::text) end run,
 case when j.id is not null then jsonb_build_object('id',j.id,'state',j.state,'error',j.error_code,'queued_at',j.created_at) end automation
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
 if revision_value is distinct from private.command_map_revision(p_incident_id,p_organization_id) then raise exception 'STALE_VERSION';end if;
 return jsonb_build_object('revision',revision_value,'removals',coalesce((
  select jsonb_agg(jsonb_build_object('route_id',nr.id,'reason',case
   when not private.navigation_visible(p_incident_id,p_organization_id,a.incident_unit_id) or not private.task_recipient_eligible(p_incident_id,'INCIDENT_UNIT',a.incident_unit_id) then 'VISIBILITY_CHANGED'
   when a.status='COMPLETED' or n.status='ARRIVED_REPORTED' then 'COMPLETED'
   when a.status='CANCELLED' then 'CANCELLED'
   when n.status='SUPERSEDED' or n.current_route_id is distinct from nr.id then 'SUPERSEDED'
   else 'INVALIDATED' end))
  from public.incident_navigation_routes nr join public.incident_navigation_sessions n on n.id=nr.session_id
  join public.incident_task_assignments a on a.id=n.task_assignment_id
  where a.incident_id=p_incident_id and nr.id=any(coalesce(p_known_routes,'{}'))
 ),'[]'::jsonb),'rows',items,'cursor',cursor_value,
  'more',more_value or jsonb_array_length(items)=25,
  'simulation',s.id is not null,'automation',case when s.id is not null then s.automatic_execution end,
  'observed_at',statement_timestamp());
end; $$;

commit;
