-- M15B. Source implementation only. No policy/activation seed, schedule or deployment.
begin;
create table private.vehicle_location_policies (
 id uuid primary key, organization_id uuid not null references public.organizations(id),
 version text not null check(version ~ '^[A-Za-z0-9._-]{1,64}$'),
 status text not null default 'DRAFT' check(status in ('DRAFT','APPROVED','REVOKED')),
 notice jsonb, document_sha256 text, audience_sha256 text, audience text, recovery_epoch uuid,
 approved_by uuid references public.profiles(id), approved_at timestamptz, expires_at timestamptz,
 revoked_by uuid references public.profiles(id),revoked_at timestamptz,
 lease_seconds integer, maximum_seconds integer, interval_seconds integer, accuracy_cm integer,
 observed_lag_seconds integer, future_skew_seconds integer, position_seconds integer,
 allow_stale boolean, cleanup_sla_seconds integer,maximum_speed_mps integer,movement_metres integer,
 unique(organization_id,version),unique(id,organization_id),
 check((status='REVOKED' and revoked_by is not null and revoked_at is not null) or (status<>'REVOKED' and revoked_by is null and revoked_at is null)),
 check(status<>'APPROVED' or (
  notice is not null and jsonb_typeof(notice)='object' and octet_length(notice::text)<=16384
  and jsonb_typeof(notice->'sl')='string' and jsonb_typeof(notice->'de')='string' and jsonb_typeof(notice->'default')='string'
  and length(btrim(notice->>'sl')) between 1 and 5000 and length(btrim(notice->>'de')) between 1 and 5000 and length(btrim(notice->>'default')) between 1 and 5000
  and document_sha256 ~ '^[0-9a-f]{64}$' and document_sha256=encode(sha256(convert_to(notice::text,'UTF8')),'hex')
  and audience_sha256 ~ '^[0-9a-f]{64}$' and audience ~ '^[A-Za-z0-9._:/-]{1,128}$'
  and recovery_epoch is not null and recovery_epoch<>'00000000-0000-0000-0000-000000000000'::uuid
  and approved_by is not null and approved_at is not null and expires_at>approved_at
  and lease_seconds between 30 and 90 and maximum_seconds between lease_seconds and 3600
  and interval_seconds between 20 and 120 and interval_seconds*2<=lease_seconds and accuracy_cm between 1 and 10000
  and observed_lag_seconds between 1 and 30 and future_skew_seconds between 0 and 5
  and movement_metres between 0 and 100 and maximum_speed_mps between 1 and 100 and position_seconds between 120 and 900 and allow_stale is not null and cleanup_sla_seconds between 15 and 120
 ) is true)
);
create unique index vehicle_location_approved_policy on private.vehicle_location_policies(organization_id) where status='APPROVED';
create table private.vehicle_location_readiness (
 organization_id uuid primary key references public.organizations(id),
 manual_enabled boolean not null default false,legal_approved boolean not null default false,
 readers_approved boolean not null default false,verifier_approved boolean not null default false,
 android_approved boolean not null default false,web_approved boolean not null default false,
 retention_schedule_approved boolean not null default false,
 cleanup_at timestamptz,cleanup_rows integer,cleanup_backlog boolean not null default true,
 signed_off_by uuid references public.profiles(id),signed_off_at timestamptz,edge_epoch uuid,edge_seen_at timestamptz
);
alter table private.vehicle_device_credentials add constraint vehicle_device_credential_scope_unique
 unique(credential_id,actor_user_id,acting_organization_id,incident_id,deployment_id,vehicle_id,authority_episode_id,generation);
create table private.vehicle_location_bindings (
 id uuid primary key,credential_id uuid not null unique references private.vehicle_device_credentials(credential_id),
 actor_user_id uuid not null references public.profiles(id),organization_id uuid not null,
 incident_id uuid not null,deployment_id uuid not null,vehicle_id uuid not null,authority_episode_id uuid not null,
 credential_generation bigint not null check(credential_generation>0),generation bigint not null default 1 check(generation>0),
 policy_id uuid not null,proof_operation_id uuid not null unique references private.incident_operation_receipts(operation_id),
 state text not null check(state in ('INACTIVE','REVOKED')),created_at timestamptz not null default clock_timestamp(),revoked_at timestamptz,
 foreign key(policy_id,organization_id) references private.vehicle_location_policies(id,organization_id),
 foreign key(deployment_id,incident_id,organization_id) references public.incident_units(id,incident_id,organization_id),
 foreign key(vehicle_id,organization_id) references public.operational_vehicles(id,organization_id),
 foreign key(authority_episode_id,incident_id) references public.incident_crew_members(id,incident_id),
 unique(id,organization_id,incident_id,deployment_id,vehicle_id),
 unique(id,actor_user_id,policy_id),
 unique(id,credential_id,credential_generation,authority_episode_id),
 foreign key(credential_id,actor_user_id,organization_id,incident_id,deployment_id,vehicle_id,authority_episode_id,credential_generation)
  references private.vehicle_device_credentials(credential_id,actor_user_id,acting_organization_id,incident_id,deployment_id,vehicle_id,authority_episode_id,generation),
 check((state='REVOKED')=(revoked_at is not null))
);
create table private.vehicle_location_consents (
 id uuid primary key, binding_id uuid not null references private.vehicle_location_bindings(id),
 policy_id uuid not null references private.vehicle_location_policies(id),actor_user_id uuid not null references public.profiles(id),
 operation_id uuid not null unique references private.incident_operation_receipts(operation_id),
 notice_sha256 text not null check(notice_sha256 ~ '^[0-9a-f]{64}$'),
 granted_at timestamptz not null default clock_timestamp(),withdrawn_at timestamptz,
 unique(id,binding_id,policy_id,actor_user_id),
 foreign key(binding_id,actor_user_id,policy_id) references private.vehicle_location_bindings(id,actor_user_id,policy_id)
);
create table private.vehicle_location_sessions (
 id uuid primary key,binding_id uuid not null,actor_user_id uuid not null references public.profiles(id),
 organization_id uuid not null,incident_id uuid not null,deployment_id uuid not null,vehicle_id uuid not null,
 consent_id uuid not null,policy_id uuid not null,credential_id uuid not null references private.vehicle_device_credentials(credential_id),
 credential_generation bigint not null check(credential_generation>0),binding_generation bigint not null check(binding_generation>0),
 authority_episode_id uuid not null,session_context text not null check(session_context ~ '^[A-Za-z0-9_-]{43}$'),
 start_operation_id uuid not null unique,stop_operation_id uuid unique,
 state text not null check(state in ('SHARING','STOPPED','REVOKED','LEASE_EXPIRED')),
 started_at timestamptz not null,lease_expires_at timestamptz not null,maximum_expires_at timestamptz not null,
 stopped_at timestamptz,accepted_sequence bigint not null default 0 check(accepted_sequence>=0),
 last_renewed_at timestamptz not null default clock_timestamp(),last_observed_at timestamptz,last_sample_at timestamptz,last_sample_id uuid,last_sample_hash text,last_sample_ack jsonb,
 foreign key(binding_id,organization_id,incident_id,deployment_id,vehicle_id)
  references private.vehicle_location_bindings(id,organization_id,incident_id,deployment_id,vehicle_id),
 foreign key(binding_id,credential_id,credential_generation,authority_episode_id)
  references private.vehicle_location_bindings(id,credential_id,credential_generation,authority_episode_id),
 foreign key(consent_id,binding_id,policy_id,actor_user_id) references private.vehicle_location_consents(id,binding_id,policy_id,actor_user_id),
 foreign key(policy_id,organization_id) references private.vehicle_location_policies(id,organization_id),
 foreign key(authority_episode_id,incident_id) references public.incident_crew_members(id,incident_id),
 unique(id,organization_id,incident_id,deployment_id,vehicle_id),
 check(lease_expires_at>started_at and maximum_expires_at>=lease_expires_at),
 check((state='SHARING' and stopped_at is null) or (state<>'SHARING' and stopped_at is not null))
);
create unique index vehicle_location_live_vehicle on private.vehicle_location_sessions(vehicle_id) where state='SHARING';
create index vehicle_location_sessions_scope on private.vehicle_location_sessions(organization_id,incident_id,state);
create table private.vehicle_latest_positions (
 vehicle_id uuid primary key,session_id uuid not null unique,organization_id uuid not null,incident_id uuid not null,deployment_id uuid not null,
 sample_id uuid not null,sample_sequence bigint not null check(sample_sequence>0),
 observed_at timestamptz not null,received_at timestamptz not null,expires_at timestamptz not null,
 latitude_e7 integer not null check(latitude_e7 between -900000000 and 900000000),
 longitude_e7 integer not null check(longitude_e7 between -1800000000 and 1800000000),
 accuracy_cm integer not null check(accuracy_cm between 1 and 10000),
 source text not null check(source='ANDROID_REAL_GNSS'),
 foreign key(session_id,organization_id,incident_id,deployment_id,vehicle_id)
  references private.vehicle_location_sessions(id,organization_id,incident_id,deployment_id,vehicle_id),
 check(expires_at>received_at and expires_at<=observed_at+interval '900 seconds')
);
create index vehicle_latest_positions_expiry on private.vehicle_latest_positions(expires_at,vehicle_id);
create table private.vehicle_location_readers (
 actor_user_id uuid not null references public.profiles(id),organization_id uuid not null,incident_id uuid not null,
 deployment_id uuid not null,policy_id uuid not null,active boolean not null default false,
 approved_by uuid references public.profiles(id),approved_at timestamptz,
 primary key(actor_user_id,organization_id,incident_id,deployment_id,policy_id),
 foreign key(deployment_id,incident_id,organization_id) references public.incident_units(id,incident_id,organization_id),
 foreign key(policy_id,organization_id) references private.vehicle_location_policies(id,organization_id),
 check(not active or (approved_by is not null and approved_at is not null))
);


