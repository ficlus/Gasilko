-- Target-aware operational authority. Organization inventory roles never grant it.
create function private.can_manage_incident_unit(p_incident uuid,p_org uuid,p_owner uuid,p_unit uuid,p_action text) returns boolean
language sql volatile security definer set search_path='' as $$
 select private.incident_acting_member(p_org) and public.incident_context(p_incident,p_org) is not null
 and exists(select 1 from public.incident_participants ip join public.organizations o on o.id=ip.organization_id and o.active
 where ip.incident_id=p_incident and ip.organization_id=p_owner and ip.status='ACTIVE')
 and exists(select 1 from public.incident_role_assignments a where a.incident_id=p_incident and a.organization_id=p_org and a.user_id=auth.uid()
 and private.incident_assignment_effective(a.id) and (
 a.role='INCIDENT_COMMANDER' or (a.role='AGENCY_COMMANDER' and a.organization_id=p_owner)
 or (p_action in ('STATUS','CREW','RESOURCE_TRANSITION') and exists(select 1 from public.incident_units d
 where d.id=p_unit and d.incident_id=p_incident and d.organization_id=p_owner and d.status not in ('RELEASED','UNAVAILABLE')
 and ((a.role='SECTOR_COMMANDER' and a.sector_id=d.sector_id) or (a.role='UNIT_LEADER' and a.unit_assignment_id=d.id))))));
$$;
create function private.can_manage_incident_resource(p_incident uuid,p_org uuid,p_allocation uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select exists(select 1 from public.incident_resource_allocations a where a.id=p_allocation and a.incident_id=p_incident
 and private.can_manage_incident_unit(p_incident,p_org,a.organization_id,a.unit_assignment_id,'RESOURCE_TRANSITION'));
$$;
-- A single guard is also reused before M14.2 closure ends command episodes.
create function private.incident_resources_open(p_incident uuid,p_owner uuid default null) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.incident_units d where d.incident_id=p_incident and (p_owner is null or d.organization_id=p_owner) and d.status not in ('RELEASED','UNAVAILABLE'))
 or exists(select 1 from public.incident_crew_members c where c.incident_id=p_incident and (p_owner is null or c.membership_organization_id=p_owner) and c.status='ACTIVE')
 or exists(select 1 from public.incident_resource_allocations a where a.incident_id=p_incident and (p_owner is null or a.organization_id=p_owner) and a.status in ('RESERVED','DEPLOYED'))
 or exists(select 1 from public.incident_role_assignments a where a.incident_id=p_incident and (p_owner is null or a.organization_id=p_owner) and a.role='UNIT_LEADER' and a.status='ACTIVE');
$$;
create function private.guard_incident_resource_lifecycle() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='incident_participants' then
  if old.status='ACTIVE' and new.status<>'ACTIVE' and private.incident_resources_open(old.incident_id,old.organization_id) then raise exception 'PARTICIPANT_HAS_ACTIVE_RESOURCES'; end if;
 elsif tg_table_name='incidents' then
  if new.status in ('CLOSED','CANCELLED') and old.status<>new.status and private.incident_resources_open(old.id) then raise exception 'INCIDENT_HAS_ACTIVE_RESOURCES'; end if;
 elsif tg_table_name='incident_sectors' then
  if old.active and not new.active and exists(select 1 from public.incident_units d where d.sector_id=old.id and d.status not in ('RELEASED','UNAVAILABLE')) then raise exception 'SECTOR_HAS_ACTIVE_UNITS'; end if;
 end if;
 return new;
