-- M14.7C: immutable communication. Not tasks, acknowledgements or dispatch.
create table public.incident_messages (
 id uuid primary key,incident_id uuid not null references public.incidents(id) on delete restrict,
 sender_user_id uuid not null references public.profiles(id) on delete restrict,
 sender_acting_org_id uuid not null references public.organizations(id) on delete restrict,
 audience_kind text not null check(audience_kind in ('INCIDENT','ORGANIZATION','UNIT')),
 audience_org_id uuid references public.organizations(id) on delete restrict,
 audience_unit_assignment_id uuid,supersedes_id uuid,
 body text not null check(length(btrim(body))>0 and char_length(body)<=4000 and octet_length(body)<=16000),
 sent_at timestamptz not null default clock_timestamp(),version bigint not null default 1 check(version=1),
 changed_revision bigint not null check(changed_revision>0),operation_id uuid not null unique,
 unique(id,incident_id),
 foreign key(audience_unit_assignment_id,incident_id) references public.incident_units(id,incident_id) on delete restrict,
 foreign key(supersedes_id,incident_id) references public.incident_messages(id,incident_id) on delete restrict,
 check((audience_kind='INCIDENT' and audience_org_id is null and audience_unit_assignment_id is null)
 or (audience_kind='ORGANIZATION' and audience_org_id is not null and audience_unit_assignment_id is null)
 or (audience_kind='UNIT' and audience_org_id is null and audience_unit_assignment_id is not null))
);
create index incident_messages_page on public.incident_messages(incident_id,sent_at desc,id desc);
create unique index incident_message_successor on public.incident_messages(supersedes_id) where supersedes_id is not null;
alter table public.incident_messages enable row level security;
revoke all on public.incident_messages from public,anon,authenticated,service_role;
create trigger incident_messages_immutable before update or delete on public.incident_messages for each row execute function private.audit_immutable();
create trigger incident_messages_no_truncate before truncate on public.incident_messages for each statement execute function private.audit_immutable();

