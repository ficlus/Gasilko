-- M7.4: geographic assignment only. No road costs, route sequence or manual reassignment.
alter table public.inspection_plan_items add column team_id uuid;
alter table public.inspection_plan_items add constraint plan_item_selected_team
 foreign key(plan_id,team_id) references public.inspection_plan_teams(plan_id,team_id) on delete restrict;
create index plan_items_team_idx on public.inspection_plan_items(organization_id,plan_id,team_id) where active;

-- Any explicit selection edit invalidates the previous partition, including deselection/reselection.
-- Updating team_id does not fire these triggers; frozen item identities/active flags are never changed here.
create function private.clear_plan_assignment() returns trigger
language plpgsql security definer set search_path='' as $$
declare previous jsonb; actor uuid; source text;
begin
 if tg_op='UPDATE' and old.active=new.active then return new; end if;
 select jsonb_object_agg(i.id::text,i.team_id::text order by i.id) into previous
  from public.inspection_plan_items i where i.plan_id=new.plan_id and i.team_id is not null;
 if previous is not null then
  update public.inspection_plan_items set team_id=null where plan_id=new.plan_id and team_id is not null;
  if current_setting('role',true)='authenticated' then actor:=auth.uid();source:='authenticated';
  else
   actor:=coalesce(nullif(current_setting('gasilko.audit_actor',true),'')::uuid,'00000000-0000-0000-0000-000000000000'::uuid);
   source:='trusted_database';
  end if;
  perform private.write_audit(new.organization_id,actor,'PLAN_ASSIGNMENT_CLEARED','inspection_plans',new.plan_id,
   previous,jsonb_build_object('reason','SELECTION_CHANGED','actor_source',source,'database_principal',session_user));
 end if;
 return new;
end;
$$;
create trigger plan_items_assignment_reset after insert or update of active on public.inspection_plan_items
 for each row execute function private.clear_plan_assignment();
create trigger plan_teams_assignment_reset after insert or update of active on public.inspection_plan_teams
 for each row execute function private.clear_plan_assignment();

-- Deterministic recursive spatial bisection. Points are projected to a local longitude/latitude plane.
-- At each node evaluate X, Y and principal-axis cuts with prefix sums (no pairwise distance matrix).
-- Compactness dominates; workload is a soft penalty and wide geographic gaps receive a preference.
-- Team slots follow each child's approximate population share; no exact equal-count constraint.
-- Each split is a half-plane, so distinct-coordinate sibling sectors cannot cross.
create function private.partition_plan_points(points jsonb, teams uuid[]) returns jsonb
language plpgsql immutable set search_path='' as $$
declare n integer:=jsonb_array_length(points); k integer:=least(cardinality(teams),n);
 total_x double precision; total_y double precision; total_q double precision;
 vx double precision; vy double precision; cv double precision; spread double precision; angle double precision;
 cut record; left_points jsonb; right_points jsonb; result jsonb;
begin
 if n=0 or k=0 then return '{}'::jsonb; end if;
 select sum(x order by id),sum(y order by id),sum(x*x+y*y order by id),
  sum(x*x order by id),sum(y*y order by id),sum(x*y order by id)
 into total_x,total_y,total_q,vx,vy,cv
 from jsonb_to_recordset(points) as t(id uuid,x double precision,y double precision);
 vx:=greatest(0,vx-total_x*total_x/n);vy:=greatest(0,vy-total_y*total_y/n);
 cv:=cv-total_x*total_y/n;spread:=vx+vy;
 if k=1 or spread<1e-20 then
  -- Co-located hydrants stay together rather than manufacturing sectors for equal counts.
  select jsonb_object_agg(p->>'id',teams[1]::text order by p->>'id') into result from jsonb_array_elements(points) p;
  return result;
 end if;
 angle:=0.5*atan2(2*cv,vx-vy);
 with p as (
  select * from jsonb_to_recordset(points) as t(id uuid,x double precision,y double precision)
 ), projected as (
  select a.axis,a.dx,a.dy,p.*,x*a.dx+y*a.dy as position
  from p cross join (values(0,1.0::double precision,0.0::double precision),
    (1,0.0::double precision,1.0::double precision),(2,cos(angle),sin(angle))) a(axis,dx,dy)
 ), ranked as (
  select *,row_number() over w as rn,
   sum(x) over w as sx,sum(y) over w as sy,sum(x*x+y*y) over w as sq,
   lead(position) over w as next_position,
   max(position) over(partition by axis)-min(position) over(partition by axis) as extent
  from projected window w as(partition by axis order by position,id rows between unbounded preceding and current row)
 ), cuts as (
  select *,greatest(1,least(k-1,round(rn::numeric*k/n)::integer)) as slots from ranked where rn<n
 ), scored as (
  select *,
   greatest(0,sq-(sx*sx+sy*sy)/rn + (total_q-sq)-
       ((total_x-sx)*(total_x-sx)+(total_y-sy)*(total_y-sy))/(n-rn))/spread
   +4.0*power(rn::double precision/n-slots::double precision/k,2)
   -0.25*coalesce((next_position-position)/nullif(extent,0),0) as score
  from cuts
 )
 select * into cut from scored
 -- Prefer true separating boundaries to splitting a co-located group.
 order by case when next_position>position then 0 else 1 end,score,axis,rn limit 1;
 select coalesce(jsonb_agg(value order by rank) filter(where rank<=cut.rn),'[]'::jsonb),
        coalesce(jsonb_agg(value order by rank) filter(where rank>cut.rn),'[]'::jsonb)
 into left_points,right_points from (
  select value,row_number() over(order by (value->>'x')::double precision*cut.dx+
      (value->>'y')::double precision*cut.dy,(value->>'id')::uuid) as rank
  from jsonb_array_elements(points)
 ) ordered;
 return private.partition_plan_points(left_points,teams[1:cut.slots]) ||
        private.partition_plan_points(right_points,teams[cut.slots+1:k]);
