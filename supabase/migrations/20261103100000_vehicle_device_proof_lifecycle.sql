-- M15A.3: inaccessible inactive security primitives; NOT GPS enrollment.
-- No public wrapper, policy approval, credential writer, ISSUE or FINALIZE.
begin;

create table private.vehicle_device_credentials (
 credential_id uuid primary key check(credential_id<>'00000000-0000-0000-0000-000000000000'::uuid),
 actor_user_id uuid not null references public.profiles(id),
 acting_organization_id uuid not null references public.organizations(id),
 incident_id uuid not null references public.incidents(id),
 deployment_id uuid not null,
 vehicle_id uuid not null,
 authority_episode_id uuid not null,
 protocol_version integer not null check(protocol_version=1),
 public_key_spki_der bytea not null check(octet_length(public_key_spki_der)=91
  and substring(public_key_spki_der from 1 for 27)=decode('3059301306072a8648ce3d020106082a8648ce3d03010703420004','hex')),
 public_key_sha256 text not null unique check(public_key_sha256=encode(sha256(public_key_spki_der),'hex')),
 generation bigint not null check(generation>0),
 lifecycle_status text not null default 'INACTIVE' check(lifecycle_status in ('INACTIVE','REVOKED')),
 created_at timestamptz not null default clock_timestamp(),
 revoked_at timestamptz,
 revoked_reason text check(revoked_reason in ('OWNER_REQUEST','KEY_LOST','SUPERSEDED','AUTHORITY_LOST')),
 foreign key(deployment_id,incident_id,acting_organization_id)
  references public.incident_units(id,incident_id,organization_id),
 foreign key(vehicle_id,acting_organization_id) references public.operational_vehicles(id,organization_id),
 foreign key(authority_episode_id,incident_id) references public.incident_crew_members(id,incident_id),
 unique(actor_user_id,acting_organization_id,incident_id,deployment_id,authority_episode_id,generation),
 check((lifecycle_status='INACTIVE' and revoked_at is null and revoked_reason is null)
  or (lifecycle_status='REVOKED' and revoked_at is not null and revoked_reason is not null))
);
create index vehicle_device_credentials_scope on private.vehicle_device_credentials
 (actor_user_id,acting_organization_id,incident_id,credential_id);

create table private.vehicle_device_challenges (
 challenge_id uuid primary key check(challenge_id<>'00000000-0000-0000-0000-000000000000'::uuid),
 credential_id uuid not null references private.vehicle_device_credentials(credential_id),
 actor_user_id uuid not null references public.profiles(id),
 acting_organization_id uuid not null references public.organizations(id),
 incident_id uuid not null references public.incidents(id),
 deployment_id uuid not null,
 vehicle_id uuid not null,
 authority_episode_id uuid not null,
 issue_operation_id uuid not null unique check(issue_operation_id<>'00000000-0000-0000-0000-000000000000'::uuid),
 confirm_operation_id uuid not null unique check(confirm_operation_id<>issue_operation_id and confirm_operation_id<>'00000000-0000-0000-0000-000000000000'::uuid),
 nonce bytea not null unique check(octet_length(nonce)=32),
 issued_at timestamptz not null check(issued_at=date_trunc('second',issued_at)),
 expires_at timestamptz not null check(expires_at=issued_at+interval '120 seconds'),
 transcript_sha256 text not null check(transcript_sha256 ~ '^[0-9a-f]{64}$'),
 immutable_request jsonb not null check(jsonb_typeof(immutable_request)='object' and octet_length(immutable_request::text)<=8192),
 immutable_request_sha256 text not null check(immutable_request_sha256=encode(sha256(convert_to(immutable_request::text,'UTF8')),'hex')),
 expected_incident_version bigint not null check(expected_incident_version>0),
 expected_deployment_version bigint not null check(expected_deployment_version>0),
 expected_vehicle_version bigint not null check(expected_vehicle_version>0),
 reserved_generation bigint not null check(reserved_generation>0),
 recovery_epoch uuid not null check(recovery_epoch<>'00000000-0000-0000-0000-000000000000'::uuid),
 policy_version text not null check(policy_version ~ '^[A-Za-z0-9._-]{1,64}$'),
 policy_document_sha256 text not null check(policy_document_sha256 ~ '^[0-9a-f]{64}$'),
 precise_audience_sha256 text not null check(precise_audience_sha256 ~ '^[0-9a-f]{64}$'),
 audience text not null check(audience ~ '^[A-Za-z0-9._:/-]{1,128}$'),
 state text not null default 'ISSUED' check(state in ('ISSUED','CLAIMED','VERIFIED_INACTIVE','REJECTED','EXPIRED','REVOKED')),
 claim_id uuid,
 claim_expires_at timestamptz,
 signature_sha256 text check(signature_sha256 ~ '^[0-9a-f]{64}$'),
 consumed_at timestamptz,
 created_at timestamptz not null default clock_timestamp(),
 foreign key(deployment_id,incident_id,acting_organization_id)
  references public.incident_units(id,incident_id,organization_id),
 foreign key(vehicle_id,acting_organization_id) references public.operational_vehicles(id,organization_id),
 foreign key(authority_episode_id,incident_id) references public.incident_crew_members(id,incident_id),
 check((claim_id is null)=(claim_expires_at is null)),
 check((claim_id is null)=(signature_sha256 is null)),
 check(claim_expires_at<=expires_at and claim_expires_at>issued_at),
 check(state<>'ISSUED' or claim_id is null),
 check(state<>'CLAIMED' or claim_id is not null),
 check((state in ('VERIFIED_INACTIVE','REJECTED','EXPIRED','REVOKED'))=(consumed_at is not null))
);
create index vehicle_device_challenges_credential on private.vehicle_device_challenges(credential_id,state,expires_at);
create index vehicle_device_challenges_owner on private.vehicle_device_challenges(actor_user_id,acting_organization_id,incident_id);

