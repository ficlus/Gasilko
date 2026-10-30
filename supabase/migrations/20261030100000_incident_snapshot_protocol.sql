-- M14.7B1. Temporary synchronization metadata only; canonical history is untouched.
create table private.incident_sync_limits (
 id boolean primary key default true check(id), salt uuid not null default gen_random_uuid()
);
insert into private.incident_sync_limits(id) values(true);
create table private.incident_change_horizons (
 incident_id uuid primary key references public.incidents(id) on delete restrict,
 floor_revision bigint not null check(floor_revision>=0)
);
insert into private.incident_change_horizons select i.id,i.revision from public.incidents i;
create table private.incident_changes (
 incident_id uuid not null references public.incidents(id) on delete restrict,
 revision bigint not null check(revision>0), ordinal integer not null check(ordinal>0),
 entity_kind text not null check(entity_kind in ('FIELD_COLLECTIONS','INCIDENT_SCOPE')),
 operation text not null check(operation in ('UPSERT','REVOKE','SCOPE_RESET')),
 entity_version bigint not null, audience_scope text not null default 'CURRENT_AUTHORIZED_PROJECTION',
 recorded_at timestamptz not null default clock_timestamp(),
 primary key(incident_id,revision,ordinal)
);
create index incident_changes_retention on private.incident_changes(incident_id,recorded_at,revision);
create table private.incident_snapshot_manifests (
 id uuid primary key default gen_random_uuid(), actor_id uuid not null references public.profiles(id),
 organization_id uuid not null references public.organizations(id),
 incident_id uuid not null references public.incidents(id),
 revision bigint not null, timeline_sequence bigint not null, fingerprint text not null,
 schema_version integer not null default 1 check(schema_version=1),
 counts jsonb not null, byte_size integer not null check(byte_size between 0 and 3145728),
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null default clock_timestamp()+interval '5 minutes',
 unique(id,actor_id,organization_id,incident_id)
);
create index incident_manifest_expiry on private.incident_snapshot_manifests(expires_at,id);
create index incident_manifest_owner on private.incident_snapshot_manifests(actor_id,organization_id,incident_id,expires_at);
create table private.incident_snapshot_items (
 manifest_id uuid not null, actor_id uuid not null, organization_id uuid not null, incident_id uuid not null,
 collection text not null check(collection in ('core','units','assignments','history')),
 ordinal bigint not null check(ordinal>0), payload jsonb not null,
 primary key(manifest_id,collection,ordinal),
 foreign key(manifest_id,actor_id,organization_id,incident_id)
 references private.incident_snapshot_manifests(id,actor_id,organization_id,incident_id) on delete cascade
);
revoke all on private.incident_sync_limits,private.incident_change_horizons,private.incident_changes,
 private.incident_snapshot_manifests,private.incident_snapshot_items from public,anon,authenticated,service_role;

-- The canonical timeline is append-only and shares the command/receipt transaction.
-- Only explicitly supported field collection changes are incremental. Unknown,
-- command/participation, COP, inventory and SIM event classes invalidate the scope.
create function private.capture_incident_change() returns trigger
language plpgsql security definer set search_path='' as $capture_change$
begin
 insert into private.incident_change_horizons(incident_id,floor_revision)
 values(new.incident_id,new.revision-1) on conflict do nothing;
 insert into private.incident_changes(incident_id,revision,ordinal,entity_kind,operation,entity_version,recorded_at)
 values(new.incident_id,new.revision,new.event_ordinal,
 case when new.event_code in ('TASK_ISSUED','TASK_CLOSED','TASK_CANCELLED','TASK_ASSIGNMENT_ACKNOWLEDGED',
 'TASK_ASSIGNMENT_STARTED','TASK_ASSIGNMENT_BLOCKED','TASK_ASSIGNMENT_COMPLETED','TASK_ASSIGNMENT_UNABLE',
 'TASK_ASSIGNMENT_CANCELLED','UNIT_STATUS_CHANGED') then 'FIELD_COLLECTIONS' else 'INCIDENT_SCOPE' end,
 case when new.event_code in ('TASK_ISSUED','TASK_CLOSED','TASK_CANCELLED','TASK_ASSIGNMENT_ACKNOWLEDGED',
 'TASK_ASSIGNMENT_STARTED','TASK_ASSIGNMENT_BLOCKED','TASK_ASSIGNMENT_COMPLETED','TASK_ASSIGNMENT_UNABLE',
 'TASK_ASSIGNMENT_CANCELLED','UNIT_STATUS_CHANGED') then 'UPSERT' else 'SCOPE_RESET' end,
 new.revision,new.recorded_at);
 return new;