end; $$;
create trigger incident_participant_resources_guard before update on public.incident_participants for each row execute function private.guard_incident_resource_lifecycle();
create trigger incident_close_resources_guard before update on public.incidents for each row execute function private.guard_incident_resource_lifecycle();
create trigger incident_sector_units_guard before update on public.incident_sectors for each row execute function private.guard_incident_resource_lifecycle();
create or replace function private.finish_incident_command(p_incident uuid,p_actor uuid,p_now timestamptz,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_ids jsonb;
begin
 if private.incident_resources_open(p_incident) then raise exception 'INCIDENT_HAS_ACTIVE_RESOURCES'; end if;
 with ended as (update public.incident_role_assignments a set status='ENDED',valid_until=least(a.valid_until,p_now),ended_by=p_actor,ended_at=p_now,
 end_reason=p_reason,updated_at=p_now,version=a.version+1 where a.incident_id=p_incident and a.status='ACTIVE' returning a.id)
 select coalesce(jsonb_agg(e.id),'[]') into v_ids from ended e;
 update private.incident_command_consents c set status='CANCELLED',ended_at=p_now,decided_by=p_actor where c.incident_id=p_incident and c.kind<>'INITIAL' and c.status in ('REQUESTED','ACCEPTED');
 return v_ids;
end; $$;
alter table public.incident_timeline
 add column unit_assignment_id uuid,add column crew_member_id uuid,add column resource_allocation_id uuid,
 add constraint timeline_unit_fk foreign key(unit_assignment_id,incident_id) references public.incident_units(id,incident_id),
 add constraint timeline_crew_fk foreign key(crew_member_id,incident_id) references public.incident_crew_members(id,incident_id),
 add constraint timeline_allocation_fk foreign key(resource_allocation_id,incident_id) references public.incident_resource_allocations(id,incident_id),
 add constraint timeline_typed_subject check(num_nonnulls(participation_id,assignment_id,unit_assignment_id,crew_member_id,resource_allocation_id)<=1);
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
 'LEAD_ORGANIZATION_CHANGED','COMMAND_RECOVERY_REQUESTED','COMMAND_RECOVERY_ASSIGNED','SECTOR_CREATED','SECTOR_UPDATED','SECTOR_DEACTIVATED','MAP_OBJECT_CREATED','MAP_OBJECT_UPDATED','MAP_OBJECT_DEACTIVATED','HYDRANT_LINKED','HYDRANT_UNLINKED','UNIT_ASSIGNED','UNIT_STATUS_CHANGED','UNIT_SECTOR_CHANGED','UNIT_RELEASED','CREW_JOINED','CREW_LEFT','RESOURCE_ALLOCATED','RESOURCE_DEPLOYED','RESOURCE_RETURNED','RESOURCE_CONSUMED','RESOURCE_CANCELLED') or auth.uid() is null then
 raise exception 'VALIDATION_FAILED'; end if;
 update public.incidents i set revision=i.revision+case when p_ordinal=1 then 1 else 0 end,
 timeline_sequence=i.timeline_sequence+1,updated_at=clock_timestamp() where i.id=p_incident
 returning i.revision,i.timeline_sequence into v_revision,v_sequence;
 insert into public.incident_timeline(incident_id,sequence,revision,operation_id,event_ordinal,event_code,
 actor_user_id,actor_organization_id,participation_id,assignment_id,unit_assignment_id,crew_member_id,resource_allocation_id,data)
 values(p_incident,v_sequence,v_revision,p_operation,p_ordinal,p_code,auth.uid(),p_org,p_participation,p_assignment,
 case when p_code in ('UNIT_ASSIGNED','UNIT_STATUS_CHANGED','UNIT_SECTOR_CHANGED','UNIT_RELEASED') then (p_data->>'unit_assignment_id')::uuid end,
 case when p_code in ('CREW_JOINED','CREW_LEFT') then (p_data->>'crew_member_id')::uuid end,
 case when p_code in ('RESOURCE_ALLOCATED','RESOURCE_DEPLOYED','RESOURCE_RETURNED','RESOURCE_CONSUMED','RESOURCE_CANCELLED') then (p_data->>'resource_allocation_id')::uuid end,p_data);
