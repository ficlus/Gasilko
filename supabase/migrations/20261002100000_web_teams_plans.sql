-- M8.3: scoped web projections and exact-organization adapters to the M7 domain.
-- No Android tables, lifecycle, routing algorithm or inspection semantics change.
create policy web_teams_read on public.inspection_teams for select to authenticated using(private.web_read(organization_id));
create policy web_team_members_read on public.inspection_team_members for select to authenticated using(private.web_read(organization_id));
create policy web_plans_read on public.inspection_plans for select to authenticated using(private.web_read(organization_id));
create policy web_plan_teams_read on public.inspection_plan_teams for select to authenticated using(private.web_read(organization_id));
create policy web_plan_items_read on public.inspection_plan_items for select to authenticated using(private.web_read(organization_id));
create policy web_plan_routes_read on public.inspection_plan_routes for select to authenticated using(private.web_read(organization_id));
create policy web_reassignments_read on public.plan_reassignments for select to authenticated using(private.web_read(organization_id));
create index web_plans_recent on public.inspection_plans(organization_id,updated_at desc,id);
create index web_teams_name on public.inspection_teams(organization_id,name,id);

create function private.web_team_revision(team uuid) returns text
language sql stable security definer set search_path='' as $$
 select md5(jsonb_build_array(to_jsonb(t),(select coalesce(jsonb_agg(to_jsonb(m) order by m.user_id),'[]')
 from public.inspection_team_members m where m.team_id=t.id))::text) from public.inspection_teams t where t.id=team;
$$;

create function public.web_teams(root uuid, search text default '', state text default '', page integer default 0, owner uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.name,x.id),'[]') into rows from (
 select t.*,o.name organization_name,private.can_manage_organization(t.organization_id) writable,
 (select count(*) from public.inspection_team_members m where m.team_id=t.id and m.active) member_count,
 (select count(*) from public.inspection_plan_teams pt join public.inspection_plans p on p.id=pt.plan_id
 where pt.team_id=t.id and pt.active and p.status in ('PLANNED','ACTIVE')) plan_count
 from public.inspection_teams t join public.organizations o on o.id=t.organization_id
 where t.organization_id in (select private.web_subtree(root)) and (owner is null or t.organization_id=owner)
 and (state='' or t.active=(state='active')) and position(lower(left(search,200)) in lower(t.name))>0
 order by t.name,t.id limit 51 offset least(greatest(page,0),10000)*50) x;
 return jsonb_build_object('rows',(select coalesce(jsonb_agg(value order by ord),'[]') from jsonb_array_elements(rows) with ordinality a(value,ord) where ord<=50),'more',jsonb_array_length(rows)>50);
end;
$$;

create function public.web_team_detail(root uuid, team uuid, page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t public.inspection_teams;
begin
 select * into t from public.inspection_teams where id=team and organization_id in (select private.web_subtree(root));
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return jsonb_build_object('team',to_jsonb(t),'revision',private.web_team_revision(team),
 'writable',private.can_manage_organization(t.organization_id),
 'member_count',(select count(*) from public.inspection_team_members where team_id=team and active),
 'members',(select coalesce(jsonb_agg(to_jsonb(x) order by x.active desc,x.display_name,x.user_id),'[]') from (
 select m.user_id,m.active,p.display_name from public.inspection_team_members m join public.profiles p on p.id=m.user_id
 where m.team_id=team order by m.active desc,p.display_name,m.user_id limit 50 offset least(greatest(page,0),10000)*50) x),
 'more',(select count(*)> (least(greatest(page,0),10000)+1)*50 from public.inspection_team_members where team_id=team),
 'plans',(select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc,x.id),'[]') from (
 select p.id,p.name,p.status,p.updated_at from public.inspection_plan_teams pt join public.inspection_plans p on p.id=pt.plan_id
 where pt.team_id=team and pt.active and p.status in ('PLANNED','ACTIVE') order by p.updated_at desc,p.id limit 20) x));
end;
$$;

