-- Exact-org inventory; reuse M8.4 immutable audit receipts and lock namespace.
create function private.operational_inventory_manager(p_org uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select private.incident_acting_member(p_org) and private.has_organization_role(p_org,array['MANAGER','ADMIN']);
$$;
create function private.operational_inventory_command(p_kind text,p_org uuid,p_operation uuid,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=auth.uid();entity_id uuid;expected_version bigint;before_data jsonb;after_data jsonb;receipt_row public.audit_log;
 result_value jsonb;live_quantity numeric;allowed_keys text[];capability_value text;
begin
 if actor_id is null or not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_operation is null or p_org is null or jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>20000 then raise exception 'VALIDATION_FAILED'; end if;
 allowed_keys:=case when p_kind='VEHICLE' then array['id','version','callsign','name','category_code','registration','active','availability','seats','water_litres','capabilities']
when p_kind='UNIT' then array['id','version','callsign','name','unit_kind','vehicle_id','active','capabilities']
when p_kind='RESOURCE' then array['id','version','name','resource_type_code','unit_of_measure_code','total_quantity','active'] else array[]::text[] end;
 if exists(select 1 from jsonb_object_keys(p_payload) k where not(k=any(allowed_keys))) or jsonb_typeof(p_payload->'active') is distinct from 'boolean' then raise exception 'VALIDATION_FAILED'; end if;
 entity_id:=(p_payload->>'id')::uuid;expected_version:=(p_payload->>'version')::bigint;
 if entity_id is null or expected_version is null or expected_version<0 then raise exception 'VALIDATION_FAILED'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,842));
 perform private.lock_organization(p_org);perform 1 from public.organizations o where o.id=p_org for share;
 perform 1 from public.profiles pr where pr.id=actor_id for share;
 if not private.operational_inventory_manager(p_org) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into receipt_row from public.audit_log a where a.entity_type='web_administration_operations' and a.entity_id=p_operation;
 if found then
  if receipt_row.user_id<>actor_id or receipt_row.organization_id is distinct from p_org or receipt_row.new_data->>'action' is distinct from ('OPERATIONAL_'||p_kind) or receipt_row.new_data->'request' is distinct from p_payload then raise exception 'OPERATION_REUSED'; end if;
  return receipt_row.new_data->'result';
 end if;
if p_kind='VEHICLE' then
 select to_jsonb(e) into before_data from public.operational_vehicles e where e.id=entity_id and e.organization_id=p_org for update;
 if (before_data is null and expected_version<>0) or (before_data is not null and (before_data->>'version')::bigint<>expected_version) then raise exception 'STALE_VERSION'; end if;
 if exists(select 1 from public.incident_units d join public.operational_units u on u.id=d.unit_id where u.vehicle_id=entity_id and d.status not in ('RELEASED','UNAVAILABLE')) and (not(p_payload->>'active')::boolean or p_payload->>'availability' is distinct from 'AVAILABLE') then raise exception 'VEHICLE_DEPLOYED'; end if;
 if not exists(select 1 from public.operational_vehicle_categories c where c.code=p_payload->>'category_code' and (c.active or c.code=before_data->>'category_code')) then raise exception 'INVALID_VEHICLE'; end if;
 insert into public.operational_vehicles(id,organization_id,callsign,name,category_code,registration,active,availability,seats,water_litres,created_by,updated_by)
 values(entity_id,p_org,btrim(p_payload->>'callsign'),btrim(p_payload->>'name'),p_payload->>'category_code',nullif(btrim(p_payload->>'registration'),''),(p_payload->>'active')::boolean,p_payload->>'availability',(p_payload->>'seats')::integer,(p_payload->>'water_litres')::integer,actor_id,actor_id)
 on conflict(id) do update set callsign=excluded.callsign,name=excluded.name,category_code=excluded.category_code,registration=excluded.registration,active=excluded.active,availability=excluded.availability,seats=excluded.seats,water_litres=excluded.water_litres,updated_by=actor_id,updated_at=clock_timestamp(),version=public.operational_vehicles.version+1
 where public.operational_vehicles.organization_id=p_org and public.operational_vehicles.version=expected_version returning to_jsonb(operational_vehicles) into after_data;
