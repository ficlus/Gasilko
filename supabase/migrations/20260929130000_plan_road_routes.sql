-- M7.5: derived road routes. Team assignments and frozen selections are never changed.
alter table public.inspection_plan_items add column route_order integer check(route_order>0);
create table public.inspection_plan_routes (
 plan_id uuid not null, organization_id uuid not null, team_id uuid not null,
 provider text not null, profile text not null, calculated_at timestamptz not null default statement_timestamp(),
 distance_m double precision not null check(distance_m>=0 and distance_m<'Infinity'::double precision),
 duration_s double precision not null check(duration_s>=0 and duration_s<'Infinity'::double precision),
 geometry jsonb not null, stops jsonb not null, valid boolean not null default true,
 primary key(plan_id,team_id),
 foreign key(plan_id,organization_id) references public.inspection_plans(id,organization_id) on delete restrict,
 foreign key(plan_id,team_id) references public.inspection_plan_teams(plan_id,team_id) on delete restrict
);
create index plan_routes_org_idx on public.inspection_plan_routes(organization_id,plan_id);
alter table public.inspection_plan_routes enable row level security;
revoke all on public.inspection_plan_routes from public,anon,authenticated,service_role;
grant select on public.inspection_plan_routes to authenticated;
create policy plan_routes_read on public.inspection_plan_routes for select to authenticated using (
 private.is_organization_member(organization_id) and exists(select 1 from public.organizations o where o.id=organization_id and o.active));
create trigger plan_routes_no_delete before delete on public.inspection_plan_routes for each row execute function private.audit_immutable();
create trigger plan_routes_no_truncate before truncate on public.inspection_plan_routes for each statement execute function private.audit_immutable();

