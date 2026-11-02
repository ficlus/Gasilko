-- M14.8D2: bounded read-only diagnostics. Owner applies after D1; NOT applied by Codex.
-- Metadata indexes only; no canonical write/receipt/RLS/transport change.
create index incident_reliability_receipts on private.incident_operation_receipts
 (incident_id,acting_organization_id,actor_user_id,created_at desc,operation_id);
create index incident_reliability_task_history on public.incident_timeline
 (incident_id,actor_organization_id,recorded_at desc,sequence desc)
 where event_code in ('TASK_ISSUED','TASK_CLOSED','TASK_CANCELLED','TASK_ASSIGNMENT_ACKNOWLEDGED',
 'TASK_ASSIGNMENT_STARTED','TASK_ASSIGNMENT_BLOCKED','TASK_ASSIGNMENT_COMPLETED','TASK_ASSIGNMENT_UNABLE','TASK_ASSIGNMENT_CANCELLED');
create index incident_reliability_transport_events on private.notification_events
 (entity_id,organization_id,created_at desc,id)
 where entity_type='INCIDENT' and category='INCIDENT_TASK';
create index incident_reliability_deliveries on private.notification_deliveries(event_id,id) include(state);

create function public.incident_field_reliability_summary(
 p_acting_organization_id uuid,p_incident_id uuid,p_window text default '24h'
) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $field_reliability$
declare
 v_head jsonb;v_result jsonb;v_now timestamptz:=statement_timestamp();v_since timestamptz;
 v_receipts jsonb;v_activity jsonb;v_transport jsonb;v_events uuid[];v_event_count integer;v_event_capped boolean;
