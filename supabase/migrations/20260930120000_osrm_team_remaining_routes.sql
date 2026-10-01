-- Provider-neutral, team-scoped routing. No new tables or client credentials.
create function private.authorize_team_route(actor uuid, organization uuid, plan uuid, team uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform private.lock_organization(organization);
 perform 1 from public.profiles where id=actor and account_status='ACTIVE' for share;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from public.organizations where id=organization and active for share;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from public.user_organizations where user_id=actor and organization_id=organization for share;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if team is not null then
  perform 1 from public.inspection_plan_teams pt join public.inspection_teams t on t.id=pt.team_id
   where pt.plan_id=plan and pt.organization_id=organization and pt.team_id=team and pt.active and t.active
    and t.organization_id=organization for share of pt,t;
  if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 end if;
 if exists(select 1 from public.user_organizations where user_id=actor and organization_id=organization and role in ('MANAGER','ADMIN')) then return; end if;
 if team is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from public.inspection_team_members where team_id=team and organization_id=organization and user_id=actor and active for share;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
end;
$$;
create or replace function private.team_route_input(organization uuid, plan uuid, target uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare p public.inspection_plans; teams jsonb; items jsonb;
begin
 select * into p from public.inspection_plans where id=plan and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p.status not in ('DRAFT','PLANNED','ACTIVE') then raise exception 'PLAN_NOT_EDITABLE' using errcode='22023'; end if;
 perform 1 from public.inspection_teams t join public.inspection_plan_teams pt on pt.team_id=t.id
  where pt.plan_id=plan and (target is null or pt.team_id=target) and pt.active order by t.id for share of t;
 if exists(select 1 from public.inspection_plan_teams pt join public.inspection_teams t on t.id=pt.team_id
   where pt.plan_id=plan and (target is null or pt.team_id=target) and pt.active and (not t.active or t.organization_id<>organization)) then
  raise exception 'ROUTE_ASSIGNMENTS_REQUIRED' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(team_id order by team_id),'[]'::jsonb) into teams
  from public.inspection_plan_teams where plan_id=plan and (target is null or team_id=target) and active;
 if jsonb_array_length(teams)=0 then raise exception 'ROUTE_ASSIGNMENTS_REQUIRED' using errcode='22023'; end if;
 perform 1 from public.hydrants h join public.inspection_plan_items i on i.hydrant_id=h.id
  where i.plan_id=plan and (target is null or i.team_id=target) and i.active and (p.status<>'ACTIVE' or i.inspection_id is null) order by h.id for share of h;
 if exists(select 1 from public.inspection_plan_items i join public.hydrants h on h.id=i.hydrant_id
   where i.plan_id=plan and (target is null or i.team_id=target) and i.active and (p.status<>'ACTIVE' or i.inspection_id is null) and (h.organization_id<>organization or h.latitude is null or h.longitude is null
    or not(h.latitude between -90 and 90 and h.longitude between -180 and 180))) then
  raise exception 'ROUTE_COORDINATES_REQUIRED' using errcode='22023';
 end if;
 if exists(select 1 from public.inspection_plan_items i where i.plan_id=plan and (target is null or i.team_id=target) and i.active and (p.status<>'ACTIVE' or i.inspection_id is null) and
   (i.team_id is null or not exists(select 1 from public.inspection_plan_teams pt where pt.plan_id=plan and pt.team_id=i.team_id and pt.active))) then
  raise exception 'ROUTE_ASSIGNMENTS_REQUIRED' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'hydrant',h.id,'team',i.team_id,'code',h.code,
    'latitude',h.latitude::double precision,'longitude',h.longitude::double precision) order by h.id),'[]'::jsonb) into items
  from public.inspection_plan_items i join public.hydrants h on h.id=i.hydrant_id where i.plan_id=plan and (target is null or i.team_id=target) and i.active and (p.status<>'ACTIVE' or i.inspection_id is null);
 if jsonb_array_length(items)=0 and p.status<>'ACTIVE' then raise exception 'ROUTE_ASSIGNMENTS_REQUIRED' using errcode='22023'; end if;
 return jsonb_build_object('id',p.id,'organization',organization,'version',p.version,'latitude',p.start_latitude::double precision,
  'longitude',p.start_longitude::double precision,'returnToStart',p.return_to_start,'teams',teams,'items',items);
