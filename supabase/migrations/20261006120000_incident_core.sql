-- M14.1. Forward-only operational API; foundation tables remain RPC-write-only.
create table private.incident_operation_receipts (
 operation_id uuid primary key, actor_user_id uuid not null references public.profiles(id),
 acting_organization_id uuid not null references public.organizations(id),
 incident_id uuid not null references public.incidents(id), command_code text not null,
 request jsonb not null check (octet_length(request::text)<=65536), result jsonb not null,
 created_at timestamptz not null default clock_timestamp()
);
create table private.incident_number_counters (
 organization_id uuid not null references public.organizations(id), reference_year smallint not null,
 next_value bigint not null check(next_value>0), primary key(organization_id,reference_year)
);
create table private.incident_command_consents (
 id uuid primary key default gen_random_uuid(), incident_id uuid not null references public.incidents(id),
 user_id uuid not null references public.profiles(id), organization_id uuid not null references public.organizations(id),
 nominated_by uuid not null references public.profiles(id), created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null, accepted_at timestamptz, ended_at timestamptz,
 status text not null check(status in ('REQUESTED','ACCEPTED','WITHDRAWN','CONSUMED')),
 check(expires_at>created_at), check(status<>'ACCEPTED' or accepted_at is not null)
);
create unique index incident_consent_current_unique on private.incident_command_consents(incident_id)
 where status in ('REQUESTED','ACCEPTED');
create index incident_consent_inbox_idx on private.incident_command_consents(user_id,created_at,id) where status='REQUESTED';
create index incidents_created_cursor_idx on public.incidents(created_at desc,id desc);
revoke all on private.incident_operation_receipts,private.incident_number_counters,private.incident_command_consents from public,anon,authenticated,service_role;
create trigger incident_receipts_immutable before update or delete on private.incident_operation_receipts for each row execute function private.audit_immutable();
create trigger incident_receipts_no_truncate before truncate on private.incident_operation_receipts for each statement execute function private.audit_immutable();
create trigger incident_consents_no_delete before delete on private.incident_command_consents for each row execute function private.audit_immutable();
create trigger incident_consents_no_truncate before truncate on private.incident_command_consents for each statement execute function private.audit_immutable();
alter table public.incident_participants add column release_consented_by uuid references public.profiles(id),
 add column release_consented_at timestamptz,
 add constraint incident_release_consent_pair check((release_consented_by is null)=(release_consented_at is null));

