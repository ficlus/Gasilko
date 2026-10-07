-- M14.4 explicit unit command scope; extend the existing role/consent subsystem.
alter table public.incident_role_assignments add column unit_assignment_id uuid,
 add constraint incident_role_unit_fk foreign key(unit_assignment_id,incident_id) references public.incident_units(id,incident_id),
 add constraint incident_role_unit_scope check((role='UNIT_LEADER')=(unit_assignment_id is not null));
alter table public.incident_role_assignments drop constraint incident_role_assignments_role_check;
alter table public.incident_role_assignments add constraint incident_role_assignments_role_check check(role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER','AGENCY_COMMANDER','SECTOR_COMMANDER','UNIT_LEADER','OPERATOR','RESPONDER'));
create unique index incident_roles_unit_unique on public.incident_role_assignments(unit_assignment_id) where status='ACTIVE' and role='UNIT_LEADER';
alter table private.incident_command_consents add column unit_assignment_id uuid,
 add constraint incident_consent_unit_fk foreign key(unit_assignment_id,incident_id) references public.incident_units(id,incident_id),
 add constraint incident_consent_unit_scope check((offered_role='UNIT_LEADER' and unit_assignment_id is not null) or (coalesce(offered_role,'')<>'UNIT_LEADER' and unit_assignment_id is null));
alter table private.incident_command_consents drop constraint incident_command_consents_offered_role_check;
alter table private.incident_command_consents add constraint incident_command_consents_offered_role_check check(offered_role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER','AGENCY_COMMANDER','SECTOR_COMMANDER','UNIT_LEADER'));
create function private.incident_unit_leader_candidate(p_incident uuid,p_unit uuid,p_user uuid,p_org uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select exists(select 1 from public.incident_units d
 join public.incident_participants ip on ip.id=d.participation_id and ip.status='ACTIVE'
 join public.organizations o on o.id=d.organization_id and o.active
 join public.incident_crew_members c on c.unit_assignment_id=d.id and c.status='ACTIVE' and c.user_id=p_user
 join public.profiles pr on pr.id=c.user_id and pr.account_status='ACTIVE'
 join public.user_organizations m on m.user_id=pr.id and m.organization_id=d.organization_id
 where d.id=p_unit and d.incident_id=p_incident and d.organization_id=p_org and d.status not in ('RELEASED','UNAVAILABLE'));
$$;
create or replace function private.incident_assignment_effective(p_assignment uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select exists(select 1 from public.incident_role_assignments a
 join public.incidents i on i.id=a.incident_id and i.status in ('ACTIVE','STABILIZED')
 join public.incident_participants ip on ip.id=a.participation_id and ip.status='ACTIVE'
 join public.organizations o on o.id=a.organization_id and o.active
 join public.profiles pr on pr.id=a.user_id and pr.account_status='ACTIVE'
 join public.user_organizations m on m.user_id=a.user_id and m.organization_id=a.organization_id
 where a.id=p_assignment and a.status='ACTIVE' and a.valid_from<=clock_timestamp()
 and (a.valid_until is null or a.valid_until>clock_timestamp())
 and (a.role<>'SECTOR_COMMANDER' or exists(select 1 from public.incident_sectors s where s.id=a.sector_id and s.incident_id=a.incident_id and s.active))
 and (a.role<>'UNIT_LEADER' or private.incident_unit_leader_candidate(a.incident_id,a.unit_assignment_id,a.user_id,a.organization_id))
 and (a.role<>'INCIDENT_COMMANDER' or a.organization_id=i.lead_organization_id));
$$;
create function private.incident_unit_leader_parent(p_incident uuid,p_org uuid) returns uuid
language sql volatile security definer set search_path='' as $$
 select a.id from public.incident_role_assignments a where a.incident_id=p_incident and private.incident_assignment_effective(a.id)
 and (a.role='INCIDENT_COMMANDER' or (a.role='AGENCY_COMMANDER' and a.organization_id=p_org))
 order by (a.role='AGENCY_COMMANDER') desc,a.id limit 1;
$$;
create or replace function private.guard_incident_command_role() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_parent public.incident_role_assignments;
begin
 perform 1 from public.incidents i where i.id=new.incident_id for update;
 if tg_op='UPDATE' then
  if (new.id,new.incident_id,new.participation_id,new.organization_id,new.user_id,new.role,new.sector_id,new.unit_assignment_id,new.parent_assignment_id,new.valid_from,new.assigned_by)
   is distinct from (old.id,old.incident_id,old.participation_id,old.organization_id,old.user_id,old.role,old.sector_id,old.unit_assignment_id,old.parent_assignment_id,old.valid_from,old.assigned_by)
   or old.status<>'ACTIVE' or new.status not in ('ENDED','REVOKED') then raise exception 'INVALID_COMMAND_HIERARCHY'; end if;
  return new;
 end if;
 if new.role='SECTOR_COMMANDER' and not exists(select 1 from public.incident_sectors s where s.id=new.sector_id and s.incident_id=new.incident_id and s.active) then raise exception 'INVALID_SECTOR'; end if;
 if new.role='UNIT_LEADER' and (not private.incident_unit_leader_candidate(new.incident_id,new.unit_assignment_id,new.user_id,new.organization_id)
 or new.parent_assignment_id is distinct from private.incident_unit_leader_parent(new.incident_id,new.organization_id)) then raise exception 'INVALID_COMMAND_CANDIDATE'; end if;
 if new.role='INCIDENT_COMMANDER' then
  if new.parent_assignment_id is not null then raise exception 'INVALID_COMMAND_HIERARCHY'; end if;
 else
  select * into v_parent from public.incident_role_assignments a where a.id=new.parent_assignment_id and a.incident_id=new.incident_id and a.status='ACTIVE';
  if not found or (new.role in ('DEPUTY_COMMANDER','AGENCY_COMMANDER','SECTOR_COMMANDER') and v_parent.role<>'INCIDENT_COMMANDER')
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
create or replace function private.incident_command_structure(p_action text,p_operation uuid,p_org uuid,p_incident uuid,p_expected bigint,p_payload jsonb)
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
 v_allowed:=case when p_action in ('OFFER','TRANSFER','RECOVERY') then array['user_id','organization_id','role','parent_assignment_id','mode','reason','sector_id','unit_assignment_id']
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
   if (p_payload->>'role'='SECTOR_COMMANDER') is distinct from (nullif(p_payload->>'sector_id','') is not null) then raise exception 'INVALID_SCOPE'; end if;
   if p_payload->>'role'='SECTOR_COMMANDER' and not exists(select 1 from public.incident_sectors s where s.id=(p_payload->>'sector_id')::uuid and s.incident_id=p_incident and s.active) then raise exception 'INVALID_SECTOR'; end if;
   if (p_payload->>'role'='UNIT_LEADER') is distinct from (nullif(p_payload->>'unit_assignment_id','') is not null) then raise exception 'INVALID_SCOPE'; end if;
   if p_payload->>'role'='UNIT_LEADER' and not private.incident_unit_leader_candidate(p_incident,(p_payload->>'unit_assignment_id')::uuid,v_target_user,v_target_org) then raise exception 'INVALID_COMMAND_CANDIDATE'; end if;
   if not private.incident_assignment_effective(v_ic.id) then raise exception 'INVALID_COMMANDER'; end if;
   v_role_name:=p_payload->>'role'; v_parent:=(p_payload->>'parent_assignment_id')::uuid;
   if v_role_name is null or v_role_name not in ('DEPUTY_COMMANDER','AGENCY_COMMANDER','SECTOR_COMMANDER','UNIT_LEADER') then raise exception 'INVALID_COMMAND_ROLE'; end if;
   if (v_role_name='UNIT_LEADER' and v_parent is distinct from private.incident_unit_leader_parent(p_incident,v_target_org))
    or (v_role_name<>'UNIT_LEADER' and v_parent is distinct from v_ic.id) or not private.incident_assignment_effective(v_parent) then raise exception 'INVALID_COMMAND_HIERARCHY'; end if;
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
   outgoing_assignment_id,outgoing_version,reason,operation_id,transfer_lead,sector_id,unit_assignment_id)
   values(p_incident,v_target_user,v_target_org,v_actor,v_now+interval '24 hours','REQUESTED',case when p_action='OFFER' then 'ROLE' else p_action end,
    v_role_name,v_parent,v_ic.id,v_ic.version,nullif(v_reason,''),p_operation,v_cross,(p_payload->>'sector_id')::uuid,(p_payload->>'unit_assignment_id')::uuid) returning id into v_request_id;
  v_code:=case p_action when 'OFFER' then 'COMMAND_ROLE_OFFERED' when 'TRANSFER' then 'COMMAND_TRANSFER_REQUESTED' else 'COMMAND_RECOVERY_REQUESTED' end;
  v_data:=jsonb_build_object('request_id',v_request_id,'user_id',v_target_user,'organization_id',v_target_org,'role',v_role_name,'transfer_lead',v_cross,'sector_id',(p_payload->>'sector_id')::uuid,'unit_assignment_id',(p_payload->>'unit_assignment_id')::uuid,'reason',nullif(v_reason,''));
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
    if v_c.offered_role='SECTOR_COMMANDER' and not exists(select 1 from public.incident_sectors s where s.id=v_c.sector_id and s.incident_id=p_incident and s.active) then raise exception 'INVALID_SECTOR'; end if;
    if (v_c.offered_role='UNIT_LEADER' and (not private.incident_unit_leader_candidate(p_incident,v_c.unit_assignment_id,v_actor,p_org) or v_c.parent_assignment_id is distinct from private.incident_unit_leader_parent(p_incident,p_org)))
     or (v_c.offered_role<>'UNIT_LEADER' and v_c.parent_assignment_id is distinct from v_ic.id) then raise exception 'INVALID_COMMAND_HIERARCHY'; end if;
    insert into public.incident_role_assignments(incident_id,participation_id,organization_id,user_id,role,parent_assignment_id,assigned_by,valid_from,sector_id,unit_assignment_id)
     values(p_incident,v_part,p_org,v_actor,v_c.offered_role,v_c.parent_assignment_id,v_c.nominated_by,v_now,v_c.sector_id,v_c.unit_assignment_id) returning id into v_id;
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
    ) select * from tree order by depth,(role='UNIT_LEADER'),id loop
     update public.incident_role_assignments a set status='ENDED',valid_until=least(a.valid_until,v_now),ended_by=v_actor,ended_at=v_now,end_reason='COMMAND_HIERARCHY_REBASED',version=a.version+1,updated_at=v_now where a.id=v_child.id;
     if (v_child.valid_until is null or v_child.valid_until>v_now)
      and (v_child.role<>'UNIT_LEADER' or private.incident_unit_leader_candidate(p_incident,v_child.unit_assignment_id,v_child.user_id,v_child.organization_id))
      and v_map ? v_child.parent_assignment_id::text then
      insert into public.incident_role_assignments(incident_id,participation_id,organization_id,user_id,role,parent_assignment_id,assigned_by,valid_from,valid_until,sector_id,unit_assignment_id)
       values(p_incident,v_child.participation_id,v_child.organization_id,v_child.user_id,v_child.role,case when v_child.role='UNIT_LEADER' then private.incident_unit_leader_parent(p_incident,v_child.organization_id) else (v_map->>v_child.parent_assignment_id::text)::uuid end,v_actor,v_now,v_child.valid_until,v_child.sector_id,v_child.unit_assignment_id) returning id into v_id;
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
  v_data:=v_data||jsonb_build_object('request_id',v_c.id,'decision_reason',nullif(v_reason,''),'user_id',v_c.user_id,'organization_id',v_c.organization_id,'role',v_c.offered_role,'sector_id',v_c.sector_id,'unit_assignment_id',v_c.unit_assignment_id);
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
create or replace function private.incident_command_request_dto(p_request private.incident_command_consents,p_org uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p_request.id,'incident_id',p_request.incident_id,'organization_id',p_request.organization_id,
 'organization_name',(select o.name from public.organizations o where o.id=p_request.organization_id),
 'outgoing_name',(select pr.display_name from public.incident_role_assignments a join public.profiles pr on pr.id=a.user_id where a.id=p_request.outgoing_assignment_id),
 'lead_name',(select o.name from public.incidents i join public.organizations o on o.id=i.lead_organization_id where i.id=p_request.incident_id),
 'name',(select pr.display_name from public.profiles pr where pr.id=p_request.user_id),
 'unit_assignment_id',p_request.unit_assignment_id,'unit_name',(select u.callsign from public.incident_units d join public.operational_units u on u.id=d.unit_id where d.id=p_request.unit_assignment_id),
 'sector_id',p_request.sector_id,'sector_name',(select s.name from public.incident_sectors s where s.id=p_request.sector_id),
 'kind',p_request.kind,'role',p_request.offered_role,'status',case when p_request.status='REQUESTED' and p_request.expires_at<=statement_timestamp() then 'EXPIRED' else p_request.status end,
 'reason',p_request.reason,'created_at',p_request.created_at,'expires_at',p_request.expires_at,'transfer_lead',p_request.transfer_lead,
 'lead_consented',p_request.lead_consented_at is not null,'version',(select i.version::text from public.incidents i where i.id=p_request.incident_id),
 'can_accept',p_request.status='REQUESTED' and p_request.expires_at>statement_timestamp() and p_request.user_id=auth.uid() and p_org=p_request.organization_id,
 'can_lead_consent',p_request.status='REQUESTED' and p_request.expires_at>statement_timestamp() and p_request.transfer_lead and p_org=p_request.organization_id
  and private.has_organization_role(p_org,array['MANAGER','ADMIN']),
 'can_cancel',p_request.status='REQUESTED' and p_request.expires_at>statement_timestamp() and
  (private.has_incident_capability(p_request.incident_id,p_org,'TRANSFER_COMMAND')
   or (p_request.kind in ('TRANSFER','RECOVERY')
   and exists(select 1 from public.incidents i where i.id=p_request.incident_id and i.lead_organization_id=p_org)
   and not exists(select 1 from public.incident_role_assignments a where a.incident_id=p_request.incident_id and a.role='INCIDENT_COMMANDER' and private.incident_assignment_effective(a.id))
   and private.has_organization_role(p_org,array['MANAGER','ADMIN']))));
$$;
create or replace function public.incident_command_view(p_incident_id uuid,p_acting_organization_id uuid,p_before_created timestamptz default null,p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_i public.incidents; v_has_ic boolean; v_can_assign boolean;
begin
 if public.incident_context(p_incident_id,p_acting_organization_id) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if (p_before_created is null)<>(p_before_id is null) then raise exception 'VALIDATION_FAILED'; end if;
 select * into v_i from public.incidents i where i.id=p_incident_id;
 v_has_ic:=exists(select 1 from public.incident_role_assignments a where a.incident_id=p_incident_id and a.role='INCIDENT_COMMANDER' and private.incident_assignment_effective(a.id));
 v_can_assign:=private.has_incident_capability(p_incident_id,p_acting_organization_id,'ASSIGN_INCIDENT_ROLE');
 return jsonb_build_object('version',v_i.version::text,'valid_commander',v_has_ic,'operational',v_i.status in ('ACTIVE','STABILIZED'),
 'can_assign',v_can_assign,
 'can_transfer',private.has_incident_capability(p_incident_id,p_acting_organization_id,'TRANSFER_COMMAND'),
 'can_recover',v_i.status in ('ACTIVE','STABILIZED') and not v_has_ic and v_i.lead_organization_id=p_acting_organization_id
  and private.has_organization_role(p_acting_organization_id,array['MANAGER','ADMIN']),
 'units',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'organization_id',d.organization_id,'name',u.callsign||' · '||u.name,'parent_id',private.incident_unit_leader_parent(p_incident_id,d.organization_id)) order by u.callsign,d.id) from public.incident_units d join public.operational_units u on u.id=d.unit_id where d.incident_id=p_incident_id and d.status not in ('RELEASED','UNAVAILABLE')),'[]'),
 'sectors',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'code',s.code) order by s.code,s.id) from public.incident_sectors s where s.incident_id=p_incident_id and s.active),'[]'),
 'roles',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'user_id',a.user_id,'name',pr.display_name,'organization_id',a.organization_id,'organization_name',o.name,
  'role',a.role,'unit_assignment_id',a.unit_assignment_id,'unit_name',(select u.callsign from public.incident_units d join public.operational_units u on u.id=d.unit_id where d.id=a.unit_assignment_id),'sector_id',a.sector_id,'sector_name',(select s.name from public.incident_sectors s where s.id=a.sector_id),'parent_id',a.parent_assignment_id,'valid',private.incident_assignment_effective(a.id),'created_at',a.created_at,
  'can_end',v_can_assign
   and a.role<>'INCIDENT_COMMANDER' and not exists(select 1 from public.incident_role_assignments child where child.parent_assignment_id=a.id and child.status='ACTIVE')) order by a.role,o.name,a.id)
  from public.incident_role_assignments a join public.profiles pr on pr.id=a.user_id join public.organizations o on o.id=a.organization_id where a.incident_id=p_incident_id and a.status='ACTIVE'),'[]'),
 'history',coalesce((select jsonb_agg(q.dto order by q.created_at desc,q.id desc) from (
  select a.created_at,a.id,jsonb_build_object('id',a.id,'name',pr.display_name,'organization_name',o.name,'role',a.role,'unit_assignment_id',a.unit_assignment_id,'unit_name',(select u.callsign from public.incident_units d join public.operational_units u on u.id=d.unit_id where d.id=a.unit_assignment_id),'sector_id',a.sector_id,'sector_name',(select s.name from public.incident_sectors s where s.id=a.sector_id),'status',a.status,
   'parent_id',a.parent_assignment_id,'valid_from',a.valid_from,'ended_at',a.ended_at,'reason',a.end_reason,'assigned_by',assigner.display_name,'created_at',a.created_at) dto
  from public.incident_role_assignments a join public.profiles pr on pr.id=a.user_id join public.organizations o on o.id=a.organization_id
  join public.profiles assigner on assigner.id=a.assigned_by where a.incident_id=p_incident_id and a.status<>'ACTIVE'
   and (p_before_created is null or (a.created_at,a.id)<(p_before_created,p_before_id)) order by a.created_at desc,a.id desc limit 50) q),'[]'),
 'requests',coalesce((select jsonb_agg(q.dto order by q.pending desc,q.created_at desc,q.id desc) from (
  select c.id,c.created_at,(c.status='REQUESTED' and c.expires_at>statement_timestamp()) pending,private.incident_command_request_dto(c,p_acting_organization_id) dto
  from private.incident_command_consents c where c.incident_id=p_incident_id and c.kind<>'INITIAL'
   and (v_can_assign or (c.user_id=auth.uid() and c.organization_id=p_acting_organization_id)
    or (c.transfer_lead and c.organization_id=p_acting_organization_id and private.has_organization_role(p_acting_organization_id,array['MANAGER','ADMIN']))
    or (c.kind in ('TRANSFER','RECOVERY') and not v_has_ic and v_i.lead_organization_id=p_acting_organization_id and private.has_organization_role(p_acting_organization_id,array['MANAGER','ADMIN'])))
  order by pending desc,c.created_at desc,c.id desc limit 50) q),'[]'));
