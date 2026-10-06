-- Narrow public API follows the command transaction migration.

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
   where c.incident_id=p_incident_id and c.kind='INITIAL' and c.status='ACCEPTED' and c.expires_at>statement_timestamp()),
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
  from private.incident_command_consents c join public.profiles pr on pr.id=c.user_id where c.incident_id=p_incident_id and c.kind='INITIAL' and c.status in ('REQUESTED','ACCEPTED') limit 1),
 'commander',(select jsonb_build_object('id',a.id,'name',pr.display_name,'user_id',a.user_id,'status',a.status,'ended_at',a.ended_at,
  'valid',a.status='ACTIVE' and pr.account_status='ACTIVE' and o.active and ip.status='ACTIVE' and a.valid_from<=statement_timestamp()
   and (a.valid_until is null or a.valid_until>statement_timestamp()) and exists(select 1 from public.user_organizations m where m.user_id=a.user_id and m.organization_id=a.organization_id))
  from public.incident_role_assignments a join public.profiles pr on pr.id=a.user_id join public.organizations o on o.id=a.organization_id
  join public.incident_participants ip on ip.id=a.participation_id where a.incident_id=p_incident_id and a.role='INCIDENT_COMMANDER'
  order by a.created_at desc,a.id desc limit 1));
 return v_dto;
end; $$;


create function public.incident_offer_role(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command_structure('OFFER',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_offer_role(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_offer_role(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_end_role(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command_structure('END',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_end_role(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_end_role(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_request_command_transfer(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command_structure('TRANSFER',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_request_command_transfer(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_request_command_transfer(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_request_command_recovery(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command_structure('RECOVERY',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_request_command_recovery(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_request_command_recovery(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_accept_command_request(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command_structure('ACCEPT',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_accept_command_request(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_accept_command_request(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_decline_command_request(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command_structure('DECLINE',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_decline_command_request(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_decline_command_request(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_cancel_command_request(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command_structure('CANCEL',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_cancel_command_request(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_cancel_command_request(uuid,uuid,uuid,bigint,jsonb) to authenticated;
create function public.incident_consent_lead_transfer(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb)
returns jsonb language sql volatile security definer set search_path='' as $$
 select private.incident_command_structure('LEAD_CONSENT',p_operation,p_acting_organization_id,p_incident_id,p_expected_version,p_payload);
$$;
revoke all on function public.incident_consent_lead_transfer(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_consent_lead_transfer(uuid,uuid,uuid,bigint,jsonb) to authenticated;

create function public.incident_command_candidates(p_incident_id uuid,p_acting_organization_id uuid,p_organization_id uuid,p_role text,p_query text default '')
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_i public.incidents; v_recovery boolean;
begin
 if public.incident_context(p_incident_id,p_acting_organization_id) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into v_i from public.incidents i where i.id=p_incident_id;
 v_recovery:=v_i.lead_organization_id=p_acting_organization_id and private.has_organization_role(p_acting_organization_id,array['MANAGER','ADMIN'])
  and not exists(select 1 from public.incident_role_assignments a where a.incident_id=p_incident_id and a.role='INCIDENT_COMMANDER' and private.incident_assignment_effective(a.id));
 if v_i.status not in ('ACTIVE','STABILIZED') or not (private.has_incident_capability(p_incident_id,p_acting_organization_id,'ASSIGN_INCIDENT_ROLE')
  or (v_recovery and p_role='INCIDENT_COMMANDER' and p_organization_id=v_i.lead_organization_id)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_role not in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER','AGENCY_COMMANDER') or length(p_query)>100 then raise exception 'INVALID_COMMAND_ROLE'; end if;
 return coalesce((select jsonb_agg(q.dto order by q.display_name,q.id) from (
  select pr.id,pr.display_name,jsonb_build_object('id',pr.id,'name',coalesce(pr.display_name,pr.id::text),'organization_id',o.id,'organization_name',o.name) dto
  from public.user_organizations m join public.profiles pr on pr.id=m.user_id and pr.account_status='ACTIVE'
  join public.organizations o on o.id=m.organization_id and o.active
  where m.organization_id=p_organization_id and exists(select 1 from public.incident_participants ip where ip.incident_id=p_incident_id and ip.organization_id=o.id and ip.status='ACTIVE')
  and position(lower(p_query) in lower(coalesce(pr.display_name,'')))>0 order by pr.display_name,pr.id limit 30) q),'[]');
end; $$;

create function private.incident_command_request_dto(p_request private.incident_command_consents,p_org uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p_request.id,'incident_id',p_request.incident_id,'organization_id',p_request.organization_id,
 'organization_name',(select o.name from public.organizations o where o.id=p_request.organization_id),
 'outgoing_name',(select pr.display_name from public.incident_role_assignments a join public.profiles pr on pr.id=a.user_id where a.id=p_request.outgoing_assignment_id),
 'lead_name',(select o.name from public.incidents i join public.organizations o on o.id=i.lead_organization_id where i.id=p_request.incident_id),
 'name',(select pr.display_name from public.profiles pr where pr.id=p_request.user_id),
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
revoke all on function private.incident_command_request_dto(private.incident_command_consents,uuid) from public,anon,authenticated,service_role;

create function public.incident_command_view(p_incident_id uuid,p_acting_organization_id uuid,p_before_created timestamptz default null,p_before_id uuid default null)
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
 'roles',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'user_id',a.user_id,'name',pr.display_name,'organization_id',a.organization_id,'organization_name',o.name,
  'role',a.role,'parent_id',a.parent_assignment_id,'valid',private.incident_assignment_effective(a.id),'created_at',a.created_at,
  'can_end',v_can_assign
   and a.role<>'INCIDENT_COMMANDER' and not exists(select 1 from public.incident_role_assignments child where child.parent_assignment_id=a.id and child.status='ACTIVE')) order by a.role,o.name,a.id)
  from public.incident_role_assignments a join public.profiles pr on pr.id=a.user_id join public.organizations o on o.id=a.organization_id where a.incident_id=p_incident_id and a.status='ACTIVE'),'[]'),
 'history',coalesce((select jsonb_agg(q.dto order by q.created_at desc,q.id desc) from (
  select a.created_at,a.id,jsonb_build_object('id',a.id,'name',pr.display_name,'organization_name',o.name,'role',a.role,'status',a.status,
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

create function public.incident_command_inbox() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(q.dto order by q.created_at,q.id) from (
  select c.id,c.created_at,private.incident_command_request_dto(c,c.organization_id)||jsonb_build_object('title',i.title,'reference_number',i.reference_number) dto
  from private.incident_command_consents c join public.incidents i on i.id=c.incident_id
  where c.kind<>'INITIAL' and c.status='REQUESTED' and c.expires_at>statement_timestamp() and i.status in ('ACTIVE','STABILIZED')
   and private.incident_acting_member(c.organization_id) and public.incident_context(i.id,c.organization_id) is not null
   and (c.user_id=auth.uid() or (c.transfer_lead and c.lead_consented_at is null and private.has_organization_role(c.organization_id,array['MANAGER','ADMIN'])))
  order by c.created_at,c.id limit 50) q),'[]');
end; $$;
revoke all on function public.incident_command_candidates(uuid,uuid,uuid,text,text),public.incident_command_view(uuid,uuid,timestamptz,uuid),public.incident_command_inbox() from public,anon,authenticated,service_role;
grant execute on function public.incident_command_candidates(uuid,uuid,uuid,text,text),public.incident_command_view(uuid,uuid,timestamptz,uuid),public.incident_command_inbox() to authenticated;
