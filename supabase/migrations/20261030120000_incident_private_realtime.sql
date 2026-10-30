-- Optional metadata-only transport. Canonical commands and B1 remain authority.
create function private.incident_realtime_read(p_topic text) returns boolean
language plpgsql stable security definer set search_path='' as $read_topic$
declare v_parts text[];v_incident uuid;v_org uuid;
begin
 if auth.uid() is null or not private.is_active_user() or p_topic is null or length(p_topic)<>86 then return false;end if;
 v_parts:=regexp_match(p_topic,'^incident:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):org:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$');
 if v_parts is null then return false;end if;
 v_incident:=v_parts[1]::uuid;v_org:=v_parts[2]::uuid;
 if not private.incident_acting_member(v_org) then return false;end if;
 return coalesce(
 (private.can_read_incident(v_incident) and
 (private.incident_draft_manager(v_incident,v_org) or exists(
 select 1 from public.incidents i join public.incident_participants ip on ip.incident_id=i.id
 where i.id=v_incident and i.status<>'DRAFT' and ip.organization_id=v_org
 and (ip.status='ACTIVE' or (i.status in ('CLOSED','CANCELLED') and ip.status='RELEASED')))))
 or exists(select 1 from public.incident_units u where u.incident_id=v_incident
 and private.field_unit_visible(auth.uid(),v_org,u.id)),false);
end;
$read_topic$;
revoke all on function private.incident_realtime_read(text) from public,anon,authenticated,service_role;
grant execute on function private.incident_realtime_read(text) to authenticated;
create policy incident_private_receive on realtime.messages for select to authenticated
 using(extension='broadcast' and private.incident_realtime_read((select realtime.topic())));
-- Restrictive guards prevent pre-existing permissive policies from opening this namespace.
create policy incident_private_read_guard on realtime.messages as restrictive for select to authenticated
 using(coalesce((select realtime.topic()),topic,'') not like 'incident:%'
 or (extension='broadcast' and private.incident_realtime_read((select realtime.topic()))));
create policy incident_private_no_client_send on realtime.messages as restrictive for insert to authenticated
 with check(coalesce((select realtime.topic()),'') not like 'incident:%' and coalesce(topic,'') not like 'incident:%');

create policy incident_private_anon_read_guard on realtime.messages as restrictive for select to anon
 using(coalesce((select realtime.topic()),topic,'') not like 'incident:%');
create policy incident_private_anon_send_guard on realtime.messages as restrictive for insert to anon
 with check(coalesce((select realtime.topic()),'') not like 'incident:%' and coalesce(topic,'') not like 'incident:%');

create function private.incident_realtime_emit() returns trigger
language plpgsql security definer set search_path='' set lock_timeout='100ms' as $emit_hint$
declare v_i record;v_org record;v_payload jsonb;v_count integer:=0;
begin
 -- Deferred: both counters identify the final aggregate state. With canonical
 -- monotonic counters only the last advancing update can match; revision-only
 -- writes are covered without a second producer or transaction marker.
 select i.id,i.revision,i.timeline_sequence,i.status,i.created_organization_id into v_i
 from public.incidents i where i.id=new.id;
 if not found or v_i.revision<>new.revision
 or v_i.timeline_sequence<>new.timeline_sequence then return new;end if;
 v_payload:=jsonb_build_object('incident_id',v_i.id,'revision',v_i.revision::text,'timeline_sequence',v_i.timeline_sequence::text);
 if octet_length(v_payload::text)>512 then return new;end if;
 for v_org in select o.id from public.organizations o where o.active and (
 (v_i.status='DRAFT' and o.id=v_i.created_organization_id) or exists(
 select 1 from public.incident_participants ip where ip.incident_id=v_i.id and ip.organization_id=o.id
 and (ip.status='ACTIVE' or (v_i.status in ('CLOSED','CANCELLED') and ip.status='RELEASED'))))
 order by o.id limit 50 loop
  perform realtime.send(v_payload,'incident_changed','incident:'||v_i.id::text||':org:'||v_org.id::text,true);
  v_count:=v_count+1;
 end loop;
 return new;
exception when query_canceled then
 return new;
when others then
 -- Optional transport failure rolls back this trigger's broadcast inserts only.
 -- No payload/error detail is logged; polling/FCM recover lost hints.
 raise warning 'Optional incident hint unavailable';
 return new;
end;
$emit_hint$;
revoke all on function private.incident_realtime_emit() from public,anon,authenticated,service_role;
create constraint trigger incident_private_hint after update on public.incidents
 deferrable initially deferred for each row when(new.revision>old.revision or new.timeline_sequence>old.timeline_sequence)
 execute function private.incident_realtime_emit();
