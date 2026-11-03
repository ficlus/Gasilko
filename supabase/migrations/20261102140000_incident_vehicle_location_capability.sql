-- M14.8C2 permitted safe subset. No GPS producer, observation store or enable switch.
-- Policy, physical-retention maintenance and authenticated device binding are NOT approved.
-- Future activation requires a separately reviewed forward migration and compatible clients.
create function public.incident_vehicle_location_capabilities(
 p_acting_organization_id uuid,p_incident_id uuid
) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $vehicle_capability$
declare v_head jsonb;v_mode text;
begin
 if p_acting_organization_id is null or p_incident_id is null then
  raise exception 'VALIDATION_FAILED' using errcode='P0001';
 end if;
 -- Reuse the exact current B1 Web head authorization and organization/actor/incident
 -- locks. This returns a watermark, not commander context or field/map geometry.
 v_head:=public.incident_sync_head(p_acting_organization_id,p_incident_id);
 if v_head is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 -- Scenario membership is authoritative even if SIM writes are disabled.
 v_mode:=case when exists(select 1 from public.simulation_scenarios s where s.incident_id=p_incident_id)
  then 'TRAINING' else 'REAL' end;
 return jsonb_build_object(
  'schema_version',1,'account',auth.uid(),'organization',p_acting_organization_id,'incident_id',p_incident_id,
  'scope_fingerprint',v_head->>'scope_fingerprint','mode',v_mode,'state','DISABLED',
  'enabled',false,'producer_available',false,'reader_available',false,
  'policy_approved',false,'retention_ready',false,'device_binding_ready',false);
 -- No START/SAMPLE/STOP RPC, receipt, audit/event, unit eligibility or precise data.
 -- Unit-name visibility MUST NOT become a location-sharing or precise-reader grant.
end;
$vehicle_capability$;
alter function public.incident_vehicle_location_capabilities(uuid,uuid) owner to postgres;
revoke all on function public.incident_vehicle_location_capabilities(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.incident_vehicle_location_capabilities(uuid,uuid) to authenticated;
