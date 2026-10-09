-- Catalog administration reuses M8.4 durable audit receipts and exact-org locks.
create function public.operational_action_save(p_organization_id uuid,p_operation uuid,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();d public.operational_action_definitions;receipt public.audit_log;result_value jsonb;
 id_value uuid;version_id uuid;expected bigint;cfg jsonb;
begin
 if actor is null or not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_operation is null or jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>40000 then raise exception 'VALIDATION_FAILED'; end if;
 if exists(select 1 from jsonb_object_keys(p_payload) k where k not in ('id','version','version_id','code','active','configuration')) or
 jsonb_typeof(p_payload->'active') is distinct from 'boolean' then raise exception 'VALIDATION_FAILED'; end if;
 id_value:=(p_payload->>'id')::uuid;version_id:=(p_payload->>'version_id')::uuid;expected:=(p_payload->>'version')::bigint;cfg:=p_payload->'configuration';
 if id_value is null or version_id is null or expected is null or expected<0 or jsonb_typeof(cfg) is distinct from 'object' then raise exception 'VALIDATION_FAILED'; end if;
 if exists(select 1 from jsonb_object_keys(cfg) k where k not in ('native_behavior','label_sl','label_de','description_sl','description_de','default_priority','requires_acknowledgement','active_for_new_commands','recipient_types','target_types','parameter_definitions')) then raise exception 'VALIDATION_FAILED'; end if;
 if jsonb_typeof(cfg->'requires_acknowledgement') is distinct from 'boolean' or jsonb_typeof(cfg->'active_for_new_commands') is distinct from 'boolean'
 or jsonb_typeof(cfg->'recipient_types') is distinct from 'array' or jsonb_typeof(cfg->'target_types') is distinct from 'array'
 or jsonb_typeof(cfg->'label_sl') is distinct from 'string' or jsonb_typeof(cfg->'label_de') is distinct from 'string'
 or (cfg ? 'description_sl' and jsonb_typeof(cfg->'description_sl') not in ('string','null'))
 or (cfg ? 'description_de' and jsonb_typeof(cfg->'description_de') not in ('string','null')) then raise exception 'VALIDATION_FAILED'; end if;
 perform private.validate_action_parameters(cfg->'parameter_definitions');
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,842));
 perform private.lock_organization(p_organization_id);
 perform 1 from public.organizations where id=p_organization_id for share;
 perform 1 from public.profiles where id=actor for share;
 if not private.operational_inventory_manager(p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into receipt from public.audit_log where entity_type='web_administration_operations' and entity_id=p_operation;
 if found then
  if receipt.user_id<>actor or receipt.organization_id is distinct from p_organization_id or receipt.new_data->>'action' is distinct from 'ACTION_DEFINITION_SAVE'
   or receipt.new_data->'request' is distinct from p_payload then raise exception 'OPERATION_REUSED'; end if;
  return receipt.new_data->'result';
 end if;
 select * into d from public.operational_action_definitions where id=id_value for update;
 if found then
  if d.owner_organization_id is distinct from p_organization_id then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if d.version<>expected then raise exception 'STALE_VERSION'; end if;
  if d.code is distinct from p_payload->>'code' then raise exception 'INVALID_ACTION_DEFINITION'; end if;
 else
  if expected<>0 then raise exception 'STALE_VERSION'; end if;
  insert into public.operational_action_definitions(id,owner_organization_id,code,current_version_id,created_by,updated_by)
   values(id_value,p_organization_id,p_payload->>'code',version_id,actor,actor);
 end if;
 insert into public.operational_action_definition_versions(id,definition_id,version_number,native_behavior,label_sl,label_de,description_sl,description_de,
 default_priority,requires_acknowledgement,active_for_new_commands,recipient_types,target_types,parameter_definitions,created_by)
 values(version_id,id_value,expected+1,cfg->>'native_behavior',btrim(cfg->>'label_sl'),btrim(cfg->>'label_de'),cfg->>'description_sl',cfg->>'description_de',
 cfg->>'default_priority',(cfg->>'requires_acknowledgement')::boolean,(cfg->>'active_for_new_commands')::boolean,
 array(select jsonb_array_elements_text(cfg->'recipient_types')),array(select jsonb_array_elements_text(cfg->'target_types')),cfg->'parameter_definitions',actor);
 update public.operational_action_definitions set active=(p_payload->>'active')::boolean,current_version_id=version_id,updated_by=actor,
 updated_at=clock_timestamp(),version=expected+1 where id=id_value;
 result_value:=jsonb_build_object('id',id_value,'version',(expected+1)::text,'version_id',version_id);
 perform private.write_audit(p_organization_id,actor,'ACTION_DEFINITION_SAVE','web_administration_operations',p_operation,to_jsonb(d),
 jsonb_build_object('action','ACTION_DEFINITION_SAVE','request',p_payload,'result',result_value));
 return result_value;
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation then raise exception 'VALIDATION_FAILED';
 when unique_violation then raise exception 'OPERATION_REUSED';
end; $$;
create function public.operational_action_catalog(p_organization_id uuid,p_admin boolean default false,p_query text default '',p_page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows_value jsonb;count_value integer;
begin
 if not private.incident_acting_member(p_organization_id) or (p_admin and not private.operational_inventory_manager(p_organization_id)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_admin is null or p_page is null or p_page not between 0 and 10000 or p_query is null or length(p_query)>100 then raise exception 'VALIDATION_FAILED'; end if;
 select coalesce(jsonb_agg(q.dto order by q.code,q.id),'[]'),count(*) into rows_value,count_value from(
 select d.id,d.code,jsonb_build_object('id',d.id,'owner_organization_id',d.owner_organization_id,'code',d.code,'active',d.active,'version',d.version::text,
 'configuration',to_jsonb(v)||jsonb_build_object('version_number',v.version_number::text)) dto
 from public.operational_action_definitions d join public.operational_action_definition_versions v on v.id=d.current_version_id
 where (d.owner_organization_id is null or d.owner_organization_id=p_organization_id)
 and (p_admin or (d.active and v.active_for_new_commands))
 and (p_query='' or position(lower(p_query) in lower(d.code||' '||v.label_sl||' '||v.label_de))>0)
 order by d.code,d.id limit 101 offset p_page*100) q;
 return jsonb_build_object('rows',case when count_value>100 then rows_value-100 else rows_value end,'more',count_value>100);
end; $$;
create function public.incident_task_recipients(p_incident_id uuid,p_acting_organization_id uuid,p_query text default '',p_page integer default 0,p_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare rows_value jsonb;n integer;
begin
 if public.incident_context(p_incident_id,p_acting_organization_id) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_query is null or length(p_query)>100 or p_page is null or p_page not between 0 and 10000 then raise exception 'VALIDATION_FAILED'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.name,q.id),'[]'),count(*) into rows_value,n from(
 select candidates.* from (
 select u.id,'INCIDENT_UNIT'::text type,ou.callsign||' · '||ou.name name,u.organization_id,o.name organization_name,u.sector_id
 from public.incident_units u join public.operational_units ou on ou.id=u.unit_id join public.organizations o on o.id=u.organization_id where u.incident_id=p_incident_id
 union all
 select c.id,'INCIDENT_CREW_MEMBER',coalesce(pr.display_name,c.user_id::text)||' · '||ou.callsign,u.organization_id,o.name,u.sector_id
 from public.incident_crew_members c join public.profiles pr on pr.id=c.user_id join public.incident_units u on u.id=c.unit_assignment_id
 join public.operational_units ou on ou.id=u.unit_id join public.organizations o on o.id=u.organization_id where c.incident_id=p_incident_id
 ) candidates where (p_id is null or candidates.id=p_id) and (p_query='' or position(lower(p_query) in lower(candidates.name))>0)
 and private.task_recipient_eligible(p_incident_id,candidates.type,candidates.id)
 and private.can_issue_task(p_incident_id,p_acting_organization_id,candidates.type,candidates.id)
 order by name,id limit 51 offset p_page*50) q;
 return jsonb_build_object('rows',case when n>50 then rows_value-50 else rows_value end,'more',n>50);
end; $$;
create function private.task_projection(p_task public.incident_tasks) returns jsonb
language sql stable security definer set search_path='' as $$
 select to_jsonb(p_task)||jsonb_build_object('version',p_task.version::text,'changed_revision',p_task.changed_revision::text,
 'issuer_name',coalesce(pr.display_name,p_task.issued_by::text),'organization_name',o.name,
 'configuration',to_jsonb(v)||jsonb_build_object('version_number',v.version_number::text))
 from public.operational_action_definition_versions v join public.profiles pr on pr.id=p_task.issued_by
 join public.organizations o on o.id=p_task.issuing_organization_id where v.id=p_task.action_definition_version_id;
$$;
create function public.incident_tasks_page(p_incident_id uuid,p_acting_organization_id uuid,p_history boolean default false,p_page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows_value jsonb;n integer;
begin
 if public.incident_context(p_incident_id,p_acting_organization_id) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_history is null or p_page is null or p_page not between 0 and 10000 then raise exception 'VALIDATION_FAILED'; end if;
 select coalesce(jsonb_agg(q.dto order by q.issued_at desc,q.id desc),'[]'),count(*) into rows_value,n from (
 select t.id,t.issued_at,private.task_projection(t) dto from public.incident_tasks t
 where t.incident_id=p_incident_id and ((not p_history and t.status='OPEN') or (p_history and t.status<>'OPEN'))
 order by t.issued_at desc,t.id desc limit 51 offset p_page*50) q;
 return jsonb_build_object('rows',case when n>50 then rows_value-50 else rows_value end,'more',n>50);
end; $$;
create function public.incident_task_detail(p_incident_id uuid,p_acting_organization_id uuid,p_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare t public.incident_tasks;assignments_value jsonb;live boolean;can_cancel boolean;
begin
 if public.incident_context(p_incident_id,p_acting_organization_id) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into t from public.incident_tasks where id=p_id and incident_id=p_incident_id;
 if not found then raise exception 'TASK_NOT_FOUND'; end if;
 select status in ('ACTIVE','STABILIZED') into live from public.incidents where id=p_incident_id;
 select coalesce(jsonb_agg(q.dto order by q.id),'[]') into assignments_value from(
 select a.id,to_jsonb(a)||jsonb_build_object('version',a.version::text,'changed_revision',a.changed_revision::text,
 'recipient_name',case when a.recipient_type='INCIDENT_UNIT' then ou.callsign||' · '||ou.name else coalesce(pr.display_name,c.user_id::text)||' · '||ou.callsign end,
 'can_execute',live and t.status='OPEN' and a.status not in ('COMPLETED','UNABLE','CANCELLED') and
 private.can_execute_task(p_incident_id,p_acting_organization_id,a.recipient_type,coalesce(a.incident_unit_id,a.incident_crew_member_id)),
 'can_cancel',live and t.status='OPEN' and a.status not in ('COMPLETED','UNABLE','CANCELLED') and
 private.can_issue_task(p_incident_id,p_acting_organization_id,a.recipient_type,coalesce(a.incident_unit_id,a.incident_crew_member_id))) dto
 from public.incident_task_assignments a left join public.incident_crew_members c on c.id=a.incident_crew_member_id
 left join public.profiles pr on pr.id=c.user_id join public.incident_units u on u.id=coalesce(a.incident_unit_id,c.unit_assignment_id)
 join public.operational_units ou on ou.id=u.unit_id where a.task_id=p_id order by a.id limit 100) q;
 can_cancel:=live and t.status='OPEN' and not exists(select 1 from public.incident_task_assignments a where a.task_id=p_id
 and a.status not in ('COMPLETED','UNABLE','CANCELLED') and not private.can_issue_task(p_incident_id,p_acting_organization_id,a.recipient_type,coalesce(a.incident_unit_id,a.incident_crew_member_id)));
 return private.task_projection(t)||jsonb_build_object('assignments',assignments_value,'can_cancel',can_cancel);
end; $$;
revoke all on function private.task_projection(public.incident_tasks) from public,anon,authenticated,service_role;
revoke all on function public.operational_action_save(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.operational_action_save(uuid,uuid,jsonb) to authenticated;
revoke all on function public.operational_action_catalog(uuid,boolean,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_action_catalog(uuid,boolean,text,integer) to authenticated;
revoke all on function public.incident_task_recipients(uuid,uuid,text,integer,uuid) from public,anon,authenticated,service_role;
grant execute on function public.incident_task_recipients(uuid,uuid,text,integer,uuid) to authenticated;
revoke all on function public.incident_tasks_page(uuid,uuid,boolean,integer) from public,anon,authenticated,service_role;
grant execute on function public.incident_tasks_page(uuid,uuid,boolean,integer) to authenticated;
revoke all on function public.incident_task_detail(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.incident_task_detail(uuid,uuid,uuid) to authenticated;