create function private.invalidate_plan_routes(plan uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 update public.inspection_plan_routes set valid=false where plan_id=plan and valid;
 update public.inspection_plan_items set route_order=null where plan_id=plan and route_order is not null;
end;
$$;
create function private.invalidate_changed_plan_routes() returns trigger
language plpgsql security definer set search_path='' as $$
declare plan uuid;
begin
 if tg_table_name='inspection_plans' then
  if (new.start_latitude,new.start_longitude,new.return_to_start) is distinct from
     (old.start_latitude,old.start_longitude,old.return_to_start) or new.status='CANCELLED' then
   perform private.invalidate_plan_routes(new.id);
  end if;
 elsif tg_table_name='hydrants' then
  if (new.latitude,new.longitude) is distinct from (old.latitude,old.longitude) then
   for plan in select distinct plan_id from public.inspection_plan_items where hydrant_id=new.id and active order by plan_id loop
    perform private.invalidate_plan_routes(plan);
   end loop;
  end if;
 else
  if tg_op='INSERT' or to_jsonb(new)->'active' is distinct from to_jsonb(old)->'active'
    or to_jsonb(new)->'team_id' is distinct from to_jsonb(old)->'team_id' then
   perform private.invalidate_plan_routes(new.plan_id);
  end if;
 end if;
 return new;
end;
$$;
create trigger plan_route_input_changed after update of start_latitude,start_longitude,return_to_start,status on public.inspection_plans
 for each row execute function private.invalidate_changed_plan_routes();
create trigger plan_route_assignment_changed after insert or update of team_id,active on public.inspection_plan_items
 for each row execute function private.invalidate_changed_plan_routes();
create trigger plan_route_teams_changed after insert or update of active on public.inspection_plan_teams
 for each row execute function private.invalidate_changed_plan_routes();
create trigger plan_route_coordinates_changed after update of latitude,longitude on public.hydrants
 for each row execute function private.invalidate_changed_plan_routes();

-- Called only after current authority is checked. Locks and canonical ordering make prepare/commit comparable.
create function private.plan_route_input(organization uuid, plan uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare p public.inspection_plans; teams jsonb; items jsonb;
begin
 select * into p from public.inspection_plans where id=plan and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p.status not in ('DRAFT','PLANNED') then raise exception 'PLAN_NOT_EDITABLE' using errcode='22023'; end if;
 perform 1 from public.inspection_teams t join public.inspection_plan_teams pt on pt.team_id=t.id
  where pt.plan_id=plan and pt.active order by t.id for share of t;
 if exists(select 1 from public.inspection_plan_teams pt join public.inspection_teams t on t.id=pt.team_id
   where pt.plan_id=plan and pt.active and (not t.active or t.organization_id<>organization)) then
  raise exception 'ROUTE_ASSIGNMENTS_REQUIRED' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(team_id order by team_id),'[]'::jsonb) into teams
  from public.inspection_plan_teams where plan_id=plan and active;
 if jsonb_array_length(teams)=0 then raise exception 'ROUTE_ASSIGNMENTS_REQUIRED' using errcode='22023'; end if;
 perform 1 from public.hydrants h join public.inspection_plan_items i on i.hydrant_id=h.id
  where i.plan_id=plan and i.active order by h.id for share of h;
 if exists(select 1 from public.inspection_plan_items i join public.hydrants h on h.id=i.hydrant_id
   where i.plan_id=plan and i.active and (h.organization_id<>organization or h.latitude is null or h.longitude is null
    or not(h.latitude between -90 and 90 and h.longitude between -180 and 180))) then
  raise exception 'ROUTE_COORDINATES_REQUIRED' using errcode='22023';
 end if;
 if exists(select 1 from public.inspection_plan_items i where i.plan_id=plan and i.active and
   (i.team_id is null or not exists(select 1 from public.inspection_plan_teams pt where pt.plan_id=plan and pt.team_id=i.team_id and pt.active))) then
  raise exception 'ROUTE_ASSIGNMENTS_REQUIRED' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'hydrant',h.id,'team',i.team_id,'code',h.code,
    'latitude',h.latitude::double precision,'longitude',h.longitude::double precision) order by h.id),'[]'::jsonb) into items
  from public.inspection_plan_items i join public.hydrants h on h.id=i.hydrant_id where i.plan_id=plan and i.active;
 if jsonb_array_length(items)=0 then raise exception 'ROUTE_ASSIGNMENTS_REQUIRED' using errcode='22023'; end if;
 return jsonb_build_object('id',p.id,'organization',organization,'version',p.version,'latitude',p.start_latitude::double precision,
  'longitude',p.start_longitude::double precision,'returnToStart',p.return_to_start,'teams',teams,'items',items);