end;
$$;

create function public.assign_inspection_plan(organization uuid, request jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare actor uuid; p public.inspection_plans; plan uuid:=(request->>'id')::uuid;
 operation uuid:=(request->>'operation_id')::uuid; expected bigint:=(request->>'version')::bigint;
 teams uuid[]; points jsonb; assignments jsonb; previous jsonb;
 latitude_origin double precision; longitude_origin double precision;
begin
 actor:=private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']::text[]);
 if plan is null or operation is null or expected is null or request->>'action' is distinct from 'ASSIGN' then
  raise exception 'INVALID_PLAN' using errcode='22023';
 end if;
 select * into p from public.inspection_plans where id=plan and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p.last_operation_id=operation then
  if p.last_request is distinct from request then raise exception 'OPERATION_REUSED' using errcode='22023'; end if;
  return public.read_inspection_plans(organization);
 end if;
 if p.status not in ('DRAFT','PLANNED') then raise exception 'PLAN_NOT_EDITABLE' using errcode='22023'; end if;
 if expected<>p.version then raise exception 'PLAN_VERSION_CONFLICT' using errcode='P0001'; end if;
 -- Existing organization lock serializes team/plan mutations. Lock hydrants before reading coordinates.
 perform 1 from public.inspection_teams t join public.inspection_plan_teams pt on pt.team_id=t.id
  where pt.plan_id=plan and pt.active order by t.id for share of t;
 if exists(select 1 from public.inspection_plan_teams pt join public.inspection_teams t on t.id=pt.team_id
  where pt.plan_id=plan and pt.active and (not t.active or t.organization_id<>organization)) then
  raise exception 'INVALID_PLAN_TEAM' using errcode='22023';
 end if;
 select array_agg(team_id order by team_id) into teams from public.inspection_plan_teams where plan_id=plan and active;
 if coalesce(cardinality(teams),0)=0 then raise exception 'TEAM_REQUIRED' using errcode='22023'; end if;
 perform 1 from public.hydrants h join public.inspection_plan_items i on i.hydrant_id=h.id
  where i.plan_id=plan and i.active order by h.id for share of h;
 if exists(select 1 from public.inspection_plan_items i join public.hydrants h on h.id=i.hydrant_id
  where i.plan_id=plan and i.active and h.organization_id<>organization) then
  raise exception 'INVALID_PLAN_HYDRANT' using errcode='22023';
 end if;
 -- Circular longitude origin handles adjacent hydrants across the date line.
 select avg(h.latitude)::double precision,
  degrees(atan2(sum(sin(radians(h.longitude::double precision)) order by i.id),
                sum(cos(radians(h.longitude::double precision)) order by i.id)))
 into latitude_origin,longitude_origin
 from public.inspection_plan_items i join public.hydrants h on h.id=i.hydrant_id
 where i.plan_id=plan and i.active and h.latitude between -90 and 90 and h.longitude between -180 and 180;
 select coalesce(jsonb_agg(jsonb_build_object('id',i.id,
  'x',atan2(sin(radians(h.longitude::double precision-longitude_origin)),
            cos(radians(h.longitude::double precision-longitude_origin)))*cos(radians(latitude_origin)),
  'y',radians(h.latitude::double precision-latitude_origin)) order by i.id),'[]'::jsonb)
 into points from public.inspection_plan_items i join public.hydrants h on h.id=i.hydrant_id
 where i.plan_id=plan and i.active and h.latitude between -90 and 90 and h.longitude between -180 and 180;
 assignments:=private.partition_plan_points(points,teams);
 select coalesce(jsonb_object_agg(id::text,team_id order by id),'{}'::jsonb) into previous
  from public.inspection_plan_items where plan_id=plan and active;
 update public.inspection_plan_items set team_id=(assignments->>id::text)::uuid where plan_id=plan and active;
 update public.inspection_plans set version=p.version+1,last_operation_id=operation,last_request=request where id=plan;
 perform private.write_audit(organization,actor,'PLAN_ASSIGNED','inspection_plans',plan,previous,
  jsonb_build_object('assignments',assignments,'algorithm','SPATIAL_BISECTION_V1','version',p.version+1,
   'unassigned',(select count(*) from public.inspection_plan_items where plan_id=plan and active and team_id is null),
   'actor_source','authenticated','database_principal',session_user));
 return public.read_inspection_plans(organization);
end;
$$;
alter function private.clear_plan_assignment() owner to postgres;
alter function private.partition_plan_points(jsonb,uuid[]) owner to postgres;
alter function public.assign_inspection_plan(uuid,jsonb) owner to postgres;
revoke all on function private.clear_plan_assignment(),private.partition_plan_points(jsonb,uuid[]),
 public.assign_inspection_plan(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.assign_inspection_plan(uuid,jsonb) to authenticated;