-- Trusted rate budgets: one current minute per actor/org; no coordinate metadata.
create table private.vehicle_location_rate_org(organization_id uuid primary key references public.organizations(id),minute bigint not null,n integer not null);
create table private.vehicle_location_rate_actor(actor_user_id uuid not null references public.profiles(id),organization_id uuid not null references public.organizations(id),minute bigint not null,n integer not null,primary key(actor_user_id,organization_id));
alter table private.vehicle_location_rate_org owner to postgres;
alter table private.vehicle_location_rate_actor owner to postgres;
alter table private.vehicle_location_rate_org enable row level security;
alter table private.vehicle_location_rate_actor enable row level security;
revoke all on private.vehicle_location_rate_org,private.vehicle_location_rate_actor from public,anon,authenticated,service_role;
create function private.vehicle_location_rate(p_actor uuid,p_org uuid) returns void
language plpgsql security definer set search_path='' as $rate$
declare v_min bigint:=floor(extract(epoch from clock_timestamp())/60);v_n integer;
begin
 if p_actor is distinct from auth.uid() or not private.is_active_user() or not private.incident_acting_member(p_org)
  then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 insert into private.vehicle_location_rate_org values(p_org,v_min,1)
 on conflict(organization_id) do update set minute=excluded.minute,n=case when vehicle_location_rate_org.minute=excluded.minute then vehicle_location_rate_org.n+1 else 1 end returning n into v_n;
 if v_n>1000 then raise exception 'RATE_LIMITED';end if;
 insert into private.vehicle_location_rate_actor values(p_actor,p_org,v_min,1)
 on conflict(actor_user_id,organization_id) do update set minute=excluded.minute,n=case when vehicle_location_rate_actor.minute=excluded.minute then vehicle_location_rate_actor.n+1 else 1 end returning n into v_n;
 if v_n>120 then raise exception 'RATE_LIMITED';end if;
end;$rate$;
alter function private.vehicle_location_rate(uuid,uuid) owner to postgres;
revoke all on function private.vehicle_location_rate(uuid,uuid) from public,anon,authenticated,service_role;

create function private.guard_vehicle_location_identity() returns trigger
language plpgsql set search_path='' as $identity$
declare allowed text[];
begin
 allowed:=case tg_table_name
  when 'vehicle_location_bindings' then array['state','revoked_at']
  when 'vehicle_location_consents' then array['withdrawn_at']
  when 'vehicle_location_sessions' then array['state','lease_expires_at','stopped_at','stop_operation_id','accepted_sequence',
   'last_observed_at','last_sample_at','last_sample_id','last_sample_hash','last_sample_ack','last_renewed_at'] end;
 if (to_jsonb(new)-allowed) is distinct from (to_jsonb(old)-allowed) then raise exception 'OPERATION_REUSED';end if;
 if tg_table_name='vehicle_location_bindings' and (old.state<>'INACTIVE' or new.state<>'REVOKED')
  then raise exception 'CREDENTIAL_REVOKED';end if;
 if tg_table_name='vehicle_location_consents' and old.withdrawn_at is not null then raise exception 'CREDENTIAL_REVOKED';end if;
 if tg_table_name='vehicle_location_sessions' and old.state<>'SHARING' then raise exception 'SESSION_EXPIRED';end if;
 return new;
end;$identity$;
alter function private.guard_vehicle_location_identity() owner to postgres;
revoke all on function private.guard_vehicle_location_identity() from public,anon,authenticated,service_role;
create trigger vehicle_binding_identity before update on private.vehicle_location_bindings for each row execute function private.guard_vehicle_location_identity();
create trigger vehicle_consent_identity before update on private.vehicle_location_consents for each row execute function private.guard_vehicle_location_identity();
create trigger vehicle_session_identity before update on private.vehicle_location_sessions for each row execute function private.guard_vehicle_location_identity();
create trigger vehicle_binding_no_delete before delete on private.vehicle_location_bindings for each row execute function private.audit_immutable();
create trigger vehicle_binding_no_truncate before truncate on private.vehicle_location_bindings for each statement execute function private.audit_immutable();
create trigger vehicle_consent_no_delete before delete on private.vehicle_location_consents for each row execute function private.audit_immutable();
create trigger vehicle_consent_no_truncate before truncate on private.vehicle_location_consents for each statement execute function private.audit_immutable();
create trigger vehicle_session_no_delete before delete on private.vehicle_location_sessions for each row execute function private.audit_immutable();
create trigger vehicle_session_no_truncate before truncate on private.vehicle_location_sessions for each statement execute function private.audit_immutable();


create function private.guard_vehicle_location_policy() returns trigger
language plpgsql set search_path='' as $policy_identity$
begin
 if old.status='REVOKED' or (new.id,new.organization_id,new.version) is distinct from (old.id,old.organization_id,old.version)
  or (old.status='APPROVED' and (new.status<>'REVOKED' or (to_jsonb(new)-array['status','revoked_by','revoked_at']) is distinct from (to_jsonb(old)-array['status','revoked_by','revoked_at'])))
  then raise exception 'POLICY_IMMUTABLE';end if;
 return new;
end;$policy_identity$;
alter function private.guard_vehicle_location_policy() owner to postgres;
revoke all on function private.guard_vehicle_location_policy() from public,anon,authenticated,service_role;
create trigger vehicle_policy_identity before update on private.vehicle_location_policies for each row execute function private.guard_vehicle_location_policy();
create trigger vehicle_policy_no_delete before delete on private.vehicle_location_policies for each row execute function private.audit_immutable();
create trigger vehicle_policy_no_truncate before truncate on private.vehicle_location_policies for each statement execute function private.audit_immutable();
create function private.vehicle_location_health() returns jsonb
language sql security definer set search_path='' as $health$
 select jsonb_build_object('expired_rows',(select count(*) from private.vehicle_latest_positions p where p.expires_at<=clock_timestamp()),
 'oldest_expired_seconds',(select coalesce(max(extract(epoch from clock_timestamp()-p.expires_at)),0) from private.vehicle_latest_positions p where p.expires_at<=clock_timestamp()),
 'oldest_cleanup',(select min(r.cleanup_at) from private.vehicle_location_readiness r),
 'backlogged_orgs',(select count(*) from private.vehicle_location_readiness r where r.cleanup_backlog));
$health$;
alter function private.vehicle_location_health() owner to postgres;
revoke all on function private.vehicle_location_health() from public,anon,authenticated,service_role;


create table private.vehicle_location_device_trust (
 credential_id uuid primary key references private.vehicle_device_credentials(credential_id),
 public_key_sha256 text not null check(public_key_sha256 ~ '^[0-9a-f]{64}$'),
 active boolean not null default false,approved_by uuid references public.profiles(id),approved_at timestamptz,expires_at timestamptz,
 check(not active or ((approved_by is not null and approved_at is not null and expires_at>approved_at) is true))
);
alter table private.vehicle_location_device_trust owner to postgres;
alter table private.vehicle_location_device_trust enable row level security;
revoke all on private.vehicle_location_device_trust from public,anon,authenticated,service_role;
create function private.vehicle_location_key_trust(p_credential uuid,p_hash text) returns void
language plpgsql security definer set search_path='' as $trust$
begin
 perform 1 from private.vehicle_location_device_trust t where t.credential_id=p_credential and t.public_key_sha256=p_hash
  and t.active and t.expires_at>clock_timestamp() for share;
 if not found then raise exception 'DEVICE_APPROVAL_REQUIRED';end if;
