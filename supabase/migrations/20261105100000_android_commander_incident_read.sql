-- M14.8E: versioned B1 READ audience. No field/command/precise-GPS authority expansion.
-- Owner applies AFTER 20261104120000_vehicle_location_end_to_end.sql. Not executed by Codex.
begin;
create function private.incident_commander_roles(p_org uuid,p_incident uuid)
returns setof public.incident_role_assignments language sql volatile security definer set search_path='' as $roles$
 select r.* from public.incident_role_assignments r
 where auth.uid() is not null and private.is_active_user() and private.incident_acting_member(p_org)
 and private.can_read_incident(p_incident) and r.incident_id=p_incident and r.organization_id=p_org and r.user_id=auth.uid()
 and r.role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER','AGENCY_COMMANDER','SECTOR_COMMANDER')
 and private.incident_assignment_effective(r.id)
 and (r.role='INCIDENT_COMMANDER' or exists(select 1 from public.incident_role_assignments parent
  where parent.id=r.parent_assignment_id and parent.incident_id=p_incident and parent.role='INCIDENT_COMMANDER'
  and private.incident_assignment_effective(parent.id)));
$roles$;
-- Terminal access is current canonical historical membership/participation, NOT a past role grant.
create function private.incident_reader_history(p_org uuid,p_incident uuid) returns boolean
language sql volatile security definer set search_path='' as $historic$
 select private.is_active_user() and private.incident_acting_member(p_org) and private.can_read_incident(p_incident)
 and exists(select 1 from public.incidents i join public.incident_participants p on p.incident_id=i.id
  where i.id=p_incident and i.status in ('CLOSED','CANCELLED') and p.organization_id=p_org and p.status in ('ACTIVE','RELEASED'));
$historic$;
create function private.incident_reader_admitted(p_org uuid,p_incident uuid) returns boolean
language sql volatile security definer set search_path='' as $admit$
 select private.is_active_user() and private.incident_acting_member(p_org) and (
 exists(select 1 from private.incident_commander_roles(p_org,p_incident))
 or private.incident_reader_history(p_org,p_incident)
 or exists(select 1 from public.incident_units u where u.incident_id=p_incident and private.field_unit_visible(auth.uid(),p_org,u.id)));
$admit$;
create function private.incident_commander_unit_readable(p_org uuid,p_incident uuid,p_unit uuid) returns boolean
language sql volatile security definer set search_path='' as $command_unit$
 select exists(select 1 from public.incident_units u
 join public.incident_participants p on p.id=u.participation_id and p.incident_id=u.incident_id and p.organization_id=u.organization_id
 join public.organizations o on o.id=u.organization_id and o.active
 where u.id=p_unit and u.incident_id=p_incident and
 ((private.incident_reader_history(p_org,p_incident) and u.organization_id=p_org and p.status in ('ACTIVE','RELEASED'))
 or (p.status='ACTIVE' and exists(select 1 from private.incident_commander_roles(p_org,p_incident) r where
  r.role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER')
  or (r.role='AGENCY_COMMANDER' and u.organization_id=r.organization_id)
  or (r.role='SECTOR_COMMANDER' and u.sector_id=r.sector_id)))));
$command_unit$;
create function private.incident_reader_unit(p_org uuid,p_incident uuid,p_unit uuid) returns boolean
language sql volatile security definer set search_path='' as $read_unit$
 select exists(select 1 from public.incident_units u where u.id=p_unit and u.incident_id=p_incident)
 and (private.field_unit_visible(auth.uid(),p_org,p_unit) or private.incident_commander_unit_readable(p_org,p_incident,p_unit));
$read_unit$;
create function private.incident_reader_assignment(p_org uuid,p_incident uuid,p_assignment uuid) returns boolean
language sql volatile security definer set search_path='' as $read_assignment$
 select exists(select 1 from public.incident_task_assignments a left join public.incident_crew_members c on c.id=a.incident_crew_member_id
 where a.id=p_assignment and a.incident_id=p_incident and
 (private.field_assignment_visible(auth.uid(),p_org,a.id)
  or private.incident_commander_unit_readable(p_org,p_incident,coalesce(a.incident_unit_id,c.unit_assignment_id))));
$read_assignment$;