end;
$capture_change$;
create trigger incident_change_capture after insert on public.incident_timeline
 for each row execute function private.capture_incident_change();

-- Bounded maintenance never edits canonical timeline, receipts or audit.
create function private.prune_incident_changes(p_incident uuid) returns void
language plpgsql security definer set search_path='' as $prune_changes$
declare v_floor bigint;
begin
 select max(q.revision) into v_floor from (
 select c.revision from private.incident_changes c where c.incident_id=p_incident
 and c.recorded_at<clock_timestamp()-interval '30 days' order by c.revision,c.ordinal limit 500) q;
 if v_floor is not null then
  update private.incident_change_horizons h set floor_revision=greatest(h.floor_revision,v_floor)
   where h.incident_id=p_incident;
  delete from private.incident_changes c where c.incident_id=p_incident and c.revision<=v_floor;
 end if;
end;
$prune_changes$;

-- Bound lock waits and retain the established organization -> actor -> incident order.
-- Called only inside RPC transactions; no HTTP transaction is held open.
create function private.incident_sync_lock(p_org uuid,p_incident uuid) returns void
language plpgsql security definer set search_path='' as $sync_lock$
begin
 if auth.uid() is null or not private.is_active_user() or not private.incident_acting_member(p_org)
 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform private.lock_organization(p_org);
 perform 1 from public.organizations o where o.id=p_org for share;
 perform 1 from public.profiles pr where pr.id=auth.uid() for share;
 if p_incident is not null then perform 1 from public.incidents i where i.id=p_incident for share; end if;
 if not private.is_active_user() or not private.incident_acting_member(p_org)
 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
end;
$sync_lock$;

-- Internal signature never leaves PostgreSQL; returned digest includes a private salt.
-- Include active recipient identities, effective roles and profile/membership changes,
-- not task content or the incident revision. New grants/narrowing both reset the scope.
create function private.incident_field_scope(p_org uuid,p_incident uuid) returns text
language plpgsql volatile security definer set search_path='' as $field_scope$
declare v_scope jsonb;v_units jsonb;v_count integer;
begin
 if not private.is_active_user() or not private.incident_acting_member(p_org)
 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select coalesce(jsonb_agg(q.value order by q.id),'[]'),count(*) into v_units,v_count from (
 select u.id,jsonb_build_object('unit',u.id,'leader',private.field_unit_leader(auth.uid(),p_org,u.id),
 'catalog',ou.updated_at,'crew',coalesce((select jsonb_agg(jsonb_build_array(c.id,c.user_id,pr.account_status,
 pr.display_name,m.role) order by c.id)
 from (select cc.* from public.incident_crew_members cc where cc.unit_assignment_id=u.id and cc.status='ACTIVE'
 and (cc.user_id=auth.uid() or private.field_unit_leader(auth.uid(),p_org,u.id))
 order by cc.id limit 101) c join public.profiles pr on pr.id=c.user_id
 left join public.user_organizations m on m.user_id=c.user_id and m.organization_id=p_org
 where c.unit_assignment_id=u.id and c.status='ACTIVE'
 and (c.user_id=auth.uid() or private.field_unit_leader(auth.uid(),p_org,u.id))),'[]')) value
 from public.incident_units u join public.operational_units ou on ou.id=u.unit_id
 where u.incident_id=p_incident and private.field_unit_visible(auth.uid(),p_org,u.id)
 order by u.id limit 101) q;
 if v_count=0 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if v_count>100 then raise exception 'SNAPSHOT_TOO_LARGE'; end if;
 if exists(select 1 from jsonb_array_elements(v_units) uv where jsonb_array_length(uv->'crew')>100)
 then raise exception 'SNAPSHOT_TOO_LARGE';end if;
 v_scope:=jsonb_build_array(auth.uid(),p_org,p_incident,v_units,
 (select jsonb_agg(jsonb_build_array(r.id,r.version::text,private.incident_assignment_effective(r.id)) order by r.id)
 from public.incident_role_assignments r where r.incident_id=p_incident and r.organization_id=p_org
 and r.user_id=auth.uid() and r.status='ACTIVE'),
 (select h.floor_revision::text from private.incident_change_horizons h where h.incident_id=p_incident));
 return md5((select l.salt::text from private.incident_sync_limits l where l.id)||v_scope::text);
end;
$field_scope$;

