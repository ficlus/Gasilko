-- M14.4.2: bounded source-domain projections only. No writes, tables or policy changes.
create function public.hydrant_plan_context(p_hydrant uuid,p_candidates boolean default false)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows_value jsonb;
begin
 if not private.incident_hydrant_readable(p_hydrant) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.updated_at desc,q.id),'[]') into rows_value from (
 select p.id,p.organization_id,p.name,p.status,p.updated_at,
 exists(select 1 from public.inspection_plan_items i where i.plan_id=p.id and i.hydrant_id=p_hydrant and i.active) included
 from public.inspection_plans p
 where ((private.is_organization_member(p.organization_id) and exists(select 1 from public.organizations o where o.id=p.organization_id and o.active)) or private.web_read(p.organization_id))
 and case when p_candidates then p.status in ('DRAFT','PLANNED') and private.can_manage_organization(p.organization_id)
 and p.organization_id=(select h.organization_id from public.hydrants h where h.id=p_hydrant)
 else p.status in ('DRAFT','PLANNED','ACTIVE') and exists(select 1 from public.inspection_plan_items i where i.plan_id=p.id and i.hydrant_id=p_hydrant and i.active) end
 order by p.updated_at desc,p.id limit 26) q;
 return jsonb_build_object('rows',case when jsonb_array_length(rows_value)>25 then rows_value-25 else rows_value end,'more',jsonb_array_length(rows_value)>25);
end; $$;

create function public.hydrant_incident_context(p_hydrant uuid,p_candidates boolean default false)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows_value jsonb;
begin
 if not private.incident_hydrant_readable(p_hydrant) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.updated_at desc,q.id),'[]') into rows_value from (
 select i.id,i.title name,i.reference_number,i.status,i.updated_at,acting.organization_id,
 (select l.purpose from public.incident_hydrant_links l where l.incident_id=i.id and l.hydrant_id=p_hydrant and l.active limit 1) purpose
 from public.incidents i
 cross join lateral (select m.organization_id from public.user_organizations m
 where m.user_id=auth.uid() and private.incident_acting_member(m.organization_id)
 and (not p_candidates or private.has_incident_capability(i.id,m.organization_id,'MANAGE_COP'))
 order by m.organization_id limit 1) acting
 where private.can_read_incident(i.id) and i.status in ('ACTIVE','STABILIZED')
 and (p_candidates or exists(select 1 from public.incident_hydrant_links l where l.incident_id=i.id and l.hydrant_id=p_hydrant and l.active))
 order by i.updated_at desc,i.id limit 26) q;
 return jsonb_build_object('rows',case when jsonb_array_length(rows_value)>25 then rows_value-25 else rows_value end,'more',jsonb_array_length(rows_value)>25);
end; $$;

create function public.incident_team_template(p_incident_id uuid,p_acting_organization_id uuid,p_unit_assignment_id uuid,p_team uuid default null,p_page integer default 0)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare owner_value uuid; rows_value jsonb;
begin
 if p_page is null or p_page not between 0 and 10000 then raise exception 'VALIDATION_FAILED'; end if;
 select d.organization_id into owner_value from public.incident_units d join public.incidents i on i.id=d.incident_id
 where d.id=p_unit_assignment_id and d.incident_id=p_incident_id and d.status not in ('RELEASED','UNAVAILABLE') and i.status in ('ACTIVE','STABILIZED');
 if owner_value is null or not private.can_manage_incident_unit(p_incident_id,p_acting_organization_id,owner_value,p_unit_assignment_id,'CREW')
 or not ((private.is_organization_member(owner_value) and exists(select 1 from public.organizations o where o.id=owner_value and o.active)) or private.web_read(owner_value))
 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_team is null then
  select coalesce(jsonb_agg(to_jsonb(q) order by q.name,q.id),'[]') into rows_value from (
   select t.id,t.name from public.inspection_teams t where t.organization_id=owner_value and t.active order by t.name,t.id limit 31 offset p_page*30) q;
 else
  if not exists(select 1 from public.inspection_teams t where t.id=p_team and t.organization_id=owner_value and t.active) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  -- Preview eligibility is advisory; incident_add_crew_member rechecks all locked
  -- participation/membership/profile/unit rules on each explicit confirmation.
  select coalesce(jsonb_agg(to_jsonb(q) order by q.id),'[]') into rows_value from (
   select m.user_id id,coalesce(pr.display_name,m.user_id::text) name,
    (pr.account_status='ACTIVE' and exists(select 1 from public.user_organizations u where u.user_id=m.user_id and u.organization_id=owner_value)
     and not exists(select 1 from public.incident_crew_members c where c.incident_id=p_incident_id and c.user_id=m.user_id and c.status='ACTIVE')) eligible
   from public.inspection_team_members m join public.profiles pr on pr.id=m.user_id
   where m.team_id=p_team and m.organization_id=owner_value and m.active order by m.user_id limit 31 offset p_page*30) q;
 end if;
 return jsonb_build_object('rows',case when jsonb_array_length(rows_value)>30 then rows_value-30 else rows_value end,'more',jsonb_array_length(rows_value)>30);
end; $$;
revoke all on function public.hydrant_plan_context(uuid,boolean),public.hydrant_incident_context(uuid,boolean),public.incident_team_template(uuid,uuid,uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function public.hydrant_plan_context(uuid,boolean),public.hydrant_incident_context(uuid,boolean),public.incident_team_template(uuid,uuid,uuid,uuid,integer) to authenticated;

-- Resolve a deep-linked historical resource to the existing bounded history page.
-- The original incident_resources reader still owns the DTO and all action flags.
create function public.incident_resource_selection_page(p_incident_id uuid,p_acting_organization_id uuid,p_kind text,p_id uuid)
returns integer language plpgsql stable security definer set search_path='' as $$
declare page_value integer:=0;u public.incident_units;a public.incident_resource_allocations;
begin
 if public.incident_context(p_incident_id,p_acting_organization_id) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_kind='UNIT' then
  select * into u from public.incident_units d where d.id=p_id and d.incident_id=p_incident_id and d.status in ('RELEASED','UNAVAILABLE');
  if found then select least(count(*)/50,100000)::integer into page_value from public.incident_units d
   where d.incident_id=p_incident_id and d.status in ('RELEASED','UNAVAILABLE') and (d.assigned_at,d.id)>(u.assigned_at,u.id); end if;
 elsif p_kind='ALLOCATION' then
  select * into a from public.incident_resource_allocations r where r.id=p_id and r.incident_id=p_incident_id and r.status not in ('RESERVED','DEPLOYED');
  if found then select least(count(*)/50,100000)::integer into page_value from public.incident_resource_allocations r
   where r.incident_id=p_incident_id and r.status not in ('RESERVED','DEPLOYED') and (r.allocated_at,r.id)>(a.allocated_at,a.id); end if;
 else raise exception 'VALIDATION_FAILED'; end if;
 return page_value;
end; $$;
revoke all on function public.incident_resource_selection_page(uuid,uuid,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.incident_resource_selection_page(uuid,uuid,text,uuid) to authenticated;
