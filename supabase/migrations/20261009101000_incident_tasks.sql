-- Immutable intent with independently versioned recipient execution episodes.
create table public.incident_tasks(
 id uuid primary key,incident_id uuid not null references public.incidents(id),
 action_definition_version_id uuid not null references public.operational_action_definition_versions(id),
 issuing_organization_id uuid not null references public.organizations(id),issued_by uuid not null references public.profiles(id),
 priority text not null check(priority in ('LOW','NORMAL','HIGH','CRITICAL')),title text check(length(title)<=200),notes text check(length(notes)<=4000),
 target_type text not null check(target_type in ('NONE','HYDRANT','INCIDENT_MAP_OBJECT','INCIDENT_SECTOR','COORDINATE')),
 target_entity_id uuid,target_incident_id uuid references public.incidents(id),target_geometry_snapshot jsonb,target_label_snapshot text check(length(target_label_snapshot)<=300),
 parameters jsonb not null check(jsonb_typeof(parameters)='object' and octet_length(parameters::text)<=8192),
 status text not null default 'OPEN' check(status in ('OPEN','CLOSED','CANCELLED')),
 outcome text check(outcome in ('SUCCESS','PARTIAL','FAILED')),
 issued_at timestamptz not null default clock_timestamp(),closed_at timestamptz,cancelled_at timestamptz,cancelled_by uuid references public.profiles(id),
 version bigint not null default 1 check(version>0),changed_revision bigint not null check(changed_revision>0),unique(id,incident_id),
 check((status='OPEN' and outcome is null and closed_at is null and cancelled_at is null) or
 (status='CLOSED' and outcome is not null and closed_at is not null and cancelled_at is null) or
 (status='CANCELLED' and outcome is null and cancelled_at is not null and cancelled_by is not null)),
 check((target_type='NONE' and target_entity_id is null and target_incident_id is null and target_geometry_snapshot is null) or
 (target_type='COORDINATE' and target_entity_id is null and target_incident_id is null and target_geometry_snapshot is not null) or
 (target_type='HYDRANT' and target_entity_id is not null and target_incident_id is null) or
 (target_type in ('INCIDENT_MAP_OBJECT','INCIDENT_SECTOR') and target_entity_id is not null and target_incident_id is not null and target_incident_id=incident_id))
);
create table public.incident_task_assignments(
 id uuid primary key,task_id uuid not null,incident_id uuid not null,
 recipient_type text not null check(recipient_type in ('INCIDENT_UNIT','INCIDENT_CREW_MEMBER')),
 incident_unit_id uuid,incident_crew_member_id uuid,
 status text not null default 'ISSUED' check(status in ('ISSUED','ACKNOWLEDGED','IN_PROGRESS','BLOCKED','COMPLETED','UNABLE','CANCELLED')),
 acknowledged_at timestamptz,acknowledged_by uuid references public.profiles(id),
 started_at timestamptz,started_by uuid references public.profiles(id),
 blocked_at timestamptz,blocked_by uuid references public.profiles(id),blocked_reason text check(length(btrim(blocked_reason)) between 1 and 2000),
 completed_at timestamptz,completed_by uuid references public.profiles(id),
 unable_at timestamptz,unable_by uuid references public.profiles(id),unable_reason text check(length(btrim(unable_reason)) between 1 and 2000),
 cancelled_at timestamptz,cancelled_by uuid references public.profiles(id),
 version bigint not null default 1 check(version>0),changed_revision bigint not null check(changed_revision>0),unique(id,incident_id),
 foreign key(task_id,incident_id) references public.incident_tasks(id,incident_id),
 foreign key(incident_unit_id,incident_id) references public.incident_units(id,incident_id),
 foreign key(incident_crew_member_id,incident_id) references public.incident_crew_members(id,incident_id),
 check((recipient_type='INCIDENT_UNIT' and incident_unit_id is not null and incident_crew_member_id is null) or
 (recipient_type='INCIDENT_CREW_MEMBER' and incident_unit_id is null and incident_crew_member_id is not null)),
 check(status<>'BLOCKED' or (blocked_at is not null and blocked_by is not null and blocked_reason is not null)),
 check(status<>'UNABLE' or (unable_at is not null and unable_by is not null and unable_reason is not null)),
 check(status<>'COMPLETED' or (completed_at is not null and completed_by is not null)),
 check(status<>'ACKNOWLEDGED' or (acknowledged_at is not null and acknowledged_by is not null)),
 check(status<>'IN_PROGRESS' or (started_at is not null and started_by is not null)),
 check(status<>'CANCELLED' or (cancelled_at is not null and cancelled_by is not null))
);
create unique index task_unit_recipient on public.incident_task_assignments(task_id,incident_unit_id) where incident_unit_id is not null;
create unique index task_person_recipient on public.incident_task_assignments(task_id,incident_crew_member_id) where incident_crew_member_id is not null;
create index task_incident_page on public.incident_tasks(incident_id,status,issued_at desc,id desc);
create index task_unit_open on public.incident_task_assignments(incident_unit_id) where status not in ('COMPLETED','UNABLE','CANCELLED');
create index task_crew_open on public.incident_task_assignments(incident_crew_member_id) where status not in ('COMPLETED','UNABLE','CANCELLED');
alter table public.incident_tasks enable row level security;
alter table public.incident_task_assignments enable row level security;
revoke all on public.incident_tasks,public.incident_task_assignments from public,anon,authenticated,service_role;
create function private.guard_task_history() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_table_name='incident_tasks' then
  if old.status<>'OPEN' or
   (to_jsonb(old)-array['status','outcome','closed_at','cancelled_at','cancelled_by','version','changed_revision']) is distinct from
   (to_jsonb(new)-array['status','outcome','closed_at','cancelled_at','cancelled_by','version','changed_revision']) then raise exception 'INVALID_TASK_TRANSITION'; end if;
 else
  if old.status in ('COMPLETED','UNABLE','CANCELLED') or
   row(old.id,old.task_id,old.incident_id,old.recipient_type,old.incident_unit_id,old.incident_crew_member_id) is distinct from
   row(new.id,new.task_id,new.incident_id,new.recipient_type,new.incident_unit_id,new.incident_crew_member_id) then raise exception 'INVALID_TASK_TRANSITION'; end if;
 end if;
 if new.version<>old.version+1 then raise exception 'STALE_VERSION'; end if;
 return new;