alter table private.vehicle_device_credentials owner to postgres;
alter table private.vehicle_device_challenges owner to postgres;
alter table private.vehicle_device_credentials enable row level security;
alter table private.vehicle_device_challenges enable row level security;
revoke all on private.vehicle_device_credentials,private.vehicle_device_challenges from public,anon,authenticated,service_role;
-- No RLS policies: no application access. private remains outside PostgREST.

-- Current driver episode, not an invented recovery epoch or UNIT_LEADER fallback.
-- Existing org mutex + profile/incident share locks serialize canonical authority writes.
create function private.vehicle_device_driver_scope(p_org uuid,p_incident uuid,p_deployment uuid,p_vehicle uuid) returns jsonb
language plpgsql security definer set search_path='' as $driver$
declare v_scope jsonb;
begin
 perform private.incident_sync_lock(p_org,p_incident);
 if not private.can_read_incident(p_incident) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select jsonb_build_object(
  'scope',jsonb_build_object('account',auth.uid(),'organization',p_org,'incident',i.id,
   'deployment',d.id,'vehicle',v.id,'authorityEpisode',c.id),
  'incidentVersion',i.version::text,'deploymentVersion',d.version::text,'vehicleVersion',v.version::text)
 into v_scope
 from public.incidents i
 join public.incident_participants ip on ip.incident_id=i.id and ip.organization_id=p_org and ip.status='ACTIVE'
 join public.incident_units d on d.incident_id=i.id and d.participation_id=ip.id and d.organization_id=p_org
 join public.operational_units u on u.id=d.unit_id and u.organization_id=p_org and u.active
 join public.operational_vehicles v on v.id=u.vehicle_id and v.organization_id=p_org and v.active and v.availability='AVAILABLE'
 join public.incident_crew_members c on c.incident_id=i.id and c.unit_assignment_id=d.id
  and c.membership_organization_id=p_org and c.user_id=auth.uid() and c.crew_role='DRIVER' and c.status='ACTIVE'
 where i.id=p_incident and i.status='ACTIVE' and d.id=p_deployment and v.id=p_vehicle
  and d.status not in ('RELEASED','UNAVAILABLE')
  and not exists(select 1 from public.simulation_scenarios s where s.incident_id=i.id);
 if v_scope is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return v_scope;
end;
$driver$;

