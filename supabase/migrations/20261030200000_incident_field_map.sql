-- M14.8C1: bounded field-map read enrichment. No canonical writes or broad COP grant.
-- Apply AFTER 20261030180000_android_unit_leadership.sql; owner-only, not applied here.

create index incident_navigation_assignment_latest on public.incident_navigation_sessions(task_assignment_id,created_at desc,id desc);

-- One current read boundary for the head, watermark and projected routes.
-- Keep original NAV participation/unit/SIM gates; do not infer command authority.
create function private.field_map_route_units(p_org uuid,p_incident uuid) returns setof uuid
language sql volatile security definer set search_path='' as $map_route_units$
 select u.id from public.incident_units u
 where u.incident_id=p_incident
 and private.incident_acting_member(p_org) and private.can_read_incident(p_incident)
 and private.field_unit_visible(auth.uid(),p_org,u.id)
 and private.navigation_visible(p_incident,p_org,u.id);
$map_route_units$;
alter function private.field_map_route_units(uuid,uuid) owner to postgres;
revoke all on function private.field_map_route_units(uuid,uuid) from public,anon,authenticated,service_role;

-- Navigation writes have their own session versions, not incident revision.
-- Separate DATA watermark; never part of the B1 authorization fingerprint.
create function private.field_map_watermark(p_org uuid,p_incident uuid) returns text
language sql volatile security definer set search_path='' as $map_watermark$
 select md5((select l.salt::text from private.incident_sync_limits l where l.id)||auth.uid()::text||p_org::text||p_incident::text||
 coalesce((select jsonb_agg(jsonb_build_array(q.id,q.version::text,q.current_route_id,q.status) order by q.id)::text from (
  select n.id,n.version,n.current_route_id,n.status
  from public.incident_task_assignments a
  join private.field_map_route_units(p_org,p_incident) allowed(unit_id) on allowed.unit_id=a.incident_unit_id
  join lateral(select latest_session.* from public.incident_navigation_sessions latest_session
   where latest_session.task_assignment_id=a.id and latest_session.incident_id=p_incident
   order by latest_session.created_at desc,latest_session.id desc limit 1)n on true
  join public.incident_navigation_routes r on r.id=n.current_route_id and r.session_id=n.id
  where a.incident_id=p_incident and a.recipient_type='INCIDENT_UNIT' and private.field_assignment_visible(auth.uid(),p_org,a.id)
  and r.origin_snapshot->>'source'='MANUAL_PLANNING_POINT'
  order by n.id limit 1001
 ) q),'[]'));
$map_watermark$;
alter function private.field_map_watermark(uuid,uuid) owner to postgres;
revoke all on function private.field_map_watermark(uuid,uuid) from public,anon,authenticated,service_role;

alter function private.field_projection(uuid,uuid) rename to field_projection_before_incident_map;
alter function private.field_projection_before_incident_map(uuid,uuid) owner to postgres;
revoke all on function private.field_projection_before_incident_map(uuid,uuid) from public,anon,authenticated,service_role;

-- Core-only reads (notably timeline) must not calculate map geometry/NAV data.
create function private.field_projection(p_acting_organization_id uuid,p_incident_id uuid) returns jsonb
language sql volatile security definer set search_path='' as $field_core$
 select private.field_projection_before_incident_map(p_acting_organization_id,p_incident_id);
$field_core$;
alter function private.field_projection(uuid,uuid) owner to postgres;
revoke all on function private.field_projection(uuid,uuid) from public,anon,authenticated,service_role;