-- Read-only effective actor scope. The mutator repeats this after security locks.
create function private.incident_acting_member(p_org uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select private.is_organization_member(p_org) and exists(select 1 from public.organizations o where o.id=p_org and o.active);
$$;
create function private.incident_draft_manager(p_incident uuid,p_org uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select private.incident_acting_member(p_org) and private.has_organization_role(p_org,array['MANAGER','ADMIN'])
 and exists(select 1 from public.incidents i where i.id=p_incident and i.status='DRAFT' and i.created_organization_id=p_org);
$$;
revoke all on function private.incident_acting_member(uuid),private.incident_draft_manager(uuid,uuid) from public,anon,authenticated,service_role;

-- All event codes are selected by trusted commands, never by an API caller.
-- First event of a command increments aggregate revision; later events share it.
create function private.append_incident_event(p_incident uuid,p_org uuid,p_operation uuid,p_ordinal smallint,
 p_code text,p_data jsonb,p_participation uuid default null,p_assignment uuid default null) returns void
language plpgsql volatile security definer set search_path='' as $$
declare v_revision bigint; v_sequence bigint;
begin
 if p_code not in ('INCIDENT_CREATED','PARTICIPANT_JOINED','INCIDENT_DETAILS_UPDATED','COMMAND_NOMINATED',
 'COMMAND_ACCEPTED','COMMAND_ENDED','COMMAND_ASSIGNED','PARTICIPANT_REQUESTED','PARTICIPANT_DECLINED',
 'PARTICIPANT_RELEASE_REQUESTED','PARTICIPANT_RELEASED','INCIDENT_ACTIVATED','INCIDENT_STABILIZED',
 'INCIDENT_REACTIVATED','INCIDENT_CLOSED','INCIDENT_CANCELLED') or auth.uid() is null then
 raise exception 'VALIDATION_FAILED'; end if;
 update public.incidents i set revision=i.revision+case when p_ordinal=1 then 1 else 0 end,
 timeline_sequence=i.timeline_sequence+1,updated_at=clock_timestamp() where i.id=p_incident
 returning i.revision,i.timeline_sequence into v_revision,v_sequence;
 insert into public.incident_timeline(incident_id,sequence,revision,operation_id,event_ordinal,event_code,
 actor_user_id,actor_organization_id,participation_id,assignment_id,data)
 values(p_incident,v_sequence,v_revision,p_operation,p_ordinal,p_code,auth.uid(),p_org,p_participation,p_assignment,p_data);
end; $$;
revoke all on function private.append_incident_event(uuid,uuid,uuid,smallint,text,jsonb,uuid,uuid) from public,anon,authenticated,service_role;

-- Fixed-command dispatcher is private. Narrow public wrappers below are the API.
create function private.incident_command(p_command text,p_operation uuid,p_org uuid,p_incident uuid,
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
  select c.id into v_previous_consent from private.incident_command_consents c where c.incident_id=v_id and c.status in ('REQUESTED','ACCEPTED');
  update private.incident_command_consents c set status='WITHDRAWN',ended_at=v_now where c.incident_id=v_id and c.status in ('REQUESTED','ACCEPTED');
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
    or exists(select 1 from public.incident_role_assignments a where a.participation_id=v_part.id and a.status='ACTIVE') then raise exception 'INVALID_PARTICIPANT'; end if;
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
   select * into v_consent from private.incident_command_consents c where c.incident_id=v_id and c.status='ACCEPTED' for update;
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
   if exists(select 1 from private.incident_command_consents c where c.incident_id=v_id and c.status in ('REQUESTED','ACCEPTED')) then raise exception 'INVALID_COMMANDER'; end if;
   update public.incident_role_assignments a set status='ENDED',ended_by=v_actor,ended_at=v_now,end_reason=v_reason,updated_at=v_now,version=a.version+1
    where a.incident_id=v_id and a.status='ACTIVE' and a.role='INCIDENT_COMMANDER' returning * into v_role;
   v_data:=jsonb_build_object('final_commander_assignment_id',v_role.id);
   update public.incidents i set status='CLOSED',closed_at=v_now where i.id=v_id; v_event:='INCIDENT_CLOSED';
  elsif p_command='CANCEL' and v_incident.status='DRAFT' then
   if length(v_reason) not between 1 and 2000 then raise exception 'VALIDATION_FAILED'; end if;
   update private.incident_command_consents c set status='WITHDRAWN',ended_at=v_now where c.incident_id=v_id and c.status in ('REQUESTED','ACCEPTED');
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

-- Public actions have fixed command identity; the browser cannot choose a private dispatcher operation.
create function public.incident_create_draft(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('CREATE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_create_draft(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_create_draft(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_update_summary(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('UPDATE_CORE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_update_summary(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_update_summary(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_nominate_initial_command(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('NOMINATE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_nominate_initial_command(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_nominate_initial_command(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_accept_initial_command(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('ACCEPT_COMMAND',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_accept_initial_command(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_accept_initial_command(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_request_participation(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('REQUEST_PARTICIPATION',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_request_participation(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_request_participation(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_accept_participation(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('ACCEPT_PARTICIPATION',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_accept_participation(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_accept_participation(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_decline_participation(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('DECLINE_PARTICIPATION',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_decline_participation(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_decline_participation(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_consent_release(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('CONSENT_RELEASE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_consent_release(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_consent_release(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_release_participation(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('RELEASE_PARTICIPATION',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_release_participation(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_release_participation(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_activate(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('ACTIVATE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_activate(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_activate(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_stabilize(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('STABILIZE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_stabilize(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_stabilize(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_reactivate(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('REACTIVATE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_reactivate(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_reactivate(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_close(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('CLOSE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_close(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_close(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_cancel(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command('CANCEL',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_cancel(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_cancel(uuid,uuid,uuid,bigint,jsonb) to authenticated;

-- A small exact-org entry/inbox read supports firefighters receiving nomination
-- consent without widening draft SELECT RLS or exposing a national directory.
create function public.incident_entry() returns jsonb
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
  where c.user_id=auth.uid() and c.status='REQUESTED' and c.expires_at>statement_timestamp() and i.status='DRAFT'
   and private.incident_acting_member(c.organization_id) order by c.created_at,c.id limit 50) q),'[]'));
end; $$;

create function public.incident_list(p_acting_organization_id uuid,p_status text default '',p_before_created timestamptz default null,p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.incident_acting_member(p_acting_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_status not in ('','DRAFT','ACTIVE','STABILIZED','CLOSED','CANCELLED') or (p_before_created is null)<>(p_before_id is null) then raise exception 'VALIDATION_FAILED'; end if;
 return coalesce((select jsonb_agg(q.dto order by q.created_at desc,q.id desc) from (
  select i.created_at,i.id,jsonb_build_object('id',i.id,'reference_number',i.reference_number,'title',i.title,'status',i.status,
   'priority',i.priority,'severity',i.severity,'created_at',i.created_at,'address',i.address,'lead_name',o.name,
   'type',jsonb_build_object('code',it.code,'names',it.names)) dto
  from public.incidents i join public.organizations o on o.id=i.lead_organization_id join public.incident_types it on it.id=i.incident_type_id
  where private.can_read_incident(i.id) and (p_status='' or i.status=p_status)
   and ((i.status='DRAFT' and private.incident_draft_manager(i.id,p_acting_organization_id)) or
    (i.status<>'DRAFT' and exists(select 1 from public.incident_participants ip where ip.incident_id=i.id and ip.organization_id=p_acting_organization_id
     and (ip.status='ACTIVE' or (i.status in ('CLOSED','CANCELLED') and ip.status='RELEASED')))))
   and (p_before_created is null or (i.created_at,i.id)<(p_before_created,p_before_id))
  order by i.created_at desc,i.id desc limit 25) q),'[]');
end; $$;

-- Preserve the existing signature/DTO fields, add scoped core presentation data.
create or replace function public.incident_context(p_incident_id uuid,p_acting_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_i public.incidents; v_manager boolean; v_command boolean; v_read boolean; v_dto jsonb;
begin
 if not private.incident_acting_member(p_acting_organization_id) or not private.can_read_incident(p_incident_id) then return null; end if;
 select * into v_i from public.incidents i where i.id=p_incident_id;
 v_manager:=private.incident_draft_manager(p_incident_id,p_acting_organization_id);
 v_read:=v_manager or (v_i.status<>'DRAFT' and exists(select 1 from public.incident_participants ip where ip.incident_id=p_incident_id and ip.organization_id=p_acting_organization_id
  and (ip.status='ACTIVE' or (v_i.status in ('CLOSED','CANCELLED') and ip.status='RELEASED'))));
 if not v_read then return null; end if;
 v_command:=private.has_incident_capability(p_incident_id,p_acting_organization_id,'CHANGE_LIFECYCLE');
 v_dto:=jsonb_build_object('contract_version',1,'id',v_i.id,'reference_number',v_i.reference_number,'title',v_i.title,'summary',v_i.summary,
 'incident_type_id',v_i.incident_type_id,'severity',v_i.severity,'priority',v_i.priority,'status',v_i.status,
 'lead_organization_id',v_i.lead_organization_id,'created_organization_id',v_i.created_organization_id,
 'latitude',v_i.latitude,'longitude',v_i.longitude,'address',v_i.address,'timezone',v_i.timezone,'unknown_location_reason',v_i.metadata->>'unknown_location_reason',
 'version',v_i.version::text,'revision',v_i.revision::text,'timeline_sequence',v_i.timeline_sequence::text,
 'updated_at',v_i.updated_at,'created_at',v_i.created_at,'started_at',v_i.started_at,'declared_at',v_i.declared_at,
 'stabilized_at',v_i.stabilized_at,'closed_at',v_i.closed_at,'cancelled_at',v_i.cancelled_at,'acting_organization_id',p_acting_organization_id,
 'lead_name',(select o.name from public.organizations o where o.id=v_i.lead_organization_id),
 'type',(select jsonb_build_object('id',it.id,'code',it.code,'names',it.names) from public.incident_types it where it.id=v_i.incident_type_id),
 'capabilities',coalesce((select jsonb_agg(c.code order by c.code) from unnest(array['EDIT_SUMMARY','INVITE_ORGANIZATION','ASSIGN_INCIDENT_ROLE','CHANGE_LIFECYCLE','TRANSFER_COMMAND']) c(code)
  where private.has_incident_capability(p_incident_id,p_acting_organization_id,c.code)),'[]'),
 'actions',jsonb_build_object('edit',v_manager or private.has_incident_capability(p_incident_id,p_acting_organization_id,'EDIT_SUMMARY'),
  'nominate',v_manager,'activate',v_manager and exists(select 1 from private.incident_command_consents c
   join public.profiles pr on pr.id=c.user_id and pr.account_status='ACTIVE'
   join public.user_organizations m on m.user_id=c.user_id and m.organization_id=c.organization_id
   where c.incident_id=p_incident_id and c.status='ACCEPTED' and c.expires_at>statement_timestamp()),
  'invite',v_manager or private.has_incident_capability(p_incident_id,p_acting_organization_id,'INVITE_ORGANIZATION'),
  'stabilize',v_command and v_i.status='ACTIVE','reactivate',v_command and v_i.status='STABILIZED',
  'close',v_command and v_i.status='STABILIZED','cancel',v_manager),
 'participants',coalesce((select jsonb_agg(jsonb_build_object('id',ip.id,'organization_id',ip.organization_id,'name',o.name,'status',ip.status,
  'agency_role',ip.agency_role,'accepted_at',ip.accepted_at,'ended_at',ip.ended_at,'end_reason',ip.end_reason,
  'can_consent_release',ip.status='ACTIVE' and ip.organization_id<>v_i.lead_organization_id and ip.organization_id=p_acting_organization_id
   and v_i.status in ('ACTIVE','STABILIZED') and private.has_organization_role(p_acting_organization_id,array['MANAGER','ADMIN']),
  'can_release',v_command and ip.status='ACTIVE' and ip.organization_id<>v_i.lead_organization_id and ip.release_consented_at is not null)
  order by ip.requested_at,ip.id) from public.incident_participants ip join public.organizations o on o.id=ip.organization_id where ip.incident_id=p_incident_id),'[]'),
 'nomination',(select jsonb_build_object('id',c.id,'user_id',c.user_id,'name',pr.display_name,'status',c.status,'expires_at',c.expires_at)
  from private.incident_command_consents c join public.profiles pr on pr.id=c.user_id where c.incident_id=p_incident_id and c.status in ('REQUESTED','ACCEPTED') limit 1),
 'commander',(select jsonb_build_object('id',a.id,'name',pr.display_name,'user_id',a.user_id,'status',a.status,'ended_at',a.ended_at,
  'valid',a.status='ACTIVE' and pr.account_status='ACTIVE' and o.active and ip.status='ACTIVE' and a.valid_from<=statement_timestamp()
   and (a.valid_until is null or a.valid_until>statement_timestamp()) and exists(select 1 from public.user_organizations m where m.user_id=a.user_id and m.organization_id=a.organization_id))
  from public.incident_role_assignments a join public.profiles pr on pr.id=a.user_id join public.organizations o on o.id=a.organization_id
  join public.incident_participants ip on ip.id=a.participation_id where a.incident_id=p_incident_id and a.role='INCIDENT_COMMANDER'
  order by a.created_at desc,a.id desc limit 1));
 return v_dto;
end; $$;

create function public.incident_candidates(p_incident_id uuid,p_acting_organization_id uuid,p_kind text,p_query text default '')
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_lead uuid;
begin
 if not (private.incident_draft_manager(p_incident_id,p_acting_organization_id) or
  (p_kind='ORGANIZATION' and private.has_incident_capability(p_incident_id,p_acting_organization_id,'INVITE_ORGANIZATION')))
  then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if length(p_query)>100 then raise exception 'VALIDATION_FAILED'; end if;
 if p_kind='ORGANIZATION' then
  return coalesce((select jsonb_agg(q.dto order by q.name,q.id) from (
   select o.id,o.name,jsonb_build_object('id',o.id,'name',o.name) dto from public.organizations o where o.active
   and position(lower(p_query) in lower(o.name))>0 and not exists(select 1 from public.incident_participants ip
    where ip.incident_id=p_incident_id and ip.organization_id=o.id and ip.status in ('REQUESTED','ACTIVE'))
   order by o.name,o.id limit 30) q),'[]');
 elsif p_kind='MEMBER' then
  select i.lead_organization_id into v_lead from public.incidents i where i.id=p_incident_id;
  return coalesce((select jsonb_agg(q.dto order by q.display_name,q.id) from (
   select pr.id,pr.display_name,jsonb_build_object('id',pr.id,'name',coalesce(pr.display_name,pr.id::text)) dto
   from public.user_organizations m join public.profiles pr on pr.id=m.user_id and pr.account_status='ACTIVE'
   where m.organization_id=v_lead and position(lower(p_query) in lower(coalesce(pr.display_name,'')))>0
   order by pr.display_name,pr.id limit 30) q),'[]');
 else raise exception 'VALIDATION_FAILED'; end if;
end; $$;
revoke all on function public.incident_entry(),public.incident_list(uuid,text,timestamptz,uuid),public.incident_context(uuid,uuid),public.incident_candidates(uuid,uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function public.incident_entry(),public.incident_list(uuid,text,timestamptz,uuid),public.incident_context(uuid,uuid),public.incident_candidates(uuid,uuid,text,text) to authenticated;

-- Preserve M14.0 keyset behavior; explicit actor labels avoid per-event profile
-- reads and do not widen profile RLS. BIGINT cursors are decimal text on the wire.
create or replace function public.incident_timeline_page(p_incident_id uuid,p_acting_organization_id uuid,
 p_after_sequence bigint default 0,p_limit integer default 100)
returns jsonb language sql stable security definer set search_path='' as $$
 select case when public.incident_context(p_incident_id,p_acting_organization_id) is null then null else
 jsonb_build_object('contract_version',1,'incident_id',p_incident_id,
 'events',coalesce((select jsonb_agg(e.dto order by e.sequence) from (
  select it.sequence,jsonb_build_object('id',it.id,'sequence',it.sequence::text,'revision',it.revision::text,
   'operation_id',it.operation_id,'event_ordinal',it.event_ordinal,'event_code',it.event_code,
   'actor_user_id',it.actor_user_id,'actor_name',pr.display_name,'actor_organization_id',it.actor_organization_id,'actor_organization_name',o.name,
   'subject_name',coalesce(subject_org.name,assigned_profile.display_name,nominee.display_name),
   'participation_id',it.participation_id,'assignment_id',it.assignment_id,'recorded_at',it.recorded_at,'occurred_at',it.occurred_at,'data',it.data) dto
  from public.incident_timeline it join public.profiles pr on pr.id=it.actor_user_id join public.organizations o on o.id=it.actor_organization_id
  left join public.incident_participants ip on ip.id=it.participation_id left join public.organizations subject_org on subject_org.id=ip.organization_id
  left join public.incident_role_assignments a on a.id=it.assignment_id left join public.profiles assigned_profile on assigned_profile.id=a.user_id
  left join public.profiles nominee on nominee.id::text=it.data->>'user_id'
  where it.incident_id=p_incident_id and it.sequence>greatest(coalesce(p_after_sequence,0),0)
  order by it.sequence limit least(greatest(coalesce(p_limit,100),1),200)) e),'[]'),
 'high_watermark',(select i.timeline_sequence::text from public.incidents i where i.id=p_incident_id)) end;
$$;
revoke all on function public.incident_timeline_page(uuid,uuid,bigint,integer) from public,anon,authenticated,service_role;
grant execute on function public.incident_timeline_page(uuid,uuid,bigint,integer) to authenticated;