elsif p_kind='UNIT' then
 select to_jsonb(e) into before_data from public.operational_units e where e.id=entity_id and e.organization_id=p_org for update;
 if (before_data is null and expected_version<>0) or (before_data is not null and (before_data->>'version')::bigint<>expected_version) then raise exception 'STALE_VERSION'; end if;
 if exists(select 1 from public.incident_units d where d.unit_id=entity_id and d.status not in ('RELEASED','UNAVAILABLE')) and (not(p_payload->>'active')::boolean or (p_payload->>'vehicle_id')::uuid is distinct from (before_data->>'vehicle_id')::uuid or p_payload->>'unit_kind' is distinct from before_data->>'unit_kind') then raise exception 'UNIT_ALREADY_DEPLOYED'; end if;
 if p_payload->>'vehicle_id' is not null and not exists(select 1 from public.operational_vehicles v where v.id=(p_payload->>'vehicle_id')::uuid and v.organization_id=p_org and (v.active or v.id=(before_data->>'vehicle_id')::uuid)) then raise exception 'INVALID_VEHICLE'; end if;
 insert into public.operational_units(id,organization_id,callsign,name,unit_kind,vehicle_id,active,created_by,updated_by)
 values(entity_id,p_org,btrim(p_payload->>'callsign'),btrim(p_payload->>'name'),p_payload->>'unit_kind',(p_payload->>'vehicle_id')::uuid,(p_payload->>'active')::boolean,actor_id,actor_id)
 on conflict(id) do update set callsign=excluded.callsign,name=excluded.name,unit_kind=excluded.unit_kind,vehicle_id=excluded.vehicle_id,active=excluded.active,updated_by=actor_id,updated_at=clock_timestamp(),version=public.operational_units.version+1
 where public.operational_units.organization_id=p_org and public.operational_units.version=expected_version returning to_jsonb(operational_units) into after_data;
elsif p_kind='RESOURCE' then
 select to_jsonb(e) into before_data from public.operational_resources e where e.id=entity_id and e.organization_id=p_org for update;
 if (before_data is null and expected_version<>0) or (before_data is not null and (before_data->>'version')::bigint<>expected_version) then raise exception 'STALE_VERSION'; end if;
 select coalesce(sum(a.quantity),0) into live_quantity from public.incident_resource_allocations a where a.resource_id=entity_id and a.status in ('RESERVED','DEPLOYED');
 if live_quantity>0 and (not(p_payload->>'active')::boolean or p_payload->>'unit_of_measure_code' is distinct from before_data->>'unit_of_measure_code' or p_payload->>'resource_type_code' is distinct from before_data->>'resource_type_code') then raise exception 'RESOURCE_IN_USE'; end if;
 if (p_payload->>'total_quantity')::numeric<live_quantity then raise exception 'INSUFFICIENT_RESOURCE_QUANTITY'; end if;
 if not exists(select 1 from public.operational_resource_types c where c.code=p_payload->>'resource_type_code' and (c.active or c.code=before_data->>'resource_type_code')) or not exists(select 1 from public.operational_units_of_measure c where c.code=p_payload->>'unit_of_measure_code' and (c.active or c.code=before_data->>'unit_of_measure_code')) then raise exception 'INVALID_RESOURCE'; end if;
 insert into public.operational_resources(id,organization_id,name,resource_type_code,unit_of_measure_code,total_quantity,active,created_by,updated_by)
 values(entity_id,p_org,btrim(p_payload->>'name'),p_payload->>'resource_type_code',p_payload->>'unit_of_measure_code',(p_payload->>'total_quantity')::numeric,(p_payload->>'active')::boolean,actor_id,actor_id)
 on conflict(id) do update set name=excluded.name,resource_type_code=excluded.resource_type_code,unit_of_measure_code=excluded.unit_of_measure_code,total_quantity=excluded.total_quantity,active=excluded.active,updated_by=actor_id,updated_at=clock_timestamp(),version=public.operational_resources.version+1
 where public.operational_resources.organization_id=p_org and public.operational_resources.version=expected_version returning to_jsonb(operational_resources) into after_data;
else raise exception 'VALIDATION_FAILED'; end if;
 if after_data is null then raise exception 'STALE_VERSION'; end if;