create function private.field_projection(p_acting_organization_id uuid,p_incident_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $incident_field_snapshot$
declare v_actor uuid:=auth.uid();v_i public.incidents;v_rows jsonb:='[]';v_units jsonb;v_tasks jsonb;v_history jsonb;v_result jsonb;v_count integer:=0;v_lock_timeout text:=current_setting('lock_timeout');
begin
 if v_actor is null or not private.incident_acting_member(p_acting_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 -- Same organization security lock as canonical mutations. Parent locks pin each
 -- incident projection; no client merging of unrelated pages is supported.
 perform set_config('lock_timeout','1500ms',true);
 perform private.lock_organization(p_acting_organization_id);
 if not private.incident_acting_member(p_acting_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 for v_i in select i.* from public.incidents i where i.id=p_incident_id and i.status<>'DRAFT'
 and exists(select 1 from public.incident_units u where u.incident_id=i.id
 and private.field_unit_visible(v_actor,p_acting_organization_id,u.id))
 order by i.id limit 51 for share loop
  v_count:=v_count+1;
  if v_count>50 then raise exception 'SNAPSHOT_TOO_LARGE'; end if;
  select coalesce(jsonb_agg(q.dto order by q.id),'[]') into v_units from (
   select u.id,jsonb_build_object('id',u.id,'name',ou.callsign||' · '||ou.name,'status',u.status,'version',u.version::text,
    'can_return',u.status='ON_SCENE' and private.field_unit_leader(v_actor,p_acting_organization_id,u.id)
       and private.can_manage_incident_unit(v_i.id,p_acting_organization_id,u.organization_id,u.id,'STATUS'),
    'leader',private.field_unit_leader(v_actor,p_acting_organization_id,u.id),
    'leader_name',(select pr.display_name from public.incident_role_assignments r join public.profiles pr on pr.id=r.user_id
       where r.unit_assignment_id=u.id and r.role='UNIT_LEADER' and private.incident_assignment_effective(r.id) limit 1),
    'crew',coalesce((select jsonb_agg(qc.dto order by qc.id) from (
      select c.id,jsonb_build_object('id',c.id,'user_id',c.user_id,'name',coalesce(pr.display_name,c.user_id::text),
       'role',c.crew_role,'status',c.status,
       'can_issue',private.field_unit_leader(v_actor,p_acting_organization_id,u.id)
        and private.task_recipient_eligible(v_i.id,'INCIDENT_CREW_MEMBER',c.id)
        and private.can_issue_task(v_i.id,p_acting_organization_id,'INCIDENT_CREW_MEMBER',c.id)) dto
      from public.incident_crew_members c join public.profiles pr on pr.id=c.user_id and pr.account_status='ACTIVE'
      join public.user_organizations cm on cm.user_id=c.user_id and cm.organization_id=c.membership_organization_id
      where c.unit_assignment_id=u.id and c.status='ACTIVE'
      and (c.user_id=v_actor or private.field_unit_leader(v_actor,p_acting_organization_id,u.id))
      order by c.id limit 101) qc),'[]')) dto
   from public.incident_units u join public.operational_units ou on ou.id=u.unit_id
   where u.incident_id=v_i.id and private.field_unit_visible(v_actor,p_acting_organization_id,u.id)
   order by u.id limit 101) q;
  if jsonb_array_length(v_units)>100 or exists(select 1 from jsonb_array_elements(v_units) x where jsonb_array_length(x->'crew')>100)
   then raise exception 'FIELD_SNAPSHOT_LIMIT'; end if;
  select coalesce(jsonb_agg(q.dto order by q.id),'[]') into v_tasks from (
   select a.id,jsonb_build_object('id',a.id,'version',a.version::text,'changed_revision',a.changed_revision::text,'status',a.status,'recipient_type',a.recipient_type,
    'recipient_id',coalesce(a.incident_unit_id,a.incident_crew_member_id),'unit_id',coalesce(a.incident_unit_id,c.unit_assignment_id),
    'recipient_name',case when c.id is null then ou.callsign||' · '||ou.name else coalesce(pr.display_name,c.user_id::text) end,
    'mine',c.user_id=v_actor,'can_execute',v_i.status in ('ACTIVE','STABILIZED') and t.status='OPEN'
      and a.status not in ('COMPLETED','UNABLE','CANCELLED')
      and private.can_execute_task(v_i.id,p_acting_organization_id,a.recipient_type,coalesce(a.incident_unit_id,a.incident_crew_member_id)),
    'task',private.field_task_projection(t)) dto
   from public.incident_task_assignments a join public.incident_tasks t on t.id=a.task_id
   left join public.incident_crew_members c on c.id=a.incident_crew_member_id
   left join public.profiles pr on pr.id=c.user_id
   join public.incident_units u on u.id=coalesce(a.incident_unit_id,c.unit_assignment_id)
   join public.operational_units ou on ou.id=u.unit_id
   where a.incident_id=v_i.id and private.field_assignment_visible(v_actor,p_acting_organization_id,a.id)
   order by a.id limit 1001) q;
  if jsonb_array_length(v_tasks)>1000 then raise exception 'FIELD_SNAPSHOT_LIMIT'; end if;
  -- Event-specific allowlist. Shared task events never carry recipient-private
  -- fields. Assignment reasons are only for that recipient or its effective leader.
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
          and private.field_assignment_visible(v_actor,p_acting_organization_id,pa.id)
          and (pc.user_id=v_actor or private.field_unit_leader(v_actor,p_acting_organization_id,
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
  v_rows:=v_rows||jsonb_build_array(jsonb_build_object('id',v_i.id,'reference',v_i.reference_number,
    'title',v_i.title,'status',v_i.status,'mode',case when exists(select 1 from public.simulation_scenarios s where s.incident_id=v_i.id) then 'TRAINING' else 'REAL' end,'latitude',v_i.latitude,'longitude',v_i.longitude,
    'version',v_i.version::text,'revision',v_i.revision::text,'timeline_sequence',v_i.timeline_sequence::text,
    'units',v_units,'assignments',v_tasks,'history',v_history));
 end loop;
 v_result:=jsonb_build_object('account',v_actor,'organization',p_acting_organization_id,'verified_at',clock_timestamp(),'incidents',v_rows);
 if octet_length(v_result::text)>3145728 then raise exception 'FIELD_SNAPSHOT_LIMIT'; end if;
 perform set_config('lock_timeout',v_lock_timeout,true);
 return v_rows->0;
end;
$incident_field_snapshot$;


create function public.incident_field_directory(p_acting_organization_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $directory$
declare v_rows jsonb:='[]';v_row record;v_scope text;v_n integer:=0;
begin
 perform private.incident_sync_lock(p_acting_organization_id,null);
 for v_row in select i.id,i.revision,i.timeline_sequence from public.incidents i where exists(
 select 1 from public.incident_units u where u.incident_id=i.id
 and private.field_unit_visible(auth.uid(),p_acting_organization_id,u.id))
 order by i.id limit 51 for share loop
  v_n:=v_n+1;if v_n>50 then raise exception 'SNAPSHOT_TOO_LARGE';end if;
  v_scope:=private.incident_field_scope(p_acting_organization_id,v_row.id);
  v_rows:=v_rows||jsonb_build_array(jsonb_build_object('id',v_row.id,
  'revision',v_row.revision::text,'timeline_sequence',v_row.timeline_sequence::text,'scope_fingerprint',v_scope));
 end loop;
 return jsonb_build_object('account',auth.uid(),'organization',p_acting_organization_id,'schema_version',1,'incidents',v_rows);
end;
$directory$;

create function public.incident_snapshot_manifest(p_acting_organization_id uuid,p_incident_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $manifest$
declare v_payload jsonb;v_counts jsonb;v_id uuid:=gen_random_uuid();v_scope text;
 v_bytes integer;v_kind text;v_items jsonb;v_live integer;v_total bigint;v_started timestamptz:=clock_timestamp();
begin
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 v_scope:=private.incident_field_scope(p_acting_organization_id,p_incident_id);
 v_payload:=private.field_projection(p_acting_organization_id,p_incident_id);
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

create function public.incident_snapshot_page(p_acting_organization_id uuid,p_incident_id uuid,p_manifest_id uuid,
 p_collection text,p_after_ordinal bigint default 0,p_limit integer default 25) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $page$
declare v_manifest private.incident_snapshot_manifests;v_scope text;v_rows jsonb;v_last bigint;v_count bigint;
begin
 if p_after_ordinal is null or p_after_ordinal<0 or p_limit is null or p_limit not between 1 and 25
 or p_collection is null or p_collection not in ('core','units','assignments','history') then raise exception 'VALIDATION_FAILED';end if;
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 v_scope:=private.incident_field_scope(p_acting_organization_id,p_incident_id);
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

create function public.incident_change_feed(p_acting_organization_id uuid,p_incident_id uuid,
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
 v_scope:=private.incident_field_scope(p_acting_organization_id,p_incident_id);
 select * into v_i from public.incidents i where i.id=p_incident_id;
 perform private.prune_incident_changes(p_incident_id);
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

-- One grouped DTO read, not one request per recipient. Collection identity is the
-- incident; its version is aggregate revision, never assignment.version.
-- This complete bounded projection can supersede all feed pages through this revision.
create function public.incident_field_entities(p_acting_organization_id uuid,p_incident_id uuid,
 p_scope_fingerprint text,p_expected_revision bigint) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $entities$
declare v_scope text;v_payload jsonb;
begin
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 v_scope:=private.incident_field_scope(p_acting_organization_id,p_incident_id);
 if p_scope_fingerprint is distinct from v_scope then raise exception 'MANIFEST_SCOPE_CHANGED';end if;
 if p_expected_revision is null or p_expected_revision<0 then raise exception 'VALIDATION_FAILED';end if;
 v_payload:=private.field_projection(p_acting_organization_id,p_incident_id);
 if v_payload is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if (v_payload->>'revision')::bigint<>p_expected_revision then raise exception 'RESET_REQUIRED';end if;
 return jsonb_build_object('schema_version',1,'account',auth.uid(),'organization',p_acting_organization_id,
 'incident_id',p_incident_id,'scope_fingerprint',v_scope,'revision',v_payload->>'revision',
 'timeline_sequence',v_payload->>'timeline_sequence','payload',v_payload);
end;
$entities$;

-- Revision writes without a timeline event cannot silently look current. A
-- deferred trigger observes the finished transaction, including later events.
create function private.incident_change_fallback() returns trigger
language plpgsql security definer set search_path='' as $fallback$
begin
 if tg_op='UPDATE' and new.revision=old.revision then return new;end if;
 insert into private.incident_change_horizons(incident_id,floor_revision)
 values(new.id,greatest(0,new.revision-1)) on conflict do nothing;
 if new.revision>0 and not exists(select 1 from private.incident_changes c
 where c.incident_id=new.id and c.revision=new.revision) then
  insert into private.incident_changes(incident_id,revision,ordinal,entity_kind,operation,entity_version)
  values(new.id,new.revision,1,'INCIDENT_SCOPE','SCOPE_RESET',new.revision);
 end if;
 return new;
end;
$fallback$;
create constraint trigger incident_change_fallback after insert or update on public.incidents
 deferrable initially deferred for each row execute function private.incident_change_fallback();

-- Web keeps its existing command/COP/resource DTOs and independent SIM lane.
-- This small authorization-aware watermark replaces the heavy context polling.
create function public.incident_sync_head(p_acting_organization_id uuid,p_incident_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $web_head$
declare v_context jsonb;
begin
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 v_context:=public.incident_context(p_incident_id,p_acting_organization_id);
 if v_context is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return jsonb_build_object('id',p_incident_id,'version',v_context->>'version',
 'revision',v_context->>'revision','timeline_sequence',v_context->>'timeline_sequence',
 'scope_fingerprint',md5((select l.salt::text from private.incident_sync_limits l where l.id)||
 auth.uid()::text||p_acting_organization_id::text||v_context::text));
end;
$web_head$;

create function public.incident_field_timeline(p_acting_organization_id uuid,p_incident_id uuid,p_after_sequence bigint default 0) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $history$
declare v_tasks jsonb;v_history jsonb;v_projection jsonb;
begin
 if p_after_sequence is null or p_after_sequence<0 then raise exception 'VALIDATION_FAILED';end if;
 perform private.incident_sync_lock(p_acting_organization_id,p_incident_id);
 perform private.incident_field_scope(p_acting_organization_id,p_incident_id);
 v_projection:=private.field_projection(p_acting_organization_id,p_incident_id);
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

revoke all on function private.capture_incident_change(),private.prune_incident_changes(uuid),
 private.incident_sync_lock(uuid,uuid),private.incident_field_scope(uuid,uuid),private.field_projection(uuid,uuid),
 private.incident_change_fallback() from public,anon,authenticated,service_role;
revoke all on function public.incident_field_directory(uuid),public.incident_snapshot_manifest(uuid,uuid),
 public.incident_snapshot_page(uuid,uuid,uuid,text,bigint,integer),
 public.incident_change_feed(uuid,uuid,text,bigint,integer,integer),
 public.incident_field_entities(uuid,uuid,text,bigint),public.incident_sync_head(uuid,uuid),
 public.incident_field_timeline(uuid,uuid,bigint) from public,anon,authenticated,service_role;
grant execute on function public.incident_field_directory(uuid),public.incident_snapshot_manifest(uuid,uuid),
 public.incident_snapshot_page(uuid,uuid,uuid,text,bigint,integer),
 public.incident_change_feed(uuid,uuid,text,bigint,integer,integer),
 public.incident_field_entities(uuid,uuid,text,bigint),public.incident_sync_head(uuid,uuid),
 public.incident_field_timeline(uuid,uuid,bigint) to authenticated;