end;
$$;
create or replace function public.prepare_plan_routes(organization uuid, request jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare p public.inspection_plans; input jsonb;
begin
 perform private.authorize_hydrant_write(organization,array['FIREFIGHTER','MANAGER','ADMIN']::text[]);
 if (request->>'action' is null or request->>'action' not in ('ROUTE','ROUTE_REMAINING')) or (request->>'operation_id')::uuid is null then
  raise exception 'INVALID_PLAN' using errcode='22023';
 end if;
 select * into p from public.inspection_plans where id=(request->>'id')::uuid and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform private.authorize_team_route(auth.uid(),organization,p.id,(request->>'team_id')::uuid);
 if p.last_operation_id=(request->>'operation_id')::uuid and p.last_request=request then return jsonb_build_object('acknowledged',true); end if;
 if p.version is distinct from (request->>'version')::bigint then raise exception 'PLAN_VERSION_CONFLICT' using errcode='P0001'; end if;
 if request->>'team_id' is not null and p.status<>'ACTIVE' then raise exception 'INVALID_PLAN' using errcode='22023'; end if;
 if (p.status='ACTIVE') is distinct from (request->>'action'='ROUTE_REMAINING') then raise exception 'PLAN_NOT_EDITABLE' using errcode='22023'; end if;
 input:=private.team_route_input(organization,p.id,(request->>'team_id')::uuid);
 return jsonb_build_object('input',input);
end;
$$;
create or replace function public.commit_plan_routes(actor uuid, organization uuid, request jsonb, input jsonb, results jsonb) returns void
language plpgsql volatile security definer set search_path='' as $$
declare p public.inspection_plans; current_input jsonb; result jsonb; stop jsonb; team uuid; seen uuid[]:='{}'; item_ids uuid[];
 position integer; previous jsonb;
begin
 perform private.lock_organization(organization);
 perform 1 from public.profiles where id=actor and account_status='ACTIVE' for share;
 if not found or not exists(select 1 from public.user_organizations where user_id=actor and organization_id=organization ) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 perform 1 from public.organizations where id=organization and active for share;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into p from public.inspection_plans where id=(request->>'id')::uuid and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform private.authorize_team_route(actor,organization,p.id,(request->>'team_id')::uuid);
 if p.last_operation_id=(request->>'operation_id')::uuid and p.last_request=request then return; end if;
 if (request->>'action' is null or request->>'action' not in ('ROUTE','ROUTE_REMAINING')) or (request->>'operation_id')::uuid is null then raise exception 'INVALID_PLAN' using errcode='22023'; end if;
 if request->>'team_id' is not null and p.status<>'ACTIVE' then raise exception 'INVALID_PLAN' using errcode='22023'; end if;
 if (p.status='ACTIVE') is distinct from (request->>'action'='ROUTE_REMAINING') then raise exception 'PLAN_NOT_EDITABLE' using errcode='22023'; end if;
 current_input:=private.team_route_input(organization,p.id,(request->>'team_id')::uuid);
 if current_input is distinct from input or p.version is distinct from (request->>'version')::bigint then
  raise exception 'PLAN_VERSION_CONFLICT' using errcode='P0001';
 end if;
 if jsonb_typeof(results) is distinct from 'array' or jsonb_array_length(results)<>jsonb_array_length(input->'teams') then
  raise exception 'INVALID_ROUTES' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(to_jsonb(r)-'geometry' order by team_id),'[]'::jsonb) into previous
  from public.inspection_plan_routes r where plan_id=p.id;
 -- All validation/mutations roll back together. No partial team results are visible.
 if p.status='ACTIVE' then
  update public.inspection_plan_routes set valid=false where plan_id=p.id and (request->>'team_id' is null or team_id=(request->>'team_id')::uuid);
  update public.inspection_plan_items set route_order=null where plan_id=p.id and inspection_id is null and (request->>'team_id' is null or team_id=(request->>'team_id')::uuid);
 else perform private.invalidate_plan_routes(p.id); end if;
 for result in select value from jsonb_array_elements(results) loop
  team:=(result->>'team')::uuid;
  if team is null or not (input->'teams' @> jsonb_build_array(team)) or team=any(seen) or not exists(select 1 from public.inspection_plan_teams where plan_id=p.id and team_id=team and active)
   or jsonb_typeof(result->'stops') is distinct from 'array' or coalesce(result->>'provider','') not in ('GraphHopper','OSRM')
   or result->>'profile' is distinct from 'car' or result->'geometry'->>'type' is distinct from 'FeatureCollection'
   or jsonb_typeof(result->'geometry'->'features') is distinct from 'array' then
   raise exception 'INVALID_ROUTES' using errcode='22023';
  end if;
  seen:=array_append(seen,team);item_ids:='{}';position:=0;
  for stop in select value from jsonb_array_elements(result->'stops') loop
   position:=position+1;
   if (stop->>'id')::uuid=any(item_ids) or not exists(select 1 from jsonb_array_elements(input->'items') i
     where i->>'id'=stop->>'id' and i->>'team'=team::text and i=stop-'order') or
     (stop->>'order')::integer is distinct from position then raise exception 'INVALID_ROUTES' using errcode='22023'; end if;
   item_ids:=array_append(item_ids,(stop->>'id')::uuid);
   update public.inspection_plan_items set route_order=position where id=(stop->>'id')::uuid and plan_id=p.id and team_id=team and active;
  end loop;
  if cardinality(item_ids)<>(select count(*) from jsonb_array_elements(input->'items') i where i->>'team'=team::text) then
   raise exception 'INVALID_ROUTES' using errcode='22023';
  end if;
  insert into public.inspection_plan_routes(plan_id,organization_id,team_id,provider,profile,distance_m,duration_s,geometry,stops)
  values(p.id,organization,team,result->>'provider',result->>'profile',(result->>'distance_m')::double precision,
   (result->>'duration_s')::double precision,result->'geometry',result->'stops')
  on conflict(plan_id,team_id) do update set provider=excluded.provider,profile=excluded.profile,distance_m=excluded.distance_m,
   duration_s=excluded.duration_s,geometry=excluded.geometry,stops=excluded.stops,valid=true,calculated_at=statement_timestamp();
 end loop;
 update public.inspection_plans set version=p.version+1,last_operation_id=(request->>'operation_id')::uuid,last_request=request where id=p.id;
 perform private.write_audit(organization,actor,'PLAN_ROUTES_CALCULATED','inspection_plans',p.id,previous,
  jsonb_build_object('operation',request->>'operation_id','version',p.version+1,'providers',(select jsonb_agg(distinct value->>'provider') from jsonb_array_elements(results)),'profile','car',
   'routes',(select jsonb_agg(to_jsonb(r)-'geometry' order by team_id) from public.inspection_plan_routes r where plan_id=p.id and valid),
   'actor_source','authenticated_edge'));
end;
$$;

-- Stale even if the client disconnects immediately after the immutable inspection commits.
create function private.stale_completed_team_route() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if old.inspection_id is null and new.inspection_id is not null then
  update public.inspection_plan_routes set valid=false where plan_id=new.plan_id and team_id=new.team_id;
 end if;
 return new;
end;
$$;
create trigger completed_team_route_stale after update of inspection_id on public.inspection_plan_items
 for each row execute function private.stale_completed_team_route();
alter function private.authorize_team_route(uuid,uuid,uuid,uuid) owner to postgres;
alter function private.team_route_input(uuid,uuid,uuid) owner to postgres;
alter function private.stale_completed_team_route() owner to postgres;
revoke all on function private.authorize_team_route(uuid,uuid,uuid,uuid),private.team_route_input(uuid,uuid,uuid),
 private.stale_completed_team_route() from public,anon,authenticated,service_role;