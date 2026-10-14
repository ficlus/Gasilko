-- M14.5F3: tactical triage annotations reuse the established COP object model.
alter table public.incident_map_objects drop constraint incident_map_objects_kind_check;
alter table public.incident_map_objects add constraint incident_map_objects_kind_check
 check(kind in ('COMMAND_POST','STAGING','TRIAGE_POINT','HAZARD','WATER_SOURCE','ACCESS_POINT','PERIMETER','NOTE'));

-- Preserve the COP command contract and authorization path. Object mutations now
-- record immutable before/after snapshots on the existing organization audit log.
create or replace function private.incident_cop_command(p_action text,p_operation uuid,p_org uuid,p_incident uuid,p_expected bigint,p_payload jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
 actor_id uuid:=auth.uid(); organization_id_value uuid; profile_id_value uuid; incident_row public.incidents;
 sector_row public.incident_sectors; map_object_row public.incident_map_objects; link_row public.incident_hydrant_links;
 entity_id uuid; target_sector_id uuid; expected_entity_version bigint; geometry_value jsonb; event_code_value text;
 request_value jsonb; receipt_row private.incident_operation_receipts; result_value jsonb; entity_version bigint;
 changed_revision_value bigint; global_authority boolean; allowed_keys text[]; hydrant_org uuid; geometry_bytes bigint; map_object_before jsonb; map_object_after jsonb;
begin
 if actor_id is null or not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_operation is null or p_org is null or p_incident is null or jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>96000 then raise exception 'VALIDATION_FAILED'; end if;
 allowed_keys:=case p_action when 'SECTOR_CREATE' then array['id','code','name','geometry']
 when 'SECTOR_UPDATE' then array['id','version','name','geometry']
 when 'OBJECT_PUT' then array['id','version','kind','label','description','geometry','sector_id']
 when 'HYDRANT_LINK' then array['id','hydrant_id','purpose'] else array['id','version'] end;
 if exists(select 1 from jsonb_each(p_payload) f where not(f.key=any(allowed_keys))
  or (f.key<>'geometry' and jsonb_typeof(f.value) not in ('string','null'))) then raise exception 'VALIDATION_FAILED'; end if;
 if p_action='SECTOR_UPDATE' and not(p_payload ? 'geometry') then raise exception 'VALIDATION_FAILED'; end if;
 entity_id:=(p_payload->>'id')::uuid; target_sector_id:=(p_payload->>'sector_id')::uuid;
 expected_entity_version:=(p_payload->>'version')::bigint; geometry_value:=nullif(p_payload->'geometry','null'::jsonb);
 if entity_id is null then raise exception 'VALIDATION_FAILED'; end if;
 request_value:=jsonb_build_object('command','COP_'||p_action,'org',p_org,'incident',p_incident,'expected',p_expected,'payload',p_payload);
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 if p_action='HYDRANT_LINK' then select h.organization_id into hydrant_org from public.hydrants h where h.id=(p_payload->>'hydrant_id')::uuid; end if;
 for organization_id_value in select distinct q.org from(select p_org org union all select hydrant_org union all
  select ip.organization_id from public.incident_participants ip where ip.incident_id=p_incident) q where q.org is not null order by q.org loop
  perform private.lock_organization(organization_id_value);
  perform 1 from public.organizations o where o.id=organization_id_value for share;
 end loop;
 for profile_id_value in select distinct q.uid from(select actor_id uid union all
  select a.user_id from public.incident_role_assignments a where a.incident_id=p_incident and a.status='ACTIVE') q order by q.uid loop
  perform 1 from public.profiles pr where pr.id=profile_id_value for share;
 end loop;
 if not private.incident_acting_member(p_org) or public.incident_context(p_incident,p_org) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into receipt_row from private.incident_operation_receipts r where r.operation_id=p_operation;
 if found then
  if receipt_row.actor_user_id<>actor_id or receipt_row.request is distinct from request_value then raise exception 'OPERATION_REUSED'; end if;
  return receipt_row.result;
 end if;
 select * into incident_row from public.incidents i where i.id=p_incident for update;
 if incident_row.status not in ('ACTIVE','STABILIZED') then raise exception 'INCIDENT_TERMINAL'; end if;
 if incident_row.version is distinct from p_expected then raise exception 'STALE_VERSION'; end if;
 global_authority:=private.has_incident_capability(p_incident,p_org,'MANAGE_COP');
 changed_revision_value:=incident_row.revision+1;
 if p_action in ('SECTOR_CREATE','SECTOR_UPDATE','SECTOR_DEACTIVATE') then
  if p_action='SECTOR_CREATE' then
   if not global_authority then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if (select count(*) from public.incident_sectors s where s.incident_id=p_incident and s.active)>=100 then raise exception 'COP_LIMIT_REACHED'; end if;
   insert into public.incident_sectors(id,incident_id,code,name,geometry,created_by,updated_by,changed_revision)
    values(entity_id,p_incident,p_payload->>'code',btrim(p_payload->>'name'),geometry_value,actor_id,actor_id,changed_revision_value) returning version into entity_version;
   event_code_value:='SECTOR_CREATED';
  else
   select * into sector_row from public.incident_sectors s where s.id=entity_id and s.incident_id=p_incident for update;
   if not found or not sector_row.active then raise exception 'INVALID_SECTOR'; end if;
   if not private.can_manage_incident_cop(p_incident,p_org,sector_row.id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if sector_row.version is distinct from expected_entity_version then raise exception 'STALE_VERSION'; end if;
   if p_action='SECTOR_DEACTIVATE' then
    if not global_authority then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
    if exists(select 1 from public.incident_role_assignments a where a.incident_id=p_incident and a.sector_id=entity_id and a.status='ACTIVE') then raise exception 'SECTOR_HAS_ACTIVE_COMMAND'; end if;
    update public.incident_sectors s set active=false,updated_by=actor_id,updated_at=clock_timestamp(),version=s.version+1,changed_revision=changed_revision_value where s.id=entity_id returning version into entity_version;
    event_code_value:='SECTOR_DEACTIVATED';
   else
    update public.incident_sectors s set name=btrim(p_payload->>'name'),geometry=geometry_value,updated_by=actor_id,updated_at=clock_timestamp(),version=s.version+1,changed_revision=changed_revision_value where s.id=entity_id returning version into entity_version;
    event_code_value:='SECTOR_UPDATED';
   end if;
  end if;
 elsif p_action in ('OBJECT_PUT','OBJECT_DEACTIVATE') then
  select * into map_object_row from public.incident_map_objects m where m.id=entity_id and m.incident_id=p_incident for update;
  if found then
   map_object_before:=to_jsonb(map_object_row);
   if not map_object_row.active then raise exception 'INVALID_MAP_OBJECT'; end if;
   if not private.can_manage_incident_cop(p_incident,p_org,map_object_row.sector_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if map_object_row.version is distinct from expected_entity_version then raise exception 'STALE_VERSION'; end if;
  elsif p_action='OBJECT_DEACTIVATE' or expected_entity_version is distinct from 0 then raise exception 'STALE_VERSION';
  end if;
  if p_action='OBJECT_PUT' then
   if not private.can_manage_incident_cop(p_incident,p_org,target_sector_id) then raise exception 'INVALID_SCOPE'; end if;
   if target_sector_id is not null and not exists(select 1 from public.incident_sectors s where s.id=target_sector_id and s.incident_id=p_incident and s.active) then raise exception 'INVALID_SECTOR'; end if;
   if map_object_row.id is null then
    if (select count(*) from public.incident_map_objects m where m.incident_id=p_incident and m.active)>=1000 then raise exception 'COP_LIMIT_REACHED'; end if;
    insert into public.incident_map_objects(id,incident_id,kind,label,description,geometry,sector_id,created_by,updated_by,changed_revision)
     values(entity_id,p_incident,p_payload->>'kind',btrim(p_payload->>'label'),coalesce(p_payload->>'description',''),geometry_value,target_sector_id,actor_id,actor_id,changed_revision_value) returning version into entity_version;
    event_code_value:='MAP_OBJECT_CREATED';
   else
    if p_payload->>'kind' is distinct from map_object_row.kind then raise exception 'INVALID_MAP_OBJECT'; end if;
    update public.incident_map_objects m set label=btrim(p_payload->>'label'),description=coalesce(p_payload->>'description',''),geometry=geometry_value,sector_id=target_sector_id,
     updated_by=actor_id,updated_at=clock_timestamp(),version=m.version+1,changed_revision=changed_revision_value where m.id=entity_id returning version into entity_version;
    event_code_value:='MAP_OBJECT_UPDATED';
   end if;
  else
   update public.incident_map_objects m set active=false,updated_by=actor_id,updated_at=clock_timestamp(),version=m.version+1,changed_revision=changed_revision_value where m.id=entity_id returning version into entity_version;
   event_code_value:='MAP_OBJECT_DEACTIVATED';
  end if;
  if p_action in ('OBJECT_PUT','OBJECT_DEACTIVATE') then
   select to_jsonb(m) into map_object_after from public.incident_map_objects m where m.id=entity_id and m.incident_id=p_incident;
  end if;
 elsif p_action in ('HYDRANT_LINK','HYDRANT_UNLINK') then
  if not global_authority then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if p_action='HYDRANT_LINK' then
   if not private.incident_hydrant_readable((p_payload->>'hydrant_id')::uuid) then raise exception 'INVALID_HYDRANT'; end if;
   if (select count(*) from public.incident_hydrant_links l where l.incident_id=p_incident and l.active)>=500 then raise exception 'COP_LIMIT_REACHED'; end if;
   insert into public.incident_hydrant_links(id,incident_id,hydrant_id,purpose,created_by,updated_by,changed_revision)
    values(entity_id,p_incident,(p_payload->>'hydrant_id')::uuid,p_payload->>'purpose',actor_id,actor_id,changed_revision_value) returning version into entity_version;
   event_code_value:='HYDRANT_LINKED';
  else
   select * into link_row from public.incident_hydrant_links l where l.id=entity_id and l.incident_id=p_incident for update;
   if not found or not link_row.active then raise exception 'INVALID_HYDRANT'; end if;
   if link_row.version is distinct from expected_entity_version then raise exception 'STALE_VERSION'; end if;
   update public.incident_hydrant_links l set active=false,updated_by=actor_id,updated_at=clock_timestamp(),version=l.version+1,changed_revision=changed_revision_value where l.id=entity_id returning version into entity_version;
   event_code_value:='HYDRANT_UNLINKED';
  end if;
 else raise exception 'VALIDATION_FAILED';
 end if;
 select coalesce(sum(q.bytes),0) into geometry_bytes from(
  select octet_length(s.geometry::text) bytes from public.incident_sectors s where s.incident_id=p_incident and s.active
  union all select octet_length(m.geometry::text) from public.incident_map_objects m where m.incident_id=p_incident and m.active) q;
 if geometry_bytes>2097152 then raise exception 'COP_LIMIT_REACHED'; end if;
 update public.incidents i set version=i.version+1 where i.id=p_incident;
 perform private.append_incident_event(p_incident,p_org,p_operation,1::smallint,event_code_value,
  jsonb_build_object('entity_id',entity_id,'entity_version',entity_version::text,'sector_id',target_sector_id,
   'geometry_changed',p_payload ? 'geometry','changed_fields',(select jsonb_agg(k) from jsonb_object_keys(p_payload) k)),null,null);
 select jsonb_build_object('incident_id',i.id,'operation_id',p_operation,'version',i.version::text,'revision',i.revision::text,'timeline_sequence',i.timeline_sequence::text,
  'entity_id',entity_id,'entity_version',entity_version::text) into result_value from public.incidents i where i.id=p_incident;
 if p_action in ('OBJECT_PUT','OBJECT_DEACTIVATE') then
  perform private.write_audit(p_org,actor_id,event_code_value,'incident_map_objects',entity_id,map_object_before,
   jsonb_build_object('incident_id',p_incident,'operation_id',p_operation,'result',result_value,'entity',map_object_after));
 else
  perform private.write_audit(p_org,actor_id,event_code_value,'incidents',p_incident,null,result_value||jsonb_build_object('geometry_changed',p_payload ? 'geometry'));
 end if;
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,actor_id,p_org,p_incident,'COP_'||p_action,request_value,result_value);
 return result_value;
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation then raise exception 'VALIDATION_FAILED';
 when unique_violation then raise exception 'DUPLICATE_COP_ENTITY';
end; $$;

revoke all on function private.incident_cop_command(text,uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