end; $$;
create function public.incident_unit_leader_candidates(p_incident_id uuid,p_acting_organization_id uuid,p_unit_assignment_id uuid,p_query text default '') returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if public.incident_context(p_incident_id,p_acting_organization_id) is null or not private.has_incident_capability(p_incident_id,p_acting_organization_id,'ASSIGN_INCIDENT_ROLE') then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_query is null or length(p_query)>100 then raise exception 'VALIDATION_FAILED'; end if;
 return coalesce((select jsonb_agg(q.dto order by q.name,q.id) from (
 select pr.id,pr.display_name name,jsonb_build_object('id',pr.id,'name',coalesce(pr.display_name,pr.id::text)) dto
 from public.incident_crew_members c join public.incident_units d on d.id=c.unit_assignment_id join public.profiles pr on pr.id=c.user_id
 where d.id=p_unit_assignment_id and c.status='ACTIVE' and private.incident_unit_leader_candidate(p_incident_id,d.id,pr.id,d.organization_id)
 and position(lower(p_query) in lower(coalesce(pr.display_name,'')))>0 order by pr.display_name,pr.id limit 30) q),'[]');
end; $$;
revoke all on function private.incident_unit_leader_candidate(uuid,uuid,uuid,uuid),private.incident_unit_leader_parent(uuid,uuid),public.incident_unit_leader_candidates(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.incident_unit_leader_candidates(uuid,uuid,uuid,text) to authenticated;
