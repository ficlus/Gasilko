-- Minimal shared DTOs; no registrations, email, phone or private profile fields.
create function private.operational_vehicle_projection(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',v.id,'callsign',v.callsign,'name',v.name,'category_code',v.category_code,'active',v.active,'availability',v.availability,'seats',v.seats,'water_litres',v.water_litres,
 'capabilities',coalesce((select jsonb_agg(c.capability_code order by c.capability_code) from public.operational_vehicle_capabilities c where c.vehicle_id=v.id and c.active),'[]')) from public.operational_vehicles v where v.id=p_vehicle;
$$;
create function public.incident_resources(p_incident_id uuid,p_acting_organization_id uuid,p_history_page integer default 0) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare incident_row public.incidents;units_value jsonb;allocations_value jsonb;
begin
 if public.incident_context(p_incident_id,p_acting_organization_id) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_history_page is null or p_history_page not between 0 and 100000 then raise exception 'VALIDATION_FAILED'; end if;
 select * into incident_row from public.incidents i where i.id=p_incident_id;
 with terminal as (select d.id from public.incident_units d where d.incident_id=p_incident_id and d.status in ('RELEASED','UNAVAILABLE') order by d.assigned_at desc,d.id desc limit 50 offset p_history_page*50)
 select coalesce(jsonb_agg(jsonb_build_object(
 'id',d.id,'unit_id',d.unit_id,'name',u.name,'callsign',u.callsign,'unit_kind',u.unit_kind,'organization_id',d.organization_id,'organization_name',o.name,
 'status',d.status,'sector_id',d.sector_id,'sector_name',se.name,'assigned_at',d.assigned_at,'released_at',d.released_at,'end_reason',d.end_reason,
 'version',d.version::text,'changed_revision',d.changed_revision::text,'vehicle',private.operational_vehicle_projection(u.vehicle_id),
 'capabilities',coalesce((select jsonb_agg(c.capability_code order by c.capability_code) from public.operational_unit_capabilities c where c.unit_id=u.id and c.active),'[]'),
 'leader',(select jsonb_build_object('id',a.id,'name',pr.display_name,'valid',private.incident_assignment_effective(a.id)) from public.incident_role_assignments a join public.profiles pr on pr.id=a.user_id where a.unit_assignment_id=d.id and a.role='UNIT_LEADER' and a.status='ACTIVE'),
 'crew',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'user_id',c.user_id,'name',coalesce(pr.display_name,c.user_id::text),'crew_role',c.crew_role,'joined_at',c.joined_at,'version',c.version::text,
 'can_leave',private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,d.organization_id,d.id,'CREW') and not exists(select 1 from public.incident_role_assignments a where a.unit_assignment_id=d.id and a.user_id=c.user_id and a.role='UNIT_LEADER' and a.status='ACTIVE')) order by c.joined_at,c.id)
 from public.incident_crew_members c join public.profiles pr on pr.id=c.user_id where c.unit_assignment_id=d.id and c.status='ACTIVE'),'[]'),
 'can_status',d.status not in ('RELEASED','UNAVAILABLE') and private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,d.organization_id,d.id,'STATUS'),
 'can_sector',d.status not in ('RELEASED','UNAVAILABLE') and private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,d.organization_id,d.id,'SECTOR'),
 'can_crew',d.status not in ('RELEASED','UNAVAILABLE') and private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,d.organization_id,d.id,'CREW'),
 'can_end',d.status not in ('RELEASED','UNAVAILABLE') and private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,d.organization_id,d.id,'STATUS')
 and not exists(select 1 from public.incident_role_assignments a where a.unit_assignment_id=d.id and a.status='ACTIVE')
 and not exists(select 1 from public.incident_resource_allocations a where a.unit_assignment_id=d.id and a.status in ('RESERVED','DEPLOYED'))
 ) order by d.assigned_at,d.id),'[]') into units_value
 from public.incident_units d join public.operational_units u on u.id=d.unit_id join public.organizations o on o.id=d.organization_id left join public.incident_sectors se on se.id=d.sector_id
 where d.incident_id=p_incident_id and (d.status not in ('RELEASED','UNAVAILABLE') or d.id in(select id from terminal));
 with terminal as (select a.id from public.incident_resource_allocations a where a.incident_id=p_incident_id and a.status not in ('RESERVED','DEPLOYED') order by a.allocated_at desc,a.id desc limit 50 offset p_history_page*50)
 select coalesce(jsonb_agg(jsonb_build_object(
 'id',a.id,'resource_id',a.resource_id,'name',r.name,'resource_type_code',r.resource_type_code,'unit_of_measure_code',r.unit_of_measure_code,
 'organization_id',a.organization_id,'organization_name',o.name,'quantity',a.quantity::text,'status',a.status,'unit_assignment_id',a.unit_assignment_id,
 'unit_name',u.callsign,'allocated_at',a.allocated_at,'ended_at',a.ended_at,'version',a.version::text,'changed_revision',a.changed_revision::text,
 'can_transition',a.status in ('RESERVED','DEPLOYED') and private.can_manage_incident_resource(p_incident_id,p_acting_organization_id,a.id)
 ) order by a.allocated_at,a.id),'[]') into allocations_value
 from public.incident_resource_allocations a join public.operational_resources r on r.id=a.resource_id join public.organizations o on o.id=a.organization_id
 left join public.incident_units d on d.id=a.unit_assignment_id left join public.operational_units u on u.id=d.unit_id
 where a.incident_id=p_incident_id and (a.status in ('RESERVED','DEPLOYED') or a.id in(select id from terminal));
 return jsonb_build_object('version',incident_row.version::text,'revision',incident_row.revision::text,'units',units_value,'allocations',allocations_value,
 'organizations',coalesce((select jsonb_agg(jsonb_build_object('id',ip.organization_id,'name',o.name) order by o.name,ip.id) from public.incident_participants ip join public.organizations o on o.id=ip.organization_id
 where ip.incident_id=p_incident_id and ip.status='ACTIVE' and private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,ip.organization_id,null,'DEPLOY')),'[]'),
 'sectors',coalesce((select jsonb_agg(jsonb_build_object('id',se.id,'name',se.name,'code',se.code) order by se.code) from public.incident_sectors se where se.incident_id=p_incident_id and se.active),'[]'),
 'history_more',(select count(*) from public.incident_units d where d.incident_id=p_incident_id and d.status in ('RELEASED','UNAVAILABLE'))>(p_history_page+1)*50
 or (select count(*) from public.incident_resource_allocations a where a.incident_id=p_incident_id and a.status not in ('RESERVED','DEPLOYED'))>(p_history_page+1)*50);