end; $$;
create function private.incident_resource_command(p_action text,p_operation uuid,p_org uuid,p_incident uuid,p_expected bigint,p_payload jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare actor_id uuid:=auth.uid();lock_org uuid;lock_profile uuid;incident_row public.incidents;receipt_row private.incident_operation_receipts;
 request_value jsonb;result_value jsonb;allowed_keys text[];entity_id uuid;expected_entity_version bigint;
 inventory_unit_row public.operational_units;incident_unit_row public.incident_units;crew_row public.incident_crew_members;
 resource_row public.operational_resources;allocation_row public.incident_resource_allocations;
 target_owner uuid;target_user uuid;target_unit uuid;target_resource uuid;target_sector uuid;participant_id_value uuid;
 event_value text;event_data jsonb;target_status text;reason_value text;quantity_value numeric;live_quantity numeric;revision_value bigint;now_value timestamptz;
 crew_ended record;ordinal_value smallint:=1;
begin
 if actor_id is null or not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_operation is null or p_org is null or p_incident is null or jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>8192 then raise exception 'VALIDATION_FAILED'; end if;
 allowed_keys:=case p_action when 'DEPLOY' then array['id','unit_id','sector_id']
 when 'STATUS' then array['id','version','status','reason','end_crew']
 when 'SECTOR' then array['id','version','sector_id']
 when 'CREW_JOIN' then array['id','unit_assignment_id','user_id','crew_role']
 when 'CREW_LEAVE' then array['id','version']
 when 'ALLOCATE' then array['id','resource_id','unit_assignment_id','quantity']
 when 'RESOURCE_TRANSITION' then array['id','version','status'] else array[]::text[] end;
 if exists(select 1 from jsonb_each(p_payload) f where not(f.key=any(allowed_keys)) or jsonb_typeof(f.value) not in ('string','null')) then raise exception 'VALIDATION_FAILED'; end if;
 entity_id:=(p_payload->>'id')::uuid;expected_entity_version:=(p_payload->>'version')::bigint;
 target_user:=(p_payload->>'user_id')::uuid;target_unit:=(p_payload->>'unit_assignment_id')::uuid;target_resource:=(p_payload->>'resource_id')::uuid;
 target_sector:=(p_payload->>'sector_id')::uuid;target_status:=p_payload->>'status';reason_value:=btrim(coalesce(p_payload->>'reason',''));
 if entity_id is null or length(reason_value)>2000 then raise exception 'VALIDATION_FAILED'; end if;
 request_value:=jsonb_build_object('command','RESOURCE_'||p_action,'org',p_org,'incident',p_incident,'expected',p_expected,'payload',p_payload);
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 -- Include a requested inventory owner before row locks, even when invalid for this incident.
 if p_action='DEPLOY' then select u.organization_id into target_owner from public.operational_units u where u.id=(p_payload->>'unit_id')::uuid;
 elsif p_action='ALLOCATE' then select r.organization_id into target_owner from public.operational_resources r where r.id=target_resource; end if;
 for lock_org in select distinct q.org from(select p_org org union all select target_owner union all
 select ip.organization_id from public.incident_participants ip where ip.incident_id=p_incident) q where q.org is not null order by q.org loop
  perform private.lock_organization(lock_org);perform 1 from public.organizations o where o.id=lock_org for share;
 end loop;
 for lock_profile in select distinct q.person from(select actor_id person union all select target_user union all
 select c.user_id from public.incident_crew_members c where c.incident_id=p_incident and c.status='ACTIVE' union all
 select a.user_id from public.incident_role_assignments a where a.incident_id=p_incident and a.status='ACTIVE') q where q.person is not null order by q.person loop
  perform 1 from public.profiles pr where pr.id=lock_profile for share;
 end loop;
 if not private.incident_acting_member(p_org) or public.incident_context(p_incident,p_org) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into receipt_row from private.incident_operation_receipts r where r.operation_id=p_operation;
 if found then
  if receipt_row.actor_user_id<>actor_id or receipt_row.request is distinct from request_value then raise exception 'OPERATION_REUSED'; end if;
  return receipt_row.result;
 end if;
 select * into incident_row from public.incidents i where i.id=p_incident for update;
 if incident_row.status not in ('ACTIVE','STABILIZED') then raise exception 'INCIDENT_TERMINAL'; end if;
 if incident_row.version is distinct from p_expected then raise exception 'STALE_VERSION'; end if;
 revision_value:=incident_row.revision+1;now_value:=clock_timestamp();
 if p_action='DEPLOY' then
  select * into inventory_unit_row from public.operational_units u where u.id=(p_payload->>'unit_id')::uuid for update;
  if not found or not inventory_unit_row.active then raise exception 'INVALID_UNIT'; end if;
  target_owner:=inventory_unit_row.organization_id;
  if not private.can_manage_incident_unit(p_incident,p_org,target_owner,null,'DEPLOY') then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if inventory_unit_row.vehicle_id is not null then
   perform 1 from public.operational_vehicles v where v.id=inventory_unit_row.vehicle_id and v.organization_id=target_owner and v.active and v.availability='AVAILABLE' for share;
   if not found then raise exception 'INVALID_VEHICLE'; end if;
   if exists(select 1 from public.incident_units d join public.operational_units u on u.id=d.unit_id where u.vehicle_id=inventory_unit_row.vehicle_id and d.status not in ('RELEASED','UNAVAILABLE')) then raise exception 'VEHICLE_DEPLOYED'; end if;
  end if;
  if exists(select 1 from public.incident_units d where d.unit_id=inventory_unit_row.id and d.status not in ('RELEASED','UNAVAILABLE')) then raise exception 'UNIT_ALREADY_DEPLOYED'; end if;
  if (select count(*) from public.incident_units d where d.incident_id=p_incident and d.status not in ('RELEASED','UNAVAILABLE'))>=500 then raise exception 'RESOURCE_LIMIT_REACHED'; end if;
  if target_sector is not null and not exists(select 1 from public.incident_sectors se where se.id=target_sector and se.incident_id=p_incident and se.active) then raise exception 'INVALID_SECTOR'; end if;
  select ip.id into participant_id_value from public.incident_participants ip where ip.incident_id=p_incident and ip.organization_id=target_owner and ip.status='ACTIVE';
  insert into public.incident_units(id,incident_id,participation_id,organization_id,unit_id,sector_id,status,assigned_by,changed_revision)
  values(entity_id,p_incident,participant_id_value,target_owner,inventory_unit_row.id,target_sector,'ON_SCENE',actor_id,revision_value);
  event_value:='UNIT_ASSIGNED';event_data:=jsonb_build_object('unit_assignment_id',entity_id,'unit_id',inventory_unit_row.id,'status','ON_SCENE','sector_id',target_sector);
 elsif p_action in ('STATUS','SECTOR','CREW_JOIN','CREW_LEAVE') then
  if p_action='CREW_LEAVE' then
   select * into crew_row from public.incident_crew_members c where c.id=entity_id and c.incident_id=p_incident;
   if not found or crew_row.status<>'ACTIVE' then raise exception 'INVALID_CREW_MEMBER'; end if;
   target_unit:=crew_row.unit_assignment_id;
  elsif p_action in ('STATUS','SECTOR') then target_unit:=entity_id; end if;
  select * into incident_unit_row from public.incident_units d where d.id=target_unit and d.incident_id=p_incident for update;
  if not found or incident_unit_row.status in ('RELEASED','UNAVAILABLE') then raise exception 'INVALID_UNIT'; end if;
  if not private.can_manage_incident_unit(p_incident,p_org,incident_unit_row.organization_id,target_unit,case when p_action like 'CREW_%' then 'CREW' else p_action end) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if p_action in ('STATUS','SECTOR') and incident_unit_row.version is distinct from expected_entity_version then raise exception 'STALE_VERSION'; end if;
  if p_action='SECTOR' then
   if not(p_payload ? 'sector_id') then raise exception 'VALIDATION_FAILED'; end if;
   if target_sector is not null and not exists(select 1 from public.incident_sectors se where se.id=target_sector and se.incident_id=p_incident and se.active) then raise exception 'INVALID_SECTOR'; end if;
   update public.incident_units d set sector_id=target_sector,version=d.version+1,changed_revision=revision_value where d.id=entity_id;
   event_value:='UNIT_SECTOR_CHANGED';event_data:=jsonb_build_object('unit_assignment_id',entity_id,'from_sector_id',incident_unit_row.sector_id,'sector_id',target_sector);
  elsif p_action='STATUS' then
   if target_status is null or not ((incident_unit_row.status='ON_SCENE' and target_status in ('RETURNING','UNAVAILABLE')) or (incident_unit_row.status='RETURNING' and target_status in ('RELEASED','UNAVAILABLE'))) then raise exception 'INVALID_UNIT_STATUS'; end if;
   if target_status='UNAVAILABLE' and reason_value='' then raise exception 'VALIDATION_FAILED'; end if;
   if target_status in ('RELEASED','UNAVAILABLE') then
    if exists(select 1 from public.incident_role_assignments a where a.unit_assignment_id=entity_id and a.status='ACTIVE') then raise exception 'UNIT_HAS_ACTIVE_COMMAND'; end if;
    if exists(select 1 from public.incident_resource_allocations a where a.unit_assignment_id=entity_id and a.status in ('RESERVED','DEPLOYED')) then raise exception 'RESOURCE_IN_USE'; end if;
    if p_payload->>'end_crew' is distinct from 'CONFIRMED' then raise exception 'UNIT_HAS_ACTIVE_CREW'; end if;
   end if;
   update public.incident_units d set status=target_status,status_changed_at=now_value,
    released_by=case when target_status in ('RELEASED','UNAVAILABLE') then actor_id end,released_at=case when target_status in ('RELEASED','UNAVAILABLE') then now_value end,
    end_reason=nullif(reason_value,''),version=d.version+1,changed_revision=revision_value where d.id=entity_id;
   event_value:=case when target_status='RELEASED' then 'UNIT_RELEASED' else 'UNIT_STATUS_CHANGED' end;
   event_data:=jsonb_build_object('unit_assignment_id',entity_id,'from_status',incident_unit_row.status,'status',target_status,'reason',nullif(reason_value,''));
  elsif p_action='CREW_JOIN' then
   if not exists(select 1 from public.profiles pr join public.user_organizations m on m.user_id=pr.id where pr.id=target_user and pr.account_status='ACTIVE' and m.organization_id=incident_unit_row.organization_id) then raise exception 'INVALID_CREW_MEMBER'; end if;
   if (select count(*) from public.incident_crew_members c where c.unit_assignment_id=target_unit and c.status='ACTIVE')>=50 then raise exception 'RESOURCE_LIMIT_REACHED'; end if;
   insert into public.incident_crew_members(id,incident_id,unit_assignment_id,user_id,membership_organization_id,crew_role,added_by,changed_revision)
    values(entity_id,p_incident,target_unit,target_user,incident_unit_row.organization_id,p_payload->>'crew_role',actor_id,revision_value);
   event_value:='CREW_JOINED';event_data:=jsonb_build_object('crew_member_id',entity_id,'unit_assignment_id',target_unit,'user_id',target_user,'crew_role',p_payload->>'crew_role');
  else
   select * into crew_row from public.incident_crew_members c where c.id=entity_id for update;
   if crew_row.version is distinct from expected_entity_version then raise exception 'STALE_VERSION'; end if;
   if exists(select 1 from public.incident_role_assignments a where a.unit_assignment_id=target_unit and a.user_id=crew_row.user_id and a.status='ACTIVE' and a.role='UNIT_LEADER') then raise exception 'UNIT_HAS_ACTIVE_COMMAND'; end if;
   update public.incident_crew_members c set status='LEFT',left_at=now_value,left_by=actor_id,version=c.version+1,changed_revision=revision_value where c.id=entity_id;
   event_value:='CREW_LEFT';event_data:=jsonb_build_object('crew_member_id',entity_id,'unit_assignment_id',target_unit,'user_id',crew_row.user_id);
  end if;
 elsif p_action in ('ALLOCATE','RESOURCE_TRANSITION') then
  if p_action='RESOURCE_TRANSITION' then
   select * into allocation_row from public.incident_resource_allocations a where a.id=entity_id and a.incident_id=p_incident;
   if not found then raise exception 'INVALID_RESOURCE'; end if;target_resource:=allocation_row.resource_id;
  end if;
  select * into resource_row from public.operational_resources r where r.id=target_resource for update;
  if not found then raise exception 'INVALID_RESOURCE'; end if;
  if p_action='ALLOCATE' then
   if not resource_row.active or not private.can_manage_incident_unit(p_incident,p_org,resource_row.organization_id,null,'ALLOCATE') then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if target_unit is not null and not exists(select 1 from public.incident_units d where d.id=target_unit and d.incident_id=p_incident and d.organization_id=resource_row.organization_id and d.status not in ('RELEASED','UNAVAILABLE')) then raise exception 'INVALID_UNIT'; end if;
   quantity_value:=(p_payload->>'quantity')::numeric;
   if quantity_value is null or not(quantity_value>0 and quantity_value<1000000000000 and scale(quantity_value)<=3) then raise exception 'VALIDATION_FAILED'; end if;
   select coalesce(sum(a.quantity),0) into live_quantity from public.incident_resource_allocations a where a.resource_id=target_resource and a.status in ('RESERVED','DEPLOYED');
   if quantity_value>resource_row.total_quantity-live_quantity then raise exception 'INSUFFICIENT_RESOURCE_QUANTITY'; end if;
   if (select count(*) from public.incident_resource_allocations a where a.incident_id=p_incident and a.status in ('RESERVED','DEPLOYED'))>=2000 then raise exception 'RESOURCE_LIMIT_REACHED'; end if;
   select ip.id into participant_id_value from public.incident_participants ip where ip.incident_id=p_incident and ip.organization_id=resource_row.organization_id and ip.status='ACTIVE';
   insert into public.incident_resource_allocations(id,incident_id,resource_id,participant_id,organization_id,quantity,unit_assignment_id,status,allocated_by,changed_revision)
    values(entity_id,p_incident,target_resource,participant_id_value,resource_row.organization_id,quantity_value,target_unit,'RESERVED',actor_id,revision_value);
   event_value:='RESOURCE_ALLOCATED';event_data:=jsonb_build_object('resource_allocation_id',entity_id,'resource_id',target_resource,'quantity',quantity_value::text,'unit_assignment_id',target_unit);
  else
   select * into allocation_row from public.incident_resource_allocations a where a.id=entity_id for update;
   if not private.can_manage_incident_resource(p_incident,p_org,entity_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if allocation_row.version is distinct from expected_entity_version then raise exception 'STALE_VERSION'; end if;
   if target_status is null or not((allocation_row.status='RESERVED' and target_status in ('DEPLOYED','CANCELLED')) or (allocation_row.status='DEPLOYED' and target_status in ('RETURNED','CONSUMED'))) then raise exception 'INVALID_RESOURCE_STATUS'; end if;
   if target_status='CONSUMED' then
    update public.operational_resources r set total_quantity=r.total_quantity-allocation_row.quantity,version=r.version+1,updated_at=now_value,updated_by=actor_id where r.id=target_resource;
    perform private.write_audit(resource_row.organization_id,actor_id,'RESOURCE_STOCK_CONSUMED','operational_resources',target_resource,jsonb_build_object('quantity',resource_row.total_quantity::text,'version',resource_row.version::text),jsonb_build_object('quantity',(resource_row.total_quantity-allocation_row.quantity)::text,'version',(resource_row.version+1)::text,'allocation_id',entity_id,'operation_id',p_operation));
   end if;
   update public.incident_resource_allocations a set status=target_status,version=a.version+1,changed_revision=revision_value,
    ended_at=case when target_status in ('RETURNED','CONSUMED','CANCELLED') then now_value end,ended_by=case when target_status in ('RETURNED','CONSUMED','CANCELLED') then actor_id end where a.id=entity_id;
   event_value:='RESOURCE_'||target_status;event_data:=jsonb_build_object('resource_allocation_id',entity_id,'resource_id',target_resource,'quantity',allocation_row.quantity::text,'from_status',allocation_row.status,'status',target_status);
  end if;
 else raise exception 'VALIDATION_FAILED'; end if;
 update public.incidents i set version=i.version+1 where i.id=p_incident;
 perform private.append_incident_event(p_incident,p_org,p_operation,ordinal_value,event_value,event_data);
 if p_action='STATUS' and target_status in ('RELEASED','UNAVAILABLE') then
  for crew_ended in update public.incident_crew_members c set status='LEFT',left_at=now_value,left_by=actor_id,version=c.version+1,changed_revision=revision_value
   where c.unit_assignment_id=entity_id and c.status='ACTIVE' returning c.id,c.user_id loop
   ordinal_value:=ordinal_value+1;
   perform private.append_incident_event(p_incident,p_org,p_operation,ordinal_value,'CREW_LEFT',jsonb_build_object('crew_member_id',crew_ended.id,'unit_assignment_id',entity_id,'user_id',crew_ended.user_id,'reason','UNIT_TERMINAL'));
  end loop;
 end if;
 select jsonb_build_object('incident_id',i.id,'operation_id',p_operation,'version',i.version::text,'revision',i.revision::text,'timeline_sequence',i.timeline_sequence::text) into result_value from public.incidents i where i.id=p_incident;
 perform private.write_audit(p_org,actor_id,event_value,'incidents',p_incident,null,jsonb_build_object('operation_id',p_operation,'event',event_data,'result',result_value));
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,actor_id,p_org,p_incident,'RESOURCE_'||p_action,request_value,result_value);
 return result_value;
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation then raise exception 'VALIDATION_FAILED';
 when unique_violation then
  if p_action='DEPLOY' then raise exception 'UNIT_ALREADY_DEPLOYED'; elsif p_action='CREW_JOIN' then raise exception 'INVALID_CREW_MEMBER'; else raise exception 'OPERATION_REUSED'; end if;
end; $$;
create function public.incident_deploy_unit(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.incident_resource_command('DEPLOY',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload); $$;
revoke all on function public.incident_deploy_unit(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_deploy_unit(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_update_unit_status(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.incident_resource_command('STATUS',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload); $$;
revoke all on function public.incident_update_unit_status(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_update_unit_status(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_assign_unit_sector(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.incident_resource_command('SECTOR',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload); $$;
revoke all on function public.incident_assign_unit_sector(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_assign_unit_sector(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_add_crew_member(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.incident_resource_command('CREW_JOIN',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload); $$;
revoke all on function public.incident_add_crew_member(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_add_crew_member(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_remove_crew_member(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.incident_resource_command('CREW_LEAVE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload); $$;
revoke all on function public.incident_remove_crew_member(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_remove_crew_member(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_allocate_resource(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.incident_resource_command('ALLOCATE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload); $$;
revoke all on function public.incident_allocate_resource(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_allocate_resource(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_transition_resource_allocation(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.incident_resource_command('RESOURCE_TRANSITION',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload); $$;
revoke all on function public.incident_transition_resource_allocation(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_transition_resource_allocation(uuid,uuid,uuid,bigint,jsonb) to authenticated;
revoke all on function private.can_manage_incident_unit(uuid,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function private.can_manage_incident_resource(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.incident_resources_open(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.guard_incident_resource_lifecycle() from public,anon,authenticated,service_role;
revoke all on function private.incident_resource_command(text,uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