create function private.incident_reader_scope(p_org uuid,p_incident uuid) returns text
language plpgsql volatile security definer set search_path='' as $reader_scope$
declare v_roles jsonb;v_units jsonb;v_assignments jsonb;v_field text;v_history boolean;v_scope jsonb;
begin
 if not private.incident_reader_admitted(p_org,p_incident) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_array(r.id,r.version::text,r.role,r.organization_id,r.sector_id,
 r.parent_assignment_id,r.valid_from,r.valid_until,
 (select p.version::text from public.incident_role_assignments p where p.id=r.parent_assignment_id)) order by r.id),'[]')
 into v_roles from private.incident_commander_roles(p_org,p_incident) r;
 v_history:=private.incident_reader_history(p_org,p_incident);
 if exists(select 1 from public.incident_units u where u.incident_id=p_incident and private.field_unit_visible(auth.uid(),p_org,u.id))
  then v_field:=private.incident_field_scope(p_org,p_incident);end if;
 -- Non-command field readers keep their exact prior cursor/receipt identity.
 if jsonb_array_length(v_roles)=0 and not v_history then return v_field;end if;
 select coalesce(jsonb_agg(q.value order by q.id),'[]') into v_units from(
  select u.id,jsonb_build_array(u.id,u.organization_id,u.sector_id,u.participation_id,p.status,
   private.field_unit_visible(auth.uid(),p_org,u.id),
   private.field_unit_leader(auth.uid(),p_org,u.id)) value
  from public.incident_units u join public.incident_participants p on p.id=u.participation_id
  where u.incident_id=p_incident and private.incident_reader_unit(p_org,p_incident,u.id) order by u.id limit 101)q;
 select coalesce(jsonb_agg(q.value order by q.id),'[]') into v_assignments from(
  select a.id,jsonb_build_array(a.id,a.recipient_type,a.incident_unit_id,a.incident_crew_member_id,
   private.field_assignment_visible(auth.uid(),p_org,a.id)) value
  from public.incident_task_assignments a where a.incident_id=p_incident and private.incident_reader_assignment(p_org,p_incident,a.id)
  order by a.id limit 1001)q;
 if jsonb_array_length(v_units)>100 or jsonb_array_length(v_assignments)>1000 then raise exception 'SNAPSHOT_TOO_LARGE';end if;
 v_scope:=jsonb_build_array('ANDROID_READ_V2',auth.uid(),p_org,p_incident,v_field,v_roles,v_history,v_units,v_assignments,
 (select m.role from public.user_organizations m where m.user_id=auth.uid() and m.organization_id=p_org),
 (select jsonb_agg(jsonb_build_array(p.id,p.organization_id,p.status,p.version::text) order by p.id)
  from public.incident_participants p where p.incident_id=p_incident),
 (select i.lead_organization_id from public.incidents i where i.id=p_incident));
 return md5((select l.salt::text from private.incident_sync_limits l where l.id)||v_scope::text);
end;$reader_scope$;

create function private.incident_reader_projection(p_org uuid,p_incident uuid,p_map boolean default true) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $reader_projection$
declare v_base jsonb;v_core jsonb;v_units jsonb;v_tasks jsonb;v_history jsonb;v_roles jsonb;v_i public.incidents;
 v_features jsonb;v_result jsonb;v_scope text;v_terminal boolean;
