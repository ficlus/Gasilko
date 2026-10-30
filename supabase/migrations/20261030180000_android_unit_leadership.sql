-- M14.8B. Additive, bounded field read enrichment only. All mutations remain canonical.
create index incident_crew_left_field_page on public.incident_crew_members(unit_assignment_id,left_at desc,id desc) where status='LEFT';
create index incident_allocation_field_history on public.incident_resource_allocations(unit_assignment_id,allocated_at desc,id desc)
 where status not in ('RESERVED','DEPLOYED');
alter function private.field_projection(uuid,uuid) rename to field_projection_before_unit_leadership;
alter function private.field_projection_before_unit_leadership(uuid,uuid) owner to postgres;
revoke all on function private.field_projection_before_unit_leadership(uuid,uuid) from public,anon,authenticated,service_role;
create function private.field_projection(p_acting_organization_id uuid,p_incident_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $unit_field$
declare v_result jsonb;v_unit jsonb;v_units jsonb:='[]';v_row public.incident_units;
 v_leader public.incident_role_assignments;v_crew jsonb;v_left jsonb;v_assignments jsonb;v_resources jsonb;v_count integer;
 v_live boolean;v_manage boolean;v_resource_manage boolean;v_resource_count integer:=0;
begin
 -- Existing org/incident share locks, projection privacy, versions and limits.
 v_result:=private.field_projection_before_unit_leadership(p_acting_organization_id,p_incident_id);
 if v_result is null then return null;end if;
 v_live:=v_result->>'status' in ('ACTIVE','STABILIZED');
 for v_unit in select x.value from jsonb_array_elements(v_result->'units') x loop
  select * into v_row from public.incident_units u where u.id=(v_unit->>'id')::uuid and u.incident_id=p_incident_id;
  v_unit:=v_unit||jsonb_build_object('organization_id',v_row.organization_id,'status_changed_at',v_row.status_changed_at);
  if private.field_unit_leader(auth.uid(),p_acting_organization_id,v_row.id) then
   select * into v_leader from public.incident_role_assignments r
    where r.incident_id=p_incident_id and r.unit_assignment_id=v_row.id and r.organization_id=p_acting_organization_id
    and r.user_id=auth.uid() and r.role='UNIT_LEADER' and private.incident_assignment_effective(r.id);
   v_manage:=v_live and private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,v_row.organization_id,v_row.id,'CREW');
   select coalesce(jsonb_agg(x.value||jsonb_build_object('version',c.version::text,'joined_at',c.joined_at,
    'can_leave',v_manage and not exists(select 1 from public.incident_role_assignments r where r.unit_assignment_id=v_row.id
     and r.user_id=c.user_id and r.role='UNIT_LEADER' and r.status='ACTIVE')
    and not exists(select 1 from public.incident_task_assignments a where a.incident_crew_member_id=c.id
     and a.status not in ('COMPLETED','UNABLE','CANCELLED'))) order by c.id),'[]')
   into v_crew from jsonb_array_elements(v_unit->'crew') x join public.incident_crew_members c on c.id=(x.value->>'id')::uuid;
   select coalesce(jsonb_agg(q.dto order by q.left_at desc,q.id desc),'[]') into v_left from(
    select c.id,c.left_at,jsonb_build_object('id',c.id,'name',coalesce(pr.display_name,c.user_id::text),
     'role',c.crew_role,'status',c.status,'joined_at',c.joined_at,'left_at',c.left_at,'version',c.version::text) dto
    from public.incident_crew_members c join public.profiles pr on pr.id=c.user_id
    where c.unit_assignment_id=v_row.id and c.incident_id=p_incident_id and c.status='LEFT'
    order by c.left_at desc,c.id desc limit 30) q;
   v_resource_manage:=v_live and not exists(select 1 from public.simulation_scenarios sim where sim.incident_id=p_incident_id)
     and private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,v_row.organization_id,v_row.id,'RESOURCE_TRANSITION');
   -- ALL live allocations + bounded terminal history. No stock/warehouse projection.
   select coalesce(jsonb_agg(q.dto order by q.allocated_at desc,q.id desc),'[]'),count(*) into v_resources,v_count from(
    select a.id,a.allocated_at,jsonb_build_object('id',a.id,'unit_assignment_id',a.unit_assignment_id,
     'organization_id',a.organization_id,'organization_name',o.name,'name',r.name,'quantity',a.quantity::text,
     'unit_of_measure_code',r.unit_of_measure_code,'measure',jsonb_build_object('label_sl',measure.names->>'sl','label_de',measure.names->>'de'),'status',a.status,'version',a.version::text,
     'allocated_at',a.allocated_at,'ended_at',a.ended_at,
     'can_transition',v_resource_manage and a.status in ('RESERVED','DEPLOYED')) dto
    from public.incident_resource_allocations a join public.operational_resources r on r.id=a.resource_id and r.organization_id=a.organization_id
    join public.organizations o on o.id=a.organization_id
    join public.operational_units_of_measure measure on measure.code=r.unit_of_measure_code
    where a.incident_id=p_incident_id and a.unit_assignment_id=v_row.id and a.organization_id=v_row.organization_id
     and (a.status in ('RESERVED','DEPLOYED') or a.id in(select past.id from public.incident_resource_allocations past
      where past.unit_assignment_id=v_row.id and past.incident_id=p_incident_id and past.status not in ('RESERVED','DEPLOYED')
      order by past.allocated_at desc,past.id desc limit 30))
    order by a.allocated_at desc,a.id desc limit 231) q;
   if v_count>230 then raise exception 'SNAPSHOT_TOO_LARGE';end if;
   v_resource_count:=v_resource_count+v_count;
   if v_resource_count>1000 then raise exception 'SNAPSHOT_TOO_LARGE';end if;
   v_unit:=v_unit||jsonb_build_object('crew',v_crew,'crew_history',v_left,
    'crew_history_more',exists(select 1 from public.incident_crew_members c where c.unit_assignment_id=v_row.id and c.status='LEFT' offset 30 limit 1),
    'resources',v_resources,'resource_history_more',exists(select 1 from public.incident_resource_allocations a
     where a.unit_assignment_id=v_row.id and a.status not in ('RESERVED','DEPLOYED') offset 30 limit 1),
    'can_manage_crew',v_manage,'leader_assignment',jsonb_build_object('id',v_leader.id,'version',v_leader.version::text,
      'parent_assignment_id',v_leader.parent_assignment_id,'organization_id',v_leader.organization_id),
    'status_actions',case when v_live and v_row.status='ON_SCENE' and private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,v_row.organization_id,v_row.id,'STATUS')
      then jsonb_build_array('RETURNING') else '[]'::jsonb end);
  end if;
  v_units:=v_units||jsonb_build_array(v_unit);
 end loop;
 select coalesce(jsonb_agg(x.value||jsonb_build_object(
  'blocked_reason',case when c.user_id=auth.uid() or private.field_unit_leader(auth.uid(),p_acting_organization_id,(x.value->>'unit_id')::uuid) then a.blocked_reason end,
  'unable_reason',case when c.user_id=auth.uid() or private.field_unit_leader(auth.uid(),p_acting_organization_id,(x.value->>'unit_id')::uuid) then a.unable_reason end) order by a.id),'[]')
 into v_assignments from jsonb_array_elements(v_result->'assignments') x
 join public.incident_task_assignments a on a.id=(x.value->>'id')::uuid and a.incident_id=p_incident_id
 left join public.incident_crew_members c on c.id=a.incident_crew_member_id;
 v_result:=v_result||jsonb_build_object('units',v_units,'assignments',v_assignments,'leadership_schema',1);
 if octet_length(v_result::text)>3145728 then raise exception 'SNAPSHOT_TOO_LARGE';end if;
 return v_result;
end;
$unit_field$;
alter function private.field_projection(uuid,uuid) owner to postgres;
revoke all on function private.field_projection(uuid,uuid) from public,anon,authenticated,service_role;
-- B1 manifest units already contain nested DTOs; entity replacement calls the same
-- projector. Existing crew/resource/role events SCOPE_RESET, status/task UPSERT.
-- No new collection, feed, public read grant, queue or mutation wrapper is introduced.
