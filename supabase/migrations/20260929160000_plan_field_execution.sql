-- M7.6: item execution is independent of frozen selection and team assignment.
alter table public.inspection_plan_items
 add column execution_version bigint not null default 0 check(execution_version>=0),
 add column inspection_id uuid unique references public.inspections(id) on delete restrict,
 add column completed_by uuid references public.profiles(id) on delete restrict,
 add column completed_at timestamptz,
 add column skip_reason text, add column skipped_by uuid references public.profiles(id) on delete restrict,
 add column skipped_at timestamptz;
create table public.plan_execution_events (
 id uuid primary key, organization_id uuid not null references public.organizations(id),
 plan_id uuid not null, item_id uuid not null references public.inspection_plan_items(id),
 actor uuid not null references public.profiles(id), request jsonb not null, receipt jsonb not null,
 created_at timestamptz not null default statement_timestamp(),
 foreign key(plan_id,organization_id) references public.inspection_plans(id,organization_id)
);
create index plan_execution_events_scope on public.plan_execution_events(organization_id,plan_id,item_id);
alter table public.plan_execution_events enable row level security;
revoke all on public.plan_execution_events from public,anon,authenticated,service_role;
grant select on public.plan_execution_events to authenticated;
create policy execution_events_read on public.plan_execution_events for select to authenticated using (
 private.is_organization_member(organization_id) and exists(select 1 from public.organizations where id=organization_id and active));
create trigger execution_events_immutable before update or delete on public.plan_execution_events
 for each row execute function private.audit_immutable();
create trigger execution_events_no_truncate before truncate on public.plan_execution_events
 for each statement execute function private.audit_immutable();

