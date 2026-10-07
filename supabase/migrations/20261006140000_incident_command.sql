-- M14.2: generalize the existing consent lifecycle, not a second request system.
alter table private.incident_command_consents
 add column kind text not null default 'INITIAL' check(kind in ('INITIAL','ROLE','TRANSFER','RECOVERY')),
 add column offered_role text check(offered_role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER','AGENCY_COMMANDER')),
 add column parent_assignment_id uuid,
 add column outgoing_assignment_id uuid,
 add column outgoing_version bigint,
 add column reason text check(length(reason)<=2000),
 add column operation_id uuid unique,
 add column transfer_lead boolean not null default false,
 add column lead_consented_by uuid references public.profiles(id),
 add column lead_consented_at timestamptz,
 add column decided_by uuid references public.profiles(id),
 add constraint incident_consent_parent_fk foreign key(parent_assignment_id,incident_id) references public.incident_role_assignments(id,incident_id),
 add constraint incident_consent_outgoing_fk foreign key(outgoing_assignment_id,incident_id) references public.incident_role_assignments(id,incident_id),
 add constraint incident_consent_lead_pair check((lead_consented_by is null)=(lead_consented_at is null)),
 add constraint incident_consent_role_kind check(kind='INITIAL' or (offered_role is not null and operation_id is not null)),
 add constraint incident_consent_transfer_kind check(not transfer_lead or kind='TRANSFER');
alter table private.incident_command_consents drop constraint incident_command_consents_status_check;
alter table private.incident_command_consents add constraint incident_command_consents_status_check
 check(status in ('REQUESTED','ACCEPTED','WITHDRAWN','CONSUMED','DECLINED','CANCELLED','EXPIRED'));
drop index private.incident_consent_current_unique;
create unique index incident_consent_current_unique on private.incident_command_consents(incident_id)
 where kind='INITIAL' and status in ('REQUESTED','ACCEPTED');
create unique index incident_transfer_live_unique on private.incident_command_consents(incident_id)
 where kind in ('TRANSFER','RECOVERY') and status='REQUESTED';
create unique index incident_role_offer_unique on private.incident_command_consents(incident_id,organization_id,user_id,offered_role)
 where kind='ROLE' and status='REQUESTED';
create index incident_command_request_history_idx on private.incident_command_consents(incident_id,created_at desc,id desc) where kind<>'INITIAL';
create index incident_command_role_history_idx on public.incident_role_assignments(incident_id,created_at desc,id desc);

-- Independent of auth.uid: private predicate for validating a named assignment,
-- not an exposed arbitrary-user authorization API. Parentage grants nothing.
create function private.incident_assignment_effective(p_assignment uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select exists(select 1 from public.incident_role_assignments a
 join public.incidents i on i.id=a.incident_id and i.status in ('ACTIVE','STABILIZED')
 join public.incident_participants ip on ip.id=a.participation_id and ip.status='ACTIVE'
 join public.organizations o on o.id=a.organization_id and o.active
 join public.profiles pr on pr.id=a.user_id and pr.account_status='ACTIVE'
 join public.user_organizations m on m.user_id=a.user_id and m.organization_id=a.organization_id
 where a.id=p_assignment and a.status='ACTIVE' and a.valid_from<=clock_timestamp()
 and (a.valid_until is null or a.valid_until>clock_timestamp())
 and (a.role<>'INCIDENT_COMMANDER' or a.organization_id=i.lead_organization_id));
$$;
revoke all on function private.incident_assignment_effective(uuid) from public,anon,authenticated,service_role;
create or replace function private.has_incident_capability(p_incident_id uuid,p_acting_organization_id uuid,p_capability text)
returns boolean language sql volatile security definer set search_path='' as $$
 select private.can_read_incident(p_incident_id) and private.incident_acting_member(p_acting_organization_id) and exists(
 select 1 from public.incident_role_assignments a where a.incident_id=p_incident_id and a.organization_id=p_acting_organization_id
 and a.user_id=auth.uid() and private.incident_assignment_effective(a.id) and (
 (a.role='INCIDENT_COMMANDER' and p_capability in ('EDIT_SUMMARY','INVITE_ORGANIZATION','ASSIGN_INCIDENT_ROLE','END_INCIDENT_ROLE','CHANGE_LIFECYCLE','TRANSFER_COMMAND','TRANSFER_LEAD','RELEASE_PARTICIPANT'))
 or (a.role='DEPUTY_COMMANDER' and p_capability in ('EDIT_SUMMARY','INVITE_ORGANIZATION'))));
$$;
revoke all on function private.has_incident_capability(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function private.has_incident_capability(uuid,uuid,text) to authenticated;

-- Scope/identity immutability and acyclicity apply at the storage boundary.
create function private.guard_incident_command_role() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_parent public.incident_role_assignments;
begin
 perform 1 from public.incidents i where i.id=new.incident_id for update;
 if tg_op='UPDATE' then
  if (new.id,new.incident_id,new.participation_id,new.organization_id,new.user_id,new.role,new.parent_assignment_id,new.valid_from,new.assigned_by)
   is distinct from (old.id,old.incident_id,old.participation_id,old.organization_id,old.user_id,old.role,old.parent_assignment_id,old.valid_from,old.assigned_by)
   or old.status<>'ACTIVE' or new.status not in ('ENDED','REVOKED') then raise exception 'INVALID_COMMAND_HIERARCHY'; end if;
  return new;
 end if;
 if new.role='INCIDENT_COMMANDER' then
  if new.parent_assignment_id is not null then raise exception 'INVALID_COMMAND_HIERARCHY'; end if;
 else
  select * into v_parent from public.incident_role_assignments a where a.id=new.parent_assignment_id and a.incident_id=new.incident_id and a.status='ACTIVE';
  if not found or (new.role in ('DEPUTY_COMMANDER','AGENCY_COMMANDER') and v_parent.role<>'INCIDENT_COMMANDER')
   or (new.role in ('OPERATOR','RESPONDER') and not(v_parent.role='INCIDENT_COMMANDER' or
    (v_parent.role='AGENCY_COMMANDER' and v_parent.organization_id=new.organization_id))) then raise exception 'INVALID_COMMAND_HIERARCHY'; end if;
  if exists(with recursive ancestors as (
   select a.id,a.parent_assignment_id,array[a.id] path,false cycle from public.incident_role_assignments a where a.id=new.parent_assignment_id
   union all select a.id,a.parent_assignment_id,c.path||a.id,a.id=any(c.path) from ancestors c
    join public.incident_role_assignments a on a.id=c.parent_assignment_id where not c.cycle
  ) select 1 from ancestors c where c.id=new.id or c.cycle) then raise exception 'INVALID_COMMAND_HIERARCHY'; end if;
 end if;
 return new;
end; $$;
revoke all on function private.guard_incident_command_role() from public,anon,authenticated,service_role;
create trigger incident_command_role_guard before insert or update on public.incident_role_assignments for each row execute function private.guard_incident_command_role();

create function private.incident_command_structure(p_action text,p_operation uuid,p_org uuid,p_incident uuid,p_expected bigint,p_payload jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
 v_actor uuid:=auth.uid(); v_org uuid; v_user uuid; v_now timestamptz; v_i public.incidents;
 v_request jsonb; v_saved private.incident_operation_receipts; v_c private.incident_command_consents;
 v_ic public.incident_role_assignments; v_role public.incident_role_assignments; v_child record;
 v_target_user uuid; v_target_org uuid; v_parent uuid; v_role_name text; v_part uuid; v_id uuid;
 v_new_ic uuid; v_map jsonb:='{}'; v_reason text:=btrim(coalesce(p_payload->>'reason',''));
 v_code text; v_data jsonb:='{}'; v_result jsonb; v_cross boolean:=false; v_manager boolean;
 v_allowed text[]; v_request_id uuid; v_old_lead uuid;
begin
 if v_actor is null or not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_operation is null or p_incident is null or p_org is null or jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>8192 then raise exception 'VALIDATION_FAILED'; end if;
 v_allowed:=case when p_action in ('OFFER','TRANSFER','RECOVERY') then array['user_id','organization_id','role','parent_assignment_id','mode','reason']
  when p_action='END' then array['assignment_id','reason'] else array['request_id','reason'] end;
 if exists(select 1 from jsonb_each(p_payload) f where not(f.key=any(v_allowed)) or jsonb_typeof(f.value) not in ('string','null')) then raise exception 'VALIDATION_FAILED'; end if;
 if length(v_reason)>2000 then raise exception 'VALIDATION_FAILED'; end if;
 v_target_user:=(p_payload->>'user_id')::uuid; v_target_org:=(p_payload->>'organization_id')::uuid;
 v_request_id:=(p_payload->>'request_id')::uuid;
 v_request:=jsonb_build_object('command','COMMAND_'||p_action,'org',p_org,'incident',p_incident,'expected',p_expected,'payload',p_payload);
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 for v_org in select distinct q.org from(select p_org org union all select v_target_org union all
  select ip.organization_id from public.incident_participants ip where ip.incident_id=p_incident) q where q.org is not null order by q.org loop
  perform private.lock_organization(v_org); perform 1 from public.organizations o where o.id=v_org for share;
 end loop;
 for v_user in select distinct q.uid from(select v_actor uid union all select v_target_user union all
  select c.user_id from private.incident_command_consents c where c.incident_id=p_incident and c.status='REQUESTED' union all
  select c.nominated_by from private.incident_command_consents c where c.incident_id=p_incident and c.status='REQUESTED' union all
  select c.lead_consented_by from private.incident_command_consents c where c.incident_id=p_incident and c.status='REQUESTED' union all
  select a.user_id from public.incident_role_assignments a where a.incident_id=p_incident and a.status='ACTIVE') q
  where q.uid is not null order by q.uid loop perform 1 from public.profiles pr where pr.id=v_user for share; end loop;
 if not private.incident_acting_member(p_org) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into v_saved from private.incident_operation_receipts r where r.operation_id=p_operation;
 if found then
  if v_saved.actor_user_id<>v_actor or v_saved.request is distinct from v_request then raise exception 'OPERATION_REUSED'; end if;
  return v_saved.result;
 end if;
 select * into v_i from public.incidents i where i.id=p_incident for update;
 if not found or public.incident_context(p_incident,p_org) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if v_i.status not in ('ACTIVE','STABILIZED') then raise exception 'INCIDENT_TERMINAL'; end if;
 if v_i.version is distinct from p_expected then raise exception 'STALE_VERSION'; end if;
 v_now:=clock_timestamp(); v_old_lead:=v_i.lead_organization_id;
 select * into v_ic from public.incident_role_assignments a where a.incident_id=p_incident and a.role='INCIDENT_COMMANDER' and a.status='ACTIVE';
 v_manager:=p_org=v_i.lead_organization_id and private.has_organization_role(p_org,array['MANAGER','ADMIN']);
 if v_request_id is not null then
  select * into v_c from private.incident_command_consents c where c.id=v_request_id and c.incident_id=p_incident and c.kind<>'INITIAL' for update;
  if not found then raise exception 'TRANSFER_NOT_CURRENT'; end if;
  if v_c.status<>'REQUESTED' then raise exception 'TRANSFER_NOT_CURRENT'; end if;
  if v_c.expires_at<=v_now then raise exception 'TRANSFER_EXPIRED'; end if;
 end if;

 if p_action in ('OFFER','TRANSFER','RECOVERY') then
  if p_action='RECOVERY' then
   if not v_manager then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if private.incident_assignment_effective(v_ic.id) then raise exception 'COMMANDER_STILL_VALID'; end if;
   if v_target_org is distinct from v_i.lead_organization_id or length(v_reason)=0 then raise exception 'INVALID_COMMAND_CANDIDATE'; end if;
  else
   if not private.has_incident_capability(p_incident,p_org,case when p_action='OFFER' then 'ASSIGN_INCIDENT_ROLE' else 'TRANSFER_COMMAND' end)
    then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  end if;
  if not exists(select 1 from public.user_organizations m join public.profiles pr on pr.id=m.user_id and pr.account_status='ACTIVE'
   join public.organizations o on o.id=m.organization_id and o.active
   join public.incident_participants ip on ip.organization_id=o.id and ip.incident_id=p_incident and ip.status='ACTIVE'
   where m.user_id=v_target_user and m.organization_id=v_target_org) then raise exception 'INVALID_COMMAND_CANDIDATE'; end if;
  if p_action='OFFER' then
   if not private.incident_assignment_effective(v_ic.id) then raise exception 'INVALID_COMMANDER'; end if;
   v_role_name:=p_payload->>'role'; v_parent:=(p_payload->>'parent_assignment_id')::uuid;
   if v_role_name is null or v_role_name not in ('DEPUTY_COMMANDER','AGENCY_COMMANDER') then raise exception 'INVALID_COMMAND_ROLE'; end if;
   if v_parent is distinct from v_ic.id or not private.incident_assignment_effective(v_parent) then raise exception 'INVALID_COMMAND_HIERARCHY'; end if;
   if exists(select 1 from public.incident_role_assignments a where a.incident_id=p_incident and a.status='ACTIVE' and a.role=v_role_name
    and a.organization_id=v_target_org and (v_role_name='AGENCY_COMMANDER' or a.user_id=v_target_user)) then raise exception 'INVALID_COMMAND_ROLE'; end if;
  else
   v_role_name:='INCIDENT_COMMANDER'; v_parent:=null;
   if p_action='TRANSFER' and v_target_user=v_ic.user_id and v_target_org=v_ic.organization_id then raise exception 'INVALID_COMMAND_CANDIDATE'; end if;
   v_cross:=v_target_org<>v_i.lead_organization_id;
   if p_action='TRANSFER' and coalesce(p_payload->>'mode','')<>(case when v_cross then 'LEAD_AND_COMMAND' else 'COMMAND' end) then raise exception 'LEAD_TRANSFER_REQUIRES_CONSENT'; end if;
  end if;
  -- Expiry is a terminal historical state; reads also derive EXPIRED before a
  -- new request causes this lazy materialization. No scheduler required.
  update private.incident_command_consents c set status='EXPIRED',ended_at=v_now where c.incident_id=p_incident and c.kind<>'INITIAL' and c.status='REQUESTED' and c.expires_at<=v_now;
  if p_action in ('TRANSFER','RECOVERY') and exists(select 1 from private.incident_command_consents c where c.incident_id=p_incident and c.kind in ('TRANSFER','RECOVERY') and c.status='REQUESTED')
   then raise exception 'TRANSFER_ALREADY_PENDING'; end if;
  insert into private.incident_command_consents(incident_id,user_id,organization_id,nominated_by,expires_at,status,kind,offered_role,parent_assignment_id,
   outgoing_assignment_id,outgoing_version,reason,operation_id,transfer_lead)
   values(p_incident,v_target_user,v_target_org,v_actor,v_now+interval '24 hours','REQUESTED',case when p_action='OFFER' then 'ROLE' else p_action end,
    v_role_name,v_parent,v_ic.id,v_ic.version,nullif(v_reason,''),p_operation,v_cross) returning id into v_request_id;
  v_code:=case p_action when 'OFFER' then 'COMMAND_ROLE_OFFERED' when 'TRANSFER' then 'COMMAND_TRANSFER_REQUESTED' else 'COMMAND_RECOVERY_REQUESTED' end;
  v_data:=jsonb_build_object('request_id',v_request_id,'user_id',v_target_user,'organization_id',v_target_org,'role',v_role_name,'transfer_lead',v_cross,'reason',nullif(v_reason,''));
 elsif p_action in ('ACCEPT','DECLINE','CANCEL','LEAD_CONSENT') then
  if v_request_id is null then raise exception 'TRANSFER_NOT_CURRENT'; end if;
  if p_action='LEAD_CONSENT' then
   if not v_c.transfer_lead or p_org<>v_c.organization_id or not private.has_organization_role(p_org,array['MANAGER','ADMIN']) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if v_c.outgoing_assignment_id is distinct from v_ic.id or not private.incident_assignment_effective(v_ic.id) then raise exception 'TRANSFER_NOT_CURRENT'; end if;
   update private.incident_command_consents c set lead_consented_by=v_actor,lead_consented_at=v_now where c.id=v_c.id;
   v_code:='LEAD_TRANSFER_CONSENTED';
  elsif p_action='DECLINE' then
   if v_c.user_id<>v_actor or v_c.organization_id<>p_org then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   update private.incident_command_consents c set status='DECLINED',ended_at=v_now,decided_by=v_actor where c.id=v_c.id;
   v_code:=case when v_c.kind='TRANSFER' then 'COMMAND_TRANSFER_DECLINED' else 'COMMAND_OFFER_DECLINED' end;
  elsif p_action='CANCEL' then
   if not (private.has_incident_capability(p_incident,p_org,'TRANSFER_COMMAND')
    or (v_c.kind in ('TRANSFER','RECOVERY') and v_manager and not private.incident_assignment_effective(v_ic.id))) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if not private.incident_assignment_effective(v_ic.id) and length(v_reason)=0 then raise exception 'VALIDATION_FAILED'; end if;
   update private.incident_command_consents c set status='CANCELLED',ended_at=v_now,decided_by=v_actor where c.id=v_c.id;
   v_code:='COMMAND_REQUEST_CANCELLED';
  else
   if v_c.user_id<>v_actor or v_c.organization_id<>p_org then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   select ip.id into v_part from public.incident_participants ip where ip.incident_id=p_incident and ip.organization_id=p_org and ip.status='ACTIVE';
   if v_part is null then raise exception 'INVALID_PARTICIPANT'; end if;
   if v_c.kind='RECOVERY' then
    if private.incident_assignment_effective(v_ic.id) then raise exception 'COMMANDER_STILL_VALID'; end if;
    if p_org<>v_i.lead_organization_id or not exists(select 1 from public.user_organizations m join public.profiles pr on pr.id=m.user_id and pr.account_status='ACTIVE'
     where m.user_id=v_c.nominated_by and m.organization_id=v_i.lead_organization_id and m.role in ('MANAGER','ADMIN')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
    if v_c.outgoing_assignment_id is distinct from v_ic.id then raise exception 'TRANSFER_NOT_CURRENT'; end if;
   else
    if v_c.outgoing_assignment_id is distinct from v_ic.id or v_c.outgoing_version is distinct from v_ic.version
     or not private.incident_assignment_effective(v_ic.id) or v_c.nominated_by<>v_ic.user_id then raise exception 'TRANSFER_NOT_CURRENT'; end if;
   end if;
   if v_c.kind='ROLE' then
    if v_c.parent_assignment_id is distinct from v_ic.id then raise exception 'INVALID_COMMAND_HIERARCHY'; end if;
    insert into public.incident_role_assignments(incident_id,participation_id,organization_id,user_id,role,parent_assignment_id,assigned_by,valid_from)
     values(p_incident,v_part,p_org,v_actor,v_c.offered_role,v_c.parent_assignment_id,v_c.nominated_by,v_now) returning id into v_id;
    v_code:='COMMAND_ASSIGNED';
   elsif v_c.kind in ('TRANSFER','RECOVERY') then
    if v_c.transfer_lead then
     if v_c.lead_consented_by is null or not exists(select 1 from public.user_organizations m join public.profiles pr on pr.id=m.user_id and pr.account_status='ACTIVE'
      where m.user_id=v_c.lead_consented_by and m.organization_id=p_org and m.role in ('MANAGER','ADMIN')) then raise exception 'LEAD_TRANSFER_REQUIRES_CONSENT'; end if;
    elsif p_org<>v_i.lead_organization_id then raise exception 'LEAD_TRANSFER_REQUIRES_CONSENT'; end if;
    if v_ic.id is not null then
     update public.incident_role_assignments a set status='ENDED',valid_until=least(a.valid_until,v_now),ended_by=v_actor,ended_at=v_now,end_reason=coalesce(v_c.reason,'COMMAND_TRANSFER'),version=a.version+1,updated_at=v_now where a.id=v_ic.id;
    end if;
    if v_c.transfer_lead then
     update public.incident_participants ip set agency_role='SUPPORT',version=ip.version+1,updated_at=v_now where ip.incident_id=p_incident and ip.status='ACTIVE' and ip.agency_role='LEAD';
     update public.incident_participants ip set agency_role='LEAD',version=ip.version+1,updated_at=v_now where ip.id=v_part;
     update public.incidents i set lead_organization_id=p_org where i.id=p_incident;
    end if;
    insert into public.incident_role_assignments(incident_id,participation_id,organization_id,user_id,role,assigned_by,valid_from)
     values(p_incident,v_part,p_org,v_actor,'INCIDENT_COMMANDER',v_actor,v_now) returning id into v_new_ic;
    if v_ic.id is not null then v_map:=jsonb_build_object(v_ic.id::text,v_new_ic); end if;
    -- Parent identity is immutable. End/recreate subordinate episodes in parent
    -- order rather than rewriting old history to point at the new commander.
    for v_child in with recursive tree as (
     select a.*,1 depth,array[a.id] path from public.incident_role_assignments a where a.incident_id=p_incident and a.status='ACTIVE' and a.parent_assignment_id=v_ic.id
     union all select a.*,t.depth+1,t.path||a.id from tree t join public.incident_role_assignments a on a.parent_assignment_id=t.id
      where a.status='ACTIVE' and not(a.id=any(t.path))
    ) select * from tree order by depth,id loop
     update public.incident_role_assignments a set status='ENDED',valid_until=least(a.valid_until,v_now),ended_by=v_actor,ended_at=v_now,end_reason='COMMAND_HIERARCHY_REBASED',version=a.version+1,updated_at=v_now where a.id=v_child.id;
     if (v_child.valid_until is null or v_child.valid_until>v_now) and v_map ? v_child.parent_assignment_id::text then
      insert into public.incident_role_assignments(incident_id,participation_id,organization_id,user_id,role,parent_assignment_id,assigned_by,valid_from,valid_until)
       values(p_incident,v_child.participation_id,v_child.organization_id,v_child.user_id,v_child.role,(v_map->>v_child.parent_assignment_id::text)::uuid,v_actor,v_now,v_child.valid_until) returning id into v_id;
      v_map:=v_map||jsonb_build_object(v_child.id::text,v_id);
     end if;
    end loop;
    -- Offers bind to the old commander; they cannot survive as new authority.
    update private.incident_command_consents c set status='CANCELLED',ended_at=v_now,decided_by=v_actor where c.incident_id=p_incident and c.kind='ROLE' and c.status='REQUESTED';
    v_code:=case when v_c.kind='RECOVERY' then 'COMMAND_RECOVERY_ASSIGNED' else 'COMMAND_TRANSFERRED' end;
    v_id:=v_new_ic;
    v_data:=jsonb_build_object('from_assignment_id',v_ic.id,'to_assignment_id',v_new_ic,'from_user_id',v_ic.user_id,'user_id',v_actor,
     'from_organization_id',v_old_lead,'organization_id',p_org,'assignment_successors',v_map,'reason',v_c.reason);
   else raise exception 'TRANSFER_NOT_CURRENT'; end if;
   update private.incident_command_consents c set status='CONSUMED',accepted_at=v_now,ended_at=v_now,decided_by=v_actor where c.id=v_c.id;
  end if;
  v_data:=v_data||jsonb_build_object('request_id',v_c.id,'decision_reason',nullif(v_reason,''),'user_id',v_c.user_id,'organization_id',v_c.organization_id,'role',v_c.offered_role);
 elsif p_action='END' then
  select * into v_role from public.incident_role_assignments a where a.id=(p_payload->>'assignment_id')::uuid and a.incident_id=p_incident and a.status='ACTIVE' for update;
  if not found or v_role.role='INCIDENT_COMMANDER' then raise exception 'INVALID_COMMAND_ROLE'; end if;
  if not private.has_incident_capability(p_incident,p_org,'END_INCIDENT_ROLE') then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if length(v_reason)=0 then raise exception 'VALIDATION_FAILED'; end if;
  if exists(select 1 from public.incident_role_assignments a where a.parent_assignment_id=v_role.id and a.status='ACTIVE') then raise exception 'INVALID_COMMAND_HIERARCHY'; end if;
  update public.incident_role_assignments a set status='ENDED',valid_until=least(a.valid_until,v_now),ended_by=v_actor,ended_at=v_now,end_reason=v_reason,version=a.version+1,updated_at=v_now where a.id=v_role.id;
  v_id:=v_role.id; v_code:='COMMAND_ENDED'; v_data:=jsonb_build_object('reason',v_reason);
 else raise exception 'VALIDATION_FAILED'; end if;
 update public.incidents i set version=i.version+1 where i.id=p_incident;
 perform private.append_incident_event(p_incident,p_org,p_operation,1::smallint,v_code,v_data,null,v_id);
 if p_action='ACCEPT' and v_c.transfer_lead then
  perform private.append_incident_event(p_incident,p_org,p_operation,2::smallint,'LEAD_ORGANIZATION_CHANGED',jsonb_build_object('from_organization_id',v_old_lead,'organization_id',p_org,'request_id',v_c.id),null,null);
 end if;
 select jsonb_build_object('incident_id',i.id,'operation_id',p_operation,'version',i.version::text,'revision',i.revision::text,'timeline_sequence',i.timeline_sequence::text) into v_result from public.incidents i where i.id=p_incident;
 perform private.write_audit(p_org,v_actor,v_code,'incidents',p_incident,null,jsonb_build_object('request',p_payload,'event',v_data,'result',v_result));
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,v_actor,p_org,p_incident,'COMMAND_'||p_action,v_request,v_result);
 return v_result;
exception when invalid_text_representation or check_violation or not_null_violation or foreign_key_violation then raise exception 'VALIDATION_FAILED';
 when unique_violation then raise exception 'INVALID_COMMAND_ROLE';
end; $$;
revoke all on function private.incident_command_structure(text,uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;

-- Closure finalizes every live subordinate and pending offer/request in the same
-- existing lifecycle transaction. Terminal records remain append-only history.
create function private.finish_incident_command(p_incident uuid,p_actor uuid,p_now timestamptz,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_ids jsonb;
begin
 with ended as (update public.incident_role_assignments a set status='ENDED',valid_until=least(a.valid_until,p_now),ended_by=p_actor,ended_at=p_now,
 end_reason=p_reason,updated_at=p_now,version=a.version+1 where a.incident_id=p_incident and a.status='ACTIVE' returning a.id)
 select coalesce(jsonb_agg(e.id),'[]') into v_ids from ended e;
 update private.incident_command_consents c set status='CANCELLED',ended_at=p_now,decided_by=p_actor where c.incident_id=p_incident and c.kind<>'INITIAL' and c.status in ('REQUESTED','ACCEPTED');
 return v_ids;
end; $$;
revoke all on function private.finish_incident_command(uuid,uuid,timestamptz,text) from public,anon,authenticated,service_role;
create or replace function private.append_incident_event(p_incident uuid,p_org uuid,p_operation uuid,p_ordinal smallint,
 p_code text,p_data jsonb,p_participation uuid default null,p_assignment uuid default null) returns void
language plpgsql volatile security definer set search_path='' as $$
declare v_revision bigint; v_sequence bigint;
begin
 if p_code not in ('INCIDENT_CREATED','PARTICIPANT_JOINED','INCIDENT_DETAILS_UPDATED','COMMAND_NOMINATED',
 'COMMAND_ACCEPTED','COMMAND_ENDED','COMMAND_ASSIGNED','PARTICIPANT_REQUESTED','PARTICIPANT_DECLINED',
 'PARTICIPANT_RELEASE_REQUESTED','PARTICIPANT_RELEASED','INCIDENT_ACTIVATED','INCIDENT_STABILIZED',
 'INCIDENT_REACTIVATED','INCIDENT_CLOSED','INCIDENT_CANCELLED','COMMAND_ROLE_OFFERED','COMMAND_TRANSFER_REQUESTED',
 'COMMAND_TRANSFERRED','COMMAND_TRANSFER_DECLINED','COMMAND_OFFER_DECLINED','COMMAND_REQUEST_CANCELLED','LEAD_TRANSFER_CONSENTED',
 'LEAD_ORGANIZATION_CHANGED','COMMAND_RECOVERY_REQUESTED','COMMAND_RECOVERY_ASSIGNED') or auth.uid() is null then
 raise exception 'VALIDATION_FAILED'; end if;
 update public.incidents i set revision=i.revision+case when p_ordinal=1 then 1 else 0 end,
 timeline_sequence=i.timeline_sequence+1,updated_at=clock_timestamp() where i.id=p_incident
 returning i.revision,i.timeline_sequence into v_revision,v_sequence;
 insert into public.incident_timeline(incident_id,sequence,revision,operation_id,event_ordinal,event_code,
 actor_user_id,actor_organization_id,participation_id,assignment_id,data)
 values(p_incident,v_sequence,v_revision,p_operation,p_ordinal,p_code,auth.uid(),p_org,p_participation,p_assignment,p_data);
end; $$;
revoke all on function private.append_incident_event(uuid,uuid,uuid,smallint,text,jsonb,uuid,uuid) from public,anon,authenticated,service_role;

create or replace function private.incident_command(p_command text,p_operation uuid,p_org uuid,p_incident uuid,
 p_expected bigint,p_payload jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
 v_actor uuid:=auth.uid(); v_request jsonb; v_saved private.incident_operation_receipts;
 v_incident public.incidents; v_before jsonb; v_result jsonb; v_org uuid; v_profile uuid;
 v_target_org uuid; v_target_user uuid; v_part public.incident_participants;
 v_consent private.incident_command_consents; v_role public.incident_role_assignments;
 v_id uuid:=p_incident; v_part_id uuid; v_role_id uuid; v_number bigint; v_year smallint;
 v_now timestamptz:=clock_timestamp(); v_reason text:=btrim(coalesce(p_payload->>'reason',''));
 v_event text; v_data jsonb:='{}'; v_is_manager boolean; v_is_commander boolean;
 v_previous_consent uuid; v_lat double precision; v_lon double precision; v_allowed text[];
begin
 if v_actor is null or not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_operation is null or p_org is null or jsonb_typeof(p_payload) is distinct from 'object'
 or octet_length(p_payload::text)>32768 then raise exception 'VALIDATION_FAILED'; end if;
 v_allowed:=case
  when p_command in ('CREATE','UPDATE_CORE') then array['title','summary','incident_type_id','severity','priority','latitude','longitude','address','unknown_location_reason']
  when p_command='NOMINATE' then array['user_id'] when p_command='ACCEPT_COMMAND' then array['consent_id']
  when p_command='REQUEST_PARTICIPATION' then array['organization_id']
  when p_command in ('ACCEPT_PARTICIPATION','DECLINE_PARTICIPATION','CONSENT_RELEASE','RELEASE_PARTICIPATION') then array['participant_id','reason']
  when p_command in ('ACTIVATE','STABILIZE','REACTIVATE','CLOSE','CANCEL') then array['reason'] else array[]::text[] end;
 if exists(select 1 from jsonb_object_keys(p_payload) k where not(k=any(v_allowed))) then raise exception 'VALIDATION_FAILED'; end if;
 if exists(select 1 from jsonb_each(p_payload) f where f.key not in ('latitude','longitude') and jsonb_typeof(f.value) not in ('string','null'))
  or exists(select 1 from jsonb_each(p_payload) f where f.key in ('latitude','longitude') and jsonb_typeof(f.value) not in ('number','null')) then raise exception 'VALIDATION_FAILED'; end if;
 v_request:=jsonb_build_object('command',p_command,'org',p_org,'incident',p_incident,'expected',p_expected,'payload',p_payload);
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 -- Lock all existing participating orgs plus the requested target before the
 -- aggregate, coordinating with the platform's exact-membership write locks.
 v_target_org:=case when p_command='REQUEST_PARTICIPATION' then (p_payload->>'organization_id')::uuid end;
 v_target_user:=case when p_command='NOMINATE' then (p_payload->>'user_id')::uuid end;
 for v_org in select distinct q.org from (
  select p_org org union all select v_target_org union all
  select ip.organization_id from public.incident_participants ip where ip.incident_id=p_incident
 ) q where q.org is not null order by q.org loop
  perform private.lock_organization(v_org);
  perform 1 from public.organizations o where o.id=v_org for share;
 end loop;
 for v_profile in select distinct q.uid from (
  select v_actor uid union all select v_target_user union all
  select c.user_id from private.incident_command_consents c where c.incident_id=p_incident and c.status in ('REQUESTED','ACCEPTED') union all
  select a.user_id from public.incident_role_assignments a where a.incident_id=p_incident and a.status='ACTIVE'
  union all select ip.release_consented_by from public.incident_participants ip where ip.incident_id=p_incident
 ) q where q.uid is not null order by q.uid loop
  perform 1 from public.profiles pr where pr.id=v_profile for share;
 end loop;
 if not private.incident_acting_member(p_org) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into v_saved from private.incident_operation_receipts r where r.operation_id=p_operation;
 if found then
  if v_saved.actor_user_id<>v_actor or v_saved.request is distinct from v_request then raise exception 'OPERATION_REUSED'; end if;
  -- A consent/invitation recipient may replay their own minimal receipt without
  -- obtaining full DRAFT incident read access. Receipt never contains detail.
  return v_saved.result;
 end if;
 if p_command='CREATE' then
  if p_incident is not null or p_expected is distinct from 0 or not private.has_organization_role(p_org,array['MANAGER','ADMIN']) then
   raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 else
  select * into v_incident from public.incidents i where i.id=p_incident for update;
  if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  v_is_manager:=private.incident_draft_manager(p_incident,p_org);
  v_is_commander:=private.has_incident_capability(p_incident,p_org,'CHANGE_LIFECYCLE');
  -- Check scope before exposing state/version errors, including inbox actions.
  if not (v_is_manager or (private.can_read_incident(p_incident) and exists(
   select 1 from public.incident_participants ip where ip.incident_id=p_incident and ip.organization_id=p_org
   and (ip.status='ACTIVE' or (v_incident.status in ('CLOSED','CANCELLED') and ip.status='RELEASED'))))
   or (p_command='ACCEPT_COMMAND' and exists(select 1 from private.incident_command_consents c where c.id=(p_payload->>'consent_id')::uuid
    and c.incident_id=p_incident and c.user_id=v_actor and c.organization_id=p_org and c.status='REQUESTED'))
   or (p_command in ('ACCEPT_PARTICIPATION','DECLINE_PARTICIPATION') and private.has_organization_role(p_org,array['MANAGER','ADMIN'])
    and exists(select 1 from public.incident_participants ip where ip.id=(p_payload->>'participant_id')::uuid
     and ip.incident_id=p_incident and ip.organization_id=p_org and ip.status='REQUESTED')))
  then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if v_incident.status in ('CLOSED','CANCELLED') then raise exception 'INCIDENT_TERMINAL'; end if;
  if p_expected is distinct from v_incident.version then raise exception 'STALE_VERSION'; end if;
  v_before:=jsonb_build_object('version',v_incident.version,'status',v_incident.status,'title',v_incident.title,
   'summary',v_incident.summary,'incident_type_id',v_incident.incident_type_id,'severity',v_incident.severity,
   'priority',v_incident.priority,'latitude',v_incident.latitude,'longitude',v_incident.longitude,'address',v_incident.address,
   'unknown_location_reason',v_incident.metadata->>'unknown_location_reason');
 end if;

 v_now:=clock_timestamp();
 if p_command in ('CREATE','UPDATE_CORE') then
  if p_command='UPDATE_CORE' and not (v_is_manager or private.has_incident_capability(p_incident,p_org,'EDIT_SUMMARY')) then
   raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if exists(select 1 from jsonb_object_keys(p_payload) k where k not in ('title','summary','incident_type_id','severity','priority','latitude','longitude','address','unknown_location_reason'))
   or length(btrim(coalesce(p_payload->>'title',''))) not between 1 and 200
   or length(coalesce(p_payload->>'summary',''))>10000 or length(coalesce(p_payload->>'address',''))>1000
   or coalesce(p_payload->>'severity','') not in ('UNKNOWN','MINOR','MAJOR','CRITICAL')
   or coalesce(p_payload->>'priority','') not in ('LOW','NORMAL','HIGH','CRITICAL') then raise exception 'VALIDATION_FAILED'; end if;
  if not exists(select 1 from public.incident_types it where it.id=(p_payload->>'incident_type_id')::uuid
   and (it.active or (p_command='UPDATE_CORE' and it.id=v_incident.incident_type_id))) then raise exception 'VALIDATION_FAILED'; end if;
  v_lat:=(p_payload->>'latitude')::double precision; v_lon:=(p_payload->>'longitude')::double precision;
  if (v_lat is null)<>(v_lon is null) or (v_lat is not null and not(v_lat between -90 and 90 and v_lon between -180 and 180))
   or length(coalesce(p_payload->>'unknown_location_reason',''))>1000
   or (v_lat is null and length(btrim(coalesce(p_payload->>'unknown_location_reason',''))) not between 1 and 1000) then raise exception 'VALIDATION_FAILED'; end if;
  if p_command='CREATE' then
   v_id:=gen_random_uuid(); v_year:=extract(year from v_now at time zone 'Europe/Ljubljana')::smallint;
   insert into private.incident_number_counters(organization_id,reference_year,next_value) values(p_org,v_year,2)
   on conflict(organization_id,reference_year) do update set next_value=private.incident_number_counters.next_value+1
   returning next_value-1 into v_number;
   insert into public.incidents(id,reference_number,reference_year,title,summary,incident_type_id,severity,priority,
    created_organization_id,lead_organization_id,created_by,latitude,longitude,address,metadata)
   values(v_id,'INC-'||v_year::text||'-'||lpad(v_number::text,greatest(6,length(v_number::text)), '0'),v_year,
    btrim(p_payload->>'title'),coalesce(p_payload->>'summary',''),(p_payload->>'incident_type_id')::uuid,
    p_payload->>'severity',p_payload->>'priority',p_org,p_org,v_actor,v_lat,v_lon,nullif(btrim(p_payload->>'address'),''),
    jsonb_build_object('unknown_location_reason',case when v_lat is null then btrim(p_payload->>'unknown_location_reason') else null end));
   insert into public.incident_participants(incident_id,organization_id,agency_role,status,source,requested_by,requested_at,accepted_by,accepted_at)
   values(v_id,p_org,'LEAD','ACTIVE','CREATOR',v_actor,v_now,v_actor,v_now) returning id into v_part_id;
   v_event:='INCIDENT_CREATED';
  else
   update public.incidents i set title=btrim(p_payload->>'title'),summary=coalesce(p_payload->>'summary',''),
    incident_type_id=(p_payload->>'incident_type_id')::uuid,severity=p_payload->>'severity',priority=p_payload->>'priority',
    latitude=v_lat,longitude=v_lon,address=nullif(btrim(p_payload->>'address'),''),
    metadata=i.metadata||jsonb_build_object('unknown_location_reason',case when v_lat is null then btrim(p_payload->>'unknown_location_reason') else null end) where i.id=v_id;
   v_event:='INCIDENT_DETAILS_UPDATED';
  end if;
 elsif p_command='NOMINATE' then
  if not v_is_manager then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if not exists(select 1 from public.user_organizations m join public.profiles pr on pr.id=m.user_id and pr.account_status='ACTIVE'
   where m.organization_id=v_incident.lead_organization_id and m.user_id=v_target_user) then raise exception 'INVALID_COMMANDER'; end if;
  select c.id into v_previous_consent from private.incident_command_consents c where c.incident_id=v_id and c.kind='INITIAL' and c.status in ('REQUESTED','ACCEPTED');
  update private.incident_command_consents c set status='WITHDRAWN',ended_at=v_now where c.incident_id=v_id and c.kind='INITIAL' and c.status in ('REQUESTED','ACCEPTED');
  insert into private.incident_command_consents(incident_id,user_id,organization_id,nominated_by,status,expires_at)
   values(v_id,v_target_user,v_incident.lead_organization_id,v_actor,'REQUESTED',v_now+interval '24 hours') returning * into v_consent;
  v_event:='COMMAND_NOMINATED'; v_data:=jsonb_build_object('consent_id',v_consent.id,'user_id',v_target_user,'withdrawn_consent_id',v_previous_consent);
 elsif p_command='ACCEPT_COMMAND' then
  select * into v_consent from private.incident_command_consents c where c.id=(p_payload->>'consent_id')::uuid
   and c.incident_id=v_id and c.user_id=v_actor and c.organization_id=p_org for update;
  if not found or v_incident.status<>'DRAFT' or v_consent.status<>'REQUESTED' or v_consent.expires_at<=v_now then raise exception 'INVALID_COMMANDER'; end if;
  update private.incident_command_consents c set status='ACCEPTED',accepted_at=v_now where c.id=v_consent.id;
  v_event:='COMMAND_ACCEPTED'; v_data:=jsonb_build_object('consent_id',v_consent.id,'user_id',v_actor);
 elsif p_command='REQUEST_PARTICIPATION' then
  if not (v_is_manager or private.has_incident_capability(v_id,p_org,'INVITE_ORGANIZATION')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if v_target_org is null or not exists(select 1 from public.organizations o where o.id=v_target_org and o.active)
   or exists(select 1 from public.incident_participants ip where ip.incident_id=v_id and ip.organization_id=v_target_org and ip.status in ('REQUESTED','ACTIVE'))
   then raise exception 'INVALID_PARTICIPANT'; end if;
  insert into public.incident_participants(incident_id,organization_id,agency_role,status,source,requested_by)
   values(v_id,v_target_org,'SUPPORT','REQUESTED','INVITATION',v_actor) returning id into v_part_id;
  v_event:='PARTICIPANT_REQUESTED'; v_data:=jsonb_build_object('organization_id',v_target_org);
 elsif p_command in ('ACCEPT_PARTICIPATION','DECLINE_PARTICIPATION','CONSENT_RELEASE','RELEASE_PARTICIPATION') then
  select * into v_part from public.incident_participants ip where ip.id=(p_payload->>'participant_id')::uuid and ip.incident_id=v_id for update;
  if not found then raise exception 'INVALID_PARTICIPANT'; end if;
  v_part_id:=v_part.id;
  if p_command in ('ACCEPT_PARTICIPATION','DECLINE_PARTICIPATION','CONSENT_RELEASE') then
   if v_part.organization_id<>p_org or not private.has_organization_role(p_org,array['MANAGER','ADMIN']) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  elsif not v_is_commander then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if p_command in ('ACCEPT_PARTICIPATION','DECLINE_PARTICIPATION') then
   if v_part.status<>'REQUESTED' then raise exception 'INVALID_PARTICIPANT'; end if;
   if p_command='ACCEPT_PARTICIPATION' then
    update public.incident_participants ip set status='ACTIVE',accepted_by=v_actor,accepted_at=v_now,updated_at=v_now,version=ip.version+1 where ip.id=v_part.id;
    v_event:='PARTICIPANT_JOINED';
   else
    if length(v_reason) not between 1 and 2000 then raise exception 'VALIDATION_FAILED'; end if;
    update public.incident_participants ip set status='DECLINED',ended_by=v_actor,ended_at=v_now,end_reason=v_reason,updated_at=v_now,version=ip.version+1 where ip.id=v_part.id;
    v_event:='PARTICIPANT_DECLINED';
   end if;
  else
   if v_part.status<>'ACTIVE' or v_part.organization_id=v_incident.lead_organization_id or v_incident.status not in ('ACTIVE','STABILIZED')
    then raise exception 'INVALID_PARTICIPANT'; end if;
   if exists(select 1 from public.incident_role_assignments a where a.participation_id=v_part.id and a.status='ACTIVE') then raise exception 'PARTICIPANT_HAS_ACTIVE_COMMAND'; end if;
   if length(v_reason) not between 1 and 2000 then raise exception 'VALIDATION_FAILED'; end if;
   if p_command='CONSENT_RELEASE' then
    update public.incident_participants ip set release_consented_by=v_actor,release_consented_at=v_now,version=ip.version+1,updated_at=v_now where ip.id=v_part.id;
    v_event:='PARTICIPANT_RELEASE_REQUESTED';
   else
    -- Consent is live authority, not a permanent permission cached on the row.
    if v_part.release_consented_at is null or not exists(select 1 from public.organizations o where o.id=v_part.organization_id and o.active) or not exists(select 1 from public.user_organizations m join public.profiles pr on pr.id=m.user_id and pr.account_status='ACTIVE'
      where m.user_id=v_part.release_consented_by and m.organization_id=v_part.organization_id and m.role in ('MANAGER','ADMIN')) then raise exception 'INVALID_PARTICIPANT'; end if;
    perform 1 from public.profiles pr where pr.id=v_part.release_consented_by and pr.account_status='ACTIVE' for share;
    if not found then raise exception 'INVALID_PARTICIPANT'; end if;
    update public.incident_participants ip set status='RELEASED',ended_by=v_actor,ended_at=v_now,end_reason=v_reason,version=ip.version+1,updated_at=v_now where ip.id=v_part.id;
    v_event:='PARTICIPANT_RELEASED';
   end if;
  end if;
  v_data:=jsonb_build_object('organization_id',v_part.organization_id,'reason',nullif(v_reason,''));
 elsif p_command in ('ACTIVATE','STABILIZE','REACTIVATE','CLOSE','CANCEL') then
  if p_command in ('ACTIVATE','CANCEL') then
   if not v_is_manager then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  elsif not v_is_commander then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if p_command='ACTIVATE' then
   select * into v_consent from private.incident_command_consents c where c.incident_id=v_id and c.kind='INITIAL' and c.status='ACCEPTED' for update;
   if not found or v_consent.expires_at<=v_now then raise exception 'INVALID_COMMANDER'; end if;
   if not exists(select 1 from public.user_organizations m join public.profiles pr on pr.id=m.user_id and pr.account_status='ACTIVE'
    where m.user_id=v_consent.user_id and m.organization_id=v_incident.lead_organization_id)
    then raise exception 'INVALID_COMMANDER'; end if;
   if v_incident.latitude is null and length(btrim(coalesce(v_incident.metadata->>'unknown_location_reason',''))) not between 1 and 1000 then raise exception 'VALIDATION_FAILED'; end if;
   select ip.id into v_part_id from public.incident_participants ip where ip.incident_id=v_id and ip.organization_id=v_incident.lead_organization_id and ip.status='ACTIVE' and ip.agency_role='LEAD';
   if v_part_id is null then raise exception 'INVALID_PARTICIPANT'; end if;
   insert into public.incident_role_assignments(incident_id,participation_id,organization_id,user_id,role,assigned_by)
    values(v_id,v_part_id,v_incident.lead_organization_id,v_consent.user_id,'INCIDENT_COMMANDER',v_actor) returning id into v_role_id;
   update private.incident_command_consents c set status='CONSUMED',ended_at=v_now where c.id=v_consent.id;
   update public.incidents i set status='ACTIVE',declared_at=v_now where i.id=v_id;
   v_event:='INCIDENT_ACTIVATED'; v_part_id:=null;
  elsif p_command='STABILIZE' and v_incident.status='ACTIVE' then
   update public.incidents i set status='STABILIZED',stabilized_at=v_now where i.id=v_id; v_event:='INCIDENT_STABILIZED';
  elsif p_command='REACTIVATE' and v_incident.status='STABILIZED' then
   if length(v_reason) not between 1 and 2000 then raise exception 'VALIDATION_FAILED'; end if;
   update public.incidents i set status='ACTIVE',stabilized_at=null where i.id=v_id; v_event:='INCIDENT_REACTIVATED';
  elsif p_command='CLOSE' and v_incident.status='STABILIZED' then
   if length(v_reason) not between 1 and 2000 then raise exception 'VALIDATION_FAILED'; end if;
   if exists(select 1 from private.incident_command_consents c where c.incident_id=v_id and c.kind='INITIAL' and c.status in ('REQUESTED','ACCEPTED')) then raise exception 'INVALID_COMMANDER'; end if;
   update public.incident_role_assignments a set status='ENDED',ended_by=v_actor,ended_at=v_now,end_reason=v_reason,updated_at=v_now,version=a.version+1
    where a.incident_id=v_id and a.status='ACTIVE' and a.role='INCIDENT_COMMANDER' returning * into v_role;
   v_data:=jsonb_build_object('final_commander_assignment_id',v_role.id,'ended_assignments',private.finish_incident_command(v_id,v_actor,v_now,v_reason));
   update public.incidents i set status='CLOSED',closed_at=v_now where i.id=v_id; v_event:='INCIDENT_CLOSED';
  elsif p_command='CANCEL' and v_incident.status='DRAFT' then
   if length(v_reason) not between 1 and 2000 then raise exception 'VALIDATION_FAILED'; end if;
   update private.incident_command_consents c set status='WITHDRAWN',ended_at=v_now where c.incident_id=v_id and c.kind='INITIAL' and c.status in ('REQUESTED','ACCEPTED');
   update public.incidents i set status='CANCELLED',cancelled_at=v_now where i.id=v_id; v_event:='INCIDENT_CANCELLED';
  else raise exception 'INVALID_TRANSITION'; end if;
  v_data:=v_data||jsonb_build_object('from_status',v_incident.status,'reason',nullif(v_reason,''));
 else raise exception 'VALIDATION_FAILED'; end if;

 if p_command<>'CREATE' then update public.incidents i set version=i.version+1 where i.id=v_id; end if;
 perform private.append_incident_event(v_id,p_org,p_operation,1::smallint,v_event,v_data,
  case when p_command='CREATE' then null else v_part_id end,null);
 if p_command='CREATE' then
  perform private.append_incident_event(v_id,p_org,p_operation,2::smallint,'PARTICIPANT_JOINED',jsonb_build_object('organization_id',p_org),v_part_id,null);
 elsif p_command='ACTIVATE' then
  perform private.append_incident_event(v_id,p_org,p_operation,2::smallint,'COMMAND_ASSIGNED',jsonb_build_object('role','INCIDENT_COMMANDER','user_id',v_consent.user_id),null,v_role_id);
 end if;
 select jsonb_build_object('contract_version',1,'operation_id',p_operation,'incident_id',i.id,
  'version',i.version::text,'revision',i.revision::text,'timeline_sequence',i.timeline_sequence::text)
 into v_result from public.incidents i where i.id=v_id;
 perform private.write_audit(p_org,v_actor,v_event,'incidents',v_id,v_before,
  jsonb_build_object('request',p_payload,'result',v_result,'event',v_data));
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,v_actor,p_org,v_id,p_command,v_request,v_result);
 return v_result;
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation then
 raise exception 'VALIDATION_FAILED';
 when unique_violation then raise exception 'INVALID_STATE';
end; $$;
revoke all on function private.incident_command(text,uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;

create or replace function public.incident_entry() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return jsonb_build_object('organizations',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'can_create',m.role in ('MANAGER','ADMIN')) order by o.name,o.id)
  from public.user_organizations m join public.organizations o on o.id=m.organization_id and o.active where m.user_id=auth.uid()),'[]'),
 'types',coalesce((select jsonb_agg(jsonb_build_object('id',it.id,'code',it.code,'names',it.names) order by it.code) from public.incident_types it where it.active),'[]'),
 'invitations',coalesce((select jsonb_agg(q.dto order by q.requested_at,q.id) from (
  select ip.id,ip.requested_at,jsonb_build_object('id',ip.id,'incident_id',i.id,'title',i.title,'reference_number',i.reference_number,
   'organization_id',ip.organization_id,'version',i.version::text) dto
  from public.incident_participants ip join public.incidents i on i.id=ip.incident_id
  where ip.status='REQUESTED' and i.status not in ('CLOSED','CANCELLED') and private.incident_acting_member(ip.organization_id)
   and private.has_organization_role(ip.organization_id,array['MANAGER','ADMIN'])
  order by ip.requested_at,ip.id limit 50) q),'[]'),
 'nominations',coalesce((select jsonb_agg(q.dto order by q.created_at,q.id) from (
  select c.id,c.created_at,jsonb_build_object('id',c.id,'incident_id',i.id,'title',i.title,'reference_number',i.reference_number,
   'organization_id',c.organization_id,'version',i.version::text,'expires_at',c.expires_at) dto
  from private.incident_command_consents c join public.incidents i on i.id=c.incident_id
  where c.user_id=auth.uid() and c.kind='INITIAL' and c.status='REQUESTED' and c.expires_at>statement_timestamp() and i.status='DRAFT'
   and private.incident_acting_member(c.organization_id) order by c.created_at,c.id limit 50) q),'[]'));
end; $$;
