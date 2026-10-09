-- Narrow recipient authority: explicit relationships, never polygon containment.
create function private.task_recipient_eligible(p_incident uuid,p_type text,p_recipient uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.incident_units u
 join public.incident_participants ip on ip.id=u.participation_id and ip.status='ACTIVE'
 join public.organizations o on o.id=u.organization_id and o.active
 where u.incident_id=p_incident and u.status not in ('RELEASED','UNAVAILABLE') and
 ((p_type='INCIDENT_UNIT' and u.id=p_recipient) or
 (p_type='INCIDENT_CREW_MEMBER' and exists(select 1 from public.incident_crew_members c
 join public.profiles pr on pr.id=c.user_id and pr.account_status='ACTIVE'
 join public.user_organizations m on m.user_id=c.user_id and m.organization_id=c.membership_organization_id
 where c.id=p_recipient and c.unit_assignment_id=u.id and c.status='ACTIVE'))));
$$;
create function private.can_issue_task(p_incident uuid,p_org uuid,p_type text,p_recipient uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select private.incident_acting_member(p_org) and exists(
 select 1 from public.incident_units u
 join public.incident_participants ip on ip.id=u.participation_id and ip.status='ACTIVE'
 join public.organizations o on o.id=u.organization_id and o.active
 join public.incident_role_assignments r on r.incident_id=u.incident_id and r.organization_id=p_org and r.user_id=auth.uid()
 where u.incident_id=p_incident and
 ((p_type='INCIDENT_UNIT' and u.id=p_recipient) or (p_type='INCIDENT_CREW_MEMBER' and exists(
 select 1 from public.incident_crew_members c where c.id=p_recipient and c.unit_assignment_id=u.id)))
 and private.incident_assignment_effective(r.id) and (
 r.role='INCIDENT_COMMANDER' or (r.role='AGENCY_COMMANDER' and r.organization_id=u.organization_id)
 or (r.role='SECTOR_COMMANDER' and r.sector_id=u.sector_id)
 or (r.role='UNIT_LEADER' and p_type='INCIDENT_CREW_MEMBER' and r.unit_assignment_id=u.id)));
$$;
create function private.can_execute_task(p_incident uuid,p_org uuid,p_type text,p_recipient uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select private.incident_acting_member(p_org) and private.task_recipient_eligible(p_incident,p_type,p_recipient) and
 ((p_type='INCIDENT_UNIT' and exists(select 1 from public.incident_role_assignments r
 where r.incident_id=p_incident and r.unit_assignment_id=p_recipient and r.role='UNIT_LEADER' and r.organization_id=p_org
 and r.user_id=auth.uid() and private.incident_assignment_effective(r.id))) or
 (p_type='INCIDENT_CREW_MEMBER' and exists(select 1 from public.incident_crew_members c
 where c.id=p_recipient and c.user_id=auth.uid() and c.membership_organization_id=p_org)));
$$;
create function private.task_target(p_incident uuid,p_target jsonb,p_behavior text) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare k text;entity uuid;g jsonb;label_value text;h public.hydrants;mo public.incident_map_objects;se public.incident_sectors;
begin
 if jsonb_typeof(p_target) is distinct from 'object' or
 exists(select 1 from jsonb_object_keys(p_target) x where x not in ('kind','entityId','incidentId','coordinate')) then raise exception 'INVALID_TASK_TARGET'; end if;
 k:=p_target->>'kind';
 if k='NONE' then
  if p_target<>'{"kind":"NONE"}'::jsonb then raise exception 'INVALID_TASK_TARGET'; end if;
 elsif k='COORDINATE' then
  if p_target ? 'entityId' or p_target ? 'incidentId' then raise exception 'INVALID_TASK_TARGET'; end if;
  g:=jsonb_build_object('type','Point','coordinates',p_target->'coordinate');
  perform private.validate_incident_geometry(g,array['Point']);label_value:=(p_target->'coordinate')::text;
 elsif k in ('HYDRANT','INCIDENT_MAP_OBJECT','INCIDENT_SECTOR') then
  entity:=(p_target->>'entityId')::uuid;
  if entity is null or p_target ? 'coordinate' then raise exception 'INVALID_TASK_TARGET'; end if;
  if k='HYDRANT' then
   if p_target ? 'incidentId' or not private.incident_hydrant_readable(entity) then raise exception 'INVALID_TASK_TARGET'; end if;
   select * into h from public.hydrants where id=entity for share;
   if not found or not h.active then raise exception 'INVALID_TASK_TARGET'; end if;
   label_value:=coalesce(h.code,h.id::text);
   if h.longitude is not null and h.latitude is not null then g:=jsonb_build_object('type','Point','coordinates',jsonb_build_array(h.longitude,h.latitude)); end if;
  else
   if (p_target->>'incidentId')::uuid is distinct from p_incident then raise exception 'INVALID_TASK_TARGET'; end if;
   if k='INCIDENT_MAP_OBJECT' then
    select * into mo from public.incident_map_objects where id=entity and incident_id=p_incident and active for share;
    if not found then raise exception 'INVALID_TASK_TARGET'; end if;g:=mo.geometry;label_value:=mo.label;
   else
    select * into se from public.incident_sectors where id=entity and incident_id=p_incident and active for share;
    if not found then raise exception 'INVALID_TASK_TARGET'; end if;g:=se.geometry;label_value:=se.name;
   end if;
  end if;
 else raise exception 'INVALID_TASK_TARGET'; end if;
 if p_behavior in ('MOVE_TO','WITHDRAW_TO') and (k not in ('COORDINATE','HYDRANT','INCIDENT_MAP_OBJECT') or g is null or g->>'type' is distinct from 'Point') then raise exception 'TASK_POINT_REQUIRED'; end if;
 if g is not null then perform private.validate_incident_geometry(g,array['Point','LineString','Polygon']); end if;
 return jsonb_build_object('kind',k,'entity_id',entity,'incident_id',case when k in ('INCIDENT_MAP_OBJECT','INCIDENT_SECTOR') then p_incident end,'geometry',g,'label',label_value);
end; $$;
create function private.incident_task_command(p_action text,p_operation uuid,p_org uuid,p_incident uuid,p_expected bigint,p_payload jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare actor uuid:=auth.uid();lock_id uuid;request_value jsonb;result_value jsonb;receipt private.incident_operation_receipts;
 incident_row public.incidents;task_row public.incident_tasks;a public.incident_task_assignments;
 definition public.operational_action_definitions;config public.operational_action_definition_versions;
 entity uuid;task_id_value uuid;rev bigint;now_value timestamptz:=clock_timestamp();ordinal_value smallint:=1;
 target_value jsonb;r jsonb;event_code text;event_data jsonb;next_status text;reason_value text;
 any_done boolean;all_done boolean;allowed text[];
begin
 if actor is null or not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_operation is null or p_org is null or p_incident is null or p_expected is null or p_expected<1 or
 jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>50000 then raise exception 'VALIDATION_FAILED'; end if;
 allowed:=case p_action when 'ISSUE' then array['id','action_version_id','priority','title','notes','target','parameters','recipients']
 when 'TRANSITION' then array['id','status','reason'] when 'CANCEL' then array['id'] else array[]::text[] end;
 if exists(select 1 from jsonb_object_keys(p_payload) x where not(x=any(allowed))) then raise exception 'VALIDATION_FAILED'; end if;
 entity:=(p_payload->>'id')::uuid;if entity is null then raise exception 'VALIDATION_FAILED'; end if;
 request_value:=jsonb_build_object('command','TASK_'||p_action,'org',p_org,'incident',p_incident,'expected',p_expected,'payload',p_payload);
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 -- Same org/profile/incident lock order as M14.4. Hydrant owner is included before row locking.
 for lock_id in select distinct q.id from (
 select p_org id union all select ip.organization_id from public.incident_participants ip where ip.incident_id=p_incident
 union all select h.organization_id from public.hydrants h where p_payload->'target'->>'kind'='HYDRANT' and h.id=(p_payload->'target'->>'entityId')::uuid
 ) q where q.id is not null order by q.id loop
  perform private.lock_organization(lock_id);perform 1 from public.organizations o where o.id=lock_id for share;
 end loop;
 for lock_id in select distinct q.id from (select actor id union all
 select c.user_id from public.incident_crew_members c where c.incident_id=p_incident and c.status='ACTIVE' union all
 select r.user_id from public.incident_role_assignments r where r.incident_id=p_incident and r.status='ACTIVE') q order by q.id loop
  perform 1 from public.profiles pr where pr.id=lock_id for share;
 end loop;
 if not private.incident_acting_member(p_org) or public.incident_context(p_incident,p_org) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into receipt from private.incident_operation_receipts where operation_id=p_operation;
 if found then
  if receipt.actor_user_id<>actor or receipt.request is distinct from request_value then raise exception 'OPERATION_REUSED'; end if;
  return receipt.result;
 end if;
 select * into incident_row from public.incidents where id=p_incident for update;
 if incident_row.status not in ('ACTIVE','STABILIZED') then raise exception 'INCIDENT_TERMINAL'; end if;
 rev:=incident_row.revision+1;
 if p_action='ISSUE' then
  if incident_row.version<>p_expected then raise exception 'STALE_VERSION'; end if;
  if (select count(*) from public.incident_tasks where incident_id=p_incident and status='OPEN')>=500 then raise exception 'TASK_LIMIT_REACHED'; end if;
  select * into config from public.operational_action_definition_versions where id=(p_payload->>'action_version_id')::uuid;
  if not found then raise exception 'INVALID_ACTION_DEFINITION'; end if;
  select * into definition from public.operational_action_definitions where id=config.definition_id for share;
  if not definition.active or not config.active_for_new_commands or definition.current_version_id<>config.id or
   (definition.owner_organization_id is not null and definition.owner_organization_id<>p_org) then raise exception 'INVALID_ACTION_DEFINITION'; end if;
  if jsonb_typeof(p_payload->'recipients') is distinct from 'array' then raise exception 'VALIDATION_FAILED'; end if;
  if jsonb_array_length(p_payload->'recipients') not between 1 and 100 then raise exception 'TASK_LIMIT_REACHED'; end if;
  if not coalesce(p_payload->'target'->>'kind'=any(config.target_types),false) then raise exception 'INVALID_TASK_TARGET'; end if;
  target_value:=private.task_target(p_incident,p_payload->'target',config.native_behavior);
  if p_payload->'parameters' is null then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  perform private.validate_action_parameters(config.parameter_definitions,p_payload->'parameters');
  if coalesce(p_payload->>'priority',config.default_priority) not in ('LOW','NORMAL','HIGH','CRITICAL') or
   (p_payload ? 'title' and jsonb_typeof(p_payload->'title') not in ('string','null')) or
   (p_payload ? 'notes' and jsonb_typeof(p_payload->'notes') not in ('string','null')) then raise exception 'VALIDATION_FAILED'; end if;
  -- Parent serialization plus sorted unit/crew locks makes input array order irrelevant.
  perform 1 from public.incident_units u where u.incident_id=p_incident and exists(
   select 1 from jsonb_array_elements(p_payload->'recipients') q where
   (q->>'type'='INCIDENT_UNIT' and u.id=(q->>'recipient_id')::uuid) or
   (q->>'type'='INCIDENT_CREW_MEMBER' and exists(select 1 from public.incident_crew_members cm where cm.id=(q->>'recipient_id')::uuid and cm.unit_assignment_id=u.id)))
   order by u.id for update;
  perform 1 from public.incident_crew_members cm where cm.incident_id=p_incident and exists(
   select 1 from jsonb_array_elements(p_payload->'recipients') q where q->>'type'='INCIDENT_CREW_MEMBER' and cm.id=(q->>'recipient_id')::uuid)
   order by cm.id for update;
  for r in select value from jsonb_array_elements(p_payload->'recipients') order by value->>'recipient_id',value->>'id' loop
   if jsonb_typeof(r) is distinct from 'object' then raise exception 'INVALID_TASK_RECIPIENT'; end if;
   if exists(select 1 from jsonb_object_keys(r) x where x not in ('id','type','recipient_id'))
    or (r->>'id')::uuid is null or not coalesce(r->>'type'=any(config.recipient_types),false)
    or not private.task_recipient_eligible(p_incident,r->>'type',(r->>'recipient_id')::uuid)
    or not private.can_issue_task(p_incident,p_org,r->>'type',(r->>'recipient_id')::uuid)
    then raise exception 'INVALID_TASK_RECIPIENT'; end if;
  end loop;
  insert into public.incident_tasks(id,incident_id,action_definition_version_id,issuing_organization_id,issued_by,priority,title,notes,
   target_type,target_entity_id,target_incident_id,target_geometry_snapshot,target_label_snapshot,parameters,changed_revision)
   values(entity,p_incident,config.id,p_org,actor,coalesce(p_payload->>'priority',config.default_priority),nullif(btrim(p_payload->>'title'),''),
    nullif(btrim(p_payload->>'notes'),''),target_value->>'kind',(target_value->>'entity_id')::uuid,(target_value->>'incident_id')::uuid,
    nullif(target_value->'geometry','null'::jsonb),target_value->>'label',p_payload->'parameters',rev);
  insert into public.incident_task_assignments(id,task_id,incident_id,recipient_type,incident_unit_id,incident_crew_member_id,changed_revision)
   select (r->>'id')::uuid,entity,p_incident,r->>'type',case when r->>'type'='INCIDENT_UNIT' then (r->>'recipient_id')::uuid end,
    case when r->>'type'='INCIDENT_CREW_MEMBER' then (r->>'recipient_id')::uuid end,rev from jsonb_array_elements(p_payload->'recipients') r;
  task_id_value:=entity;event_code:='TASK_ISSUED';event_data:=jsonb_build_object('task_id',entity,'action_version_id',config.id,'recipient_count',jsonb_array_length(p_payload->'recipients'));
 else
  if p_action='TRANSITION' then select task_id into task_id_value from public.incident_task_assignments where id=entity and incident_id=p_incident;
  elsif p_action='CANCEL' then task_id_value:=entity;else raise exception 'VALIDATION_FAILED';end if;
  select * into task_row from public.incident_tasks where id=task_id_value and incident_id=p_incident for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if p_action='CANCEL' and task_row.version<>p_expected then raise exception 'STALE_VERSION'; end if;
  if p_action='TRANSITION' then
   select * into a from public.incident_task_assignments where id=entity;
   if a.version<>p_expected then raise exception 'STALE_VERSION'; end if;
  end if;
  if task_row.status<>'OPEN' then raise exception 'INVALID_TASK_TRANSITION'; end if;
  select * into config from public.operational_action_definition_versions where id=task_row.action_definition_version_id;
  perform 1 from public.incident_task_assignments where task_id=task_id_value order by id for update;
  if p_action='CANCEL' then
   if task_row.version<>p_expected then raise exception 'STALE_VERSION'; end if;
   -- Whole-task cancellation must cover every remaining recipient, not just one.
   if exists(select 1 from public.incident_task_assignments x where x.task_id=task_id_value and x.status not in ('COMPLETED','UNABLE','CANCELLED')
    and not private.can_issue_task(p_incident,p_org,x.recipient_type,coalesce(x.incident_unit_id,x.incident_crew_member_id))) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   for a in select * from public.incident_task_assignments where task_id=task_id_value and status not in ('COMPLETED','UNABLE','CANCELLED') order by id loop
    update public.incident_task_assignments set status='CANCELLED',cancelled_at=now_value,cancelled_by=actor,version=version+1,changed_revision=rev where id=a.id;
    perform private.append_incident_event(p_incident,p_org,p_operation,ordinal_value,'TASK_ASSIGNMENT_CANCELLED',jsonb_build_object('task_id',task_id_value,'task_assignment_id',a.id,'from_status',a.status));
    ordinal_value:=ordinal_value+1;
   end loop;
   update public.incident_tasks set status='CANCELLED',cancelled_at=now_value,cancelled_by=actor,version=version+1,changed_revision=rev where id=task_id_value;
   event_code:='TASK_CANCELLED';event_data:=jsonb_build_object('task_id',task_id_value);
  else
   select * into a from public.incident_task_assignments where id=entity;
   if a.version<>p_expected then raise exception 'STALE_VERSION'; end if;
   next_status:=p_payload->>'status';reason_value:=btrim(coalesce(p_payload->>'reason',''));
   if a.status in ('COMPLETED','UNABLE','CANCELLED') or next_status is null then raise exception 'INVALID_TASK_TRANSITION'; end if;
   if next_status='CANCELLED' then
    if not private.can_issue_task(p_incident,p_org,a.recipient_type,coalesce(a.incident_unit_id,a.incident_crew_member_id)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   else
    if not private.can_execute_task(p_incident,p_org,a.recipient_type,coalesce(a.incident_unit_id,a.incident_crew_member_id)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
    if not ((a.status='ISSUED' and next_status='ACKNOWLEDGED') or
     (a.status in ('ACKNOWLEDGED','BLOCKED') and next_status='IN_PROGRESS') or
     (a.status='ISSUED' and next_status='IN_PROGRESS' and not config.requires_acknowledgement) or
     (a.status in ('ISSUED','ACKNOWLEDGED','BLOCKED') and next_status='UNABLE') or
     (a.status='IN_PROGRESS' and next_status in ('BLOCKED','COMPLETED'))) then raise exception 'INVALID_TASK_TRANSITION'; end if;
   end if;
   if length(reason_value)>2000 or (next_status in ('BLOCKED','UNABLE') and reason_value='') or
    (p_payload ? 'reason' and jsonb_typeof(p_payload->'reason')<>'string') then raise exception 'VALIDATION_FAILED'; end if;
   update public.incident_task_assignments set status=next_status,version=version+1,changed_revision=rev,
    acknowledged_at=case when next_status='ACKNOWLEDGED' then now_value else acknowledged_at end,
    acknowledged_by=case when next_status='ACKNOWLEDGED' then actor else acknowledged_by end,
    started_at=case when next_status='IN_PROGRESS' then coalesce(started_at,now_value) else started_at end,
    started_by=case when next_status='IN_PROGRESS' then coalesce(started_by,actor) else started_by end,
    blocked_at=case when next_status='BLOCKED' then now_value else blocked_at end,
    blocked_by=case when next_status='BLOCKED' then actor else blocked_by end,
    blocked_reason=case when next_status='BLOCKED' then reason_value else blocked_reason end,
    completed_at=case when next_status='COMPLETED' then now_value else completed_at end,
    completed_by=case when next_status='COMPLETED' then actor else completed_by end,
    unable_at=case when next_status='UNABLE' then now_value else unable_at end,
    unable_by=case when next_status='UNABLE' then actor else unable_by end,
    unable_reason=case when next_status='UNABLE' then reason_value else unable_reason end,
    cancelled_at=case when next_status='CANCELLED' then now_value else cancelled_at end,
    cancelled_by=case when next_status='CANCELLED' then actor else cancelled_by end where id=entity;
   select bool_and(status in ('COMPLETED','UNABLE','CANCELLED')),bool_or(status='COMPLETED') into all_done,any_done
    from public.incident_task_assignments where task_id=task_id_value;
   update public.incident_tasks set version=version+1,changed_revision=rev,status=case when all_done then 'CLOSED' else 'OPEN' end,
    closed_at=case when all_done then now_value end,outcome=case when not all_done then null when not any_done then 'FAILED'
    when not exists(select 1 from public.incident_task_assignments where task_id=task_id_value and status<>'COMPLETED') then 'SUCCESS' else 'PARTIAL' end where id=task_id_value;
   event_code:='TASK_ASSIGNMENT_'||case next_status when 'IN_PROGRESS' then 'STARTED' else next_status end;
   event_data:=jsonb_build_object('task_id',task_id_value,'task_assignment_id',entity,'from_status',a.status,'status',next_status,'reason',nullif(reason_value,''));
  end if;
 end if;
 update public.incidents set version=version+1 where id=p_incident;
 perform private.append_incident_event(p_incident,p_org,p_operation,ordinal_value,event_code,event_data);
 if all_done then
  ordinal_value:=ordinal_value+1;
  perform private.append_incident_event(p_incident,p_org,p_operation,ordinal_value,'TASK_CLOSED',
   (select jsonb_build_object('task_id',id,'outcome',outcome) from public.incident_tasks where id=task_id_value));
 end if;
 select jsonb_build_object('incident_id',i.id,'operation_id',p_operation,'task_id',task_id_value,'version',i.version::text,'revision',i.revision::text,'timeline_sequence',i.timeline_sequence::text)
  into result_value from public.incidents i where i.id=p_incident;
 perform private.write_audit(p_org,actor,event_code,'incident_tasks',task_id_value,null,jsonb_build_object('operation_id',p_operation,'event',event_data,'result',result_value));
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,actor,p_org,p_incident,'TASK_'||p_action,request_value,result_value);
 return result_value;
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation then raise exception 'VALIDATION_FAILED';
 when unique_violation then raise exception 'OPERATION_REUSED';
end; $$;
create function public.incident_issue_task(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.incident_task_command('ISSUE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload); $$;
revoke all on function public.incident_issue_task(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_issue_task(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_transition_task_assignment(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.incident_task_command('TRANSITION',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload); $$;
revoke all on function public.incident_transition_task_assignment(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_transition_task_assignment(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_cancel_task(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.incident_task_command('CANCEL',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload); $$;
revoke all on function public.incident_cancel_task(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_cancel_task(uuid,uuid,uuid,bigint,jsonb) to authenticated;
revoke all on function private.task_recipient_eligible(uuid,text,uuid),private.can_issue_task(uuid,uuid,text,uuid),private.can_execute_task(uuid,uuid,text,uuid),private.task_target(uuid,jsonb,text),private.incident_task_command(text,uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