create function public.activate_inspection_plan(organization uuid, request jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare actor uuid; p public.inspection_plans;
begin
 actor:=private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']::text[]);
 select * into p from public.inspection_plans where id=(request->>'id')::uuid and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p.last_operation_id=(request->>'operation_id')::uuid and p.last_request=request then return public.read_inspection_plans(organization); end if;
 if p.version is distinct from (request->>'version')::bigint then raise exception 'PLAN_VERSION_CONFLICT' using errcode='P0001'; end if;
 if p.status<>'PLANNED' or (request->>'operation_id')::uuid is null then raise exception 'PLAN_NOT_PLANNED' using errcode='22023'; end if;
 if not exists(select 1 from public.inspection_plan_items where plan_id=p.id and active) or
 exists(select 1 from public.inspection_plan_items i where i.plan_id=p.id and i.active and
  (i.team_id is null or not exists(select 1 from public.inspection_plan_teams pt
   join public.inspection_teams t on t.id=pt.team_id where pt.plan_id=p.id and pt.team_id=i.team_id
    and pt.organization_id=organization and t.organization_id=organization and pt.active and t.active))) then
  raise exception 'ROUTE_ASSIGNMENTS_REQUIRED' using errcode='22023';
 end if;
 -- Road routing is optional: activation requires selected, active team assignments only.
 update public.inspection_plans set status='ACTIVE',started_at=statement_timestamp(),version=p.version+1,
  last_operation_id=(request->>'operation_id')::uuid,last_request=request where id=p.id;
 perform private.write_audit(organization,actor,'PLAN_ACTIVATED','inspection_plans',p.id,to_jsonb(p),
  jsonb_build_object('version',p.version+1,'operation',request->>'operation_id'));
 return public.read_inspection_plans(organization);
end;
$$;

-- A receipt is durable even when a later skip/completion changes the item's current state.
-- INSPECT calls the existing immutable inspection RPC inside this same transaction.
create function public.execute_plan_item(organization uuid, request jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare actor uuid; p public.inspection_plans; item public.inspection_plan_items;
 prior public.plan_execution_events; receipt jsonb; event jsonb; before_item jsonb; operation uuid;
begin
 actor:=private.authorize_hydrant_write(organization,array['FIREFIGHTER','MANAGER','ADMIN']::text[]);
 operation:=(request->>'id')::uuid;
 if operation is null or request->>'action' is null or request->>'action' not in ('SKIP','INSPECT') then
  raise exception 'INVALID_EXECUTION' using errcode='22023';
 end if;
 select * into p from public.inspection_plans where id=(request->>'plan_id')::uuid and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into item from public.inspection_plan_items where id=(request->>'item_id')::uuid and plan_id=p.id
  and organization_id=organization and active for update;
 if not found or item.team_id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if not private.has_organization_role(organization,array['MANAGER','ADMIN']::text[]) and not exists(
  select 1 from public.inspection_team_members m join public.inspection_teams t on t.id=m.team_id
  join public.inspection_plan_teams pt on pt.team_id=t.id and pt.plan_id=p.id
  where m.organization_id=organization and m.team_id=item.team_id and m.user_id=actor and m.active and t.active and pt.active) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 select * into prior from public.plan_execution_events where id=operation;
 if found then
  if prior.actor<>actor or prior.organization_id<>organization or prior.request is distinct from request then
   raise exception 'EXECUTION_UUID_REUSED' using errcode='23505';
  end if;
  if request->>'action'='INSPECT' then
   event:=request->'inspection';
   receipt:=public.complete_inspection(organization,item.hydrant_id,operation,event->>'mode',event->>'result',
    (event->>'started_at')::timestamptz,(event->>'completed_at')::timestamptz,event->>'notes',
    (event->>'pressure_bar')::numeric,(event->>'flow_l_min')::numeric);
   return receipt||jsonb_build_object('plan_item',prior.receipt->'plan_item');
  end if;
  return prior.receipt;
 end if;
 if p.status<>'ACTIVE' then raise exception 'PLAN_NOT_ACTIVE' using errcode='22023'; end if;
 if item.inspection_id is not null then raise exception 'PLAN_ITEM_COMPLETED' using errcode='22023'; end if;
 if item.execution_version is distinct from (request->>'version')::bigint then
  raise exception 'PLAN_ITEM_VERSION_CONFLICT' using errcode='22023';
 end if;
 before_item:=to_jsonb(item);
 if request->>'action'='SKIP' then
  if coalesce(char_length(btrim(request->>'reason')),0) not between 1 and 2000 or
   (request->>'at')::timestamptz is null or not isfinite((request->>'at')::timestamptz) then
   raise exception 'SKIP_REASON_REQUIRED' using errcode='22023';
  end if;
  update public.inspection_plan_items set skip_reason=btrim(request->>'reason'),skipped_by=actor,
   skipped_at=(request->>'at')::timestamptz,execution_version=execution_version+1 where id=item.id returning * into item;
  receipt:=jsonb_build_object('plan_item',to_jsonb(item));
 else
  event:=request->'inspection';
  if (event->>'id')::uuid is distinct from operation then raise exception 'INVALID_EXECUTION' using errcode='22023'; end if;
  -- Never attach a previously completed standalone inspection retroactively.
  if exists(select 1 from public.inspections where id=operation) then raise exception 'INSPECTION_UUID_REUSED' using errcode='23505'; end if;
  receipt:=public.complete_inspection(organization,item.hydrant_id,operation,event->>'mode',event->>'result',
   (event->>'started_at')::timestamptz,(event->>'completed_at')::timestamptz,event->>'notes',
   (event->>'pressure_bar')::numeric,(event->>'flow_l_min')::numeric);
  update public.inspection_plan_items set inspection_id=operation,completed_by=actor,completed_at=(event->>'completed_at')::timestamptz,
   skip_reason=null,skipped_by=null,skipped_at=null,execution_version=execution_version+1 where id=item.id returning * into item;
  receipt:=receipt||jsonb_build_object('plan_item',to_jsonb(item));
 end if;
 insert into public.plan_execution_events(id,organization_id,plan_id,item_id,actor,request,receipt)
  values(operation,organization,p.id,item.id,actor,request,receipt);
 perform private.write_audit(organization,actor,'PLAN_ITEM_'||(request->>'action'),'inspection_plan_items',item.id,before_item,to_jsonb(item));
 -- No route invalidation/recalculation on completion or skip.
 return receipt;
end;
$$;
alter function public.activate_inspection_plan(uuid,jsonb) owner to postgres;
alter function public.execute_plan_item(uuid,jsonb) owner to postgres;
revoke all on function public.activate_inspection_plan(uuid,jsonb),public.execute_plan_item(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.activate_inspection_plan(uuid,jsonb),public.execute_plan_item(uuid,jsonb) to authenticated;

-- Remaining-route calculation reuses the M7.5 provider and atomic receipt.
create or replace function private.plan_route_input(organization uuid, plan uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare p public.inspection_plans; teams jsonb; items jsonb;
begin
 select * into p from public.inspection_plans where id=plan and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p.status not in ('DRAFT','PLANNED','ACTIVE') then raise exception 'PLAN_NOT_EDITABLE' using errcode='22023'; end if;
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
  where i.plan_id=plan and i.active and (p.status<>'ACTIVE' or i.inspection_id is null) order by h.id for share of h;
 if exists(select 1 from public.inspection_plan_items i join public.hydrants h on h.id=i.hydrant_id
   where i.plan_id=plan and i.active and (p.status<>'ACTIVE' or i.inspection_id is null) and (h.organization_id<>organization or h.latitude is null or h.longitude is null
    or not(h.latitude between -90 and 90 and h.longitude between -180 and 180))) then
  raise exception 'ROUTE_COORDINATES_REQUIRED' using errcode='22023';
 end if;
 if exists(select 1 from public.inspection_plan_items i where i.plan_id=plan and i.active and (p.status<>'ACTIVE' or i.inspection_id is null) and
   (i.team_id is null or not exists(select 1 from public.inspection_plan_teams pt where pt.plan_id=plan and pt.team_id=i.team_id and pt.active))) then
  raise exception 'ROUTE_ASSIGNMENTS_REQUIRED' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'hydrant',h.id,'team',i.team_id,'code',h.code,
    'latitude',h.latitude::double precision,'longitude',h.longitude::double precision) order by h.id),'[]'::jsonb) into items
  from public.inspection_plan_items i join public.hydrants h on h.id=i.hydrant_id where i.plan_id=plan and i.active and (p.status<>'ACTIVE' or i.inspection_id is null);
 if jsonb_array_length(items)=0 and p.status<>'ACTIVE' then raise exception 'ROUTE_ASSIGNMENTS_REQUIRED' using errcode='22023'; end if;
 return jsonb_build_object('id',p.id,'organization',organization,'version',p.version,'latitude',p.start_latitude::double precision,
  'longitude',p.start_longitude::double precision,'returnToStart',p.return_to_start,'teams',teams,'items',items);
end;
$$;
create or replace function public.prepare_plan_routes(organization uuid, request jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare p public.inspection_plans; input jsonb;
begin
 perform private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']::text[]);
 if (request->>'action' is null or request->>'action' not in ('ROUTE','ROUTE_REMAINING')) or (request->>'operation_id')::uuid is null then
  raise exception 'INVALID_PLAN' using errcode='22023';
 end if;
 select * into p from public.inspection_plans where id=(request->>'id')::uuid and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p.last_operation_id=(request->>'operation_id')::uuid and p.last_request=request then return jsonb_build_object('acknowledged',true); end if;
 if p.version is distinct from (request->>'version')::bigint then raise exception 'PLAN_VERSION_CONFLICT' using errcode='P0001'; end if;
 if (p.status='ACTIVE') is distinct from (request->>'action'='ROUTE_REMAINING') then raise exception 'PLAN_NOT_EDITABLE' using errcode='22023'; end if;
 input:=private.plan_route_input(organization,p.id);
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
 if not found or not exists(select 1 from public.user_organizations where user_id=actor and organization_id=organization and role in ('MANAGER','ADMIN')) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 perform 1 from public.organizations where id=organization and active for share;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into p from public.inspection_plans where id=(request->>'id')::uuid and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p.last_operation_id=(request->>'operation_id')::uuid and p.last_request=request then return; end if;
 if (request->>'action' is null or request->>'action' not in ('ROUTE','ROUTE_REMAINING')) or (request->>'operation_id')::uuid is null then raise exception 'INVALID_PLAN' using errcode='22023'; end if;
 if (p.status='ACTIVE') is distinct from (request->>'action'='ROUTE_REMAINING') then raise exception 'PLAN_NOT_EDITABLE' using errcode='22023'; end if;
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
 if p.status='ACTIVE' then
  update public.inspection_plan_routes set valid=false where plan_id=p.id;
  update public.inspection_plan_items set route_order=null where plan_id=p.id and inspection_id is null;
 else perform private.invalidate_plan_routes(p.id); end if;
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
  jsonb_build_object('operation',request->>'operation_id','version',p.version+1,'provider','GraphHopper','profile','car',
   'routes',(select jsonb_agg(to_jsonb(r)-'geometry' order by team_id) from public.inspection_plan_routes r where plan_id=p.id and valid),
   'actor_source','authenticated_edge'));
end;
$$;