end; $$;
create trigger task_intent_immutable before update on public.incident_tasks for each row execute function private.guard_task_history();
create trigger task_assignment_history before update on public.incident_task_assignments for each row execute function private.guard_task_history();
create trigger task_no_delete before delete on public.incident_tasks for each row execute function private.audit_immutable();
create trigger task_no_truncate before truncate on public.incident_tasks for each statement execute function private.audit_immutable();
create trigger task_assignment_no_delete before delete on public.incident_task_assignments for each row execute function private.audit_immutable();
create trigger task_assignment_no_truncate before truncate on public.incident_task_assignments for each statement execute function private.audit_immutable();

-- Safety guards apply to the existing owning APIs, including automatic crew ending.
create function private.guard_open_tasks() returns trigger
language plpgsql security definer set search_path='' as $$
declare incident_value uuid;owner_value uuid;unit_value uuid;crew_value uuid;
begin
 if tg_table_name='incidents' then
  if new.status not in ('CLOSED','CANCELLED') or new.status=old.status then return new; end if;incident_value:=old.id;
 elsif tg_table_name='incident_participants' then
  if old.status<>'ACTIVE' or new.status='ACTIVE' then return new; end if;incident_value:=old.incident_id;owner_value:=old.organization_id;
 elsif tg_table_name='incident_units' then
  if new.status not in ('RELEASED','UNAVAILABLE') or new.status=old.status then return new; end if;incident_value:=old.incident_id;unit_value:=old.id;
 else
  if old.status<>'ACTIVE' or new.status='ACTIVE' then return new; end if;incident_value:=old.incident_id;crew_value:=old.id;
 end if;
 if exists(select 1 from public.incident_task_assignments a
  left join public.incident_crew_members c on c.id=a.incident_crew_member_id
  join public.incident_units u on u.id=coalesce(a.incident_unit_id,c.unit_assignment_id)
  where a.incident_id=incident_value and a.status not in ('COMPLETED','UNABLE','CANCELLED')
  and (owner_value is null or u.organization_id=owner_value)
  and (unit_value is null or u.id=unit_value) and (crew_value is null or c.id=crew_value)) then raise exception 'UNRESOLVED_TASKS'; end if;
 return new;