begin
 perform private.incident_sync_lock(p_org,p_incident);
 v_scope:=private.incident_reader_scope(p_org,p_incident);
 select * into v_i from public.incidents i where i.id=p_incident;
 v_terminal:=v_i.status in ('CLOSED','CANCELLED');
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'role',r.role,'organization_id',r.organization_id,
 'sector_id',r.sector_id,'version',r.version::text,'valid_until',least(r.valid_until,
 (select parent.valid_until from public.incident_role_assignments parent where parent.id=r.parent_assignment_id))) order by r.id),'[]')
 into v_roles from private.incident_commander_roles(p_org,p_incident) r;
 if exists(select 1 from public.incident_units u where u.incident_id=p_incident and private.field_unit_visible(auth.uid(),p_org,u.id)) then
  v_base:=case when p_map then private.field_map_projection(p_org,p_incident) else private.field_projection(p_org,p_incident) end;
 end if;
 -- Commander-only additions are always read-only. Genuine field DTOs are retained by UUID.
 select coalesce(jsonb_agg(q.dto order by q.id),'[]') into v_units from(
  select u.id,coalesce((select old.value||jsonb_build_object('field_access',true) from jsonb_array_elements(coalesce(v_base->'units','[]')) old
   where old.value->>'id'=u.id::text),
   jsonb_build_object('id',u.id,'organization_id',u.organization_id,'name',ou.callsign||' · '||ou.name,
    'status',u.status,'version',u.version::text,'field_access',false,'read_only',true,'leader',false,'can_return',false,
    'can_manage_crew',false,'leader_name',null,'crew','[]'::jsonb,'crew_history','[]'::jsonb,
    'resources','[]'::jsonb,'status_actions','[]'::jsonb,
    'crew_count',(select count(*) from public.incident_crew_members c where c.unit_assignment_id=u.id and c.status='ACTIVE'))) dto
  from public.incident_units u join public.operational_units ou on ou.id=u.unit_id
  where u.incident_id=p_incident and private.incident_reader_unit(p_org,p_incident,u.id)
  order by u.id limit 101)q;
 select coalesce(jsonb_agg(q.dto order by q.id),'[]') into v_tasks from(
  select a.id,coalesce((select old.value from jsonb_array_elements(coalesce(v_base->'assignments','[]')) old where old.value->>'id'=a.id::text),
   jsonb_build_object('id',a.id,'version',a.version::text,'changed_revision',a.changed_revision::text,'status',a.status,
    'recipient_type',a.recipient_type,'recipient_id',coalesce(a.incident_unit_id,a.incident_crew_member_id),
    'unit_id',u.id,'recipient_name',ou.callsign||' · '||ou.name,'mine',false,'can_execute',false,'read_only',true,
    -- Redacted summary: no private notes/parameters/person identity or raw timeline JSON.
    'task',private.field_task_projection(t)-array['notes','parameters','issuer_name'])) dto
  from public.incident_task_assignments a join public.incident_tasks t on t.id=a.task_id and t.incident_id=a.incident_id
  left join public.incident_crew_members c on c.id=a.incident_crew_member_id
  join public.incident_units u on u.id=coalesce(a.incident_unit_id,c.unit_assignment_id)
  join public.operational_units ou on ou.id=u.unit_id
  where a.incident_id=p_incident and private.incident_reader_assignment(p_org,p_incident,a.id)
  order by a.id limit 1001)q;
 if jsonb_array_length(v_units)>100 or jsonb_array_length(v_tasks)>1000 then raise exception 'SNAPSHOT_TOO_LARGE';end if;
   select coalesce(jsonb_agg(q.dto order by q.sequence desc),'[]') into v_history from (
   select e.sequence,jsonb_build_object('sequence',e.sequence::text,'code',e.event_code,'recorded_at',e.recorded_at,
    'data',jsonb_strip_nulls(case
      when e.event_code='TASK_ISSUED' then jsonb_build_object('task_id',e.data->'task_id','action_version_id',e.data->'action_version_id')
      when e.event_code='TASK_CLOSED' then jsonb_build_object('task_id',e.data->'task_id','outcome',e.data->'outcome')
      when e.event_code='TASK_CANCELLED' then jsonb_build_object('task_id',e.data->'task_id')
      else jsonb_build_object('task_id',e.data->'task_id','task_assignment_id',e.data->'task_assignment_id',
        'from_status',e.data->'from_status','status',e.data->'status',
        'reason',case when exists(select 1 from public.incident_task_assignments pa
          left join public.incident_crew_members pc on pc.id=pa.incident_crew_member_id
          where pa.id::text=e.data->>'task_assignment_id' and pa.incident_id=v_i.id
          and private.field_assignment_visible(auth.uid(),p_org,pa.id)
          and (pc.user_id=auth.uid() or private.field_unit_leader(auth.uid(),p_org,
            coalesce(pa.incident_unit_id,pc.unit_assignment_id)))) then e.data->'reason' end)
      end)) dto
   from public.incident_timeline e where e.incident_id=v_i.id and (
    (e.event_code in ('TASK_ISSUED','TASK_CLOSED','TASK_CANCELLED') and exists(
      select 1 from jsonb_array_elements(v_tasks) visible where e.data->>'task_id'=visible->'task'->>'id'))
    or (e.event_code in ('TASK_ASSIGNMENT_ACKNOWLEDGED','TASK_ASSIGNMENT_STARTED','TASK_ASSIGNMENT_BLOCKED',
      'TASK_ASSIGNMENT_COMPLETED','TASK_ASSIGNMENT_UNABLE','TASK_ASSIGNMENT_CANCELLED') and exists(
      select 1 from jsonb_array_elements(v_tasks) visible where e.data->>'task_assignment_id'=visible->>'id'
       and e.data->>'task_id'=visible->'task'->>'id')))
   order by e.sequence desc limit 100) q;

 v_core:=jsonb_build_object('id',v_i.id,'reference',v_i.reference_number,'title',v_i.title,'status',v_i.status,
  'mode',case when exists(select 1 from public.simulation_scenarios s where s.incident_id=v_i.id) then 'TRAINING' else 'REAL' end,
  'latitude',v_i.latitude,'longitude',v_i.longitude,'version',v_i.version::text,'revision',v_i.revision::text,
  'timeline_sequence',v_i.timeline_sequence::text,'read_verified_at',clock_timestamp(),'leadership_schema',1,'read_schema',2,'commander_read',jsonb_array_length(v_roles)>0,
  'command_roles',v_roles,'historic_read',v_terminal,'read_only',v_terminal,'scope_only',true,
  'units',v_units,'assignments',v_tasks,'history',v_history);
 if p_map then
  -- Keep canonical NAV routes only from the independently authorized existing field map.
  select coalesce(jsonb_agg(q.dto order by q.id),'[]') into v_features from(
   select z.id,jsonb_build_object('id',z.id,'kind','INCIDENT_SECTOR','label',z.name,'geometry',z.geometry,'version',z.version::text) dto
   from public.incident_sectors z where z.incident_id=p_incident and z.active and z.geometry is not null and (
    exists(select 1 from private.incident_commander_roles(p_org,p_incident) r where
      r.role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER') or (r.role='SECTOR_COMMANDER' and r.sector_id=z.id))
    or exists(select 1 from public.incident_units u where u.incident_id=p_incident and u.sector_id=z.id
      and private.incident_reader_unit(p_org,p_incident,u.id))) order by z.id limit 201)q;
  -- Preserve old authorized context features, deduplicate by stable kind/UUID.
  select coalesce(jsonb_agg(q.value order by q.value->>'kind',q.value->>'id'),'[]') into v_features from(
   select distinct on (x.value->>'kind',x.value->>'id') x.value
   from jsonb_array_elements(v_features||coalesce(v_base->'field_map'->'features','[]'))x
   order by x.value->>'kind',x.value->>'id')q;
  if jsonb_array_length(v_features)>200 or octet_length(v_features::text)>786432 then
   v_features:='[]';v_result:=jsonb_build_object('status','MAP_TOO_LARGE');
  else v_result:=jsonb_build_object('status','COMPLETE');end if;
  v_core:=v_core||jsonb_build_object('field_map',coalesce(v_base->'field_map','{}')||v_result||
   jsonb_build_object('schema',1,'revision',v_i.revision::text,'source',private.field_map_watermark(p_org,p_incident),
    'features',v_features,'routes',coalesce(v_base->'field_map'->'routes','[]')));
 end if;
 if p_map and octet_length((v_core->'field_map')::text)>786432 then
  v_core:=jsonb_set(v_core,'{field_map}',jsonb_build_object('schema',1,'status','MAP_TOO_LARGE',
   'revision',v_i.revision::text,'source',private.field_map_watermark(p_org,p_incident),'features','[]'::jsonb,'routes','[]'::jsonb));
 end if;
 if octet_length(v_core::text)>3145728 then raise exception 'SNAPSHOT_TOO_LARGE';end if;
 return v_core;
end;$reader_projection$;

create function public.incident_read_directory(p_acting_organization_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $read_directory$
declare v_rows jsonb:='[]';v_row record;v_scope text;v_n integer:=0;
begin
 perform private.incident_sync_lock(p_acting_organization_id,null);
 for v_row in select i.id,i.revision,i.timeline_sequence from public.incidents i
 where private.incident_reader_admitted(p_acting_organization_id,i.id)
 order by i.id limit 51 for share loop
  v_n:=v_n+1;if v_n>50 then raise exception 'SNAPSHOT_TOO_LARGE';end if;
  v_scope:=private.incident_reader_scope(p_acting_organization_id,v_row.id);
  v_rows:=v_rows||jsonb_build_array(jsonb_build_object('id',v_row.id,'revision',v_row.revision::text,
   'timeline_sequence',v_row.timeline_sequence::text,'scope_fingerprint',v_scope,
   'map_source',private.field_map_watermark(p_acting_organization_id,v_row.id),
   'map_routes_allowed',exists(select 1 from private.field_map_route_units(p_acting_organization_id,v_row.id))));
 end loop;
 return jsonb_build_object('account',auth.uid(),'organization',p_acting_organization_id,'schema_version',1,'read_protocol',2,'incidents',v_rows);
end;$read_directory$;

-- Reuses B1/D1 storage, locks, pinning, receipt eligibility and bounds; only read-audience projection changes.
create function public.incident_read_snapshot_manifest(p_acting_organization_id uuid,p_incident_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $manifest$
declare v_payload jsonb;v_counts jsonb;v_id uuid:=gen_random_uuid();v_scope text;
 v_bytes integer;v_kind text;v_items jsonb;v_live integer;v_total bigint;v_started timestamptz:=clock_timestamp();
begin
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 v_scope:=private.incident_reader_scope(p_acting_organization_id,p_incident_id);
 v_payload:=private.incident_reader_projection(p_acting_organization_id,p_incident_id);
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

-- Reuses B1/D1 storage, locks, pinning, receipt eligibility and bounds; only read-audience projection changes.
create function public.incident_read_snapshot_page(p_acting_organization_id uuid,p_incident_id uuid,p_manifest_id uuid,
 p_collection text,p_after_ordinal bigint default 0,p_limit integer default 25) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $page$
declare v_manifest private.incident_snapshot_manifests;v_scope text;v_rows jsonb;v_last bigint;v_count bigint;
begin
 if p_after_ordinal is null or p_after_ordinal<0 or p_limit is null or p_limit not between 1 and 25
 or p_collection is null or p_collection not in ('core','units','assignments','history') then raise exception 'VALIDATION_FAILED';end if;
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 v_scope:=private.incident_reader_scope(p_acting_organization_id,p_incident_id);
 select * into v_manifest from private.incident_snapshot_manifests m where m.id=p_manifest_id
 and m.actor_id=auth.uid() and m.organization_id=p_acting_organization_id and m.incident_id=p_incident_id;
 if not found then raise exception 'MANIFEST_NOT_FOUND';end if;
 if v_manifest.expires_at<=clock_timestamp() then raise exception 'MANIFEST_EXPIRED';end if;
 if v_manifest.fingerprint<>v_scope then raise exception 'MANIFEST_SCOPE_CHANGED';end if;
 v_count:=(v_manifest.counts->>p_collection)::bigint;
 if p_after_ordinal>v_count then raise exception 'VALIDATION_FAILED';end if;
 select coalesce(jsonb_agg(jsonb_build_object('ordinal',q.ordinal::text,'payload',q.payload) order by q.ordinal),'[]'),
 coalesce(max(q.ordinal),p_after_ordinal) into v_rows,v_last from(
 select si.ordinal,si.payload from private.incident_snapshot_items si where si.manifest_id=p_manifest_id
 and si.collection=p_collection and si.ordinal>p_after_ordinal order by si.ordinal limit p_limit) q;
 if jsonb_array_length(v_rows)<>least(p_limit,v_count-p_after_ordinal) then raise exception 'MANIFEST_INCOMPLETE';end if;
 return jsonb_build_object('schema_version',1,'manifest_id',p_manifest_id,'account',auth.uid(),'organization',p_acting_organization_id,
 'incident_id',p_incident_id,'snapshot_revision',v_manifest.revision::text,'timeline_sequence',v_manifest.timeline_sequence::text,
 'scope_fingerprint',v_scope,'collection',p_collection,'items',v_rows,
 'next_cursor',case when v_last<v_count then v_last::text end,'complete',v_last=v_count);
end;
$page$;

-- Reuses B1/D1 storage, locks, pinning, receipt eligibility and bounds; only read-audience projection changes.
create function public.incident_read_change_feed(p_acting_organization_id uuid,p_incident_id uuid,
 p_scope_fingerprint text,p_after_revision bigint,p_after_ordinal integer,p_limit integer default 100) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $feed$
declare v_scope text;v_i public.incidents;v_rows jsonb;v_floor bigint;v_reset text;v_last_revision bigint;v_last_ordinal integer;
 v_started timestamptz:=clock_timestamp();
begin
 if p_after_revision is null or p_after_revision<0 or p_after_ordinal is null or p_after_ordinal<0
 or p_limit is null or p_limit not between 1 and 100 or p_scope_fingerprint is null or length(p_scope_fingerprint)<>32
 then raise exception 'VALIDATION_FAILED';end if;
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 perform private.prune_incident_changes(p_incident_id);
 v_scope:=private.incident_reader_scope(p_acting_organization_id,p_incident_id);
 select * into v_i from public.incidents i where i.id=p_incident_id;
 select h.floor_revision into v_floor from private.incident_change_horizons h where h.incident_id=p_incident_id;
 if v_scope<>p_scope_fingerprint then v_reset:='SCOPE_CHANGED';
 elsif p_after_revision>v_i.revision then v_reset:='CURSOR_FUTURE';
 elsif v_floor is null or p_after_revision<v_floor then v_reset:='CURSOR_EXPIRED';
 -- An explicit snapshot boundary uses INT_MAX; a change boundary must actually exist.
 elsif p_after_ordinal<>2147483647 and not exists(select 1 from private.incident_changes c
 where c.incident_id=p_incident_id and c.revision=p_after_revision and c.ordinal=p_after_ordinal)
 then v_reset:='CURSOR_MISSING';
 elsif v_i.revision-p_after_revision>10000 then v_reset:='CURSOR_LAG';
 elsif (select count(distinct c.revision) from private.incident_changes c where c.incident_id=p_incident_id
 and c.revision>p_after_revision and c.revision<=v_i.revision)<>v_i.revision-p_after_revision
 then v_reset:='HISTORY_GAP';
 end if;
 if v_reset is not null then return jsonb_build_object('schema_version',1,'account',auth.uid(),'organization',p_acting_organization_id,
 'incident_id',p_incident_id,'reset_required',true,'reason',v_reset);end if;
 select coalesce(jsonb_agg(jsonb_build_object('revision',q.revision::text,'ordinal',q.ordinal,
 'entity_kind',q.entity_kind,'entity_id',p_incident_id,'operation',q.operation,
 'entity_version',q.entity_version::text) order by q.revision,q.ordinal),'[]') into v_rows from(
 select c.* from private.incident_changes c where c.incident_id=p_incident_id
 and (c.revision,c.ordinal)>(p_after_revision,p_after_ordinal) order by c.revision,c.ordinal limit p_limit) q;
 v_last_revision:=coalesce((v_rows->-1->>'revision')::bigint,p_after_revision);
 v_last_ordinal:=coalesce((v_rows->-1->>'ordinal')::integer,p_after_ordinal);
 return jsonb_build_object('schema_version',1,'account',auth.uid(),'organization',p_acting_organization_id,'incident_id',p_incident_id,
 'scope_fingerprint',v_scope,'from_revision',p_after_revision::text,'from_ordinal',p_after_ordinal,
 'current_revision',v_i.revision::text,'timeline_sequence',v_i.timeline_sequence::text,
 'changes',v_rows,'next_revision',v_last_revision::text,'next_ordinal',v_last_ordinal,
 'has_more',exists(select 1 from private.incident_changes c where c.incident_id=p_incident_id and
 (c.revision,c.ordinal)>(v_last_revision,v_last_ordinal)),'reset_required',false,
 'duration_ms',extract(milliseconds from clock_timestamp()-v_started));
end;
$feed$;

-- Reuses B1/D1 storage, locks, pinning, receipt eligibility and bounds; only read-audience projection changes.
create function public.incident_read_entities(p_acting_organization_id uuid,p_incident_id uuid,
 p_scope_fingerprint text,p_expected_revision bigint) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $entities$
declare v_scope text;v_payload jsonb;
begin
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 v_scope:=private.incident_reader_scope(p_acting_organization_id,p_incident_id);
 if p_scope_fingerprint is distinct from v_scope then raise exception 'MANIFEST_SCOPE_CHANGED';end if;
 if p_expected_revision is null or p_expected_revision<0 then raise exception 'VALIDATION_FAILED';end if;
 v_payload:=private.incident_reader_projection(p_acting_organization_id,p_incident_id);
 if v_payload is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if (v_payload->>'revision')::bigint<>p_expected_revision then raise exception 'RESET_REQUIRED';end if;
 return jsonb_build_object('schema_version',1,'account',auth.uid(),'organization',p_acting_organization_id,
 'incident_id',p_incident_id,'scope_fingerprint',v_scope,'revision',v_payload->>'revision',
 'timeline_sequence',v_payload->>'timeline_sequence','payload',v_payload);
end;
$entities$;

-- Reuses B1/D1 storage, locks, pinning, receipt eligibility and bounds; only read-audience projection changes.
create function public.incident_read_timeline(p_acting_organization_id uuid,p_incident_id uuid,p_after_sequence bigint default 0) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $history$
declare v_tasks jsonb;v_history jsonb;v_projection jsonb;
begin
 if p_after_sequence is null or p_after_sequence<0 then raise exception 'VALIDATION_FAILED';end if;
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 perform private.incident_reader_scope(p_acting_organization_id,p_incident_id);
 v_projection:=private.incident_reader_projection(p_acting_organization_id,p_incident_id,false);
 if p_after_sequence>(v_projection->>'timeline_sequence')::bigint then raise exception 'VALIDATION_FAILED';end if;
 v_tasks:=v_projection->'assignments';
  select coalesce(jsonb_agg(q.dto order by q.sequence),'[]') into v_history from (
   select e.sequence,jsonb_build_object('sequence',e.sequence::text,'code',e.event_code,'recorded_at',e.recorded_at,
    'data',jsonb_strip_nulls(case
      when e.event_code='TASK_ISSUED' then jsonb_build_object('task_id',e.data->'task_id','action_version_id',e.data->'action_version_id')
      when e.event_code='TASK_CLOSED' then jsonb_build_object('task_id',e.data->'task_id','outcome',e.data->'outcome')
      when e.event_code='TASK_CANCELLED' then jsonb_build_object('task_id',e.data->'task_id')
      else jsonb_build_object('task_id',e.data->'task_id','task_assignment_id',e.data->'task_assignment_id',
        'from_status',e.data->'from_status','status',e.data->'status',
        'reason',case when exists(select 1 from public.incident_task_assignments pa
          left join public.incident_crew_members pc on pc.id=pa.incident_crew_member_id
          where pa.id::text=e.data->>'task_assignment_id' and pa.incident_id=p_incident_id
          and private.field_assignment_visible(auth.uid(),p_acting_organization_id,pa.id)
          and (pc.user_id=auth.uid() or private.field_unit_leader(auth.uid(),p_acting_organization_id,
            coalesce(pa.incident_unit_id,pc.unit_assignment_id)))) then e.data->'reason' end)
      end)) dto
   from public.incident_timeline e where e.incident_id=p_incident_id and e.sequence>p_after_sequence and (
    (e.event_code in ('TASK_ISSUED','TASK_CLOSED','TASK_CANCELLED') and exists(
      select 1 from jsonb_array_elements(v_tasks) visible where e.data->>'task_id'=visible->'task'->>'id'))
    or (e.event_code in ('TASK_ASSIGNMENT_ACKNOWLEDGED','TASK_ASSIGNMENT_STARTED','TASK_ASSIGNMENT_BLOCKED',
      'TASK_ASSIGNMENT_COMPLETED','TASK_ASSIGNMENT_UNABLE','TASK_ASSIGNMENT_CANCELLED') and exists(
      select 1 from jsonb_array_elements(v_tasks) visible where e.data->>'task_assignment_id'=visible->>'id'
       and e.data->>'task_id'=visible->'task'->>'id')))
   order by e.sequence limit 100) q;

 return jsonb_build_object('schema_version',1,'account',auth.uid(),'organization',p_acting_organization_id,
 'incident_id',p_incident_id,'events',v_history,'high_watermark',v_projection->>'timeline_sequence',
 'next_sequence',case when jsonb_array_length(v_history)=100 then v_history->-1->>'sequence' else v_projection->>'timeline_sequence' end);
end;
$history$;

-- Reuses B1/D1 storage, locks, pinning, receipt eligibility and bounds; only read-audience projection changes.
create function public.incident_read_operation_receipts(
 p_acting_organization_id uuid,p_incident_id uuid,p_requests jsonb
) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $field_receipts$
declare actor uuid:=auth.uid();entry jsonb;args jsonb;data jsonb;op uuid;rpc_name text;command_name text;
 expected_request jsonb;saved private.incident_operation_receipts;v_unit_id uuid;eligible boolean;
 rows_value jsonb:='[]';fingerprint text;
begin
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 fingerprint:=private.incident_reader_scope(p_acting_organization_id,p_incident_id);
 if jsonb_typeof(p_requests) is distinct from 'array' then raise exception 'VALIDATION_FAILED';end if;
 if jsonb_array_length(p_requests)>25 or octet_length(p_requests::text)>262144 then raise exception 'VALIDATION_FAILED';end if;
 if exists(select 1 from jsonb_array_elements(p_requests) x group by x.value->'request'->>'p_operation' having count(*)>1)
 then raise exception 'VALIDATION_FAILED';end if;
 for entry in select x.value from jsonb_array_elements(p_requests) x loop
  rpc_name:=entry->>'rpc';args:=entry->'request';data:=args->'p_payload';
  if jsonb_typeof(entry) is distinct from 'object' or jsonb_typeof(args) is distinct from 'object'
   or jsonb_typeof(data) is distinct from 'object' then raise exception 'VALIDATION_FAILED';end if;
  op:=(args->>'p_operation')::uuid;
  if op is null or (args->>'p_expected_version')::bigint is null or (args->>'p_expected_version')::bigint<1
   or (args->>'p_acting_organization_id')::uuid is distinct from p_acting_organization_id
   or (args->>'p_incident_id')::uuid is distinct from p_incident_id
   or exists(select 1 from jsonb_object_keys(args) k where k not in
    ('p_operation','p_acting_organization_id','p_incident_id','p_expected_version','p_payload'))
  then raise exception 'VALIDATION_FAILED';end if;
  command_name:=case rpc_name
   when 'incident_transition_task_assignment' then 'TASK_TRANSITION'
   when 'incident_issue_task' then 'TASK_ISSUE'
   when 'incident_update_unit_status' then 'RESOURCE_STATUS'
   when 'incident_add_crew_member' then 'RESOURCE_CREW_JOIN'
   when 'incident_remove_crew_member' then 'RESOURCE_CREW_LEAVE'
   when 'incident_transition_resource_allocation' then 'RESOURCE_RESOURCE_TRANSITION'
   when 'incident_message_send' then 'MESSAGE_SEND' end;
  if command_name is null then raise exception 'VALIDATION_FAILED';end if;
  expected_request:=jsonb_build_object('command',command_name,'org',p_acting_organization_id,
   'incident',p_incident_id,'expected',(args->>'p_expected_version')::bigint,'payload',data);
  eligible:=false;v_unit_id:=null;
  if rpc_name='incident_transition_task_assignment' then
   eligible:=private.field_assignment_visible(actor,p_acting_organization_id,(data->>'id')::uuid)
    and exists(select 1 from public.incident_task_assignments a where a.id=(data->>'id')::uuid and a.incident_id=p_incident_id);
  elsif rpc_name='incident_message_send' then
   expected_request:=jsonb_build_object('command','MESSAGE_SEND','org',p_acting_organization_id,'incident',p_incident_id,
    'payload',data||jsonb_build_object('body',btrim(replace(replace(data->>'body',chr(13)||chr(10),chr(10)),chr(13),chr(10)))));
   eligible:=private.message_authority(actor,p_acting_organization_id,p_incident_id,data->>'audience_kind',
    (data->>'audience_org_id')::uuid,(data->>'audience_unit_assignment_id')::uuid,false);
  else
   if rpc_name='incident_issue_task' then
    if jsonb_typeof(data->'recipients') is distinct from 'array' then raise exception 'VALIDATION_FAILED';end if;
    select c.unit_assignment_id into v_unit_id from public.incident_crew_members c
     where c.id=(data->'recipients'->0->>'recipient_id')::uuid and c.incident_id=p_incident_id
     and jsonb_array_length(data->'recipients')=1;
   elsif rpc_name='incident_update_unit_status' then v_unit_id:=(data->>'id')::uuid;
   elsif rpc_name='incident_add_crew_member' then v_unit_id:=(data->>'unit_assignment_id')::uuid;
   elsif rpc_name='incident_remove_crew_member' then
    select c.unit_assignment_id into v_unit_id from public.incident_crew_members c where c.id=(data->>'id')::uuid and c.incident_id=p_incident_id;
   else
    select a.unit_assignment_id into v_unit_id from public.incident_resource_allocations a where a.id=(data->>'id')::uuid and a.incident_id=p_incident_id;
   end if;
   eligible:=exists(select 1 from public.incident_units u where u.id=v_unit_id and u.incident_id=p_incident_id and u.organization_id=p_acting_organization_id)
    and private.field_unit_visible(actor,p_acting_organization_id,v_unit_id)
    and private.field_unit_leader(actor,p_acting_organization_id,v_unit_id);
  end if;
  if eligible is not true then
   rows_value:=rows_value||jsonb_build_array(jsonb_build_object('operation_id',op,'status','SCOPE_UNAVAILABLE'));
   continue;
  end if;
  select * into saved from private.incident_operation_receipts r where r.operation_id=op
   and r.actor_user_id=actor and r.acting_organization_id=p_acting_organization_id and r.incident_id=p_incident_id;
  if not found then
   -- ABSENT is NOT proof of rejection: another transaction/late reply may exist.
   rows_value:=rows_value||jsonb_build_array(jsonb_build_object('operation_id',op,'status','ABSENT'));
  elsif saved.command_code is distinct from command_name or saved.request is distinct from expected_request then
   rows_value:=rows_value||jsonb_build_array(jsonb_build_object('operation_id',op,'status','IDENTITY_MISMATCH'));
  else
   rows_value:=rows_value||jsonb_build_array(jsonb_build_object('operation_id',op,'status','FOUND',
    'result',case when command_name='MESSAGE_SEND' then saved.result-'message' else saved.result end,'confirmed_at',saved.created_at));
  end if;
 end loop;
 return jsonb_build_object('account',actor,'organization',p_acting_organization_id,'incident_id',p_incident_id,
  'scope_fingerprint',fingerprint,'rows',rows_value);
exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'VALIDATION_FAILED';
end;
$field_receipts$;

alter function private.incident_commander_roles(uuid,uuid) owner to postgres;
revoke all on function private.incident_commander_roles(uuid,uuid) from public,anon,authenticated,service_role;

alter function private.incident_reader_history(uuid,uuid) owner to postgres;
revoke all on function private.incident_reader_history(uuid,uuid) from public,anon,authenticated,service_role;

alter function private.incident_reader_admitted(uuid,uuid) owner to postgres;
revoke all on function private.incident_reader_admitted(uuid,uuid) from public,anon,authenticated,service_role;

alter function private.incident_commander_unit_readable(uuid,uuid,uuid) owner to postgres;
revoke all on function private.incident_commander_unit_readable(uuid,uuid,uuid) from public,anon,authenticated,service_role;

alter function private.incident_reader_unit(uuid,uuid,uuid) owner to postgres;
revoke all on function private.incident_reader_unit(uuid,uuid,uuid) from public,anon,authenticated,service_role;

alter function private.incident_reader_assignment(uuid,uuid,uuid) owner to postgres;
revoke all on function private.incident_reader_assignment(uuid,uuid,uuid) from public,anon,authenticated,service_role;

alter function private.incident_reader_scope(uuid,uuid) owner to postgres;
revoke all on function private.incident_reader_scope(uuid,uuid) from public,anon,authenticated,service_role;

alter function private.incident_reader_projection(uuid,uuid,boolean) owner to postgres;
revoke all on function private.incident_reader_projection(uuid,uuid,boolean) from public,anon,authenticated,service_role;

alter function public.incident_read_directory(uuid) owner to postgres;
revoke all on function public.incident_read_directory(uuid) from public,anon,authenticated,service_role;
grant execute on function public.incident_read_directory(uuid) to authenticated;

alter function public.incident_read_snapshot_manifest(uuid,uuid) owner to postgres;
revoke all on function public.incident_read_snapshot_manifest(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.incident_read_snapshot_manifest(uuid,uuid) to authenticated;

alter function public.incident_read_snapshot_page(uuid,uuid,uuid,text,bigint,integer) owner to postgres;
revoke all on function public.incident_read_snapshot_page(uuid,uuid,uuid,text,bigint,integer) from public,anon,authenticated,service_role;
grant execute on function public.incident_read_snapshot_page(uuid,uuid,uuid,text,bigint,integer) to authenticated;

alter function public.incident_read_change_feed(uuid,uuid,text,bigint,integer,integer) owner to postgres;
revoke all on function public.incident_read_change_feed(uuid,uuid,text,bigint,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.incident_read_change_feed(uuid,uuid,text,bigint,integer,integer) to authenticated;

alter function public.incident_read_entities(uuid,uuid,text,bigint) owner to postgres;
revoke all on function public.incident_read_entities(uuid,uuid,text,bigint) from public,anon,authenticated,service_role;
grant execute on function public.incident_read_entities(uuid,uuid,text,bigint) to authenticated;

alter function public.incident_read_timeline(uuid,uuid,bigint) owner to postgres;
revoke all on function public.incident_read_timeline(uuid,uuid,bigint) from public,anon,authenticated,service_role;
grant execute on function public.incident_read_timeline(uuid,uuid,bigint) to authenticated;

alter function public.incident_read_operation_receipts(uuid,uuid,jsonb) owner to postgres;
revoke all on function public.incident_read_operation_receipts(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.incident_read_operation_receipts(uuid,uuid,jsonb) to authenticated;

-- GPS remains a separately approved audience; this only supplies current Android read identity.
create or replace function private.vehicle_location_field_fingerprint(p_org uuid,p_incident uuid) returns text
language plpgsql security definer set search_path='' as $gps_reader_scope$
begin
 if not private.incident_reader_admitted(p_org,p_incident) then return null;end if;
 return private.incident_reader_scope(p_org,p_incident);
exception when raise_exception then
 if sqlerrm='SNAPSHOT_TOO_LARGE' then return null;end if;
 raise;
end;$gps_reader_scope$;
alter function private.vehicle_location_field_fingerprint(uuid,uuid) owner to postgres;
revoke all on function private.vehicle_location_field_fingerprint(uuid,uuid) from public,anon,authenticated,service_role;
commit;