create function private.field_map_projection(p_acting_organization_id uuid,p_incident_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $field_map$
declare result_value jsonb;features_value jsonb;routes_value jsonb;context_value jsonb;
 feature_count integer;route_count integer:=0;map_limit boolean:=false;
 route_row record;route_dto jsonb;map_source text;route_bytes integer:=0;
begin
 -- Retains B1 exact active actor/org, field visibility and parent share locks.
 result_value:=private.field_projection(p_acting_organization_id,p_incident_id);
 if result_value is null then return null;end if;
 map_source:=private.field_map_watermark(p_acting_organization_id,p_incident_id);
 -- Context is deliberately narrower than commander COP:
 -- current sectors of visible deployments / referenced visible tasks;
 -- objects referenced by visible tasks only; active linked hydrants owned by acting org.
 with visible_assignments as (
  select a.* from public.incident_task_assignments a
  join jsonb_array_elements(result_value->'assignments') visible on a.id=(visible.value->>'id')::uuid
  where a.incident_id=p_incident_id
 ), visible_tasks as (
  select t.* from public.incident_tasks t where t.incident_id=p_incident_id
  and exists(select 1 from visible_assignments a where a.task_id=t.id)
 ), feature_rows as (
  select s.id,'INCIDENT_SECTOR'::text kind,s.name label,s.geometry,s.version::text version,null::uuid hydrant_id
  from public.incident_sectors s where s.incident_id=p_incident_id and s.active and s.geometry is not null
  and (exists(select 1 from public.incident_units u where u.incident_id=p_incident_id and u.sector_id=s.id
   and private.field_unit_visible(auth.uid(),p_acting_organization_id,u.id))
   or exists(select 1 from visible_tasks t where t.target_type='INCIDENT_SECTOR' and t.target_incident_id=p_incident_id and t.target_entity_id=s.id))
  union all
  select o.id,'INCIDENT_MAP_OBJECT',o.label,o.geometry,o.version::text,null::uuid
  from public.incident_map_objects o where o.incident_id=p_incident_id and o.active
  and exists(select 1 from visible_tasks t where t.target_type='INCIDENT_MAP_OBJECT' and t.target_incident_id=p_incident_id and t.target_entity_id=o.id)
  union all
  select l.id,'INCIDENT_LINKED_HYDRANT',coalesce(h.code,h.id::text),
   jsonb_build_object('type','Point','coordinates',jsonb_build_array(h.longitude,h.latitude)),l.version::text,h.id
  from public.incident_hydrant_links l join public.hydrants h on h.id=l.hydrant_id
   and h.organization_id=p_acting_organization_id and h.active
   -- SECURITY DEFINER bypasses table RLS: explicitly reuse its active-row
   -- registry predicate, independently of incident field authorization.
   and private.is_organization_member(h.organization_id)
  where l.incident_id=p_incident_id and l.active and h.longitude between -180 and 180 and h.latitude between -90 and 90
 ), bounded as (select * from feature_rows order by kind,id limit 201)
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'kind',b.kind,'label',b.label,'geometry',b.geometry,
  'version',b.version,'hydrant_id',b.hydrant_id) order by b.kind,b.id),'[]'),count(*) into features_value,feature_count from bounded b;

 -- Reuse existing NAV read authority (including eligible own-org crew).
 -- Add the narrower field-assignment gate; no simulator positions/controller data.
 -- Manual origin only.
 routes_value:='[]'::jsonb;
 if feature_count>200 or octet_length(features_value::text)>786432 then map_limit:=true;
 else
 for route_row in
  select a.id assignment_id,n.id session_id,n.version,n.status,n.executor_id,n.executor_organization_id,n.incident_id,n.incident_unit_id,
   r.id,r.revision,r.route_geometry,r.provider,r.distance_m,r.duration_s,r.origin_snapshot,r.destination_snapshot,r.calculated_at
  from public.incident_task_assignments a
  join public.incident_tasks t on t.id=a.task_id and t.incident_id=a.incident_id
  join private.field_map_route_units(p_acting_organization_id,p_incident_id) allowed(unit_id) on allowed.unit_id=a.incident_unit_id
  join lateral(select x.* from public.incident_navigation_sessions x
   where x.task_assignment_id=a.id and x.incident_id=p_incident_id and x.incident_unit_id=a.incident_unit_id
   order by x.created_at desc,x.id desc limit 1)n on true
  join public.incident_navigation_routes r on r.id=n.current_route_id and r.session_id=n.id
  where a.incident_id=p_incident_id and a.recipient_type='INCIDENT_UNIT'
  and exists(select 1 from jsonb_array_elements(result_value->'assignments') visible where a.id=(visible.value->>'id')::uuid)
  and r.origin_snapshot->>'source'='MANUAL_PLANNING_POINT'
  and r.destination_snapshot->'geometry'=t.target_geometry_snapshot
  and r.destination_snapshot->>'target_type'=t.target_type
  and (r.destination_snapshot->>'target_entity_id') is not distinct from t.target_entity_id::text
  order by a.id limit 26
 loop
  route_count:=route_count+1;
  if route_count>25 then map_limit:=true;exit;end if;
  -- Bound before JSON aggregation: at most one oversized route is materialized,
  -- never 26 route geometries of up to3MiB each.
  if octet_length(route_row.route_geometry::text)+route_bytes+octet_length(features_value::text)>786432 then
   map_limit:=true;exit;
  end if;
  route_dto:=jsonb_build_object('assignment_id',route_row.assignment_id,'session_id',route_row.session_id,
  'session_version',route_row.version::text,'status',route_row.status,'route_id',route_row.id,'route_revision',route_row.revision::text,
  'geometry',route_row.route_geometry,'provider',route_row.provider,'distance_m',route_row.distance_m,'duration_s',route_row.duration_s,
  'origin_source','MANUAL_PLANNING_POINT','calculated_at',route_row.calculated_at,
  'destination',route_row.destination_snapshot->'geometry','stale',route_row.status not in ('PLANNED','ACTIVE','PAUSED')
   or not private.navigation_live(route_row.assignment_id)
   or (route_row.status in ('ACTIVE','PAUSED') and not private.navigation_executor_valid(route_row.executor_id,route_row.executor_organization_id,route_row.incident_id,route_row.incident_unit_id))
);
  route_bytes:=route_bytes+octet_length(route_dto::text);
  if route_bytes+octet_length(features_value::text)>786432 then map_limit:=true;exit;end if;
  routes_value:=routes_value||jsonb_build_array(route_dto);
 end loop;
 end if;
 map_limit:=map_limit or feature_count>200 or route_count>25;
 context_value:=jsonb_build_object('schema',1,'status','COMPLETE','revision',result_value->>'revision',
  'source',map_source,'features',features_value,'routes',routes_value);
 if map_limit or octet_length(context_value::text)>786432 or octet_length(result_value::text)+octet_length(context_value::text)>3140000 then
  -- No partial generation masquerading as current; existing frozen targets remain.
  context_value:=jsonb_build_object('schema',1,'status','MAP_TOO_LARGE','revision',result_value->>'revision',
   'source',map_source,'features','[]'::jsonb,'routes','[]'::jsonb);
 end if;
 if octet_length((result_value||jsonb_build_object('field_map',context_value))::text)>3145728 then
  return result_value; -- capability absent, never corrupt/replace a valid field projection.
 end if;
 return result_value||jsonb_build_object('field_map',context_value);