create view private.web_plan_summary as
 select p.id,p.organization_id,o.name organization_name,p.name,p.status,p.version,p.selection_mode,p.selection_snapshot,
 p.start_latitude,p.start_longitude,p.return_to_start,p.created_at,p.updated_at,p.started_at,p.completed_at,
 totals.total,totals.completed,totals.skipped,totals.unassigned,totals.latest_activity,
 (select count(*) from public.inspection_plan_teams t where t.plan_id=p.id and t.active) team_count,
 (select count(*) from public.inspection_plan_routes r where r.plan_id=p.id and not r.valid and exists(
 select 1 from public.inspection_plan_teams pt where pt.plan_id=r.plan_id and pt.team_id=r.team_id and pt.active)) stale_routes,
 (select coalesce(jsonb_agg(jsonb_build_object('team_id',r.team_id,'provider',r.provider,'valid',r.valid,'calculated_at',r.calculated_at) order by r.team_id),'[]')
 from public.inspection_plan_routes r where r.plan_id=p.id and exists(
 select 1 from public.inspection_plan_teams pt where pt.plan_id=r.plan_id and pt.team_id=r.team_id and pt.active)) route_summary
 from public.inspection_plans p join public.organizations o on o.id=p.organization_id cross join lateral (
 select count(*) total,count(*) filter(where i.inspection_id is not null) completed,
 count(*) filter(where i.inspection_id is null and i.skipped_at is not null) skipped,
 count(*) filter(where i.team_id is null) unassigned,max(greatest(i.completed_at,i.skipped_at)) latest_activity
 from public.inspection_plan_items i where i.plan_id=p.id and i.active) totals;
revoke all on private.web_plan_summary from public,anon,authenticated,service_role;

create function public.web_plans(root uuid, search text default '', state text default '', page integer default 0, owner uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 with picked as materialized (
 select p.id from public.inspection_plans p where p.organization_id in(select private.web_subtree(root))
 and (owner is null or p.organization_id=owner) and (state='' or p.status=state)
 and position(lower(left(search,200)) in lower(p.name))>0
 order by p.updated_at desc,p.id limit 26 offset least(greatest(page,0),10000)*25)
 select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc,x.id),'[]') into rows from (
 select p.*,private.can_manage_organization(p.organization_id) writable from picked join private.web_plan_summary p on p.id=picked.id) x;
 return jsonb_build_object('rows',(select coalesce(jsonb_agg(value order by ord),'[]') from jsonb_array_elements(rows) with ordinality a(value,ord) where ord<=25),'more',jsonb_array_length(rows)>25);
end;
$$;

create function public.web_plan_detail(root uuid, plan uuid, history_page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare p private.web_plan_summary;
begin
 select * into p from private.web_plan_summary where id=plan and organization_id in(select private.web_subtree(root));
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return jsonb_build_object('plan',to_jsonb(p),'writable',private.can_manage_organization(p.organization_id),
 'limited',p.total>2000 or p.team_count>100,
 'teams',(select coalesce(jsonb_agg(to_jsonb(x) order by x.name,x.id),'[]') from (
 select t.id,t.name,t.active,count(i.id) total,count(i.id) filter(where i.inspection_id is not null) completed,
 count(i.id) filter(where i.inspection_id is null and i.skipped_at is not null) skipped,max(greatest(i.completed_at,i.skipped_at)) latest_activity
 from public.inspection_plan_teams pt join public.inspection_teams t on t.id=pt.team_id
 left join public.inspection_plan_items i on i.plan_id=pt.plan_id and i.team_id=t.id and i.active
 where pt.plan_id=plan and pt.active group by t.id,t.name,t.active order by t.name,t.id limit 100) x),
 'items',(select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') from (
 select i.*,to_jsonb(h) hydrant,s.result inspection_result,
 case when s.id is not null then jsonb_build_object('id',s.id,'mode',s.mode,'result',s.result,'completed_at',s.completed_at,
 'notes',s.notes,'pressure_bar',s.pressure_bar,'flow_l_min',s.flow_l_min) end inspection
 from public.inspection_plan_items i
 join private.web_hydrant_rows h on h.id=i.hydrant_id and h.organization_id=i.organization_id
 left join public.inspections s on s.id=i.inspection_id
 where i.plan_id=plan and i.active order by i.id limit 2000) x),
 'routes',(select coalesce(jsonb_agg(to_jsonb(x) order by x.team_id),'[]') from (
 select r.* from public.inspection_plan_routes r where r.plan_id=plan and exists(
 select 1 from public.inspection_plan_teams pt where pt.plan_id=r.plan_id and pt.team_id=r.team_id and pt.active)
 order by r.team_id limit 100) x),
 'history',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id),'[]') from (
 select r.id,r.item_id,r.from_team_id,r.to_team_id,r.reason,r.created_at,p.display_name actor
 from public.plan_reassignments r left join public.profiles p on p.id=r.actor where r.plan_id=plan
 order by r.created_at desc,r.id limit 50 offset least(greatest(history_page,0),10000)*50) x),
 'history_more',(select count(*)>(least(greatest(history_page,0),10000)+1)*50 from public.plan_reassignments where plan_id=plan),
 'audit',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (
 select a.action,a.created_at,person.display_name actor from public.audit_log a left join public.profiles person on person.id=a.user_id
 where a.organization_id=p.organization_id and a.entity_type='inspection_plans' and a.entity_id=plan
 order by a.created_at desc limit 10) x));
