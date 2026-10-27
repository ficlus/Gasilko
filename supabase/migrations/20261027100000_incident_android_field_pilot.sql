-- M14.7A/M14.8A: bounded actor-bound projections; canonical commands stay unchanged.
create function private.field_unit_leader(p_person uuid,p_org uuid,p_unit uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select exists(select 1 from public.incident_role_assignments r
 where r.user_id=p_person and r.organization_id=p_org and r.unit_assignment_id=p_unit
 and r.role='UNIT_LEADER' and private.incident_assignment_effective(r.id));
$$;
create function private.field_unit_visible(p_person uuid,p_org uuid,p_unit uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select exists(select 1 from public.incident_units u
 join public.incident_participants ip on ip.id=u.participation_id and ip.status='ACTIVE'
 join public.organizations o on o.id=u.organization_id and o.active
 join public.user_organizations m on m.organization_id=p_org and m.user_id=p_person
 join public.profiles pr on pr.id=m.user_id and pr.account_status='ACTIVE'
 where u.id=p_unit and u.organization_id=p_org and
 (private.field_unit_leader(p_person,p_org,u.id) or exists(
 select 1 from public.incident_crew_members c where c.unit_assignment_id=u.id
 and c.membership_organization_id=p_org and c.user_id=p_person and c.status='ACTIVE')));
$$;
create function private.field_assignment_visible(p_person uuid,p_org uuid,p_assignment uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select exists(select 1 from public.incident_task_assignments a
 left join public.incident_crew_members c on c.id=a.incident_crew_member_id
 where a.id=p_assignment and private.field_unit_visible(p_person,p_org,coalesce(a.incident_unit_id,c.unit_assignment_id))
 and (a.recipient_type='INCIDENT_UNIT' or c.user_id=p_person or private.field_unit_leader(p_person,p_org,c.unit_assignment_id)));
$$;
create function public.incident_field_snapshot(p_acting_organization_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare v_actor uuid:=auth.uid();v_i public.incidents;v_rows jsonb:='[]';v_units jsonb;v_tasks jsonb;v_history jsonb;v_result jsonb;v_count integer:=0;
begin
 if v_actor is null or not private.incident_acting_member(p_acting_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 -- Same organization security lock as canonical mutations. Parent locks pin each
 -- incident projection; no client merging of unrelated pages is supported.
 perform private.lock_organization(p_acting_organization_id);
 for v_i in select i.* from public.incidents i where i.status<>'DRAFT'
 and exists(select 1 from public.incident_units u where u.incident_id=i.id
 and private.field_unit_visible(v_actor,p_acting_organization_id,u.id))
 order by i.id limit 51 for share loop
  v_count:=v_count+1;
  if v_count>50 then raise exception 'FIELD_SNAPSHOT_LIMIT'; end if;
  select coalesce(jsonb_agg(q.dto order by q.id),'[]') into v_units from (
   select u.id,jsonb_build_object('id',u.id,'name',ou.callsign||' · '||ou.name,'status',u.status,'version',u.version::text,
    'can_return',u.status='ON_SCENE' and private.field_unit_leader(v_actor,p_acting_organization_id,u.id)
       and private.can_manage_incident_unit(v_i.id,p_acting_organization_id,u.organization_id,u.id,'STATUS'),
    'leader',private.field_unit_leader(v_actor,p_acting_organization_id,u.id),
    'leader_name',(select pr.display_name from public.incident_role_assignments r join public.profiles pr on pr.id=r.user_id
       where r.unit_assignment_id=u.id and r.role='UNIT_LEADER' and private.incident_assignment_effective(r.id) limit 1),
    'crew',coalesce((select jsonb_agg(qc.dto order by qc.id) from (
      select c.id,jsonb_build_object('id',c.id,'user_id',c.user_id,'name',coalesce(pr.display_name,c.user_id::text),
       'role',c.crew_role,'status',c.status,
       'can_issue',private.field_unit_leader(v_actor,p_acting_organization_id,u.id)
        and private.task_recipient_eligible(v_i.id,'INCIDENT_CREW_MEMBER',c.id)
        and private.can_issue_task(v_i.id,p_acting_organization_id,'INCIDENT_CREW_MEMBER',c.id)) dto
      from public.incident_crew_members c join public.profiles pr on pr.id=c.user_id
      where c.unit_assignment_id=u.id and c.status='ACTIVE'
      and (c.user_id=v_actor or private.field_unit_leader(v_actor,p_acting_organization_id,u.id))
      order by c.id limit 101) qc),'[]')) dto
   from public.incident_units u join public.operational_units ou on ou.id=u.unit_id
   where u.incident_id=v_i.id and private.field_unit_visible(v_actor,p_acting_organization_id,u.id)
   order by u.id limit 101) q;
  if jsonb_array_length(v_units)>100 or exists(select 1 from jsonb_array_elements(v_units) x where jsonb_array_length(x->'crew')>100)
   then raise exception 'FIELD_SNAPSHOT_LIMIT'; end if;
  select coalesce(jsonb_agg(q.dto order by q.id),'[]') into v_tasks from (
   select a.id,jsonb_build_object('id',a.id,'version',a.version::text,'status',a.status,'recipient_type',a.recipient_type,
    'recipient_id',coalesce(a.incident_unit_id,a.incident_crew_member_id),'unit_id',coalesce(a.incident_unit_id,c.unit_assignment_id),
    'recipient_name',case when c.id is null then ou.callsign||' · '||ou.name else coalesce(pr.display_name,c.user_id::text) end,
    'mine',c.user_id=v_actor,'can_execute',v_i.status in ('ACTIVE','STABILIZED') and t.status='OPEN'
      and a.status not in ('COMPLETED','UNABLE','CANCELLED')
      and private.can_execute_task(v_i.id,p_acting_organization_id,a.recipient_type,coalesce(a.incident_unit_id,a.incident_crew_member_id)),
    'task',private.task_projection(t)) dto
   from public.incident_task_assignments a join public.incident_tasks t on t.id=a.task_id
   left join public.incident_crew_members c on c.id=a.incident_crew_member_id
   left join public.profiles pr on pr.id=c.user_id
   join public.incident_units u on u.id=coalesce(a.incident_unit_id,c.unit_assignment_id)
   join public.operational_units ou on ou.id=u.unit_id
   where a.incident_id=v_i.id and private.field_assignment_visible(v_actor,p_acting_organization_id,a.id)
   order by a.id limit 101) q;
  if jsonb_array_length(v_tasks)>100 then raise exception 'FIELD_SNAPSHOT_LIMIT'; end if;
  -- Only assignment/task events for these explicitly scoped episodes, never the
  -- general timeline (which can include instructor/private operational material).
  select coalesce(jsonb_agg(q.dto order by q.sequence desc),'[]') into v_history from (
   select e.sequence,jsonb_build_object('sequence',e.sequence::text,'code',e.event_code,'recorded_at',e.recorded_at,'data',e.data) dto
   from public.incident_timeline e where e.incident_id=v_i.id and e.event_code like 'TASK_%'
   and exists(select 1 from jsonb_array_elements(v_tasks) a where
    (e.data->>'task_assignment_id'=a->>'id') or
    (not(e.data ? 'task_assignment_id') and e.data->>'task_id'=a->'task'->>'id'))
   order by e.sequence desc limit 100) q;
  v_rows:=v_rows||jsonb_build_array(jsonb_build_object('id',v_i.id,'reference',v_i.reference_number,
    'title',v_i.title,'status',v_i.status,'mode',case when exists(select 1 from public.simulation_scenarios s where s.incident_id=v_i.id) then 'TRAINING' else 'REAL' end,'latitude',v_i.latitude,'longitude',v_i.longitude,
    'version',v_i.version::text,'revision',v_i.revision::text,'timeline_sequence',v_i.timeline_sequence::text,
    'units',v_units,'assignments',v_tasks,'history',v_history));
 end loop;
 v_result:=jsonb_build_object('account',v_actor,'organization',p_acting_organization_id,'verified_at',clock_timestamp(),'incidents',v_rows);
 if octet_length(v_result::text)>3145728 then raise exception 'FIELD_SNAPSHOT_LIMIT'; end if;
 return v_result;
end; $$;
revoke all on function private.field_unit_leader(uuid,uuid,uuid),private.field_unit_visible(uuid,uuid,uuid),private.field_assignment_visible(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.incident_field_snapshot(uuid) from public,anon,authenticated,service_role;
grant execute on function public.incident_field_snapshot(uuid) to authenticated;

-- Minimal envelopes use existing M10 recipients, leases, delivery worker and tokens.
insert into private.notification_categories(code,default_enabled) values('INCIDENT_TASK',true);
create function private.capture_field_notification() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_org uuid;
begin
 if tg_op='UPDATE' and new.status=old.status then return new; end if;
 select u.organization_id into v_org from public.incident_units u where u.id=coalesce(new.incident_unit_id,
  (select c.unit_assignment_id from public.incident_crew_members c where c.id=new.incident_crew_member_id));
 insert into private.notification_events(organization_id,type,category,entity_type,entity_id,teams,source_key)
 values(v_org,'INCIDENT_TASK_CHANGED','INCIDENT_TASK','INCIDENT',new.incident_id,array[new.id],new.id::text||'/'||new.version::text)
 on conflict(type,source_key) do nothing;
 return new;
end; $$;
create trigger notification_incident_assignment after insert or update of status on public.incident_task_assignments
 for each row execute function private.capture_field_notification();
revoke all on function private.capture_field_notification() from public,anon,authenticated,service_role;
create or replace function private.notification_recipient(e private.notification_events, person uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select exists(select 1 from public.user_organizations m join public.profiles p on p.id=m.user_id
 join public.organizations o on o.id=m.organization_id
 where m.user_id=person and m.organization_id=e.organization_id and p.account_status='ACTIVE' and o.active
 and coalesce((select enabled from private.notification_preferences where user_id=person and category=e.category),e.category<>'HYDRANT')
 and ((e.category='INCIDENT_TASK' and exists(select 1 from unnest(e.teams) a(id)
  where private.field_assignment_visible(person,e.organization_id,a.id)))
 or (e.category='HYDRANT' and m.role in ('MANAGER','ADMIN')) or
 (e.category in ('ASSIGNMENT','ACTIVATION') and exists(select 1 from public.inspection_team_members tm
 join public.inspection_teams t on t.id=tm.team_id and t.organization_id=tm.organization_id
 join public.inspection_plan_teams pt on pt.team_id=t.id and pt.organization_id=t.organization_id
 join public.inspection_plans plan on plan.id=pt.plan_id and plan.organization_id=pt.organization_id
 where tm.user_id=person and tm.organization_id=e.organization_id and tm.active and t.active and pt.active
 and pt.plan_id=e.entity_id and plan.status in ('DRAFT','PLANNED','ACTIVE')
 and (cardinality(e.teams)=0 or tm.team_id=any(e.teams))))));
$$;
create or replace function public.claim_notification_deliveries() returns jsonb
language plpgsql security definer set search_path='' as $$
declare e private.notification_events; d private.notification_deliveries; device private.notification_devices; result jsonb:='[]'; lease_id uuid;
begin
 -- Bounded retention of delivery telemetry, not business/audit history. Event source keys remain durable.
 delete from private.notification_deliveries where id in (select id from private.notification_deliveries where updated_at<now()-interval '90 days' and state in ('ACCEPTED','FAILED','SUPPRESSED') limit 1000);
 for e in select * from private.notification_events where resolved_at is null order by created_at,id limit 25 for update skip locked loop
  if e.created_at>now()-interval '7 days' then
   insert into private.notification_deliveries(event_id,installation,user_id)
   select distinct e.id,x.installation,x.user_id
   from public.user_organizations m join public.profiles p on p.id=m.user_id and p.account_status='ACTIVE'
   join public.organizations o on o.id=m.organization_id and o.active
   join private.notification_devices x on x.user_id=m.user_id and x.active
   left join private.notification_preferences pref on pref.user_id=m.user_id and pref.category=e.category
   where m.organization_id=e.organization_id and coalesce(pref.enabled,e.category<>'HYDRANT')
   and private.notification_recipient(e,m.user_id)
   on conflict(event_id,installation,user_id) do nothing;
  end if;
  update private.notification_events set resolved_at=now() where id=e.id;
 end loop;
 for d in select * from private.notification_deliveries where (state='PENDING' and next_at<=now()) or (state='LEASED' and lease_until<now()) order by next_at,id limit 50 for update skip locked loop
  select * into e from private.notification_events where id=d.event_id;
  select * into device from private.notification_devices where installation=d.installation;
  if not device.active or device.user_id<>d.user_id or not private.notification_recipient(e,d.user_id) or e.created_at<now()-interval '7 days' or d.attempts>=5 then
   update private.notification_deliveries set state='SUPPRESSED',updated_at=now() where id=d.id;continue;
  end if;
  lease_id:=gen_random_uuid();
  update private.notification_deliveries set state='LEASED',attempts=attempts+1,lease=lease_id,lease_until=now()+interval '5 minutes',token_revision=device.revision,updated_at=now() where id=d.id;
  result:=result||jsonb_build_array(jsonb_build_object('id',d.id,'lease',lease_id,'token',device.token,'account',d.user_id,'event',e.id,'type',e.type,'category',e.category,'entity_type',e.entity_type,'entity',e.entity_id,'organization',e.organization_id));
 end loop;
 return result;
end;
$$;