if p_kind='VEHICLE' then
 if jsonb_typeof(p_payload->'capabilities') is distinct from 'array' then raise exception 'VALIDATION_FAILED'; end if;
 if jsonb_array_length(p_payload->'capabilities')>50 then raise exception 'VALIDATION_FAILED'; end if;
 before_data:=coalesce(before_data,'{}')||jsonb_build_object('capabilities',coalesce((select jsonb_agg(c.capability_code order by c.capability_code) from public.operational_vehicle_capabilities c where c.vehicle_id=entity_id and c.active),'[]'));
 for capability_value in select jsonb_array_elements_text(p_payload->'capabilities') loop
  if not exists(select 1 from public.operational_capabilities c where c.code=capability_value and (c.active or exists(select 1 from public.operational_vehicle_capabilities old_cap where old_cap.vehicle_id=entity_id and old_cap.capability_code=c.code and old_cap.active))) then raise exception 'VALIDATION_FAILED'; end if;
 end loop;
 update public.operational_vehicle_capabilities c set active=false where c.vehicle_id=entity_id;
 insert into public.operational_vehicle_capabilities(vehicle_id,capability_code) select distinct entity_id,jsonb_array_elements_text(p_payload->'capabilities') on conflict(vehicle_id,capability_code) do update set active=true;
 after_data:=after_data||jsonb_build_object('capabilities',p_payload->'capabilities');
end if;
if p_kind='UNIT' then
 if jsonb_typeof(p_payload->'capabilities') is distinct from 'array' then raise exception 'VALIDATION_FAILED'; end if;
 if jsonb_array_length(p_payload->'capabilities')>50 then raise exception 'VALIDATION_FAILED'; end if;
 before_data:=coalesce(before_data,'{}')||jsonb_build_object('capabilities',coalesce((select jsonb_agg(c.capability_code order by c.capability_code) from public.operational_unit_capabilities c where c.unit_id=entity_id and c.active),'[]'));
 for capability_value in select jsonb_array_elements_text(p_payload->'capabilities') loop
  if not exists(select 1 from public.operational_capabilities c where c.code=capability_value and (c.active or exists(select 1 from public.operational_unit_capabilities old_cap where old_cap.unit_id=entity_id and old_cap.capability_code=c.code and old_cap.active))) then raise exception 'VALIDATION_FAILED'; end if;
 end loop;
 update public.operational_unit_capabilities c set active=false where c.unit_id=entity_id;
 insert into public.operational_unit_capabilities(unit_id,capability_code) select distinct entity_id,jsonb_array_elements_text(p_payload->'capabilities') on conflict(unit_id,capability_code) do update set active=true;
 after_data:=after_data||jsonb_build_object('capabilities',p_payload->'capabilities');
end if;
 result_value:=jsonb_build_object('id',entity_id,'version',after_data->>'version');
 perform private.write_audit(p_org,actor_id,'OPERATIONAL_'||p_kind,'web_administration_operations',p_operation,before_data,jsonb_build_object('action','OPERATIONAL_'||p_kind,'request',p_payload,'result',result_value,'entity',after_data));
 return result_value;
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation then raise exception 'VALIDATION_FAILED';
 when unique_violation then raise exception 'DUPLICATE_INVENTORY';