-- Explicit-person helper is private, for M10 recipient evaluation only; public RPCs derive auth.uid().
create function private.message_authority(p_person uuid,p_org uuid,p_incident uuid,p_kind text,p_target_org uuid,p_unit uuid,p_write boolean)
returns boolean language sql volatile security definer set search_path='' as $message_authority$
 select exists(select 1 from public.profiles pr
 join public.user_organizations m on m.user_id=pr.id and m.organization_id=p_org
 join public.organizations o on o.id=m.organization_id and o.active
 join public.incident_participants ip on ip.organization_id=p_org and ip.incident_id=p_incident and ip.status='ACTIVE'
 join public.incidents i on i.id=ip.incident_id and i.status in ('ACTIVE','STABILIZED')
 where pr.id=p_person and pr.account_status='ACTIVE' and (
 (p_kind='INCIDENT' and p_target_org is null and p_unit is null and
 (not p_write or exists(select 1 from public.incident_role_assignments r where r.incident_id=i.id
 and r.organization_id=p_org and r.user_id=p_person and r.role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER')
 and private.incident_assignment_effective(r.id))))
 or (p_kind='ORGANIZATION' and p_unit is null and exists(
 select 1 from public.incident_participants recipient join public.organizations ro on ro.id=recipient.organization_id and ro.active
 where recipient.incident_id=i.id and recipient.organization_id=p_target_org and recipient.status='ACTIVE')
 and (p_target_org=p_org or exists(select 1 from public.incident_role_assignments r
 where r.incident_id=i.id and r.organization_id=p_org and r.user_id=p_person
 and r.role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER') and private.incident_assignment_effective(r.id))))
 or (p_kind='UNIT' and p_target_org is null and exists(
 select 1 from public.incident_units u join public.incident_participants up on up.id=u.participation_id
 and up.incident_id=u.incident_id and up.organization_id=u.organization_id and up.status='ACTIVE'
 join public.organizations uo on uo.id=u.organization_id and uo.active
 where u.id=p_unit and u.incident_id=i.id and u.status not in ('RELEASED','UNAVAILABLE')
 and ((u.organization_id=p_org and exists(select 1 from public.incident_crew_members c
 where c.unit_assignment_id=u.id and c.user_id=p_person and c.membership_organization_id=p_org and c.status='ACTIVE'))
 or exists(select 1 from public.incident_role_assignments r where r.incident_id=i.id
 and r.organization_id=p_org and r.user_id=p_person and private.incident_assignment_effective(r.id)
 and (r.role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER')
 or (r.role='AGENCY_COMMANDER' and u.organization_id=p_org)
 or (r.role='SECTOR_COMMANDER' and r.sector_id=u.sector_id)
 or (r.role='UNIT_LEADER' and r.unit_assignment_id=u.id))))))));
$message_authority$;

create function private.message_scope(p_org uuid,p_incident uuid) returns text
language sql volatile security definer set search_path='' as $message_scope$
 select md5((select l.salt::text from private.incident_sync_limits l where l.id)||
 jsonb_build_array(auth.uid(),p_org,p_incident,
 (select jsonb_agg(jsonb_build_array(r.id,r.role,r.sector_id,r.unit_assignment_id,private.incident_assignment_effective(r.id)) order by r.id)
 from public.incident_role_assignments r where r.incident_id=p_incident and r.user_id=auth.uid() and r.organization_id=p_org and r.status='ACTIVE'),
 (select jsonb_agg(jsonb_build_array(c.id,c.unit_assignment_id,c.status) order by c.id)
 from public.incident_crew_members c where c.incident_id=p_incident and c.user_id=auth.uid() and c.membership_organization_id=p_org and c.status='ACTIVE'),
 (select jsonb_agg(jsonb_build_array(u.id,u.organization_id,u.sector_id,u.status) order by u.id)
 from public.incident_units u where u.incident_id=p_incident),
 (select jsonb_agg(jsonb_build_array(ip.id,ip.organization_id,ip.status,o.active) order by ip.id)
 from public.incident_participants ip join public.organizations o on o.id=ip.organization_id where ip.incident_id=p_incident))::text);
$message_scope$;

create function private.message_dto(p_row public.incident_messages,p_org uuid) returns jsonb
language sql stable security definer set search_path='' as $message_dto$
 select jsonb_build_object('id',p_row.id,'incident_id',p_row.incident_id,'sender_user_id',p_row.sender_user_id,
 'sender_name',(select pr.display_name from public.profiles pr where pr.id=p_row.sender_user_id),
 'audience_kind',p_row.audience_kind,'audience_org_id',p_row.audience_org_id,'audience_unit_assignment_id',p_row.audience_unit_assignment_id,
 'body',p_row.body,'supersedes_id',p_row.supersedes_id,'sent_at',p_row.sent_at,'version',p_row.version::text,
 'revision',p_row.changed_revision::text,'can_correct',p_row.sender_user_id=auth.uid()
 and not exists(select 1 from public.incident_messages child where child.supersedes_id=p_row.id));
$message_dto$;

create function public.incident_message_send(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,
 p_expected_version bigint,p_payload jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $message_send$
declare v_actor uuid:=auth.uid();v_org uuid;v_i public.incidents;v_parent public.incident_messages;
 v_receipt private.incident_operation_receipts;v_request jsonb;v_result jsonb;v_row public.incident_messages;
 v_id uuid;v_parent_id uuid;v_target_org uuid;v_unit uuid;v_kind text;v_body text;v_revision bigint;
begin
 if v_actor is null or not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if p_operation is null or p_incident_id is null or p_acting_organization_id is null
 or jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>24000
 or exists(select 1 from jsonb_object_keys(p_payload) k where k not in
 ('id','body','audience_kind','audience_org_id','audience_unit_assignment_id','supersedes_id','parent_version'))
 then raise exception 'VALIDATION_FAILED';end if;
 if jsonb_typeof(p_payload->'body') is distinct from 'string' then raise exception 'VALIDATION_FAILED';end if;
 v_id:=(p_payload->>'id')::uuid;v_parent_id:=(p_payload->>'supersedes_id')::uuid;
 v_target_org:=(p_payload->>'audience_org_id')::uuid;v_unit:=(p_payload->>'audience_unit_assignment_id')::uuid;
 v_kind:=p_payload->>'audience_kind';
 v_body:=btrim(replace(replace(p_payload->>'body',chr(13)||chr(10),chr(10)),chr(13),chr(10)));
 if v_id is null or regexp_replace(v_body,'[[:space:]]','','g')='' or char_length(v_body)>4000 or
 replace(replace(v_body,chr(10),''),chr(9),'') ~ '[[:cntrl:]]' then raise exception 'VALIDATION_FAILED';end if;
 v_request:=jsonb_build_object('command','MESSAGE_SEND','org',p_acting_organization_id,'incident',p_incident_id,'payload',p_payload||jsonb_build_object('body',v_body));
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 for v_org in select distinct q.org from(select p_acting_organization_id org union all
 select ip.organization_id from public.incident_participants ip where ip.incident_id=p_incident_id) q order by q.org loop
  perform private.lock_organization(v_org);
  perform 1 from public.organizations o where o.id=v_org for share;
 end loop;
 perform 1 from public.profiles pr where pr.id=v_actor for share;
 select * into v_i from public.incidents i where i.id=p_incident_id for update;
 if not found or not private.message_authority(v_actor,p_acting_organization_id,p_incident_id,v_kind,v_target_org,v_unit,true)
 then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into v_receipt from private.incident_operation_receipts r where r.operation_id=p_operation;
 if found then
  if v_receipt.actor_user_id<>v_actor or v_receipt.request is distinct from v_request then raise exception 'OPERATION_REUSED';end if;
  return v_receipt.result;
 end if;
 if v_i.status not in ('ACTIVE','STABILIZED') then raise exception 'INCIDENT_TERMINAL';end if;
 if v_parent_id is not null then
  select * into v_parent from public.incident_messages m where m.id=v_parent_id and m.incident_id=p_incident_id for update;
  if not found or v_parent.sender_user_id<>v_actor or v_parent.audience_kind is distinct from v_kind
   or v_parent.audience_org_id is distinct from v_target_org or v_parent.audience_unit_assignment_id is distinct from v_unit
  then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  if (p_payload->>'parent_version')::bigint is distinct from v_parent.version
   or exists(select 1 from public.incident_messages m where m.supersedes_id=v_parent_id)
  then raise exception 'STALE_VERSION';end if;
 end if;
 -- Independent append: no task/core version semantics are changed.
 update public.incidents i set revision=i.revision+1,updated_at=clock_timestamp()
 where i.id=p_incident_id returning i.revision into v_revision;
 insert into public.incident_messages(id,incident_id,sender_user_id,sender_acting_org_id,audience_kind,audience_org_id,
 audience_unit_assignment_id,body,supersedes_id,changed_revision,operation_id)
 values(v_id,p_incident_id,v_actor,p_acting_organization_id,v_kind,v_target_org,v_unit,v_body,v_parent_id,v_revision,p_operation)
 returning * into v_row;
 -- No shared timeline event: B1's deferred fallback emits a safe scope reset,
 -- and B2's revision-aware producer emits only incident counters.
 v_result:=jsonb_build_object('operation_id',p_operation,'incident_id',p_incident_id,'message_id',v_id,
 'revision',v_revision::text,'timeline_sequence',v_i.timeline_sequence::text,'message',private.message_dto(v_row,p_acting_organization_id));
 perform private.write_audit(p_acting_organization_id,v_actor,'INCIDENT_MESSAGE_SENT','incident_messages',v_id,null,
 jsonb_build_object('operation_id',p_operation,'incident_id',p_incident_id,'supersedes_id',v_parent_id));
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,v_actor,p_acting_organization_id,p_incident_id,'MESSAGE_SEND',v_request,v_result);
 return v_result;
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation
 then raise exception 'VALIDATION_FAILED';
 when unique_violation then raise exception 'OPERATION_REUSED';
end;
$message_send$;

create function public.incident_message_page(p_acting_organization_id uuid,p_incident_id uuid,
 p_before_sent_at timestamptz default null,p_before_id uuid default null,p_limit integer default 30,
 p_expected_revision bigint default null,p_scope_fingerprint text default null) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $message_page$
declare v_i public.incidents;v_rows jsonb;v_scope text;v_targets jsonb;v_count integer;
begin
 if p_limit is null or p_limit not between 1 and 50 or (p_before_sent_at is null)<>(p_before_id is null)
 then raise exception 'VALIDATION_FAILED';end if;
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 if not private.message_authority(auth.uid(),p_acting_organization_id,p_incident_id,'INCIDENT',null,null,false)
 then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into v_i from public.incidents i where i.id=p_incident_id;
 v_scope:=private.message_scope(p_acting_organization_id,p_incident_id);
 if p_scope_fingerprint is not null and p_scope_fingerprint<>v_scope then raise exception 'SCOPE_CHANGED';end if;
 if p_expected_revision is not null and p_expected_revision<>v_i.revision then raise exception 'STALE_VERSION';end if;
 select coalesce(jsonb_agg(q.dto order by q.sent_at desc,q.id desc),'[]') into v_rows from(
 select m.id,m.sent_at,private.message_dto(m,p_acting_organization_id) dto from public.incident_messages m
 where m.incident_id=p_incident_id and private.message_authority(auth.uid(),p_acting_organization_id,m.incident_id,
 m.audience_kind,m.audience_org_id,m.audience_unit_assignment_id,false)
 and not exists(select 1 from public.incident_messages child where child.supersedes_id=m.id)
 and (p_before_sent_at is null or (m.sent_at,m.id)<(p_before_sent_at,p_before_id))
 order by m.sent_at desc,m.id desc limit p_limit+1) q;
 v_count:=jsonb_array_length(v_rows);
 if v_count>p_limit then v_rows:=v_rows-p_limit;end if;
 select coalesce(jsonb_agg(q.dto order by q.kind,q.id),'[]') into v_targets from(
 select 'INCIDENT' kind,p_incident_id id,jsonb_build_object('kind','INCIDENT','id',p_incident_id,'label',v_i.title) dto
 where private.message_authority(auth.uid(),p_acting_organization_id,p_incident_id,'INCIDENT',null,null,true)
 union all
 select 'ORGANIZATION',o.id,jsonb_build_object('kind','ORGANIZATION','id',o.id,'label',o.name)
 from public.incident_participants ip join public.organizations o on o.id=ip.organization_id and o.active
 where ip.incident_id=p_incident_id and ip.status='ACTIVE'
 and private.message_authority(auth.uid(),p_acting_organization_id,p_incident_id,'ORGANIZATION',o.id,null,true)
 union all
 select 'UNIT',u.id,jsonb_build_object('kind','UNIT','id',u.id,'label',ou.callsign||' · '||ou.name)
 from public.incident_units u join public.operational_units ou on ou.id=u.unit_id
 where u.incident_id=p_incident_id and private.message_authority(auth.uid(),p_acting_organization_id,p_incident_id,'UNIT',null,u.id,true)
 ) q;
 if jsonb_array_length(v_targets)>100 then raise exception 'MESSAGE_SCOPE_LIMIT';end if;
 return jsonb_build_object('schema_version',1,'account',auth.uid(),'organization',p_acting_organization_id,
 'incident_id',p_incident_id,'revision',v_i.revision::text,'scope_fingerprint',v_scope,'messages',v_rows,'targets',v_targets,
 'has_more',v_count>p_limit,'next_sent_at',case when v_count>p_limit then v_rows->-1->>'sent_at' end,
 'next_id',case when v_count>p_limit then v_rows->-1->>'id' end);
end;
$message_page$;

create function public.incident_message_history(p_acting_organization_id uuid,p_incident_id uuid,p_message_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $message_history$
declare v_row public.incident_messages;v_result jsonb:='[]';v_n integer:=0;
begin
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 select * into v_row from public.incident_messages m where m.id=p_message_id and m.incident_id=p_incident_id;
 if not found or not private.message_authority(auth.uid(),p_acting_organization_id,p_incident_id,
 v_row.audience_kind,v_row.audience_org_id,v_row.audience_unit_assignment_id,false)
 then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 loop
  if not private.message_authority(auth.uid(),p_acting_organization_id,p_incident_id,
  v_row.audience_kind,v_row.audience_org_id,v_row.audience_unit_assignment_id,false)
  then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  v_result:=v_result||jsonb_build_array(private.message_dto(v_row,p_acting_organization_id));v_n:=v_n+1;
  exit when v_row.supersedes_id is null or v_n>=20;
  select * into v_row from public.incident_messages m where m.id=v_row.supersedes_id and m.incident_id=p_incident_id;
  if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 end loop;
 return jsonb_build_object('schema_version',1,'account',auth.uid(),'organization',p_acting_organization_id,
 'incident_id',p_incident_id,'messages',v_result,'next_id',case when v_n>=20 then v_row.supersedes_id end);
end;
$message_history$;

-- Reuse M10; only internal message UUIDs are carried in its private audience reference array.
insert into private.notification_categories(code,default_enabled) values('INCIDENT_MESSAGE',true);
create function private.capture_incident_message_notification() returns trigger
language plpgsql security definer set search_path='' as $capture_message_notification$
declare v_org record;
begin
 for v_org in select ip.organization_id from public.incident_participants ip
 join public.organizations o on o.id=ip.organization_id and o.active
 where ip.incident_id=new.incident_id and ip.status='ACTIVE'
 and (new.audience_kind='INCIDENT' or (new.audience_kind='ORGANIZATION' and ip.organization_id=new.audience_org_id)
 or (new.audience_kind='UNIT' and ip.organization_id=(select u.organization_id from public.incident_units u where u.id=new.audience_unit_assignment_id)))
 order by ip.organization_id limit 50 loop
  insert into private.notification_events(organization_id,type,category,entity_type,entity_id,teams,source_key)
  values(v_org.organization_id,'INCIDENT_MESSAGE_CHANGED','INCIDENT_MESSAGE','INCIDENT',new.incident_id,
  array[new.id],new.incident_id::text||'/'||new.id::text||'/'||v_org.organization_id::text)
  on conflict(type,source_key) do nothing;
 end loop;
 return new;
end;
$capture_message_notification$;
create trigger incident_message_notification after insert on public.incident_messages
 for each row execute function private.capture_incident_message_notification();
alter function private.notification_recipient(private.notification_events,uuid) rename to notification_recipient_before_messages;
create function private.notification_recipient(e private.notification_events,person uuid) returns boolean
language sql volatile security definer set search_path='' as $message_notification_recipient$
 select case when e.category<>'INCIDENT_MESSAGE' then private.notification_recipient_before_messages(e,person)
 else e.entity_type='INCIDENT'
 and coalesce((select np.enabled from private.notification_preferences np where np.user_id=person and np.category=e.category),true)
 and exists(select 1 from unnest(e.teams) ref(id) join public.incident_messages msg on msg.id=ref.id
 where msg.incident_id=e.entity_id and msg.sender_user_id<>person and private.message_authority(person,e.organization_id,
 msg.incident_id,msg.audience_kind,msg.audience_org_id,msg.audience_unit_assignment_id,false)) end;
$message_notification_recipient$;
revoke all on function private.message_authority(uuid,uuid,uuid,text,uuid,uuid,boolean),
 private.message_scope(uuid,uuid),private.message_dto(public.incident_messages,uuid),
 private.capture_incident_message_notification(),private.notification_recipient(private.notification_events,uuid),
 private.notification_recipient_before_messages(private.notification_events,uuid)
 from public,anon,authenticated,service_role;
revoke all on function public.incident_message_send(uuid,uuid,uuid,bigint,jsonb),
 public.incident_message_page(uuid,uuid,timestamptz,uuid,integer,bigint,text),
 public.incident_message_history(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.incident_message_send(uuid,uuid,uuid,bigint,jsonb),
 public.incident_message_page(uuid,uuid,timestamptz,uuid,integer,bigint,text),
 public.incident_message_history(uuid,uuid,uuid) to authenticated;