end; $$;
create function public.incident_crew_history(p_incident_id uuid,p_acting_organization_id uuid,p_unit_assignment_id uuid,p_page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows_value jsonb;
begin
 if public.incident_context(p_incident_id,p_acting_organization_id) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_page is null or p_page not between 0 and 100000 then raise exception 'VALIDATION_FAILED'; end if;
 select coalesce(jsonb_agg(q.dto order by q.left_at desc,q.id desc),'[]') into rows_value from (
 select c.id,c.left_at,jsonb_build_object('id',c.id,'name',coalesce(pr.display_name,c.user_id::text),'crew_role',c.crew_role,'joined_at',c.joined_at,'left_at',c.left_at,'left_by',leaver.display_name) dto
 from public.incident_crew_members c join public.profiles pr on pr.id=c.user_id left join public.profiles leaver on leaver.id=c.left_by
 where c.incident_id=p_incident_id and c.unit_assignment_id=p_unit_assignment_id and c.status='LEFT'
 order by c.left_at desc,c.id desc limit 51 offset p_page*50) q;
 return jsonb_build_object('rows',case when jsonb_array_length(rows_value)>50 then rows_value-50 else rows_value end,'more',jsonb_array_length(rows_value)>50);
end; $$;
create function private.incident_resource_candidates(p_kind text,p_incident uuid,p_org uuid,p_owner uuid,p_unit uuid,p_query text) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare rows_value jsonb;owner_value uuid;
begin
 if public.incident_context(p_incident,p_org) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_query is null or length(p_query)>100 then raise exception 'VALIDATION_FAILED'; end if;
 if p_kind='CREW' then
  select d.organization_id into owner_value from public.incident_units d where d.id=p_unit and d.incident_id=p_incident and d.status not in ('RELEASED','UNAVAILABLE');
  if owner_value is null or not private.can_manage_incident_unit(p_incident,p_org,owner_value,p_unit,'CREW') then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  select coalesce(jsonb_agg(q.dto order by q.name,q.id),'[]') into rows_value from (
   select pr.id,pr.display_name name,jsonb_build_object('id',pr.id,'name',coalesce(pr.display_name,pr.id::text)) dto
   from public.profiles pr join public.user_organizations m on m.user_id=pr.id and m.organization_id=owner_value
   where pr.account_status='ACTIVE' and position(lower(p_query) in lower(coalesce(pr.display_name,'')))>0
   and not exists(select 1 from public.incident_crew_members c where c.incident_id=p_incident and c.user_id=pr.id and c.status='ACTIVE')
   order by pr.display_name,pr.id limit 30) q;
 else
  if p_owner is null or not private.can_manage_incident_unit(p_incident,p_org,p_owner,null,'DEPLOY') then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if p_kind='UNIT' then
   select coalesce(jsonb_agg(q.dto order by q.callsign,q.id),'[]') into rows_value from (
    select u.id,u.callsign,jsonb_build_object('id',u.id,'name',u.name,'callsign',u.callsign,'unit_kind',u.unit_kind,'organization_id',u.organization_id,
    'vehicle',private.operational_vehicle_projection(u.vehicle_id),'capabilities',coalesce((select jsonb_agg(c.capability_code order by c.capability_code) from public.operational_unit_capabilities c where c.unit_id=u.id and c.active),'[]')) dto
    from public.operational_units u where u.organization_id=p_owner and u.active and position(lower(p_query) in lower(u.callsign||' '||u.name))>0
    and not exists(select 1 from public.incident_units d where d.unit_id=u.id and d.status not in ('RELEASED','UNAVAILABLE'))
    and (u.vehicle_id is null or (exists(select 1 from public.operational_vehicles v where v.id=u.vehicle_id and v.active and v.availability='AVAILABLE')
     and not exists(select 1 from public.incident_units d join public.operational_units other_unit on other_unit.id=d.unit_id where other_unit.vehicle_id=u.vehicle_id and d.status not in ('RELEASED','UNAVAILABLE'))))
    order by u.callsign,u.id limit 50) q;
  elsif p_kind='RESOURCE' then
   select coalesce(jsonb_agg(q.dto order by q.name,q.id),'[]') into rows_value from (
    select r.id,r.name,jsonb_build_object('id',r.id,'name',r.name,'resource_type_code',r.resource_type_code,'unit_of_measure_code',r.unit_of_measure_code,'total_quantity',r.total_quantity::text,
    'available_quantity',(r.total_quantity-coalesce((select sum(a.quantity) from public.incident_resource_allocations a where a.resource_id=r.id and a.status in ('RESERVED','DEPLOYED')),0))::text) dto
    from public.operational_resources r where r.organization_id=p_owner and r.active and position(lower(p_query) in lower(r.name))>0 order by r.name,r.id limit 50) q;
  else raise exception 'VALIDATION_FAILED'; end if;
 end if;
 return rows_value;
end; $$;
create function public.incident_unit_candidates(p_incident_id uuid,p_acting_organization_id uuid,p_organization_id uuid,p_query text default '') returns jsonb language sql security definer set search_path='' as $$ select private.incident_resource_candidates('UNIT',p_incident_id,p_acting_organization_id,p_organization_id,null,p_query); $$;
revoke all on function public.incident_unit_candidates(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.incident_unit_candidates(uuid,uuid,uuid,text) to authenticated;
create function public.incident_resource_candidates(p_incident_id uuid,p_acting_organization_id uuid,p_organization_id uuid,p_query text default '') returns jsonb language sql security definer set search_path='' as $$ select private.incident_resource_candidates('RESOURCE',p_incident_id,p_acting_organization_id,p_organization_id,null,p_query); $$;
revoke all on function public.incident_resource_candidates(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.incident_resource_candidates(uuid,uuid,uuid,text) to authenticated;
create function public.incident_crew_candidates(p_incident_id uuid,p_acting_organization_id uuid,p_unit_assignment_id uuid,p_query text default '') returns jsonb language sql security definer set search_path='' as $$ select private.incident_resource_candidates('CREW',p_incident_id,p_acting_organization_id,null,p_unit_assignment_id,p_query); $$;
revoke all on function public.incident_crew_candidates(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.incident_crew_candidates(uuid,uuid,uuid,text) to authenticated;
revoke all on function private.operational_vehicle_projection(uuid),private.incident_resource_candidates(text,uuid,uuid,uuid,uuid,text),public.incident_resources(uuid,uuid,integer),public.incident_crew_history(uuid,uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function public.incident_resources(uuid,uuid,integer),public.incident_crew_history(uuid,uuid,uuid,integer) to authenticated;