end;$trust$;
alter function private.vehicle_location_key_trust(uuid,text) owner to postgres;
revoke all on function private.vehicle_location_key_trust(uuid,text) from public,anon,authenticated,service_role;

-- Thin, expiring non-coordinate sample acknowledgements; not a position history.
create table private.vehicle_location_sample_receipts (
 operation_id uuid primary key,session_id uuid not null references private.vehicle_location_sessions(id),
 sequence bigint not null check(sequence>0),request_sha256 text not null check(request_sha256 ~ '^[0-9a-f]{64}$'),
 result jsonb not null check(octet_length(result::text)<=1024),expires_at timestamptz not null,
 unique(session_id,sequence)
);
create index vehicle_sample_receipt_expiry on private.vehicle_location_sample_receipts(expires_at,operation_id);
alter table private.vehicle_location_sample_receipts owner to postgres;
alter table private.vehicle_location_sample_receipts enable row level security;
revoke all on private.vehicle_location_sample_receipts from public,anon,authenticated,service_role;
create trigger vehicle_sample_receipt_immutable before update on private.vehicle_location_sample_receipts for each row execute function private.audit_immutable();
create trigger vehicle_sample_receipt_no_truncate before truncate on private.vehicle_location_sample_receipts for each statement execute function private.audit_immutable();

-- No policy, activation or trusted-device rows are seeded.
alter table private.vehicle_location_policies owner to postgres;
alter table private.vehicle_location_readiness owner to postgres;
alter table private.vehicle_location_bindings owner to postgres;
alter table private.vehicle_location_consents owner to postgres;
alter table private.vehicle_location_sessions owner to postgres;
alter table private.vehicle_latest_positions owner to postgres;
alter table private.vehicle_location_readers owner to postgres;
alter table private.vehicle_location_policies enable row level security;
alter table private.vehicle_location_readiness enable row level security;
alter table private.vehicle_location_bindings enable row level security;
alter table private.vehicle_location_consents enable row level security;
alter table private.vehicle_location_sessions enable row level security;
alter table private.vehicle_latest_positions enable row level security;
alter table private.vehicle_location_readers enable row level security;
revoke all on private.vehicle_location_policies,private.vehicle_location_readiness,private.vehicle_location_bindings,
 private.vehicle_location_consents,private.vehicle_location_sessions,private.vehicle_latest_positions,private.vehicle_location_readers
 from public,anon,authenticated,service_role;

-- Only service-only entrypoints call this after Edge Auth /user verification.
-- This is delegated actor authority, NOT authorization inferred from service_role.
create function private.vehicle_location_actor(p_actor uuid,p_epoch uuid) returns void
language plpgsql security definer set search_path='' as $actor$
begin
 if auth.role() is distinct from 'service_role' or p_actor is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 perform set_config('request.jwt.claim.sub',p_actor::text,true);
 perform set_config('gasilko.vehicle_epoch',coalesce(p_epoch::text,''),true);
end;$actor$;

create function private.vehicle_location_policy(p_org uuid) returns private.vehicle_location_policies
language plpgsql security definer set search_path='' as $policy$
declare p private.vehicle_location_policies;r private.vehicle_location_readiness;
begin
 select * into p from private.vehicle_location_policies x where x.organization_id=p_org and x.status='APPROVED' and x.expires_at>clock_timestamp() for share;
 if not found then raise exception 'POLICY_UNAPPROVED';end if;
 if auth.role()='service_role' and current_setting('gasilko.vehicle_epoch',true) is distinct from p.recovery_epoch::text
  then raise exception 'CAPABILITY_DISABLED';end if;
 select * into r from private.vehicle_location_readiness x where x.organization_id=p_org for share;
 if not found or not(r.legal_approved and r.readers_approved and r.verifier_approved and r.android_approved and r.web_approved and r.manual_enabled) or r.signed_off_by is null or r.signed_off_at is null
  then raise exception 'CAPABILITY_DISABLED';end if;
 if r.edge_epoch is distinct from p.recovery_epoch or r.edge_seen_at is null or r.edge_seen_at<clock_timestamp()-interval '120 seconds'
  then raise exception 'CAPABILITY_DISABLED';end if;
 if not r.retention_schedule_approved or r.cleanup_at is null or r.cleanup_backlog
  or r.cleanup_at<clock_timestamp()-make_interval(secs=>p.cleanup_sla_seconds)
  then raise exception 'RETENTION_NOT_READY';end if;
 return p;
end;$policy$;

create function private.vehicle_location_live(p_actor uuid,p_org uuid,p_incident uuid,p_binding uuid) returns private.vehicle_location_bindings
language plpgsql security definer set search_path='' as $live$
declare b private.vehicle_location_bindings;k private.vehicle_device_credentials;v jsonb;p private.vehicle_location_policies;
begin
 p:=private.vehicle_location_policy(p_org);
 select * into b from private.vehicle_location_bindings x where x.id=p_binding and x.actor_user_id=p_actor
  and x.organization_id=p_org and x.incident_id=p_incident;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into k from private.vehicle_device_credentials x where x.credential_id=b.credential_id for update;
 if b.state<>'INACTIVE' or k.lifecycle_status<>'INACTIVE' or k.generation<>b.credential_generation
  then raise exception 'CREDENTIAL_REVOKED';end if;
 perform private.vehicle_location_key_trust(k.credential_id,k.public_key_sha256);
 if b.policy_id<>p.id then raise exception 'POLICY_UNAPPROVED';end if;
 v:=private.vehicle_device_driver_scope(p_org,p_incident,b.deployment_id,b.vehicle_id);
 if (v#>>'{scope,authorityEpisode}')::uuid<>b.authority_episode_id then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return b;
end;$live$;

-- No schedule installed. Owner Cron calls this private routine under approved
-- maintenance identity. Raw positions are intentionally deletable, not audit rows.
create function private.vehicle_location_cleanup() returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $clean$
declare v_org uuid;v_count integer;v_total integer:=0;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('gasilko_vehicle_location_cleanup',150))then return jsonb_build_object('busy',true);end if;
 for v_org in select r.organization_id from private.vehicle_location_readiness r order by r.cleanup_at nulls first,r.organization_id limit 10 loop
  perform 1 from private.vehicle_location_readiness r where r.organization_id=v_org for update;
  with doomed as (select x.vehicle_id from private.vehicle_latest_positions x
   where x.organization_id=v_org and x.expires_at<=clock_timestamp() order by x.expires_at,x.vehicle_id limit 1000 for update skip locked)
  delete from private.vehicle_latest_positions x using doomed d where x.vehicle_id=d.vehicle_id;
  get diagnostics v_count=row_count;v_total:=v_total+v_count;
  update private.vehicle_location_readiness r set cleanup_at=clock_timestamp(),cleanup_rows=v_count,
   cleanup_backlog=exists(select 1 from private.vehicle_latest_positions x where x.organization_id=v_org and x.expires_at<=clock_timestamp())
   where r.organization_id=v_org;
 end loop;
 with doomed as (select r.operation_id from private.vehicle_location_sample_receipts r where r.expires_at<=clock_timestamp()
  order by r.expires_at,r.operation_id limit 1000 for update skip locked)
 delete from private.vehicle_location_sample_receipts r using doomed d where r.operation_id=d.operation_id;
 return jsonb_build_object('deleted',v_total);
end;$clean$;

create or replace function private.guard_vehicle_device_credential() returns trigger
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
  perform private.lock_organization(old.acting_organization_id);
  if auth.uid() is distinct from old.actor_user_id then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if (to_jsonb(new)-array['lifecycle_status','revoked_at','revoked_reason'])
   is distinct from (to_jsonb(old)-array['lifecycle_status','revoked_at','revoked_reason'])
   or old.lifecycle_status<>'INACTIVE' or new.lifecycle_status<>'REVOKED'
   then raise exception 'CREDENTIAL_IMMUTABLE'; end if;
 end if;
 return new;
end;
$credential$;

alter table private.vehicle_device_challenges add column policy_id uuid references private.vehicle_location_policies(id),
 add column issued_document jsonb check(issued_document is null or octet_length(issued_document::text)<=8192);