end;
$$;
create function public.prepare_plan_routes(organization uuid, request jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare p public.inspection_plans; input jsonb;
begin
 perform private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']::text[]);
 if request->>'action' is distinct from 'ROUTE' or (request->>'operation_id')::uuid is null then
  raise exception 'INVALID_PLAN' using errcode='22023';
 end if;
 select * into p from public.inspection_plans where id=(request->>'id')::uuid and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p.last_operation_id=(request->>'operation_id')::uuid and p.last_request=request then return jsonb_build_object('acknowledged',true); end if;
 if p.version is distinct from (request->>'version')::bigint then raise exception 'PLAN_VERSION_CONFLICT' using errcode='P0001'; end if;
 input:=private.plan_route_input(organization,p.id);
 return jsonb_build_object('input',input);
end;
$$;
-- Service-only receipt: Edge verifies JWT first; recheck live user authority and input after provider calls.
create function public.commit_plan_routes(actor uuid, organization uuid, request jsonb, input jsonb, results jsonb) returns void
language plpgsql volatile security definer set search_path='' as $$
declare p public.inspection_plans; current_input jsonb; result jsonb; stop jsonb; team uuid; seen uuid[]:='{}'; item_ids uuid[];
 position integer; previous jsonb;
begin
 perform private.lock_organization(organization);
 perform 1 from public.profiles where id=actor and account_status='ACTIVE' for share;
 if not found or not exists(select 1 from public.user_organizations where user_id=actor and organization_id=organization and role in ('MANAGER','ADMIN')) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 perform 1 from public.organizations where id=organization and active for share;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into p from public.inspection_plans where id=(request->>'id')::uuid and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p.last_operation_id=(request->>'operation_id')::uuid and p.last_request=request then return; end if;
 if request->>'action' is distinct from 'ROUTE' or (request->>'operation_id')::uuid is null then raise exception 'INVALID_PLAN' using errcode='22023'; end if;
 current_input:=private.plan_route_input(organization,p.id);
 if current_input is distinct from input or p.version is distinct from (request->>'version')::bigint then
  raise exception 'PLAN_VERSION_CONFLICT' using errcode='P0001';
 end if;
 if jsonb_typeof(results) is distinct from 'array' or jsonb_array_length(results)<>jsonb_array_length(input->'teams') then
  raise exception 'INVALID_ROUTES' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(to_jsonb(r)-'geometry' order by team_id),'[]'::jsonb) into previous
  from public.inspection_plan_routes r where plan_id=p.id;
 -- All validation/mutations roll back together. No partial team results are visible.
 perform private.invalidate_plan_routes(p.id);
 for result in select value from jsonb_array_elements(results) loop
  team:=(result->>'team')::uuid;
  if team is null or team=any(seen) or not exists(select 1 from public.inspection_plan_teams where plan_id=p.id and team_id=team and active)
   or jsonb_typeof(result->'stops') is distinct from 'array' or result->>'provider' is distinct from 'GraphHopper'
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
  if cardinality(item_ids)<>(select count(*) from public.inspection_plan_items where plan_id=p.id and team_id=team and active) then
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
  jsonb_build_object('operation',request->>'operation_id','version',p.version+1,'provider','GraphHopper','profile','car',
   'routes',(select jsonb_agg(to_jsonb(r)-'geometry' order by team_id) from public.inspection_plan_routes r where plan_id=p.id and valid),
   'actor_source','authenticated_edge'));
end;
$$;
create or replace function public.read_inspection_plans(organization uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_organization_member(organization) or not exists(select 1 from public.organizations where id=organization and active) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 return jsonb_build_object(
  'plans',coalesce((select jsonb_agg(to_jsonb(p)-'last_request' order by p.created_at desc,p.id) from public.inspection_plans p where p.organization_id=organization),'[]'::jsonb),
  'teams',coalesce((select jsonb_agg(to_jsonb(t) order by t.plan_id,t.team_id) from public.inspection_plan_teams t where t.organization_id=organization),'[]'::jsonb),
  'items',coalesce((select jsonb_agg(to_jsonb(i) order by i.plan_id,i.hydrant_id) from public.inspection_plan_items i where i.organization_id=organization),'[]'::jsonb),
  'routes',coalesce((select jsonb_agg(to_jsonb(r) order by r.plan_id,r.team_id) from public.inspection_plan_routes r where r.organization_id=organization),'[]'::jsonb));
end;
$$;
alter function private.invalidate_plan_routes(uuid) owner to postgres;
alter function private.invalidate_changed_plan_routes() owner to postgres;
alter function private.plan_route_input(uuid,uuid) owner to postgres;
alter function public.prepare_plan_routes(uuid,jsonb) owner to postgres;
alter function public.commit_plan_routes(uuid,uuid,jsonb,jsonb,jsonb) owner to postgres;
revoke all on function private.invalidate_plan_routes(uuid),private.invalidate_changed_plan_routes(),private.plan_route_input(uuid,uuid),
 public.prepare_plan_routes(uuid,jsonb),public.commit_plan_routes(uuid,uuid,jsonb,jsonb,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.prepare_plan_routes(uuid,jsonb) to authenticated;
grant execute on function public.commit_plan_routes(uuid,uuid,jsonb,jsonb,jsonb) to service_role;