end; $$;
revoke all on function private.operational_inventory_manager(uuid),private.operational_inventory_command(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
create function public.operational_vehicle_upsert(p_organization_id uuid,p_operation uuid,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.operational_inventory_command('VEHICLE',p_organization_id,p_operation,p_payload); $$;
revoke all on function public.operational_vehicle_upsert(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.operational_vehicle_upsert(uuid,uuid,jsonb) to authenticated;
create function public.operational_unit_upsert(p_organization_id uuid,p_operation uuid,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.operational_inventory_command('UNIT',p_organization_id,p_operation,p_payload); $$;
revoke all on function public.operational_unit_upsert(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.operational_unit_upsert(uuid,uuid,jsonb) to authenticated;
create function public.operational_resource_upsert(p_organization_id uuid,p_operation uuid,p_payload jsonb) returns jsonb
language sql security definer set search_path='' as $$ select private.operational_inventory_command('RESOURCE',p_organization_id,p_operation,p_payload); $$;
revoke all on function public.operational_resource_upsert(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.operational_resource_upsert(uuid,uuid,jsonb) to authenticated;
create function public.operational_inventory(p_organization_id uuid,p_kind text,p_query text default '',p_page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows_value jsonb;
begin
 if not private.operational_inventory_manager(p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_kind is null or p_kind not in ('VEHICLE','UNIT','RESOURCE') or p_query is null or length(p_query)>100 or p_page is null or p_page not between 0 and 100000 then raise exception 'VALIDATION_FAILED'; end if;
if p_kind='VEHICLE' then
 select coalesce(jsonb_agg(q.dto order by q.name,q.id),'[]') into rows_value from (
 select e.name,e.id,to_jsonb(e)||jsonb_build_object('version',e.version::text,'capabilities',coalesce((select jsonb_agg(c.capability_code order by c.capability_code) from public.operational_vehicle_capabilities c where c.vehicle_id=e.id and c.active),'[]')) dto
 from public.operational_vehicles e where e.organization_id=p_organization_id and position(lower(p_query) in lower(e.name||' '||e.callsign))>0 order by e.name,e.id limit 51 offset p_page*50) q;
elsif p_kind='UNIT' then
 select coalesce(jsonb_agg(q.dto order by q.name,q.id),'[]') into rows_value from (
 select e.name,e.id,to_jsonb(e)||jsonb_build_object('version',e.version::text,'capabilities',coalesce((select jsonb_agg(c.capability_code order by c.capability_code) from public.operational_unit_capabilities c where c.unit_id=e.id and c.active),'[]')) dto
 from public.operational_units e where e.organization_id=p_organization_id and position(lower(p_query) in lower(e.name||' '||e.callsign))>0 order by e.name,e.id limit 51 offset p_page*50) q;
elsif p_kind='RESOURCE' then
 select coalesce(jsonb_agg(q.dto order by q.name,q.id),'[]') into rows_value from (
 select e.name,e.id,to_jsonb(e)||jsonb_build_object('version',e.version::text,'total_quantity',e.total_quantity::text,'allocated_quantity',(select coalesce(sum(a.quantity),0)::text from public.incident_resource_allocations a where a.resource_id=e.id and a.status in ('RESERVED','DEPLOYED'))) dto
 from public.operational_resources e where e.organization_id=p_organization_id and position(lower(p_query) in lower(e.name))>0 order by e.name,e.id limit 51 offset p_page*50) q;
end if;
 return jsonb_build_object('rows',case when jsonb_array_length(rows_value)>50 then rows_value-50 else rows_value end,'more',jsonb_array_length(rows_value)>50,'configuration',jsonb_build_object(
'operational_vehicle_categories',coalesce((select jsonb_agg(to_jsonb(c) order by c.code) from public.operational_vehicle_categories c),'[]'),
'operational_capabilities',coalesce((select jsonb_agg(to_jsonb(c) order by c.code) from public.operational_capabilities c),'[]'),
'operational_resource_types',coalesce((select jsonb_agg(to_jsonb(c) order by c.code) from public.operational_resource_types c),'[]'),
'operational_units_of_measure',coalesce((select jsonb_agg(to_jsonb(c) order by c.code) from public.operational_units_of_measure c),'[]')));
end; $$;
revoke all on function public.operational_inventory(uuid,text,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_inventory(uuid,text,text,integer) to authenticated;
create function public.operational_inventory_item(p_organization_id uuid,p_kind text,p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result_value jsonb;
begin
 if not private.operational_inventory_manager(p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
if p_kind='VEHICLE' then
 select to_jsonb(e)||jsonb_build_object('version',e.version::text,'capabilities',coalesce((select jsonb_agg(c.capability_code order by c.capability_code) from public.operational_vehicle_capabilities c where c.vehicle_id=e.id and c.active),'[]')) into result_value from public.operational_vehicles e where e.id=p_id and e.organization_id=p_organization_id;
elsif p_kind='UNIT' then
 select to_jsonb(e)||jsonb_build_object('version',e.version::text,'capabilities',coalesce((select jsonb_agg(c.capability_code order by c.capability_code) from public.operational_unit_capabilities c where c.unit_id=e.id and c.active),'[]')) into result_value from public.operational_units e where e.id=p_id and e.organization_id=p_organization_id;
elsif p_kind='RESOURCE' then
 select to_jsonb(e)||jsonb_build_object('version',e.version::text,'total_quantity',e.total_quantity::text) into result_value from public.operational_resources e where e.id=p_id and e.organization_id=p_organization_id;
else raise exception 'VALIDATION_FAILED'; end if;
 if result_value is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;return result_value;
end; $$;
revoke all on function public.operational_inventory_item(uuid,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.operational_inventory_item(uuid,text,uuid) to authenticated;