create function private.guard_vehicle_device_credential() returns trigger
language plpgsql security definer set search_path='' as $credential$
declare v_scope jsonb;v_last bigint;
begin
 if tg_op='INSERT' then
  v_scope:=private.vehicle_device_driver_scope(new.acting_organization_id,new.incident_id,new.deployment_id,new.vehicle_id);
  if new.actor_user_id is distinct from auth.uid() or (v_scope#>>'{scope,authorityEpisode}')::uuid is distinct from new.authority_episode_id
   or new.lifecycle_status<>'INACTIVE' then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  select coalesce(max(c.generation),0) into v_last from private.vehicle_device_credentials c
   where c.actor_user_id=new.actor_user_id and c.acting_organization_id=new.acting_organization_id
   and c.incident_id=new.incident_id and c.deployment_id=new.deployment_id and c.authority_episode_id=new.authority_episode_id;
  if new.generation::numeric<>v_last::numeric+1 or v_last>=8 or exists(
   select 1 from private.vehicle_device_credentials c where c.actor_user_id=new.actor_user_id
    and c.acting_organization_id=new.acting_organization_id and c.incident_id=new.incident_id
    and c.deployment_id=new.deployment_id and c.authority_episode_id=new.authority_episode_id and c.lifecycle_status='INACTIVE')
   then raise exception 'CREDENTIAL_GENERATION_CHANGED'; end if;
 else
  perform private.incident_sync_lock(old.acting_organization_id,old.incident_id);
  if auth.uid() is distinct from old.actor_user_id then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if (to_jsonb(new)-array['lifecycle_status','revoked_at','revoked_reason'])
   is distinct from (to_jsonb(old)-array['lifecycle_status','revoked_at','revoked_reason'])
   or old.lifecycle_status<>'INACTIVE' or new.lifecycle_status<>'REVOKED'
   then raise exception 'CREDENTIAL_IMMUTABLE'; end if;
 end if;
 return new;
end;
$credential$;
create trigger vehicle_device_credential_guard before insert or update on private.vehicle_device_credentials
 for each row execute function private.guard_vehicle_device_credential();

create function private.guard_vehicle_device_challenge() returns trigger
language plpgsql security definer set search_path='' as $challenge$
declare v_key private.vehicle_device_credentials;v_scope jsonb;v_operation uuid;
begin
 if new.state='VERIFIED_INACTIVE' then raise exception 'VERIFIER_UNAVAILABLE'; end if;
 if tg_op='INSERT' then
  -- Same operation advisory namespace as canonical commands, before org/row locks.
  for v_operation in select x.id from unnest(array[new.issue_operation_id,new.confirm_operation_id]) x(id) order by x.id loop
   perform pg_advisory_xact_lock(hashtextextended(v_operation::text,141));
  end loop;
  v_scope:=private.vehicle_device_driver_scope(new.acting_organization_id,new.incident_id,new.deployment_id,new.vehicle_id);
  select * into v_key from private.vehicle_device_credentials c where c.credential_id=new.credential_id for update;
  if not found or v_key.lifecycle_status<>'INACTIVE' or new.actor_user_id is distinct from auth.uid()
   or (new.actor_user_id,new.acting_organization_id,new.incident_id,new.deployment_id,new.vehicle_id,new.authority_episode_id,new.reserved_generation)
    is distinct from (v_key.actor_user_id,v_key.acting_organization_id,v_key.incident_id,v_key.deployment_id,v_key.vehicle_id,v_key.authority_episode_id,v_key.generation)
   or (v_scope#>>'{scope,authorityEpisode}')::uuid is distinct from new.authority_episode_id
   then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if new.expected_incident_version::text is distinct from v_scope->>'incidentVersion'
   or new.expected_deployment_version::text is distinct from v_scope->>'deploymentVersion'
   or new.expected_vehicle_version::text is distinct from v_scope->>'vehicleVersion'
   then raise exception 'STALE_VERSION'; end if;
  if exists(select 1 from private.vehicle_device_challenges c where c.issue_operation_id in (new.issue_operation_id,new.confirm_operation_id)
    or c.confirm_operation_id in (new.issue_operation_id,new.confirm_operation_id))
   or exists(select 1 from private.incident_operation_receipts r where r.operation_id in (new.issue_operation_id,new.confirm_operation_id))
   then raise exception 'OPERATION_REUSED'; end if;
  if new.state<>'ISSUED' or new.claim_id is not null or new.consumed_at is not null
   or new.issued_at>clock_timestamp() or new.expires_at<=clock_timestamp()
   then raise exception 'CHALLENGE_EXPIRED'; end if;
  if (select count(*) from private.vehicle_device_challenges c where c.credential_id=new.credential_id)>=32
   then raise exception 'RESOURCE_LIMIT_REACHED'; end if;
 else
  if (to_jsonb(new)-array['state','claim_id','claim_expires_at','signature_sha256','consumed_at'])
   is distinct from (to_jsonb(old)-array['state','claim_id','claim_expires_at','signature_sha256','consumed_at'])
   or old.state not in ('ISSUED','CLAIMED') then raise exception 'CHALLENGE_IMMUTABLE'; end if;
  -- No verifier-to-finalizer privilege boundary exists yet. Even owner-facing
  -- ordinary updates cannot record successful verification via this trigger.
  if new.state not in ('CLAIMED','REJECTED','EXPIRED','REVOKED')
   or (old.signature_sha256 is not null and new.signature_sha256 is distinct from old.signature_sha256)
   then raise exception 'OPERATION_REUSED'; end if;
  if old.state='CLAIMED' and new.state='CLAIMED' and old.claim_expires_at>clock_timestamp()
   and (new.claim_id,new.claim_expires_at) is distinct from (old.claim_id,old.claim_expires_at)
   then raise exception 'CHALLENGE_CLAIMED'; end if;
  if new.state in ('REJECTED','EXPIRED','REVOKED') and
   (new.claim_id,new.claim_expires_at,new.signature_sha256) is distinct from (old.claim_id,old.claim_expires_at,old.signature_sha256)
   then raise exception 'CHALLENGE_IMMUTABLE'; end if;
  if new.state='CLAIMED' and (new.claim_id is null or new.claim_expires_at>least(new.expires_at,clock_timestamp()+interval '30 seconds')
   or new.claim_expires_at<=clock_timestamp()) then raise exception 'CLAIM_EXPIRED'; end if;
 end if;
 return new;
end;
$challenge$;
create trigger vehicle_device_challenge_guard before insert or update on private.vehicle_device_challenges
 for each row execute function private.guard_vehicle_device_challenge();

-- TX-A only. This is NOT a public RPC; no application/service EXECUTE grant.
-- Full immutable confirmation identity = fixed operation IDs + transcript hash +
-- raw64 signature hash. Raw signatures are not stored or used as operation IDs.
create function private.claim_vehicle_device_proof(
 p_org uuid,p_incident uuid,p_challenge uuid,p_confirm_operation uuid,p_signature_sha256 text
) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $claim$
declare v_key_id uuid;v_key private.vehicle_device_credentials;v_row private.vehicle_device_challenges;
 v_scope jsonb;v_challenge jsonb;v_context jsonb;v_now timestamptz;v_claim uuid;
begin
 if auth.uid() is null or p_confirm_operation is null or p_signature_sha256 is null
  or p_signature_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'VALIDATION_FAILED'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_confirm_operation::text,141));
 v_scope:=private.vehicle_device_driver_scope(p_org,p_incident,
  (select c.deployment_id from private.vehicle_device_challenges c where c.challenge_id=p_challenge and c.actor_user_id=auth.uid() and c.acting_organization_id=p_org and c.incident_id=p_incident),
  (select c.vehicle_id from private.vehicle_device_challenges c where c.challenge_id=p_challenge and c.actor_user_id=auth.uid() and c.acting_organization_id=p_org and c.incident_id=p_incident));
 select c.credential_id into v_key_id from private.vehicle_device_challenges c
  where c.challenge_id=p_challenge and c.actor_user_id=auth.uid() and c.acting_organization_id=p_org and c.incident_id=p_incident;
 select * into v_key from private.vehicle_device_credentials c where c.credential_id=v_key_id for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into v_row from private.vehicle_device_challenges c where c.challenge_id=p_challenge for update;
 if v_row.confirm_operation_id is distinct from p_confirm_operation
  or (v_row.signature_sha256 is not null and v_row.signature_sha256<>p_signature_sha256)
  or exists(select 1 from private.incident_operation_receipts r where r.operation_id=p_confirm_operation)
  then raise exception 'OPERATION_REUSED'; end if;
 if v_key.lifecycle_status<>'INACTIVE' or v_row.state='REVOKED' then raise exception 'CREDENTIAL_REVOKED'; end if;
 if v_row.reserved_generation<>v_key.generation then raise exception 'CREDENTIAL_GENERATION_CHANGED'; end if;
 if (v_scope#>>'{scope,authorityEpisode}')::uuid is distinct from v_row.authority_episode_id then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if v_scope->>'incidentVersion' is distinct from v_row.expected_incident_version::text
  or v_scope->>'deploymentVersion' is distinct from v_row.expected_deployment_version::text
  or v_scope->>'vehicleVersion' is distinct from v_row.expected_vehicle_version::text then raise exception 'STALE_VERSION'; end if;
 v_now:=clock_timestamp();
 if v_now<v_row.issued_at or v_now>=v_row.expires_at then raise exception 'CHALLENGE_EXPIRED'; end if;
 if v_row.state not in ('ISSUED','CLAIMED') then raise exception 'CHALLENGE_CONSUMED'; end if;
 -- Same request while lease valid recovers its same token. Expired lease recovery
 -- gets a new token; the old worker may not finalize. No success receipt at CLAIM.
 if v_row.state='ISSUED' or v_row.claim_expires_at<=v_now then
  v_claim:=gen_random_uuid();
  update private.vehicle_device_challenges c set state='CLAIMED',claim_id=v_claim,
   claim_expires_at=least(v_row.expires_at,date_trunc('second',v_now)+interval '30 seconds'),signature_sha256=p_signature_sha256
   where c.challenge_id=v_row.challenge_id returning * into v_row;
 end if;
 v_challenge:=jsonb_build_object('protocolVersion',1,'audience',v_row.audience,'recoveryEpoch',v_row.recovery_epoch,
  'scope',v_scope->'scope','credentialId',v_key.credential_id,'publicKeySha256',v_key.public_key_sha256,
  'policyVersion',v_row.policy_version,'policyDocumentSha256',v_row.policy_document_sha256,'preciseAudienceSha256',v_row.precise_audience_sha256,
  'issueOperationId',v_row.issue_operation_id,'confirmOperationId',v_row.confirm_operation_id,'challengeId',v_row.challenge_id,
  'nonceBase64Url',rtrim(translate(encode(v_row.nonce,'base64'),'+/','-_'),'='),
  'issuedAtSeconds',extract(epoch from v_row.issued_at)::bigint::text,'expiresAtSeconds',extract(epoch from v_row.expires_at)::bigint::text,
  'expectedIncidentVersion',v_row.expected_incident_version::text,'expectedDeploymentVersion',v_row.expected_deployment_version::text,
  'expectedVehicleVersion',v_row.expected_vehicle_version::text,'reservedGeneration',v_row.reserved_generation::text);
 v_context:=jsonb_build_object('account',auth.uid(),'organization',p_org,'scope',v_scope->'scope',
  'audience',v_row.audience,'recoveryEpoch',v_row.recovery_epoch,'policyVersion',v_row.policy_version,
  'policyDocumentSha256',v_row.policy_document_sha256,'preciseAudienceSha256',v_row.precise_audience_sha256,
  'incidentVersion',v_scope->>'incidentVersion','deploymentVersion',v_scope->>'deploymentVersion',
  'vehicleVersion',v_scope->>'vehicleVersion','generation',v_key.generation::text,
  'serverNowSeconds',floor(extract(epoch from v_now))::bigint::text);
 return jsonb_build_object('state','CLAIMED','claimId',v_row.claim_id,
  'claimExpiresAtSeconds',extract(epoch from v_row.claim_expires_at)::bigint::text,
  'transcriptSha256',v_row.transcript_sha256,'signatureSha256',v_row.signature_sha256,
  'challenge',v_challenge,'context',v_context,'credential',jsonb_build_object('protocolVersion',1,
   'credentialId',v_key.credential_id,'scope',v_scope->'scope','generation',v_key.generation::text,
   'lifecycleStatus',v_key.lifecycle_status,'publicKeySha256',v_key.public_key_sha256,
   'publicKeySpkiDerHex',encode(v_key.public_key_spki_der,'hex')));
end;
$claim$;

create function private.invalidate_vehicle_device_claims() returns trigger
language plpgsql security definer set search_path='' as $invalidate$
begin
 update private.vehicle_device_challenges c set state='REVOKED',consumed_at=new.revoked_at
  where c.credential_id=new.credential_id and c.state in ('ISSUED','CLAIMED');
 return new;
end;
$invalidate$;
create trigger vehicle_device_claims_revoke after update on private.vehicle_device_credentials
 for each row execute function private.invalidate_vehicle_device_claims();

-- Terminal owner revocation reuses canonical append-only receipts, not a new queue.
-- No driver requirement to withdraw one's own inactive credential;
-- active authenticated account + exact current org membership still required.
create function private.revoke_vehicle_device_credential(
 p_operation uuid,p_org uuid,p_incident uuid,p_credential uuid,p_reason text
) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $revoke$
declare v_key private.vehicle_device_credentials;v_receipt private.incident_operation_receipts;
 v_request jsonb;v_result jsonb;
begin
 if p_operation is null or p_credential is null or p_reason is null
  or p_reason not in ('OWNER_REQUEST','KEY_LOST','SUPERSEDED','AUTHORITY_LOST') then raise exception 'VALIDATION_FAILED'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 perform private.incident_sync_lock(p_org,p_incident);
 v_request:=jsonb_build_object('command','DEVICE_CREDENTIAL_REVOKE','org',p_org,'incident',p_incident,'credential',p_credential,'reason',p_reason);
 select * into v_receipt from private.incident_operation_receipts r where r.operation_id=p_operation;
 if found then
  if v_receipt.actor_user_id is distinct from auth.uid() or v_receipt.acting_organization_id is distinct from p_org
   or v_receipt.incident_id is distinct from p_incident or v_receipt.command_code<>'DEVICE_CREDENTIAL_REVOKE'
   or v_receipt.request is distinct from v_request then raise exception 'OPERATION_REUSED'; end if;
  return v_receipt.result;
 end if;
 if exists(select 1 from private.vehicle_device_challenges c where c.issue_operation_id=p_operation or c.confirm_operation_id=p_operation)
  then raise exception 'OPERATION_REUSED'; end if;
 select * into v_key from private.vehicle_device_credentials c where c.credential_id=p_credential
  and c.actor_user_id=auth.uid() and c.acting_organization_id=p_org and c.incident_id=p_incident for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if v_key.lifecycle_status='INACTIVE' then
  update private.vehicle_device_credentials c set lifecycle_status='REVOKED',revoked_at=clock_timestamp(),revoked_reason=p_reason
   where c.credential_id=v_key.credential_id returning * into v_key;
 end if;
 v_result:=jsonb_build_object('status','REVOKED','credentialId',v_key.credential_id,'generation',v_key.generation::text,'revokedAt',v_key.revoked_at);
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
  values(p_operation,auth.uid(),p_org,p_incident,'DEVICE_CREDENTIAL_REVOKE',v_request,v_result);
 return v_result;
end;
$revoke$;

create trigger vehicle_device_credentials_no_delete before delete on private.vehicle_device_credentials
 for each row execute function private.audit_immutable();
create trigger vehicle_device_credentials_no_truncate before truncate on private.vehicle_device_credentials
 for each statement execute function private.audit_immutable();
create trigger vehicle_device_challenges_no_delete before delete on private.vehicle_device_challenges
 for each row execute function private.audit_immutable();
create trigger vehicle_device_challenges_no_truncate before truncate on private.vehicle_device_challenges
 for each statement execute function private.audit_immutable();

alter function private.vehicle_device_driver_scope(uuid,uuid,uuid,uuid) owner to postgres;
alter function private.guard_vehicle_device_credential() owner to postgres;
alter function private.guard_vehicle_device_challenge() owner to postgres;
alter function private.claim_vehicle_device_proof(uuid,uuid,uuid,uuid,text) owner to postgres;
alter function private.invalidate_vehicle_device_claims() owner to postgres;
alter function private.revoke_vehicle_device_credential(uuid,uuid,uuid,uuid,text) owner to postgres;
revoke all on function private.vehicle_device_driver_scope(uuid,uuid,uuid,uuid),
 private.guard_vehicle_device_credential(),private.guard_vehicle_device_challenge(),
 private.claim_vehicle_device_proof(uuid,uuid,uuid,uuid,text),private.invalidate_vehicle_device_claims(),
 private.revoke_vehicle_device_credential(uuid,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;

commit;