-- Existing guard remains unchanged except a narrowly privileged FINALIZE branch.
-- Both service-only EXECUTE and service JWT role are required; GUC is NOT authority.
create or replace function private.guard_vehicle_device_challenge() returns trigger
language plpgsql security definer set search_path='' as $challenge$
declare v_key private.vehicle_device_credentials;v_scope jsonb;v_operation uuid;
begin
 if new.state='VERIFIED_INACTIVE' then
  if tg_op<>'UPDATE' or auth.role() is distinct from 'service_role'
   or current_setting('gasilko.vehicle_finalize',true) is distinct from new.challenge_id::text
   or old.state<>'CLAIMED' or old.claim_expires_at<=clock_timestamp() or old.expires_at<=clock_timestamp()
   or (to_jsonb(new)-array['state','consumed_at']) is distinct from (to_jsonb(old)-array['state','consumed_at'])
   then raise exception 'VERIFIER_UNAVAILABLE';end if;
  return new;
 end if;
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
  -- Ordinary updates still cannot record successful verification. Only the
  -- service-only FINALIZE branch above may consume a successfully verified claim.
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

create function public.vehicle_location_control(p_actor uuid,p_epoch uuid,p_action text,p_org uuid,p_incident uuid,p_operation uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $control$
declare p private.vehicle_location_policies;b private.vehicle_location_bindings;k private.vehicle_device_credentials;
 c private.vehicle_device_challenges;s private.vehicle_location_sessions;r private.incident_operation_receipts;
 v_scope jsonb;v_request jsonb;v_result jsonb;v_now timestamptz:=clock_timestamp();v_id uuid;v_allowed text[];
begin
 perform private.vehicle_location_actor(p_actor,p_epoch);
 if p_operation is null or p_org is null or p_incident is null or jsonb_typeof(p_payload) is distinct from 'object'
  or octet_length(p_payload::text)>16384 then raise exception 'VALIDATION_FAILED';end if;
 v_allowed:=case p_action
  when 'REGISTER' then array['credential','deployment','vehicle','spki','keyHash']
  when 'ISSUE_CONTEXT' then array['credential','confirmOperation']
  when 'ISSUE' then array['credential','confirmOperation','document','transcriptHash']
  when 'CLAIM' then array['challenge','signatureHash']
  when 'FINALIZE' then array['challenge','claim','transcriptHash','signatureHash']
  when 'CONSENT' then array['binding','policy','noticeHash','accepted']
  when 'START' then array['binding','consent','sessionContext']
  when 'RENEW' then array['session']
  when 'STOP' then array['session','reason']
  when 'REVOKE' then array['credential','reason'] else null end;
 if v_allowed is null or exists(select 1 from jsonb_object_keys(p_payload) x where not(x=any(v_allowed)))
  then raise exception 'VALIDATION_FAILED';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 -- STOP never requires still being DRIVER or still having policy approval.
 if p_action in ('STOP','REVOKE') then
  if p_action='STOP' and not exists(select 1 from private.vehicle_location_sessions x where x.id=(p_payload->>'session')::uuid
   and x.actor_user_id=p_actor and x.organization_id=p_org and x.incident_id=p_incident)
   then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  if p_action='REVOKE' and not exists(select 1 from private.vehicle_device_credentials x where x.credential_id=(p_payload->>'credential')::uuid
   and x.actor_user_id=p_actor and x.acting_organization_id=p_org and x.incident_id=p_incident)
   then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  perform private.lock_organization(p_org);
  perform 1 from public.incidents i where i.id=p_incident for share;
 else
  perform private.incident_sync_lock(p_org,p_incident);
  p:=private.vehicle_location_policy(p_org);
 end if;
 if exists(select 1 from private.vehicle_device_challenges x where
  (x.issue_operation_id=p_operation or x.confirm_operation_id=p_operation) and not (
   x.actor_user_id=p_actor and x.acting_organization_id=p_org and x.incident_id=p_incident and (
    (p_action in ('ISSUE_CONTEXT','ISSUE') and x.issue_operation_id=p_operation and x.credential_id=(p_payload->>'credential')::uuid)
    or (p_action in ('CLAIM','FINALIZE') and x.confirm_operation_id=p_operation and x.challenge_id=(p_payload->>'challenge')::uuid))))
  then raise exception 'OPERATION_REUSED';end if;
 v_request:=jsonb_build_object('command','VEHICLE_LOCATION_'||case when p_action='ISSUE_CONTEXT' then 'ISSUE' when p_action='CLAIM' then 'FINALIZE' else p_action end,'org',p_org,'incident',p_incident,'payload',
  case when p_action='ISSUE' then p_payload-array['document','transcriptHash'] when p_action='FINALIZE' then p_payload-array['claim','transcriptHash'] when p_action='START' then p_payload-'sessionContext' else p_payload end);
 select * into r from private.incident_operation_receipts x where x.operation_id=p_operation;
 if found then
  if r.actor_user_id<>p_actor or r.acting_organization_id<>p_org or r.incident_id<>p_incident or r.request is distinct from v_request
   then raise exception 'OPERATION_REUSED';end if;
  if p_action='ISSUE_CONTEXT' then return jsonb_build_object('issued',r.result);end if;
  if p_action='CLAIM' then return jsonb_build_object('confirmed',r.result);end if;
  if p_action in ('START','RENEW') then
   select * into s from private.vehicle_location_sessions x where x.id=(r.result->>'session')::uuid and x.actor_user_id=p_actor;
   b:=private.vehicle_location_live(p_actor,p_org,p_incident,s.binding_id);
   if s.state<>'SHARING' or s.lease_expires_at<=clock_timestamp() then raise exception 'SESSION_EXPIRED';end if;
  end if;
  -- Original lease/result plus a current clock/sequence; never renew via replay.
  if p_action in ('START','RENEW') then return r.result||jsonb_build_object('serverTime',clock_timestamp(),'acceptedSequence',s.accepted_sequence::text);end if;
  return r.result;
 end if;
 if p_action in ('REGISTER','ISSUE_CONTEXT','ISSUE','CLAIM','FINALIZE','REVOKE') then
  if p_action in ('CLAIM','FINALIZE') then
   select * into c from private.vehicle_device_challenges x where x.challenge_id=(p_payload->>'challenge')::uuid
    and x.actor_user_id=p_actor and x.acting_organization_id=p_org and x.incident_id=p_incident;
   if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
   v_id:=c.credential_id;
  elsif p_action='REGISTER' then v_id:=(p_payload->>'credential')::uuid;
  else v_id:=(p_payload->>'credential')::uuid;end if;
  if p_action='REGISTER' then
   v_scope:=private.vehicle_device_driver_scope(p_org,p_incident,(p_payload->>'deployment')::uuid,(p_payload->>'vehicle')::uuid);
   insert into private.vehicle_device_credentials(credential_id,actor_user_id,acting_organization_id,incident_id,deployment_id,vehicle_id,
    authority_episode_id,protocol_version,public_key_spki_der,public_key_sha256,generation)
   values(v_id,p_actor,p_org,p_incident,(p_payload->>'deployment')::uuid,(p_payload->>'vehicle')::uuid,
    (v_scope#>>'{scope,authorityEpisode}')::uuid,1,decode(p_payload->>'spki','hex'),p_payload->>'keyHash',
    (select coalesce(max(x.generation),0)+1 from private.vehicle_device_credentials x where x.actor_user_id=p_actor
     and x.acting_organization_id=p_org and x.incident_id=p_incident and x.deployment_id=(p_payload->>'deployment')::uuid
     and x.authority_episode_id=(v_scope#>>'{scope,authorityEpisode}')::uuid));
   insert into private.vehicle_location_device_trust(credential_id,public_key_sha256) values(v_id,p_payload->>'keyHash');
   v_result:=jsonb_build_object('state','INACTIVE','credential',v_id);
  else
   select * into k from private.vehicle_device_credentials x where x.credential_id=v_id and x.actor_user_id=p_actor
    and x.acting_organization_id=p_org and x.incident_id=p_incident for update;
   if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
   if p_action='REVOKE' then
    v_now:=clock_timestamp();
    if k.lifecycle_status='INACTIVE' then
     update private.vehicle_device_credentials x set lifecycle_status='REVOKED',revoked_at=v_now,revoked_reason='OWNER_REQUEST' where x.credential_id=k.credential_id;
    end if;
    update private.vehicle_location_bindings x set state='REVOKED',revoked_at=v_now where x.credential_id=k.credential_id and x.state='INACTIVE';
    update private.vehicle_location_sessions x set state='REVOKED',stopped_at=v_now where x.credential_id=k.credential_id and x.state='SHARING';
    delete from private.vehicle_latest_positions x using private.vehicle_location_sessions z where x.session_id=z.id and z.credential_id=k.credential_id;
    v_result:=jsonb_build_object('state','REVOKED','credential',k.credential_id);
   else
    if k.lifecycle_status<>'INACTIVE' then raise exception 'CREDENTIAL_REVOKED';end if;
    v_scope:=private.vehicle_device_driver_scope(p_org,p_incident,k.deployment_id,k.vehicle_id);
    if (v_scope#>>'{scope,authorityEpisode}')::uuid<>k.authority_episode_id then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
    if p_action='ISSUE_CONTEXT' then
     return jsonb_build_object('protocolVersion',1,'audience',p.audience,'recoveryEpoch',p.recovery_epoch,'scope',v_scope->'scope',
      'credentialId',k.credential_id,'publicKeySha256',k.public_key_sha256,'policyVersion',p.version,'policyDocumentSha256',p.document_sha256,
      'preciseAudienceSha256',p.audience_sha256,'issueOperationId',p_operation,'confirmOperationId',(p_payload->>'confirmOperation')::uuid,
      'expectedIncidentVersion',v_scope->>'incidentVersion','expectedDeploymentVersion',v_scope->>'deploymentVersion',
      'expectedVehicleVersion',v_scope->>'vehicleVersion','reservedGeneration',k.generation::text);
    elsif p_action='ISSUE' then
     -- Document was constructed by trusted Edge, never accepted from its HTTP client.
     v_result:=p_payload->'document';
     if v_result->>'credentialId'<>k.credential_id::text or v_result->>'publicKeySha256'<>k.public_key_sha256
      or v_result->'scope' is distinct from v_scope->'scope' or v_result->>'issueOperationId'<>p_operation::text
      or v_result->>'confirmOperationId'<>p_payload->>'confirmOperation'
      or v_result->>'policyVersion'<>p.version or v_result->>'policyDocumentSha256'<>p.document_sha256
      or v_result->>'preciseAudienceSha256'<>p.audience_sha256 or v_result->>'audience'<>p.audience
      or v_result->>'recoveryEpoch'<>p.recovery_epoch::text then raise exception 'SCOPE_CHANGED';end if;
     insert into private.vehicle_device_challenges(challenge_id,credential_id,actor_user_id,acting_organization_id,incident_id,deployment_id,
      vehicle_id,authority_episode_id,issue_operation_id,confirm_operation_id,nonce,issued_at,expires_at,transcript_sha256,immutable_request,
      immutable_request_sha256,expected_incident_version,expected_deployment_version,expected_vehicle_version,reserved_generation,recovery_epoch,
      policy_version,policy_document_sha256,precise_audience_sha256,audience,policy_id,issued_document)
     values((v_result->>'challengeId')::uuid,k.credential_id,p_actor,p_org,p_incident,k.deployment_id,k.vehicle_id,k.authority_episode_id,
      p_operation,(p_payload->>'confirmOperation')::uuid,decode(translate(v_result->>'nonceBase64Url','-_','+/')||'=','base64'),
      to_timestamp((v_result->>'issuedAtSeconds')::bigint),to_timestamp((v_result->>'expiresAtSeconds')::bigint),p_payload->>'transcriptHash',
      v_request,encode(sha256(convert_to(v_request::text,'UTF8')),'hex'),(v_result->>'expectedIncidentVersion')::bigint,
      (v_result->>'expectedDeploymentVersion')::bigint,(v_result->>'expectedVehicleVersion')::bigint,(v_result->>'reservedGeneration')::bigint,
      p.recovery_epoch,p.version,p.document_sha256,p.audience_sha256,p.audience,p.id,v_result);
    elsif p_action='CLAIM' then
     if c.policy_id is distinct from p.id then raise exception 'POLICY_UNAPPROVED';end if;
     return private.claim_vehicle_device_proof(p_org,p_incident,c.challenge_id,p_operation,p_payload->>'signatureHash');
    elsif p_action='FINALIZE' then
     select * into c from private.vehicle_device_challenges x where x.challenge_id=c.challenge_id for update;
     if c.policy_id is distinct from p.id or c.recovery_epoch<>p.recovery_epoch or c.state<>'CLAIMED'
      or c.confirm_operation_id<>p_operation or c.claim_id is distinct from (p_payload->>'claim')::uuid
      or c.claim_expires_at<=clock_timestamp() or c.expires_at<=clock_timestamp()
      or c.signature_sha256 is distinct from p_payload->>'signatureHash' or c.transcript_sha256 is distinct from p_payload->>'transcriptHash'
      or c.reserved_generation<>k.generation or c.expected_incident_version::text<>v_scope->>'incidentVersion'
      or c.expected_deployment_version::text<>v_scope->>'deploymentVersion' or c.expected_vehicle_version::text<>v_scope->>'vehicleVersion'
      then raise exception 'SCOPE_CHANGED';end if;
     v_id:=gen_random_uuid();
     v_result:=jsonb_build_object('state','PROOF_VALIDATED_INACTIVE','binding',v_id,'credential',k.credential_id,'publicKeySha256',k.public_key_sha256,'challenge',c.challenge_id);
     insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
      values(p_operation,p_actor,p_org,p_incident,'VEHICLE_LOCATION_FINALIZE',v_request,v_result);
     perform set_config('gasilko.vehicle_finalize',c.challenge_id::text,true);
     update private.vehicle_device_challenges x set state='VERIFIED_INACTIVE',consumed_at=clock_timestamp() where x.challenge_id=c.challenge_id;
     insert into private.vehicle_location_bindings(id,credential_id,actor_user_id,organization_id,incident_id,deployment_id,vehicle_id,
      authority_episode_id,credential_generation,policy_id,proof_operation_id,state)
      values(v_id,k.credential_id,p_actor,p_org,p_incident,k.deployment_id,k.vehicle_id,k.authority_episode_id,k.generation,p.id,p_operation,'INACTIVE');
     return v_result;
    end if;
   end if;
  end if;
 else
  if p_action in ('STOP','RENEW') then
   select * into s from private.vehicle_location_sessions x where x.id=(p_payload->>'session')::uuid and x.actor_user_id=p_actor
    and x.organization_id=p_org and x.incident_id=p_incident;
   if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
   select * into k from private.vehicle_device_credentials x where x.credential_id=s.credential_id for update;
   if p_action='RENEW' then b:=private.vehicle_location_live(p_actor,p_org,p_incident,s.binding_id);end if;
   select * into s from private.vehicle_location_sessions x where x.id=s.id for update;
  else
   b:=private.vehicle_location_live(p_actor,p_org,p_incident,(p_payload->>'binding')::uuid);
  end if;
  v_now:=clock_timestamp();
  if p_action='CONSENT' then
   if p_payload->>'accepted' is distinct from 'true' or (p_payload->>'policy')::uuid is distinct from p.id
    or p_payload->>'noticeHash' is distinct from p.document_sha256 then raise exception 'POLICY_UNAPPROVED';end if;
   v_id:=gen_random_uuid();v_result:=jsonb_build_object('state','CONSENT_CONFIRMED','consent',v_id,'policy',p.id);
  elsif p_action='START' then
   if not exists(select 1 from private.vehicle_location_consents x where x.id=(p_payload->>'consent')::uuid
    and x.binding_id=b.id and x.policy_id=p.id and x.actor_user_id=p_actor and x.withdrawn_at is null)
    then raise exception 'DEVICE_PROOF_REQUIRED';end if;
   perform 1 from public.operational_vehicles x where x.id=b.vehicle_id for update;
   update private.vehicle_location_sessions x set state='LEASE_EXPIRED',stopped_at=v_now
    where x.vehicle_id=b.vehicle_id and x.state='SHARING' and x.lease_expires_at<=v_now;
   delete from private.vehicle_latest_positions x using private.vehicle_location_sessions z
    where x.session_id=z.id and z.vehicle_id=b.vehicle_id and z.state<>'SHARING';
   if exists(select 1 from private.vehicle_location_sessions x where x.vehicle_id=b.vehicle_id and x.state='SHARING')
    then raise exception 'SESSION_CONFLICT';end if;
   if (select count(*) from private.vehicle_location_sessions x where x.organization_id=p_org and x.state='SHARING' and x.lease_expires_at>v_now)>=100
    or (select count(*) from private.vehicle_location_sessions x where x.actor_user_id=p_actor and x.state='SHARING' and x.lease_expires_at>v_now)>=3
    then raise exception 'RESOURCE_LIMIT_REACHED';end if;
   v_id:=gen_random_uuid();
   insert into private.vehicle_location_sessions(id,binding_id,actor_user_id,organization_id,incident_id,deployment_id,vehicle_id,consent_id,policy_id,
    credential_id,credential_generation,binding_generation,authority_episode_id,session_context,start_operation_id,state,started_at,lease_expires_at,maximum_expires_at)
    values(v_id,b.id,p_actor,p_org,p_incident,b.deployment_id,b.vehicle_id,(p_payload->>'consent')::uuid,p.id,
     b.credential_id,b.credential_generation,b.generation,b.authority_episode_id,
     p_payload->>'sessionContext',p_operation,'SHARING',v_now,
     v_now+make_interval(secs=>p.lease_seconds),v_now+make_interval(secs=>p.maximum_seconds))
    returning * into s;
  elsif p_action='RENEW' then
   if s.state<>'SHARING' or s.lease_expires_at<=v_now or s.maximum_expires_at<=v_now
    then raise exception 'SESSION_EXPIRED';end if;
   if exists(select 1 from private.vehicle_location_consents x where x.id=s.consent_id and x.withdrawn_at is not null)
    then raise exception 'CREDENTIAL_REVOKED';end if;
   if s.last_renewed_at>v_now-make_interval(secs=>p.interval_seconds) then raise exception 'RATE_LIMITED';end if;
   update private.vehicle_location_sessions x set last_renewed_at=v_now,lease_expires_at=least(s.maximum_expires_at,v_now+make_interval(secs=>p.lease_seconds))
    where x.id=s.id returning * into s;
  elsif p_action='STOP' then
   if p_payload->>'reason' is null or p_payload->>'reason' not in ('USER_STOP','LEFT_VEHICLE','LOGOUT','PERMISSION_REVOKED','ERROR') then raise exception 'VALIDATION_FAILED';end if;
   if s.state='SHARING' then
    update private.vehicle_location_sessions x set state='STOPPED',stopped_at=v_now,stop_operation_id=p_operation where x.id=s.id returning * into s;
   end if;
   delete from private.vehicle_latest_positions x where x.session_id=s.id;
   if p_payload->>'reason'='LEFT_VEHICLE' then
    update private.vehicle_device_credentials x set lifecycle_status='REVOKED',revoked_at=v_now,revoked_reason='OWNER_REQUEST'
     where x.credential_id=s.credential_id and x.lifecycle_status='INACTIVE';
    update private.vehicle_location_bindings x set state='REVOKED',revoked_at=v_now where x.id=s.binding_id and x.state='INACTIVE';
    update private.vehicle_location_consents x set withdrawn_at=v_now where x.binding_id=s.binding_id and x.withdrawn_at is null;
   end if;
   v_result:=jsonb_build_object('state','STOPPED','session',s.id);
  end if;
  if p_action in ('START','RENEW') then
   v_result:=jsonb_build_object('state','SHARING','session',s.id,'binding',s.binding_id,'credential',s.credential_id,'deployment',s.deployment_id,
    'vehicle',s.vehicle_id,'generation',s.credential_generation::text,'bindingGeneration',s.binding_generation::text,
    'context',s.session_context,'policyVersion',p.version,'leaseExpiresAt',s.lease_expires_at,'serverTime',clock_timestamp(),
    'intervalSeconds',p.interval_seconds,'movementMetres',p.movement_metres,'accuracyCm',p.accuracy_cm,'acceptedSequence',s.accepted_sequence::text);
  end if;
 end if;
 if v_result is null then raise exception 'VALIDATION_FAILED';end if;
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
  values(p_operation,p_actor,p_org,p_incident,'VEHICLE_LOCATION_'||p_action,v_request,v_result);
 if p_action='CONSENT' then
  insert into private.vehicle_location_consents(id,binding_id,policy_id,actor_user_id,operation_id,notice_sha256)
   values(v_id,b.id,p.id,p_actor,p_operation,p.document_sha256);
 end if;
 return v_result;
end;$control$;

alter table private.vehicle_location_readers add column required_role text
 check(required_role in ('DRIVER','UNIT_LEADER','INCIDENT_COMMANDER','AGENCY_COMMANDER','SECTOR_COMMANDER'));
alter table private.vehicle_location_readers add constraint vehicle_reader_role_required check(not active or required_role is not null);


-- Optional Android B1 display binding; never make Web precise permission depend
-- on being ordinary field crew or on an unrelated Android projection limit.
create function private.vehicle_location_field_fingerprint(p_org uuid,p_incident uuid) returns text
language plpgsql security definer set search_path='' as $field_hint$
begin
 if not exists(select 1 from public.incident_units u where u.incident_id=p_incident and private.field_unit_visible(auth.uid(),p_org,u.id))
  then return null;end if;
 begin return private.incident_field_scope(p_org,p_incident);
 exception when insufficient_privilege then return null;
 when raise_exception then if sqlerrm='SNAPSHOT_TOO_LARGE' then return null;end if;raise;
 end;
end;$field_hint$;
alter function private.vehicle_location_field_fingerprint(uuid,uuid) owner to postgres;
revoke all on function private.vehicle_location_field_fingerprint(uuid,uuid) from public,anon,authenticated,service_role;

create function public.vehicle_location_context(p_actor uuid,p_epoch uuid,p_org uuid,p_incident uuid) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $context$
declare p private.vehicle_location_policies;v_head jsonb;v_units jsonb;
begin
 perform private.vehicle_location_actor(p_actor,p_epoch);
 v_head:=public.incident_sync_head(p_org,p_incident);
 if v_head is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 p:=private.vehicle_location_policy(p_org);
 select coalesce(jsonb_agg(q.value order by q.id),'[]') into v_units from (
  select d.id,jsonb_build_object('deployment',d.id,'vehicle',v.id,'label',v.callsign,'authorityEpisode',c.id) value
  from public.incident_units d join public.incidents i on i.id=d.incident_id and i.status='ACTIVE'
  join public.incident_participants ip on ip.id=d.participation_id and ip.incident_id=i.id and ip.organization_id=p_org and ip.status='ACTIVE'
  join public.operational_units u on u.id=d.unit_id and u.organization_id=p_org and u.active
  join public.operational_vehicles v on v.id=u.vehicle_id and v.organization_id=p_org and v.active and v.availability='AVAILABLE'
  join public.incident_crew_members c on c.unit_assignment_id=d.id and c.user_id=p_actor and c.status='ACTIVE' and c.crew_role='DRIVER'
   and c.membership_organization_id=p_org and c.incident_id=i.id
  where d.incident_id=p_incident and d.organization_id=p_org and d.status not in ('RELEASED','UNAVAILABLE')
   and not exists(select 1 from public.simulation_scenarios z where z.incident_id=i.id) order by d.id limit 100
 )q;
 return jsonb_build_object('account',p_actor,'organization',p_org,'incident',p_incident,'fingerprint',v_head->>'scope_fingerprint','fieldFingerprint',private.vehicle_location_field_fingerprint(p_org,p_incident),
  'policy',jsonb_build_object('id',p.id,'version',p.version,'notice',p.notice,'noticeHash',p.document_sha256,
   'audience',p.audience,'audienceHash',p.audience_sha256,'recoveryEpoch',p.recovery_epoch),'vehicles',v_units,'serverTime',clock_timestamp());
end;$context$;

-- Snapshot preparation is not acceptance. Edge verifies the sample, then calls
-- commit which repeats all live gates under the same lock order.
create function public.vehicle_location_sample(p_actor uuid,p_epoch uuid,p_org uuid,p_incident uuid,p_sample jsonb,p_hash text,p_commit boolean)
returns jsonb language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $sample$
declare s private.vehicle_location_sessions;b private.vehicle_location_bindings;k private.vehicle_device_credentials;
 p private.vehicle_location_policies;v_now timestamptz;v_observed timestamptz;v_seq bigint;v_ack jsonb;v_id uuid;v_digest bytea;v_receipt private.vehicle_location_sample_receipts;v_previous private.vehicle_latest_positions;v_distance double precision;v_seconds double precision;
begin
 perform private.vehicle_location_actor(p_actor,p_epoch);
 if jsonb_typeof(p_sample) is distinct from 'object' or octet_length(p_sample::text)>4096 or p_hash is null or p_hash !~ '^[0-9a-f]{64}$'
  then raise exception 'VALIDATION_FAILED';end if;
 perform private.incident_sync_lock(p_org,p_incident);p:=private.vehicle_location_policy(p_org);
 select * into s from private.vehicle_location_sessions x where x.id=(p_sample->>'sessionId')::uuid and x.actor_user_id=p_actor
  and x.organization_id=p_org and x.incident_id=p_incident;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 b:=private.vehicle_location_live(p_actor,p_org,p_incident,s.binding_id);
 select * into k from private.vehicle_device_credentials x where x.credential_id=s.credential_id for update;
 select * into s from private.vehicle_location_sessions x where x.id=s.id for update;
 v_now:=clock_timestamp();
 if s.state<>'SHARING' or s.lease_expires_at<=v_now or s.maximum_expires_at<=v_now
  or s.binding_generation<>b.generation or s.credential_generation<>k.generation
  or exists(select 1 from private.vehicle_location_consents x where x.id=s.consent_id and x.withdrawn_at is not null)
  then raise exception 'SESSION_EXPIRED';end if;
 if p_sample->>'account' is distinct from p_actor::text or p_sample->>'organization' is distinct from p_org::text
  or p_sample->>'incident' is distinct from p_incident::text or p_sample->>'deployment' is distinct from s.deployment_id::text
  or p_sample->>'vehicle' is distinct from s.vehicle_id::text or p_sample->>'credentialId' is distinct from s.credential_id::text
  or p_sample->>'generation' is distinct from s.credential_generation::text or p_sample->>'bindingGeneration' is distinct from s.binding_generation::text
  or p_sample->>'policyVersion' is distinct from p.version or p_sample->>'sessionContext' is distinct from s.session_context
  or p_sample->>'source' is distinct from 'ANDROID_REAL_GNSS' then raise exception 'SCOPE_CHANGED';end if;
 v_id:=(p_sample->>'sampleId')::uuid;v_seq:=(p_sample->>'sequence')::bigint;
 v_digest:=substring(sha256(convert_to('GASILKO-REAL-VEHICLE-SAMPLE-ID-V1'||chr(10)||s.id::text||chr(10)||v_seq::text||chr(10),'UTF8')) from 1 for 16);
 v_digest:=set_byte(v_digest,6,(get_byte(v_digest,6)&15)|128);
 v_digest:=set_byte(v_digest,8,(get_byte(v_digest,8)&63)|128);
 if v_id is distinct from encode(v_digest,'hex')::uuid then raise exception 'OPERATION_REUSED';end if;
 select * into v_receipt from private.vehicle_location_sample_receipts x where x.operation_id=v_id;
 if found then
  if v_receipt.session_id<>s.id or v_receipt.sequence<>v_seq or v_receipt.request_sha256<>p_hash then raise exception 'OPERATION_REUSED';end if;
  return jsonb_build_object('ack',v_receipt.result);
 end if;
 if s.last_sample_id=v_id then
  if s.last_sample_hash is distinct from p_hash then raise exception 'OPERATION_REUSED';end if;
  return jsonb_build_object('ack',s.last_sample_ack);
 end if;
 if v_seq<=s.accepted_sequence or v_seq<=0 then raise exception 'OPERATION_REUSED';end if;
 v_observed:=to_timestamp((p_sample->>'observedAtMillis')::bigint/1000.0);
 if (p_sample->>'latitudeE7')::bigint not between -900000000 and 900000000
  or (p_sample->>'longitudeE7')::bigint not between -1800000000 and 1800000000
  or (p_sample->>'accuracyCm')::integer not between 1 and p.accuracy_cm
  or v_observed>v_now+make_interval(secs=>p.future_skew_seconds)
  or v_observed<v_now-make_interval(secs=>p.observed_lag_seconds)
  or v_observed<=s.last_observed_at then raise exception 'INVALID_LOCATION';end if;
 select * into v_previous from private.vehicle_latest_positions x where x.session_id=s.id for update;
 if found and v_observed>v_previous.observed_at then
  v_seconds:=extract(epoch from v_observed-v_previous.observed_at);
  v_distance:=12742000*asin(sqrt(least(1.0,
   power(sin(radians(((p_sample->>'latitudeE7')::double precision-v_previous.latitude_e7)/1e7)/2),2)
   +cos(radians(v_previous.latitude_e7/1e7))*cos(radians((p_sample->>'latitudeE7')::double precision/1e7))
   *power(sin(radians(((p_sample->>'longitudeE7')::double precision-v_previous.longitude_e7)/1e7)/2),2))));
  if v_distance>(p.maximum_speed_mps*v_seconds)+(v_previous.accuracy_cm+(p_sample->>'accuracyCm')::integer)/100.0
   then raise exception 'INVALID_LOCATION';end if;
 end if;
 if s.last_sample_at is not null and s.last_sample_at>v_now-make_interval(secs=>p.interval_seconds)
  then raise exception 'RATE_LIMITED';end if;
 if not p_commit then return jsonb_build_object('spki',encode(k.public_key_spki_der,'hex'),'sequence',s.accepted_sequence::text);end if;
 -- p_commit is reachable only with service-only EXECUTE after Edge crypto.
 -- It is NEVER copied from the public request schema.
 v_ack:=jsonb_build_object('session',s.id,'sampleId',v_id,'sequence',v_seq::text,'receivedAt',v_now);
 insert into private.vehicle_location_sample_receipts(operation_id,session_id,sequence,request_sha256,result,expires_at)
  values(v_id,s.id,v_seq,p_hash,v_ack,s.maximum_expires_at+make_interval(secs=>p.position_seconds));
 update private.vehicle_location_sessions x set accepted_sequence=v_seq,last_observed_at=v_observed,last_sample_at=v_now,
  last_sample_id=v_id,last_sample_hash=p_hash,last_sample_ack=v_ack where x.id=s.id;
 insert into private.vehicle_latest_positions(vehicle_id,session_id,organization_id,incident_id,deployment_id,sample_id,sample_sequence,
  observed_at,received_at,expires_at,latitude_e7,longitude_e7,accuracy_cm,source)
 values(s.vehicle_id,s.id,p_org,p_incident,s.deployment_id,v_id,v_seq,v_observed,v_now,
  least(v_observed+make_interval(secs=>p.position_seconds),v_now+make_interval(secs=>p.position_seconds)),
  (p_sample->>'latitudeE7')::integer,(p_sample->>'longitudeE7')::integer,(p_sample->>'accuracyCm')::integer,'ANDROID_REAL_GNSS')
 on conflict(vehicle_id) do update set session_id=excluded.session_id,organization_id=excluded.organization_id,incident_id=excluded.incident_id,
  deployment_id=excluded.deployment_id,sample_id=excluded.sample_id,sample_sequence=excluded.sample_sequence,observed_at=excluded.observed_at,
  received_at=excluded.received_at,expires_at=excluded.expires_at,latitude_e7=excluded.latitude_e7,longitude_e7=excluded.longitude_e7,
  accuracy_cm=excluded.accuracy_cm,source=excluded.source;
 return jsonb_build_object('ack',v_ack);
end;$sample$;

create function public.vehicle_location_positions(p_actor uuid,p_epoch uuid,p_org uuid,p_incident uuid) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $positions$
declare p private.vehicle_location_policies;v_head jsonb;v_rows jsonb;v_now timestamptz:=clock_timestamp();
begin
 perform private.vehicle_location_actor(p_actor,p_epoch);
 v_head:=public.incident_sync_head(p_org,p_incident);
 p:=private.vehicle_location_policy(p_org);
 v_now:=clock_timestamp();
 if v_head is null or exists(select 1 from public.simulation_scenarios x where x.incident_id=p_incident)
  then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 -- Explicit owner-approved per-deployment precise audience AND current required
 -- role; ordinary COP membership/field visibility alone is insufficient.
 if not exists(select 1 from private.vehicle_location_readers g where g.actor_user_id=p_actor and g.organization_id=p_org
  and g.incident_id=p_incident and g.policy_id=p.id and g.active and (
   (g.required_role='DRIVER' and exists(select 1 from public.incident_crew_members c where c.unit_assignment_id=g.deployment_id
    and c.incident_id=p_incident and c.user_id=p_actor and c.membership_organization_id=p_org and c.status='ACTIVE' and c.crew_role='DRIVER'))
   or exists(select 1 from public.incident_role_assignments r where r.incident_id=p_incident and r.organization_id=p_org
    and r.user_id=p_actor and r.role=g.required_role and (r.unit_assignment_id is null or r.unit_assignment_id=g.deployment_id)
    and (r.sector_id is null or r.sector_id=(select d.sector_id from public.incident_units d where d.id=g.deployment_id))
    and private.incident_assignment_effective(r.id))))
  then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select coalesce(jsonb_agg(q.value order by q.vehicle),'[]') into v_rows from (
 select v.id vehicle,jsonb_build_object('vehicle',v.id,'deployment',d.id,'session',s.id,'label',v.callsign,
  'latitudeE7',x.latitude_e7,'longitudeE7',x.longitude_e7,'accuracyCm',x.accuracy_cm,
  'observedAt',x.observed_at,'receivedAt',x.received_at,'expiresAt',x.expires_at,
  'validUntil',least(v_now+interval '15 seconds',s.lease_expires_at,x.expires_at,
    (select r.cleanup_at+make_interval(secs=>p.cleanup_sla_seconds) from private.vehicle_location_readiness r where r.organization_id=p_org)),
  'source',x.source,'freshness',case when v_now-x.observed_at<interval '120 seconds' then 'CURRENT' else 'LAST_KNOWN' end) value
 from private.vehicle_latest_positions x join private.vehicle_location_sessions s on s.id=x.session_id and s.state='SHARING'
  and s.lease_expires_at>v_now and s.maximum_expires_at>v_now and s.policy_id=p.id
 join private.vehicle_location_bindings b on b.id=s.binding_id and b.state='INACTIVE' and b.generation=s.binding_generation
 join private.vehicle_device_credentials k on k.credential_id=s.credential_id and k.lifecycle_status='INACTIVE' and k.generation=s.credential_generation
 join private.vehicle_location_device_trust kt on kt.credential_id=k.credential_id and kt.public_key_sha256=k.public_key_sha256
  and kt.active and kt.expires_at>v_now
 join private.vehicle_location_consents co on co.id=s.consent_id and co.policy_id=p.id and co.withdrawn_at is null
 join public.incidents i on i.id=s.incident_id and i.status='ACTIVE'
 join public.incident_units d on d.id=s.deployment_id and d.incident_id=i.id and d.organization_id=p_org and d.status not in ('RELEASED','UNAVAILABLE')
 join public.incident_participants ip on ip.id=d.participation_id and ip.incident_id=i.id and ip.organization_id=p_org and ip.status='ACTIVE'
 join public.operational_units u on u.id=d.unit_id and u.organization_id=p_org and u.active and u.vehicle_id=s.vehicle_id
 join public.operational_vehicles v on v.id=s.vehicle_id and v.organization_id=p_org and v.active and v.availability='AVAILABLE'
 join public.incident_crew_members c on c.id=s.authority_episode_id and c.unit_assignment_id=d.id and c.user_id=s.actor_user_id
  and c.membership_organization_id=p_org and c.incident_id=i.id and c.crew_role='DRIVER' and c.status='ACTIVE'
 join public.profiles pr on pr.id=s.actor_user_id and pr.account_status='ACTIVE'
 join public.user_organizations m on m.user_id=s.actor_user_id and m.organization_id=p_org
 join private.vehicle_location_readers g on g.actor_user_id=p_actor and g.organization_id=p_org and g.incident_id=i.id
  and g.deployment_id=d.id and g.policy_id=p.id and g.active
 where x.organization_id=p_org and x.incident_id=p_incident and x.expires_at>v_now and x.accuracy_cm<=p.accuracy_cm
  and x.observed_at<=v_now and v_now-x.observed_at<interval '900 seconds'
  and (p.allow_stale or v_now-x.observed_at<interval '120 seconds')
  and ((g.required_role='DRIVER' and exists(select 1 from public.incident_crew_members rc where rc.unit_assignment_id=d.id
   and rc.user_id=p_actor and rc.membership_organization_id=p_org and rc.status='ACTIVE' and rc.crew_role='DRIVER'))
   or exists(select 1 from public.incident_role_assignments r where r.incident_id=i.id and r.organization_id=p_org
    and r.user_id=p_actor and r.role=g.required_role and (r.unit_assignment_id is null or r.unit_assignment_id=d.id)
    and (r.sector_id is null or r.sector_id=d.sector_id)
    and private.incident_assignment_effective(r.id)))
 order by v.id limit 100
 )q;
 return jsonb_build_object('account',p_actor,'organization',p_org,'incident',p_incident,'fingerprint',v_head->>'scope_fingerprint',
  'fieldFingerprint',private.vehicle_location_field_fingerprint(p_org,p_incident),'serverTime',v_now,'positions',v_rows,'limit',100);
end;$positions$;

-- Compatible C2 shape; OFF until every independently owner-controlled gate passes.
create or replace function public.incident_vehicle_location_capabilities(p_acting_organization_id uuid,p_incident_id uuid) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $capability$
declare h jsonb;p private.vehicle_location_policies;v_ready boolean:=false;v_mode text;
begin
 h:=public.incident_sync_head(p_acting_organization_id,p_incident_id);
 if h is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 v_mode:=case when exists(select 1 from public.simulation_scenarios x where x.incident_id=p_incident_id) then 'TRAINING' else 'REAL' end;
 if v_mode='REAL' then
  begin p:=private.vehicle_location_policy(p_acting_organization_id);v_ready:=true;
  exception when raise_exception then v_ready:=false;end;
 end if;
 return jsonb_build_object('schema_version',1,'account',auth.uid(),'organization',p_acting_organization_id,'incident_id',p_incident_id,
  'scope_fingerprint',h->>'scope_fingerprint','mode',v_mode,'state',case when v_ready then 'AVAILABLE' else 'DISABLED' end,
  'enabled',v_ready,'producer_available',v_ready,'reader_available',v_ready,'policy_approved',v_ready,'retention_ready',v_ready,'device_binding_ready',v_ready);
end;$capability$;

alter function private.vehicle_location_actor(uuid,uuid) owner to postgres;
alter function private.vehicle_location_policy(uuid) owner to postgres;
alter function private.vehicle_location_live(uuid,uuid,uuid,uuid) owner to postgres;
alter function private.vehicle_location_cleanup() owner to postgres;
alter function public.vehicle_location_control(uuid,uuid,text,uuid,uuid,uuid,jsonb) owner to postgres;
alter function public.vehicle_location_context(uuid,uuid,uuid,uuid) owner to postgres;
alter function public.vehicle_location_sample(uuid,uuid,uuid,uuid,jsonb,text,boolean) owner to postgres;
alter function public.vehicle_location_positions(uuid,uuid,uuid,uuid) owner to postgres;
revoke all on function private.vehicle_location_actor(uuid,uuid),private.vehicle_location_policy(uuid),
 private.vehicle_location_live(uuid,uuid,uuid,uuid),private.vehicle_location_cleanup(),
 public.vehicle_location_control(uuid,uuid,text,uuid,uuid,uuid,jsonb),public.vehicle_location_context(uuid,uuid,uuid,uuid),
 public.vehicle_location_sample(uuid,uuid,uuid,uuid,jsonb,text,boolean),public.vehicle_location_positions(uuid,uuid,uuid,uuid)
 from public,anon,authenticated,service_role;
grant execute on function public.vehicle_location_control(uuid,uuid,text,uuid,uuid,uuid,jsonb),
 public.vehicle_location_context(uuid,uuid,uuid,uuid),public.vehicle_location_sample(uuid,uuid,uuid,uuid,jsonb,text,boolean),
 public.vehicle_location_positions(uuid,uuid,uuid,uuid) to service_role;
-- Capability retains its existing authenticated-only grant from C2.
create function public.vehicle_location_budget(p_actor uuid,p_epoch uuid,p_org uuid,p_incident uuid) returns void
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $budget$
begin
 perform private.vehicle_location_actor(p_actor,p_epoch);
 perform private.vehicle_location_rate(p_actor,p_org);
 -- Reachability evidence only, never policy approval/activation. It expires.
 update private.vehicle_location_readiness r set edge_epoch=p_epoch,edge_seen_at=clock_timestamp()
 where r.organization_id=p_org and exists(select 1 from private.vehicle_location_policies p
  where p.organization_id=p_org and p.status='APPROVED' and p.expires_at>clock_timestamp() and p.recovery_epoch=p_epoch);
end;$budget$;
alter function public.vehicle_location_budget(uuid,uuid,uuid,uuid) owner to postgres;
revoke all on function public.vehicle_location_budget(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.vehicle_location_budget(uuid,uuid,uuid,uuid) to service_role;

commit;