end;
$field_map$;
alter function private.field_map_projection(uuid,uuid) owner to postgres;
revoke all on function private.field_map_projection(uuid,uuid) from public,anon,authenticated,service_role;
-- Existing canonical geometry/link changes produce B1 SCOPE_RESET.
-- Navigation-only changes use the independent directory data watermark below.
-- Existing status/task changes replace collections through this same projector.
-- No new table grants, public RPC, queue, scheduler, event producer or telemetry.

-- Extend the existing batched directory with a lightweight route-data watermark.
-- Same public signature/grant, same original current authorization and locking.
alter function public.incident_field_directory(uuid) rename to incident_field_directory_before_map;
alter function public.incident_field_directory_before_map(uuid) set schema private;
alter function private.incident_field_directory_before_map(uuid) owner to postgres;
revoke all on function private.incident_field_directory_before_map(uuid) from public,anon,authenticated,service_role;
create function public.incident_field_directory(p_acting_organization_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $map_directory$
declare result_value jsonb;rows_value jsonb;
begin
 result_value:=private.incident_field_directory_before_map(p_acting_organization_id);
 select coalesce(jsonb_agg(entry.value||jsonb_build_object(
  'map_source',private.field_map_watermark(p_acting_organization_id,(entry.value->>'id')::uuid),
  'map_routes_allowed',exists(select 1 from private.field_map_route_units(p_acting_organization_id,(entry.value->>'id')::uuid))) order by entry.value->>'id'),'[]')
 into rows_value from jsonb_array_elements(result_value->'incidents') entry;
 return result_value||jsonb_build_object('incidents',rows_value);
end;
$map_directory$;
alter function public.incident_field_directory(uuid) owner to postgres;
revoke all on function public.incident_field_directory(uuid) from public,anon,authenticated,service_role;
grant execute on function public.incident_field_directory(uuid) to authenticated;

-- Same B1 authorization, locks, limits, pinned pages and public signatures.
-- Enrichment belongs only to the two full projection consumers; timeline stays core-only.
create or replace function public.incident_snapshot_manifest(p_acting_organization_id uuid,p_incident_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $manifest$
declare v_payload jsonb;v_counts jsonb;v_id uuid:=gen_random_uuid();v_scope text;
 v_bytes integer;v_kind text;v_items jsonb;v_live integer;v_total bigint;v_started timestamptz:=clock_timestamp();
begin
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 v_scope:=private.incident_field_scope(p_acting_organization_id,p_incident_id);
 v_payload:=private.field_map_projection(p_acting_organization_id,p_incident_id);
 if v_payload is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 v_bytes:=octet_length(v_payload::text);
 if v_bytes>3145728 then raise exception 'SNAPSHOT_TOO_LARGE';end if;
 -- Serialize quota accounting. Expired cache only, at most 8 manifests/request.
 perform 1 from private.incident_sync_limits l where l.id for update;
 delete from private.incident_snapshot_manifests m where m.id in (
 select old.id from private.incident_snapshot_manifests old where old.expires_at<=clock_timestamp()
 order by old.expires_at,old.id limit 8 for update skip locked);
 select count(*),coalesce(sum(m.byte_size),0) into v_live,v_total from private.incident_snapshot_manifests m;
 if v_live>=512 or v_total+v_bytes>67108864 then raise exception 'SNAPSHOT_CAPACITY';end if;
 if (select count(*) from private.incident_snapshot_manifests m where m.actor_id=auth.uid()
 and m.organization_id=p_acting_organization_id and m.incident_id=p_incident_id)>=3
 then raise exception 'SNAPSHOT_CAPACITY';end if;
 v_counts:=jsonb_build_object('core',1,'units',jsonb_array_length(v_payload->'units'),
 'assignments',jsonb_array_length(v_payload->'assignments'),'history',jsonb_array_length(v_payload->'history'));
 insert into private.incident_snapshot_manifests(id,actor_id,organization_id,incident_id,revision,timeline_sequence,fingerprint,counts,byte_size)
 values(v_id,auth.uid(),p_acting_organization_id,p_incident_id,(v_payload->>'revision')::bigint,
 (v_payload->>'timeline_sequence')::bigint,v_scope,v_counts,v_bytes);
 foreach v_kind in array array['core','units','assignments','history'] loop
  v_items:=case when v_kind='core' then jsonb_build_array(v_payload-'units'-'assignments'-'history') else v_payload->v_kind end;
  insert into private.incident_snapshot_items(manifest_id,actor_id,organization_id,incident_id,collection,ordinal,payload)
  select v_id,auth.uid(),p_acting_organization_id,p_incident_id,v_kind,x.ordinality,x.value
  from jsonb_array_elements(v_items) with ordinality x(value,ordinality);
 end loop;
 return jsonb_build_object('schema_version',1,'manifest_id',v_id,'account',auth.uid(),'organization',p_acting_organization_id,
 'incident_id',p_incident_id,'snapshot_revision',v_payload->>'revision','timeline_sequence',v_payload->>'timeline_sequence',
 'scope_fingerprint',v_scope,'collections',v_counts,'bytes',v_bytes,
 'expires_at',(select m.expires_at from private.incident_snapshot_manifests m where m.id=v_id),
 'creation_ms',extract(milliseconds from clock_timestamp()-v_started));
end;
$manifest$;
create or replace function public.incident_field_entities(p_acting_organization_id uuid,p_incident_id uuid,
 p_scope_fingerprint text,p_expected_revision bigint) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $entities$
declare v_scope text;v_payload jsonb;
begin
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 v_scope:=private.incident_field_scope(p_acting_organization_id,p_incident_id);
 if p_scope_fingerprint is distinct from v_scope then raise exception 'MANIFEST_SCOPE_CHANGED';end if;
 if p_expected_revision is null or p_expected_revision<0 then raise exception 'VALIDATION_FAILED';end if;
 v_payload:=private.field_map_projection(p_acting_organization_id,p_incident_id);
 if v_payload is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if (v_payload->>'revision')::bigint<>p_expected_revision then raise exception 'RESET_REQUIRED';end if;
 return jsonb_build_object('schema_version',1,'account',auth.uid(),'organization',p_acting_organization_id,
 'incident_id',p_incident_id,'scope_fingerprint',v_scope,'revision',v_payload->>'revision',
 'timeline_sequence',v_payload->>'timeline_sequence','payload',v_payload);
end;
$entities$;