begin
 -- Same live membership/read contract and small scope head as B1; no context/map/NAV materialization.
 v_head:=public.incident_sync_head(p_acting_organization_id,p_incident_id);
 if not private.has_incident_capability(p_incident_id,p_acting_organization_id,'CHANGE_LIFECYCLE')
 then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if p_window is null or p_window not in ('1h','24h','7d') then raise exception 'VALIDATION_FAILED';end if;
 v_since:=v_now-case p_window when '1h' then interval '1 hour' when '24h' then interval '24 hours' else interval '7 days' end;

 -- Only THIS actor's exact-org/incident successful receipts. Never read request/result JSON.
 with sampled as materialized (
  select r.created_at from private.incident_operation_receipts r
  where r.incident_id=p_incident_id and r.acting_organization_id=p_acting_organization_id
   and r.actor_user_id=auth.uid() and r.created_at>=v_since and r.created_at<=v_now
  order by r.created_at desc,r.operation_id limit 1001
 )
 select jsonb_build_object('source','CANONICAL_OWN_RECEIPTS','completeness',case when count(*)=0 then 'NOT_COLLECTED' else 'AVAILABLE' end,
  'count',case when count(*)=0 then null else least(count(*),1000) end,'cap',1000,'capped',count(*)>1000,'last_at',max(s.created_at))
 into v_receipts from sampled s;

 -- Historical task events, not a queue of currently unresolved assignments. No data/actor/person DTO.
 with sampled as materialized (
  select t.event_code,t.recorded_at,t.sequence from public.incident_timeline t
  where t.incident_id=p_incident_id and t.actor_organization_id=p_acting_organization_id
   and t.recorded_at>=v_since and t.recorded_at<=v_now
   and t.event_code in ('TASK_ISSUED','TASK_CLOSED','TASK_CANCELLED','TASK_ASSIGNMENT_ACKNOWLEDGED',
    'TASK_ASSIGNMENT_STARTED','TASK_ASSIGNMENT_BLOCKED','TASK_ASSIGNMENT_COMPLETED','TASK_ASSIGNMENT_UNABLE','TASK_ASSIGNMENT_CANCELLED')
  order by t.recorded_at desc,t.sequence desc limit 1001
 ), visible as (select * from sampled order by recorded_at desc,sequence desc limit 1000)
 select jsonb_build_object('source','CANONICAL_TASK_TIMELINE','completeness',case when count(*)=0 then 'NOT_COLLECTED' else 'AVAILABLE' end,
  'count',case when count(*)=0 then null else count(*) end,'cap',1000,'capped',(select count(*)>1000 from sampled),
  'last_at',max(t.recorded_at),'blocked_events',case when count(*)=0 then null else count(*) filter(where t.event_code='TASK_ASSIGNMENT_BLOCKED') end,
  'unable_events',case when count(*)=0 then null else count(*) filter(where t.event_code='TASK_ASSIGNMENT_UNABLE') end)
 into v_activity from visible t;

 -- Existing M10 task envelopes only. Private message/evidence audiences are deliberately excluded.
 with sampled as materialized (
  select e.id,e.created_at from private.notification_events e
  where e.entity_id=p_incident_id and e.organization_id=p_acting_organization_id
   and e.entity_type='INCIDENT' and e.category='INCIDENT_TASK' and e.created_at>=v_since and e.created_at<=v_now
  order by e.created_at desc,e.id limit 201
 ), visible as (select * from sampled order by created_at desc,id limit 200)
 select coalesce(array_agg(e.id),array[]::uuid[]),count(*)::integer,(select count(*)>200 from sampled)
 into v_events,v_event_count,v_event_capped from visible e;

 with sampled as materialized (
  select d.state,d.event_id,d.id from private.notification_deliveries d where d.event_id=any(v_events)
  order by d.event_id,d.id limit 2001
 ), visible as (select * from sampled order by event_id,id limit 2000)
 select jsonb_build_object('source','M10_TASK_TRANSPORT','completeness',case when count(*)=0 then 'NOT_COLLECTED' else 'AVAILABLE' end,
  'count',case when count(*)=0 then null else count(*) end,'cap',2000,'event_cap',200,'sampled_events',v_event_count,
  'capped',v_event_capped or (select count(*)>2000 from sampled),'transport_only',true,
  'states',case when count(*)=0 then null else jsonb_build_object(
   'PENDING',count(*) filter(where d.state='PENDING'),'LEASED',count(*) filter(where d.state='LEASED'),
   'ACCEPTED',count(*) filter(where d.state='ACCEPTED'),'FAILED',count(*) filter(where d.state='FAILED'),
   'SUPPRESSED',count(*) filter(where d.state='SUPPRESSED')) end)
 into v_transport from visible d;

 -- Role expiry/revocation must not turn a completed diagnostics read into a stale access grant.
 if not private.has_incident_capability(p_incident_id,p_acting_organization_id,'CHANGE_LIFECYCLE')
 then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 v_result:=jsonb_build_object('schema_version',1,'account',auth.uid(),'acting_organization_id',p_acting_organization_id,
  'incident_id',p_incident_id,'authority','CURRENT_INCIDENT_CONTROLLER','as_of_server',v_now,'window',p_window,
  'mode',case when exists(select 1 from public.simulation_scenarios s where s.incident_id=p_incident_id) then 'TRAINING' else 'REAL' end,
  'version',v_head->>'version','revision',v_head->>'revision','timeline_sequence',v_head->>'timeline_sequence',
  'scope_fingerprint',v_head->>'scope_fingerprint','own_receipts',v_receipts,'task_history',v_activity,'task_transport',v_transport,
  'not_collected',jsonb_build_array('REMOTE_DEVICE_PENDING','RETRY_COUNT','LAST_ATTEMPT_AT','AUTHORIZED_FETCH_LATENCY',
   'HUMAN_SEEN_OR_PUSH_ACK_LATENCY','CLIENT_VERSION_DISTRIBUTION','B1_RESET_COUNT','PILOT_SIGN_OFF'));
 if octet_length(v_result::text)>16384 then raise exception 'SCHEMA_MISMATCH';end if;
 return v_result;
end;
$field_reliability$;
alter function public.incident_field_reliability_summary(uuid,uuid,text) owner to postgres;
revoke all on function public.incident_field_reliability_summary(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.incident_field_reliability_summary(uuid,uuid,text) to authenticated;