end; $$;
create trigger task_incident_close_guard before update on public.incidents for each row execute function private.guard_open_tasks();
create trigger task_participant_release_guard before update on public.incident_participants for each row execute function private.guard_open_tasks();
create trigger task_unit_release_guard before update on public.incident_units for each row execute function private.guard_open_tasks();
create trigger task_crew_leave_guard before update on public.incident_crew_members for each row execute function private.guard_open_tasks();
revoke all on function private.guard_task_history(),private.guard_open_tasks() from public,anon,authenticated,service_role;
alter table public.incident_timeline add column task_id uuid,add column task_assignment_id uuid,
 add constraint timeline_task_fk foreign key(task_id,incident_id) references public.incident_tasks(id,incident_id),
 add constraint timeline_task_assignment_fk foreign key(task_assignment_id,incident_id) references public.incident_task_assignments(id,incident_id);
alter table public.incident_timeline drop constraint timeline_typed_subject;
alter table public.incident_timeline add constraint timeline_typed_subject
 check(num_nonnulls(participation_id,assignment_id,unit_assignment_id,crew_member_id,resource_allocation_id,task_id,task_assignment_id)<=1);
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
 'LEAD_ORGANIZATION_CHANGED','COMMAND_RECOVERY_REQUESTED','COMMAND_RECOVERY_ASSIGNED','SECTOR_CREATED','SECTOR_UPDATED','SECTOR_DEACTIVATED','MAP_OBJECT_CREATED','MAP_OBJECT_UPDATED','MAP_OBJECT_DEACTIVATED','HYDRANT_LINKED','HYDRANT_UNLINKED','UNIT_ASSIGNED','UNIT_STATUS_CHANGED','UNIT_SECTOR_CHANGED','UNIT_RELEASED','CREW_JOINED','CREW_LEFT','RESOURCE_ALLOCATED','RESOURCE_DEPLOYED','RESOURCE_RETURNED','RESOURCE_CONSUMED','RESOURCE_CANCELLED','TASK_ISSUED','TASK_CANCELLED','TASK_CLOSED','TASK_ASSIGNMENT_ACKNOWLEDGED','TASK_ASSIGNMENT_STARTED','TASK_ASSIGNMENT_BLOCKED','TASK_ASSIGNMENT_COMPLETED','TASK_ASSIGNMENT_UNABLE','TASK_ASSIGNMENT_CANCELLED') or auth.uid() is null then
 raise exception 'VALIDATION_FAILED'; end if;
 update public.incidents i set revision=i.revision+case when p_ordinal=1 then 1 else 0 end,
 timeline_sequence=i.timeline_sequence+1,updated_at=clock_timestamp() where i.id=p_incident
 returning i.revision,i.timeline_sequence into v_revision,v_sequence;
 insert into public.incident_timeline(incident_id,sequence,revision,operation_id,event_ordinal,event_code,
 actor_user_id,actor_organization_id,participation_id,assignment_id,unit_assignment_id,crew_member_id,resource_allocation_id,task_id,task_assignment_id,data)
 values(p_incident,v_sequence,v_revision,p_operation,p_ordinal,p_code,auth.uid(),p_org,p_participation,p_assignment,
 case when p_code in ('UNIT_ASSIGNED','UNIT_STATUS_CHANGED','UNIT_SECTOR_CHANGED','UNIT_RELEASED') then (p_data->>'unit_assignment_id')::uuid end,
 case when p_code in ('CREW_JOINED','CREW_LEFT') then (p_data->>'crew_member_id')::uuid end,
 case when p_code in ('RESOURCE_ALLOCATED','RESOURCE_DEPLOYED','RESOURCE_RETURNED','RESOURCE_CONSUMED','RESOURCE_CANCELLED') then (p_data->>'resource_allocation_id')::uuid end,
 case when p_code in ('TASK_ISSUED','TASK_CANCELLED','TASK_CLOSED') then (p_data->>'task_id')::uuid end,
 case when p_code like 'TASK_ASSIGNMENT_%' then (p_data->>'task_assignment_id')::uuid end,p_data);
end; $$;
