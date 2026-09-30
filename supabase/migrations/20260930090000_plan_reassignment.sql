-- M7.7: online ownership coordination; frozen selection and geographic partitioning are unchanged.
alter table public.inspection_plan_items add column assignment_version bigint not null default 0 check(assignment_version>=0);
create table public.plan_reassignments (
 id uuid primary key, organization_id uuid not null, plan_id uuid not null,
 item_id uuid not null references public.inspection_plan_items(id) on delete restrict,
 from_team_id uuid not null, to_team_id uuid not null,
 actor uuid not null references public.profiles(id) on delete restrict,
 created_at timestamptz not null default statement_timestamp(),
 reason text not null check(char_length(btrim(reason)) between 1 and 2000),
 item_version bigint not null, request jsonb not null,
 check(from_team_id<>to_team_id),
 foreign key(plan_id,organization_id) references public.inspection_plans(id,organization_id),
 foreign key(plan_id,from_team_id) references public.inspection_plan_teams(plan_id,team_id),
 foreign key(plan_id,to_team_id) references public.inspection_plan_teams(plan_id,team_id)
);
create index plan_reassignments_scope on public.plan_reassignments(organization_id,plan_id,item_id,created_at);
alter table public.plan_reassignments enable row level security;
revoke all on public.plan_reassignments from public,anon,authenticated,service_role;
grant select on public.plan_reassignments to authenticated;
create policy plan_reassignments_read on public.plan_reassignments for select to authenticated using (
 private.is_organization_member(organization_id) and exists(select 1 from public.organizations o where o.id=organization_id and o.active));
create trigger plan_reassignments_immutable before update or delete on public.plan_reassignments
 for each row execute function private.audit_immutable();
create trigger plan_reassignments_no_truncate before truncate on public.plan_reassignments
 for each statement execute function private.audit_immutable();

-- Preserve the existing invalidation rules, narrowing ACTIVE item transfers to their two teams.
create or replace function private.invalidate_changed_plan_routes() returns trigger
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
  if tg_table_name='inspection_plan_items' and tg_op='UPDATE' then
   if new.team_id is distinct from old.team_id and new.active=old.active and
      exists(select 1 from public.inspection_plans where id=new.plan_id and status='ACTIVE') then
    update public.inspection_plan_routes set valid=false where plan_id=new.plan_id and team_id in (old.team_id,new.team_id);
    update public.inspection_plan_items set route_order=null where plan_id=new.plan_id
     and team_id in (old.team_id,new.team_id) and inspection_id is null;
    return new;
   end if;
  end if;
  if tg_op='INSERT' or to_jsonb(new)->'active' is distinct from to_jsonb(old)->'active'
    or to_jsonb(new)->'team_id' is distinct from to_jsonb(old)->'team_id' then
   perform private.invalidate_plan_routes(new.plan_id);
  end if;
 end if;
 return new;
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
  'routes',coalesce((select jsonb_agg(to_jsonb(r) order by r.plan_id,r.team_id) from public.inspection_plan_routes r where r.organization_id=organization),'[]'::jsonb),
  'reassignments',coalesce((select jsonb_agg(to_jsonb(r)-'request' order by r.created_at,r.id) from public.plan_reassignments r where r.organization_id=organization),'[]'::jsonb));
end;
$$;

create function public.reassign_plan_item(organization uuid, request jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare actor uuid; p public.inspection_plans; item public.inspection_plan_items; prior public.plan_reassignments;
 operation uuid:=(request->>'id')::uuid; source_team uuid:=(request->>'from_team_id')::uuid;
 destination uuid:=(request->>'to_team_id')::uuid; before_item jsonb;
begin
 -- Serializes with membership/team edits, execution and routing; current authority is checked on every call.
 actor:=private.authorize_hydrant_write(organization,array['FIREFIGHTER','MANAGER','ADMIN']::text[]);
 if operation is null or source_team is null or destination is null or source_team=destination or
    coalesce(char_length(btrim(request->>'reason')),0) not between 1 and 2000 then
  raise exception 'INVALID_REASSIGNMENT' using errcode='22023';
 end if;
 select * into p from public.inspection_plans where id=(request->>'plan_id')::uuid and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into item from public.inspection_plan_items where id=(request->>'item_id')::uuid and plan_id=p.id
  and organization_id=organization and active for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if not private.has_organization_role(organization,array['MANAGER','ADMIN']::text[]) and not exists(
  select 1 from public.inspection_team_members m join public.inspection_teams t on t.id=m.team_id
   join public.inspection_plan_teams pt on pt.team_id=t.id and pt.plan_id=p.id
  where m.organization_id=organization and m.user_id=actor and m.active and t.active and pt.active
   and m.team_id in (source_team,destination)) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 select * into prior from public.plan_reassignments where id=operation;
 if found then
  if prior.actor<>actor or prior.organization_id<>organization or prior.request is distinct from request then
   raise exception 'REASSIGNMENT_UUID_REUSED' using errcode='22023';
  end if;
  return public.read_inspection_plans(organization);
 end if;
 if p.status<>'ACTIVE' or item.inspection_id is not null or item.team_id is distinct from source_team or
    item.execution_version is distinct from (request->>'version')::bigint then
  raise exception 'PLAN_ITEM_CHANGED' using errcode='22023';
 end if;
 if not exists(select 1 from public.inspection_plan_teams where plan_id=p.id and team_id=source_team and active) or
    not exists(select 1 from public.inspection_plan_teams pt join public.inspection_teams t on t.id=pt.team_id
     where pt.plan_id=p.id and pt.team_id=destination and pt.active and t.active
      and pt.organization_id=organization and t.organization_id=organization) then
  raise exception 'INVALID_REASSIGNMENT_TEAM' using errcode='22023';
 end if;
 before_item:=to_jsonb(item);
 update public.inspection_plan_items set team_id=destination,execution_version=execution_version+1,
  assignment_version=execution_version+1,route_order=null where id=item.id returning * into item;
 insert into public.plan_reassignments(id,organization_id,plan_id,item_id,from_team_id,to_team_id,actor,reason,item_version,request)
  values(operation,organization,p.id,item.id,source_team,destination,actor,btrim(request->>'reason'),item.execution_version,request);
 -- Invalidates concurrent route snapshots and prevents older plan snapshots restoring old assignments.
 update public.inspection_plans set version=version+1 where id=p.id;
 perform private.write_audit(organization,actor,'PLAN_ITEM_REASSIGNED','inspection_plan_items',item.id,before_item,
  to_jsonb(item)||jsonb_build_object('operation',operation,'reason',btrim(request->>'reason')));
 return public.read_inspection_plans(organization);
end;
$$;
alter function public.reassign_plan_item(uuid,jsonb) owner to postgres;
revoke all on function public.reassign_plan_item(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.reassign_plan_item(uuid,jsonb) to authenticated;

-- Own confirmed execution receipts remain readable after a transfer. New stale execution is
-- rejected by item version before the team check, so the existing queue retains it as ATTENTION.
create or replace function public.execute_plan_item(organization uuid, request jsonb) returns jsonb
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
 if not private.has_organization_role(organization,array['MANAGER','ADMIN']::text[]) and not exists(
  select 1 from public.inspection_team_members m join public.inspection_teams t on t.id=m.team_id
  join public.inspection_plan_teams pt on pt.team_id=t.id and pt.plan_id=p.id
  where m.organization_id=organization and m.team_id=item.team_id and m.user_id=actor and m.active and t.active and pt.active) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
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