end;
$$;

create function public.web_planning_dashboard(root uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return jsonb_build_object(
 'draft',(select count(*) from public.inspection_plans where organization_id in(select private.web_subtree(root)) and status='DRAFT'),
 'active',(select count(*) from public.inspection_plans where organization_id in(select private.web_subtree(root)) and status='ACTIVE'),
 'teams',(select count(distinct t.team_id) from public.inspection_plan_teams t join public.inspection_plans p on p.id=t.plan_id
 where p.organization_id in(select private.web_subtree(root)) and p.status='ACTIVE' and t.active),
 'stale',(select count(*) from public.inspection_plan_routes r join public.inspection_plans p on p.id=r.plan_id
 where r.organization_id in(select private.web_subtree(root)) and not r.valid and p.status in ('DRAFT','PLANNED','ACTIVE') and exists(
 select 1 from public.inspection_plan_teams pt where pt.plan_id=r.plan_id and pt.team_id=r.team_id and pt.active)),
 'plans',(with picked as materialized(select id from public.inspection_plans where organization_id in(select private.web_subtree(root))
 and status='ACTIVE' order by updated_at desc,id limit 10)
 select coalesce(jsonb_agg(to_jsonb(p) order by p.updated_at desc,p.id),'[]') from picked join private.web_plan_summary p on p.id=picked.id),
 'finished',(with picked as materialized(select id from public.inspection_plans where organization_id in(select private.web_subtree(root))
 and status='COMPLETED' order by updated_at desc,id limit 10)
 select coalesce(jsonb_agg(to_jsonb(p) order by p.updated_at desc,p.id),'[]') from picked join private.web_plan_summary p on p.id=picked.id));
end;
$$;

-- A preview runs the authoritative assignment in a rollback-only subtransaction.
-- This reuses M7.4, including locks/validation/projection, without copying its algorithm.
create function public.web_assignment_preview(organization uuid, request jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare preview jsonb;
begin
 perform private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']::text[]);
 begin
  perform public.assign_inspection_plan(organization,request);
  select coalesce(jsonb_object_agg(id::text,team_id order by id),'{}') into preview
   from public.inspection_plan_items where plan_id=(request->>'id')::uuid and organization_id=organization and active;
  raise exception 'PREVIEW_ROLLBACK' using errcode='ZP001';
 exception when sqlstate 'ZP001' then null;
 end;
 return preview;
end;
$$;

-- Durable web retry receipts use the existing immutable audit log, not another queue/model.
create function public.web_planning_write(organization uuid, operation uuid, action text, request jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare actor uuid; prior jsonb; p public.inspection_plans; t public.inspection_teams; assignments jsonb; item record;
 target uuid:=(request->>'id')::uuid; result jsonb; before_data jsonb;
begin
 actor:=private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']::text[]);
 if operation is null then raise exception 'INVALID_OPERATION' using errcode='22023'; end if;
 select new_data into prior from public.audit_log where entity_type='web_planning_operations' and entity_id=operation;
 if found then
  if prior->>'actor' is distinct from actor::text or prior->>'organization' is distinct from organization::text or prior->>'action' is distinct from action or prior->'request' is distinct from request then
   raise exception 'OPERATION_REUSED' using errcode='22023';
  end if;
  return prior->'result';
 end if;
 if action='TEAM' then
  select * into t from public.inspection_teams where id=target and organization_id=organization for update;
  if request->>'operation'<>'CREATE' and (not found or private.web_team_revision(target) is distinct from request->>'revision') then
   raise exception 'TEAM_VERSION_CONFLICT' using errcode='P0001';
  end if;
  perform public.manage_inspection_team(organization,target,request->>'operation',request->>'team_name',
   (request->>'enabled')::boolean,(request->>'member')::uuid,
   array(select value::uuid from jsonb_array_elements_text(coalesce(request->'initial_members','[]'))));
 elsif action='SAVE' then
  perform public.save_inspection_plan(organization,request||jsonb_build_object('operation_id',operation));
 elsif action='ACTIVATE' then
  perform public.activate_inspection_plan(organization,request||jsonb_build_object('operation_id',operation));
 elsif action='REASSIGN' then
  perform public.reassign_plan_item(organization,request||jsonb_build_object('id',operation));
 elsif action='ASSIGN' then
  perform public.assign_inspection_plan(organization,(request-'preview')||jsonb_build_object('operation_id',operation,'action','ASSIGN'));
  select coalesce(jsonb_object_agg(id::text,team_id order by id),'{}') into assignments from public.inspection_plan_items where plan_id=target and active;
  if assignments is distinct from request->'preview' then raise exception 'PLAN_VERSION_CONFLICT' using errcode='P0001'; end if;
 elsif action='MANUAL' then
  select * into p from public.inspection_plans where id=target and organization_id=organization for update;
  if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if p.version is distinct from (request->>'version')::bigint then raise exception 'PLAN_VERSION_CONFLICT' using errcode='P0001'; end if;
  if p.status not in ('DRAFT','PLANNED') then raise exception 'PLAN_NOT_EDITABLE' using errcode='22023'; end if;
  if jsonb_typeof(request->'assignments') is distinct from 'object' then raise exception 'INVALID_PLAN' using errcode='22023'; end if;
  for item in select key::uuid id,value::uuid team from jsonb_each_text(request->'assignments') loop
   if not exists(select 1 from public.inspection_plan_items where id=item.id and plan_id=p.id and organization_id=organization and active and inspection_id is null) or
    not exists(select 1 from public.inspection_plan_teams pt join public.inspection_teams t on t.id=pt.team_id where pt.plan_id=p.id and pt.team_id=item.team and pt.active and t.active and t.organization_id=organization) then
    raise exception 'INVALID_PLAN_TEAM' using errcode='22023';
   end if;
  end loop;
  select coalesce(jsonb_object_agg(id::text,team_id),'{}') into before_data from public.inspection_plan_items where plan_id=p.id and active;
  update public.inspection_plan_items i set team_id=(request->'assignments'->>i.id::text)::uuid
   where i.plan_id=p.id and request->'assignments' ? i.id::text;
  update public.inspection_plans set version=version+1,last_operation_id=operation,last_request=request where id=p.id;
  perform private.write_audit(organization,actor,'PLAN_ASSIGNED','inspection_plans',p.id,before_data,
   jsonb_build_object('assignments',request->'assignments','method','MANUAL','operation',operation));
 else raise exception 'INVALID_OPERATION' using errcode='22023';
 end if;
 result:=jsonb_build_object('acknowledged',true);
 perform private.write_audit(organization,actor,'WEB_PLANNING_WRITE','web_planning_operations',operation,null,
  jsonb_build_object('actor',actor,'organization',organization,'action',action,'request',request,'result',result));
 return result;
end;
$$;

-- Optional web route entry retains the same Edge Function and M7 prepare/commit contracts.
-- Exact manager authority is verified both before provider work and at commit time.
create function public.web_prepare_plan_routes(organization uuid, request jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
begin
 perform private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']::text[]);
 return public.prepare_plan_routes(organization,request);
end;
$$;
create function public.web_commit_plan_routes(actor uuid, organization uuid, request jsonb, input jsonb, results jsonb) returns void
language plpgsql volatile security definer set search_path='' as $$
begin
 perform private.lock_organization(organization);
 if not exists(select 1 from public.user_organizations u join public.profiles p on p.id=u.user_id
  join public.organizations o on o.id=u.organization_id where u.user_id=actor and u.organization_id=organization
  and u.role in ('MANAGER','ADMIN') and p.account_status='ACTIVE' and o.active) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 perform public.commit_plan_routes(actor,organization,request,input,results);
end;
$$;

revoke all on function private.web_team_revision(uuid) from public,anon,authenticated,service_role;
revoke all on function public.web_teams(uuid,text,text,integer,uuid),public.web_team_detail(uuid,uuid,integer),
 public.web_plans(uuid,text,text,integer,uuid),public.web_plan_detail(uuid,uuid,integer),public.web_planning_dashboard(uuid),
 public.web_assignment_preview(uuid,jsonb),public.web_planning_write(uuid,uuid,text,jsonb),public.web_prepare_plan_routes(uuid,jsonb)
 from public,anon,authenticated,service_role;
grant execute on function public.web_teams(uuid,text,text,integer,uuid),public.web_team_detail(uuid,uuid,integer),
 public.web_plans(uuid,text,text,integer,uuid),public.web_plan_detail(uuid,uuid,integer),public.web_planning_dashboard(uuid),
 public.web_assignment_preview(uuid,jsonb),public.web_planning_write(uuid,uuid,text,jsonb),public.web_prepare_plan_routes(uuid,jsonb) to authenticated;
revoke all on function public.web_commit_plan_routes(uuid,uuid,jsonb,jsonb,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.web_commit_plan_routes(uuid,uuid,jsonb,jsonb,jsonb) to service_role;

-- Realtime is an invalidation hint; scoped refetch is always the source of truth.
do $$ declare tab text; begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  foreach tab in array array['inspection_plans','inspection_plan_items','inspection_plan_teams','inspection_plan_routes','plan_reassignments'] loop
   if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=tab) then
    execute format('alter publication supabase_realtime add table public.%I',tab);
   end if;
  end loop;
 end if;
end $$;
