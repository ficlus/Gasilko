-- M14.8D1: read-only receipt recovery, no new write authority.
-- Apply after 20261030200000_incident_field_map.sql; NOT applied by Codex.
create function public.incident_field_operation_receipts(
 p_acting_organization_id uuid,p_incident_id uuid,p_requests jsonb
) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $field_receipts$
declare actor uuid:=auth.uid();entry jsonb;args jsonb;data jsonb;op uuid;rpc_name text;command_name text;
 expected_request jsonb;saved private.incident_operation_receipts;v_unit_id uuid;eligible boolean;
 rows_value jsonb:='[]';fingerprint text;
begin
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 fingerprint:=private.incident_field_scope(p_acting_organization_id,p_incident_id);
 if jsonb_typeof(p_requests) is distinct from 'array' then raise exception 'VALIDATION_FAILED';end if;
 if jsonb_array_length(p_requests)>25 or octet_length(p_requests::text)>262144 then raise exception 'VALIDATION_FAILED';end if;
 if exists(select 1 from jsonb_array_elements(p_requests) x group by x.value->'request'->>'p_operation' having count(*)>1)
 then raise exception 'VALIDATION_FAILED';end if;
 for entry in select x.value from jsonb_array_elements(p_requests) x loop
  rpc_name:=entry->>'rpc';args:=entry->'request';data:=args->'p_payload';
  if jsonb_typeof(entry) is distinct from 'object' or jsonb_typeof(args) is distinct from 'object'
   or jsonb_typeof(data) is distinct from 'object' then raise exception 'VALIDATION_FAILED';end if;
  op:=(args->>'p_operation')::uuid;
  if op is null or (args->>'p_expected_version')::bigint is null or (args->>'p_expected_version')::bigint<1
   or (args->>'p_acting_organization_id')::uuid is distinct from p_acting_organization_id
   or (args->>'p_incident_id')::uuid is distinct from p_incident_id
   or exists(select 1 from jsonb_object_keys(args) k where k not in
    ('p_operation','p_acting_organization_id','p_incident_id','p_expected_version','p_payload'))
  then raise exception 'VALIDATION_FAILED';end if;
  command_name:=case rpc_name
   when 'incident_transition_task_assignment' then 'TASK_TRANSITION'
   when 'incident_issue_task' then 'TASK_ISSUE'
   when 'incident_update_unit_status' then 'RESOURCE_STATUS'
   when 'incident_add_crew_member' then 'RESOURCE_CREW_JOIN'
   when 'incident_remove_crew_member' then 'RESOURCE_CREW_LEAVE'
   when 'incident_transition_resource_allocation' then 'RESOURCE_RESOURCE_TRANSITION'
   when 'incident_message_send' then 'MESSAGE_SEND' end;
  if command_name is null then raise exception 'VALIDATION_FAILED';end if;
  expected_request:=jsonb_build_object('command',command_name,'org',p_acting_organization_id,
   'incident',p_incident_id,'expected',(args->>'p_expected_version')::bigint,'payload',data);
  eligible:=false;v_unit_id:=null;
  if rpc_name='incident_transition_task_assignment' then
   eligible:=private.field_assignment_visible(actor,p_acting_organization_id,(data->>'id')::uuid)
    and exists(select 1 from public.incident_task_assignments a where a.id=(data->>'id')::uuid and a.incident_id=p_incident_id);
  elsif rpc_name='incident_message_send' then
   expected_request:=jsonb_build_object('command','MESSAGE_SEND','org',p_acting_organization_id,'incident',p_incident_id,
    'payload',data||jsonb_build_object('body',btrim(replace(replace(data->>'body',chr(13)||chr(10),chr(10)),chr(13),chr(10)))));
   eligible:=private.message_authority(actor,p_acting_organization_id,p_incident_id,data->>'audience_kind',
    (data->>'audience_org_id')::uuid,(data->>'audience_unit_assignment_id')::uuid,false);
  else
   if rpc_name='incident_issue_task' then
    if jsonb_typeof(data->'recipients') is distinct from 'array' then raise exception 'VALIDATION_FAILED';end if;
    select c.unit_assignment_id into v_unit_id from public.incident_crew_members c
     where c.id=(data->'recipients'->0->>'recipient_id')::uuid and c.incident_id=p_incident_id
     and jsonb_array_length(data->'recipients')=1;
   elsif rpc_name='incident_update_unit_status' then v_unit_id:=(data->>'id')::uuid;
   elsif rpc_name='incident_add_crew_member' then v_unit_id:=(data->>'unit_assignment_id')::uuid;
   elsif rpc_name='incident_remove_crew_member' then
    select c.unit_assignment_id into v_unit_id from public.incident_crew_members c where c.id=(data->>'id')::uuid and c.incident_id=p_incident_id;
   else
    select a.unit_assignment_id into v_unit_id from public.incident_resource_allocations a where a.id=(data->>'id')::uuid and a.incident_id=p_incident_id;
   end if;
   eligible:=exists(select 1 from public.incident_units u where u.id=v_unit_id and u.incident_id=p_incident_id and u.organization_id=p_acting_organization_id)
    and private.field_unit_visible(actor,p_acting_organization_id,v_unit_id)
    and private.field_unit_leader(actor,p_acting_organization_id,v_unit_id);
  end if;
  if eligible is not true then
   rows_value:=rows_value||jsonb_build_array(jsonb_build_object('operation_id',op,'status','SCOPE_UNAVAILABLE'));
   continue;
  end if;
  select * into saved from private.incident_operation_receipts r where r.operation_id=op
   and r.actor_user_id=actor and r.acting_organization_id=p_acting_organization_id and r.incident_id=p_incident_id;
  if not found then
   -- ABSENT is NOT proof of rejection: another transaction/late reply may exist.
   rows_value:=rows_value||jsonb_build_array(jsonb_build_object('operation_id',op,'status','ABSENT'));
  elsif saved.command_code is distinct from command_name or saved.request is distinct from expected_request then
   rows_value:=rows_value||jsonb_build_array(jsonb_build_object('operation_id',op,'status','IDENTITY_MISMATCH'));
  else
   rows_value:=rows_value||jsonb_build_array(jsonb_build_object('operation_id',op,'status','FOUND',
    'result',case when command_name='MESSAGE_SEND' then saved.result-'message' else saved.result end,'confirmed_at',saved.created_at));
  end if;
 end loop;
 return jsonb_build_object('account',actor,'organization',p_acting_organization_id,'incident_id',p_incident_id,
  'scope_fingerprint',fingerprint,'rows',rows_value);
exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'VALIDATION_FAILED';
end;
$field_receipts$;
alter function public.incident_field_operation_receipts(uuid,uuid,jsonb) owner to postgres;
revoke all on function public.incident_field_operation_receipts(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_field_operation_receipts(uuid,uuid,jsonb) to authenticated;
