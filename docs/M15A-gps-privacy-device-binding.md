# M15A — GPS privacy and secure vehicle-phone device binding

**Date: 2026-11-03. Status: DESIGN FOUNDATION; ALL PRIVACY DECISIONS UNAPPROVED.**
**GPS PERMANENTLY DISABLED IN THIS MILESTONE. NO ENROLLMENT, PAIRING OR GPS EXECUTION.**

## 1. Deliverable, baseline and dependency

This PR adds this implementable design/decision record and one factual M14 SPEC
note only. No production code, schema, API, credential, key, consent, permission,
service, worker, queue, position source or viewer is added. PR #92 already supplies
the safe localized disabled-state check; duplicating it or shipping unused
cryptographic helpers would add an unreviewed second contract.

Verified GitHub baseline: `20f3517c081d983e3b774950a028a4e2433666a1`.
PR #92 is CLOSED **and merged**, not merely present as files:
head `3f0966047fd28f4e29a1400978a0ec51595ffe68`,
merge `20f3517c081d983e3b774950a028a4e2433666a1`.
GitHub comparison head→main: ahead1, behind0; merge is the selected main HEAD.
No overlapping open PRs at initial inspection. Later corrections belong to this
one new PR, not historical #92. No merge/rollout is performed.

Local read-only inspection: workspace root contains `review-20261028` review
artifacts; that directory is not a Git repository. No attached checkout/dirty
status is available, so no claim of a clean developer checkout. Existing
docs/helpers/updated/saved review files are untouched. Work uses GitHub source
at the pinned commit; no local files are created or edited.

Read AGENTS.md, primary SPEC, M14 §7/13 and C2/C3/C1/B1/B2/D1/D2/unit-leadership/
M10-NAV docs, root C2/NAV references, SPECS gates/C2/queue and actual boundaries
listed below. SPECS queue is a planning snapshot, not merge/deployment proof.
Owner's explicit no-tests/no-execution rules override AGENTS' usual test/build/
SQL validation for this task; release validation is still outstanding.

**Implementation now ≠ protocol design ≠ policy approval ≠ deployment ≠
human acceptance ≠ operational release.**

## 2. As-found matrix — actual contracts, not proposed names

| Boundary | Verified current signature/columns/authority | Evidence / actual gap |
|---|---|---|
| Canonical vehicle | public.operational_vehicles(id UUID PK,organization_id,callsign,name,category_code,active,availability,version); UNIQUE(id,organization_id) | [supabase/migrations/20261007100000_operational_inventory_schema.sql:9](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/supabase/migrations/20261007100000_operational_inventory_schema.sql#L9); no phone/key/GPS fields |
| Inventory unit | operational_units(id,organization_id,unit_kind,vehicle_id,active,version); (vehicle_id,organization_id) FK→operational_vehicles(id,organization_id) | same inventory migration; vehicle is optional, not every unit is a vehicle |
| Incident deployment | incident_units(id,incident_id,participation_id,organization_id,unit_id,status,version,changed_revision); UNIQUE(id,incident_id,organization_id), same-org unit and participant FKs | same inventory migration; this deployment UUID is not inventory-unit UUID |
| Driver episode | incident_crew_members(id,incident_id,unit_assignment_id,user_id,membership_organization_id,crew_role,status,version); roles LEADER/DRIVER/RESPONDER/SPECIALIST; same-deployment/incident/org FK | [supabase/migrations/20261007100000_operational_inventory_schema.sql:36](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/supabase/migrations/20261007100000_operational_inventory_schema.sql#L36); ACTIVE DRIVER exists, but is not consent |
| Effective unit leader | private.field_unit_leader(p_person uuid,p_org uuid,p_unit uuid) RETURNS boolean; private.incident_assignment_effective(p_assignment uuid) RETURNS boolean | 20261027100000 + 20261007102000; current effective UNIT_LEADER, not merely a role string |
| Field visibility | private.field_unit_visible(p_person uuid,p_org uuid,p_unit uuid) RETURNS boolean | [supabase/migrations/20261027100000_incident_android_field_pilot.sql:8](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/supabase/migrations/20261027100000_incident_android_field_pilot.sql#L8); exact org and active crew/effective leader, not precise GPS permission |
| Canonical membership | private.incident_acting_member(p_org uuid) RETURNS boolean; private.is_active_user(); private.can_read_incident(uuid) | 20261006120000 + B1; organization/profile/participation checked live |
| Existing resource commands | incident_deploy_unit, incident_update_unit_status, incident_add_crew_member, incident_remove_crew_member share (p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) RETURNS jsonb | 20261007103000; current actor, exact request, incident/entity versions; no binding command |
| Lock/receipt pattern | private.incident_resource_command(text,uuid,uuid,uuid,bigint,jsonb); operation advisory lock, sorted organization locks, sorted profiles, incident row | [supabase/migrations/20261007103000_incident_resource_commands.sql:106](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/supabase/migrations/20261007103000_incident_resource_commands.sql#L106); reuse pattern in a future implementation, not a second command engine |
| Immutable receipts | private.incident_operation_receipts(operation_id PK,actor_user_id,acting_organization_id,incident_id,command_code,request jsonb≤65536bytes,result,created_at); immutable update/delete/truncate guards | [supabase/migrations/20261006120000_incident_core.sql:2](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/supabase/migrations/20261006120000_incident_core.sql#L2); command_code is text, no existing binding code/RPC |
| Device notifications | private.notification_devices(installation PK,user_id,token,active,revision,created_at,updated_at); public.register_notification_device(installation uuid,token text,enabled boolean=true) RETURNS void | [supabase/migrations/20261005140000_notifications.sql:69](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/supabase/migrations/20261005140000_notifications.sql#L69); caller-supplied installation; conflict can rebind user_id. NOT hardware identity or signing possession |
| Auth security | KeystoreSessionManager uses AndroidKeyStore AES/GCM alias gasilko_auth_v1; SDK session/PKCE/org authorization/incident lease, not asymmetric enrollment | [android/app/src/main/java/si/gasilko/app/core/auth/KeystoreSessionManager.kt:26](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/android/app/src/main/java/si/gasilko/app/core/auth/KeystoreSessionManager.kt#L26); cannot derive a server-verifiable device public key from this AES key |
| JWT/API | web/app/api/incidents/route.ts same-origin POST, ACTIVE account, optional X-Gasilko-Account matched through auth.getUser, allowlisted RPC | existing Supabase JWT is authentication, not device proof; no new JWT or client service-role path |
| Lightweight scope | public.incident_sync_head(p_acting_organization_id uuid,p_incident_id uuid) RETURNS jsonb; private.incident_sync_lock(uuid,uuid) | [supabase/migrations/20261030100000_incident_snapshot_protocol.sql:400](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/supabase/migrations/20261030100000_incident_snapshot_protocol.sql#L400); existing salted authorization fingerprint, not a GPS audience grant |
| Actual OFF capability | public.incident_vehicle_location_capabilities(p_acting_organization_id uuid,p_incident_id uuid) RETURNS jsonb | [supabase/migrations/20261102140000_incident_vehicle_location_capability.sql:4](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/supabase/migrations/20261102140000_incident_vehicle_location_capability.sql#L4); schema1, DISABLED; enabled/producer_available/reader_available/policy_approved/retention_ready/device_binding_ready all false; no ON switch |
| Android OFF flow | VehicleLocationCheck DISABLED/UNAVAILABLE; VEHICLE_LOCATION_PRODUCER_ENABLED=false; exact response decoder; ViewModel→IncidentRepository.vehicleLocationCapability(org,incident) | [android/app/src/main/java/si/gasilko/app/feature/incidents/VehicleLocationCapability.kt:7](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/android/app/src/main/java/si/gasilko/app/feature/incidents/VehicleLocationCapability.kt#L7); [android/app/src/main/java/si/gasilko/app/feature/incidents/IncidentRepository.kt:115](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/android/app/src/main/java/si/gasilko/app/feature/incidents/IncidentRepository.kt#L115);5s optional read, selected account/org + secure field lease before/after; no cache/cursor/queue write or revokeIncident on optional failure |
| Android map/capability UI | VehicleLocationCapabilityUi.kt keyed model/incident/B1 scope; IncidentMapScreen Units dialog; RealUnitPosition null-only | no enrollment/permission/start action; default/Sl/De existing OFF explanations retained |
| Web OFF flow | vehicleLocationProducerEnabled=false; isDisabledVehicleCapability(unknown,scope,fingerprint); VehicleLocationCapability.tsx / IncidentCop / RealUnitPosition | [web/lib/incidents/vehicleLocationCapability.ts:2](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/web/lib/incidents/vehicleLocationCapability.ts#L2); exact keys/booleans + current identity/Web head; keyed cancellation, manual read only,5s abort, no polling or storage |
| SDK/platform | Android minSdk26, compileSdk36,targetSdk36; Manifest existing COARSE/FINE and notifications, no location FGS/background location | app/build.gradle.kts, AndroidManifest.xml; no dependency or manifest change here |
| Local GPS | foregroundLocations(context:Context,navigation:Boolean=false) uses LocationManager callbacks, screen lifecycle and elapsed-time freshness | [android/app/src/main/java/si/gasilko/app/feature/map/ForegroundLocation.kt:28](https://github.com/ficlus/Gasilko/blob/20f3517c081d983e3b774950a028a4e2433666a1/android/app/src/main/java/si/gasilko/app/feature/map/ForegroundLocation.kt#L28); own-location display/navigation only; no incident-unit upload |
| Room/sync | RegistryDatabase version16, IncidentFieldCache/IncidentSyncCursor + original pending dispatch; same HydrantSyncWorker | Room/cursor/schema unchanged; field≤24h lease/2h warning, registry≤30days separate |
| REAL/SIM/NAV | simulation_unit_positions.source CHECK SIMULATED; navigation_input rejects ACTUAL_POSITION with NAV_POSITION_UNAVAILABLE | 20261009140000 + 20261012100000; targets, route origins, center, blue dot, SIM are NOT observations |
| Retention infrastructure | B1 demand-driven pruning, M10 on-claim delivery cleanup, optional separate SIM scheduling | no source-verified approved no-traffic GPS deletion contract; do not assume an external job exists |
| Deployment | owner reports #86 42601/partial-install uncertainty, #87–92 installation unconfirmed | report only, not reproduced/queried. GitHub merge does not prove SQL/Edge/Web/Android installation |

Other inspected source boundaries: IncidentViewModel.kt, IncidentMapScreen.kt,
RegistryDatabase.kt, Notifications.kt, ForegroundLocation.kt, IncidentCop.tsx,
VehicleLocationCapability.tsx, RealUnitPosition.tsx, IncidentLiveProvider.tsx,
web/app/api/incidents/route.ts, supabase/config.toml. No new RPC is added to
the Web allowlist or Android repository in M15A.

## 3. Implement now / design only / blocked

| Item | M15A disposition |
|---|---|
| This decision sheet, threat model, exact wire/transaction/schema proposal, acceptance guide | IMPLEMENTED documentation |
| Existing #92 server/client false gates, localized explanation and cancellation | REUSED UNCHANGED; no duplicate OFF card or local consent-approved flag |
| Key generation, enrollment challenge/verification/credential tables/RPCs | DESIGN ONLY — UNIMPLEMENTED |
| Consent/lease/STOP/LEAVE/rotation, physical cleanup and backup recovery | DESIGN ONLY — UNIMPLEMENTED |
| GPS acquisition/upload/current-position table/source/marker/trails | BLOCKED_BY_POLICY and outside M15A |
| New inert schema | NONE: storing credentials/challenges now would create operational surface and retention burden without approved purpose |
| New production pure helper/types | NONE: #92 already models only disabled states; protocol is not prematurely executable |
| M15B / M15C | Suggested future milestones below, not authorized or started |

## 4. Owner decision sheet — all UNAPPROVED

Each approval needs named accountable owner, dated decision, exact document hash/
version, scope, expiry/review date and evidence reference. Blank is denial.
Draft wording, a local checkbox, a merged PR, OS permission or a policy row alone
cannot approve or activate a producer. This document records no legal conclusion.

| ID | Decision to record | Draft candidate / unresolved choice | Status |
|---|---|---|---|
| P01 | Purpose, lawful basis, controller, notice wording/version | Locate voluntarily shared deployed vehicle for this incident; controller/legal basis/notice not selected | UNAPPROVED |
| P02 | Authorized starter | Candidate current assigned DRIVER; effective-leader fallback UNDECIDED; ordinary manager/crew not implied | UNAPPROVED |
| P03 | Eligible asset, unit, crew and lifecycle | Candidate genuine active AVAILABLE same-org vehicle + live VEHICLE_CREW deployment + ACTIVE REAL incident only; STABILIZED/terminal policy unresolved | UNAPPROVED |
| P04 | Precise-reader audience / cross-org | Default DENY all precise reads until policy; cross-org default DENY. Any IC/agency/leader/own-driver audience must be separately approved, not inferred from callsign visibility | UNAPPROVED |
| P05 | Sharing lease/renewal/offline/OS rules | Finite server lease; duration/renewal/locked-screen policy undecided; no covert restart | UNAPPROVED |
| P06 | STOP/LEAVE and disconnected withdrawal | Immediate local stop; server withdrawal only after communication or finite lease expiry; this unavoidable offline risk must be disclosed | UNAPPROVED |
| P07 | Driver handover/competing phone | Candidate fail closed on second claim; no automatic takeover; exact replacement authority/confirmation undecided | UNAPPROVED |
| P08 | Rate/accuracy/spoof/time validation | Existing design10s+10m is a candidate, stationary heartbeat/accuracy ceiling/jump rules undecided; signed fixes are not proof of truth | UNAPPROVED |
| P09 | Latest point vs history | Candidate latest-only; no path/trail, speed/performance monitoring or historical fleet read | UNAPPROVED |
| P10 | Freshness/expiry |120s stale and900s expiry are existing design defaults, not consent, legal retention or guaranteed deletion | UNAPPROVED |
| P11 | Physical deletion, SLA, backups/PITR | Independent owner-approved maintenance, capacity/SLA/alerts and restoration quarantine required; no new job authorized | UNAPPROVED |
| P12 | Logs/access audit/rights requests | No coordinates/keys/signatures in routine logs; exact metadata evidence/access-audit and subject-request procedure undecided | UNAPPROVED |
| P13 | Consent/revocation evidence | Immutable policy hash, actor/context/operation, event times and withdrawal evidence; protected metadata retention duration undecided | UNAPPROVED |
| P14 | Rollout/real-vs-training acceptance | Named sign-off, controlled REAL fixture method, release/backout; never enroll SIM as real GPS | UNAPPROVED |

Additional security decision **A01 UNAPPROVED**: is proof of possession alone
sufficient, or is verified hardware/app attestation required? Select supported
devices, security level, patch/root/revocation policy and outage behavior.
No fallback may silently downgrade assurance. Any required gate not satisfied
keeps enrollment/source disabled.

### Draft notice concepts, not a displayed consent or approved policy

Sl/default draft: »Telefon bi bil povezan z izbranim vozilom in intervencijo.
Deljenje se začne šele po izrecnem začetku in odobreni politiki. Trenutni položaj
vidijo samo posebej dovoljene osebe. Zapustil sem vozilo takoj ustavi zajem na
telefonu; brez povezave strežnik umik prejme pozneje, do takrat velja omejena
strežniška seja. Zgodovine vožnje ne ustvarjamo.«
DE draft: »Das Telefon würde mit dem gewählten Fahrzeug und Einsatz verbunden.
Die Freigabe beginnt erst nach ausdrücklichem Start und genehmigter Richtlinie.
Nur ausdrücklich Berechtigte sehen die aktuelle Position. Fahrzeug verlassen
stoppt die Erfassung am Telefon sofort; offline erreicht der Widerruf den Server
später, bis dahin begrenzt die Server-Lease das Risiko. Kein Fahrtenverlauf.«
These conditional drafts need actual audience, lease, deletion/backup limits and
approved notice version before use. They are not current product assurances.

## 5. Future protocol v1 — UNIMPLEMENTED

The proposed protocol proves possession of a signing key bound to a narrow
context. It does NOT prove phone hardware, physical driver presence, genuine
GNSS coordinates, operational command authority or consent. TLS, valid current
auth and current server membership/role/policy checks remain independent.

### 5.1 Key and authentication boundaries

Candidate algorithm: nonexportable AndroidKeyStore EC P-256 signing key, generated
only from a future visible, explicitly initiated enrollment ceremony after the
binding privacy gate. Use KeyPairGenerator EC/AndroidKeyStore,
KeyGenParameterSpec PURPOSE_SIGN, ECGenParameterSpec("secp256r1"), SHA-256;
sign message bytes with Signature("SHA256withECDSA"). No AES-key reuse.
Create a fresh key per account/org/incident/deployment enrollment; no stable
hardware ID or reusable global phone fingerprint. Alias and operation IDs belong
to the original scope; never rename/relabel a key across accounts.

Android Keystore prevents normal key export but a compromised process may still
use a key. User-authentication requirements/StrongBox support are a reviewed
device-policy decision, not assumed universally available. No key is generated
by this PR. Key attestation, if required, needs a separately designed fresh
server challenge before key generation plus remote certificate-chain, security-
level, application/root/revocation validation. A self-signed public-key certificate
or a client “hardware backed” claim is not attestation. This v1 possession-only
ceremony MUST stay denied if A01 requires attestation; do not bypass by software
fallback.

Proposed verifier is a **new future** trusted Edge component, not any current
worker or incident endpoint. It authenticates the bearer with the configured
Supabase project (getUser(token) as a candidate), rejects wrong issuer/project/
audience/expiry, and derives actor UUID from verified auth, never request JSON.
JWT cryptographic validity alone does not establish instantaneous session
revocation or current role. A live-session/revocation assurance decision remains
required; unavailable auth verification fails closed. Never use decoded
getSession data, an apikey, FCM token or installation UUID as identity proof.
No Supabase config/SDK/dependency change is made here.

### 5.2 Exact signing bytes and wire encoding

Protocol technical limits below are NEW DESIGN PROPOSALS, not installed settings
or privacy approval: challenge TTL120s,32 random nonce bytes, maximum request16KiB,
SPKI≤256bytes, proof signature64bytes, all version/generation integers decimal
strings without leading zeroes (zero only where expected initial version allows).
Use cryptographically secure server crypto.getRandomValues, not Math.random,
timestamps or caller-provided nonce. Freeze nonce/challenge on first issuance.

Candidate public key transport: unpadded base64url of DER SubjectPublicKeyInfo.
Verifier accepts only EC id-ecPublicKey / namedCurve secp256r1, imports with
WebCrypto ECDSA/P-256 and rejects trailing/invalid/noncanonical encoding. Public
key hash = lowercase hex SHA-256 of the validated original SPKI bytes; do not
hash arbitrary PEM/JWK JSON ordering or silently replace accepted bytes.

Wire signature = unpadded base64url of64 bytes unsigned big-endian r[32]||s[32].
Android SHA256withECDSA output requires strict DER-sequence-to-r/s conversion;
server WebCrypto ECDSA verify uses raw r||s. Check scalar lengths/ranges, reject
negative/overlong/trailing DER on conversion and wrong curve/length on import.
Do not double-hash: sign/verify the exact transcript using SHA-256 once.
All base64url inputs must decode/re-encode identically with no padding or
whitespace; SPKI is PublicKey.getEncoded(), not the entire certificate encoding.
Signature bytes may vary on re-signing: freeze the originally submitted proof;
retry it unchanged. A reviewed implementation/interoperability vectors are needed;
no custom crypto implementation or dependency is shipped now.

Transcript is UTF-8 of the following ordered LF-delimited ASCII lines, including
ONE final LF, no CR, BOM, JSON serialization or whitespace normalization:

```text
GASILKO-VEHICLE-PHONE-BINDING-V1
<audience>
<recovery_epoch_uuid>
BIND_INACTIVE
<actor_uuid>
<acting_organization_uuid>
<incident_uuid>
REAL
<incident_unit_assignment_uuid>
<vehicle_uuid>
<authority_episode_uuid>
DRIVER
<proposed_binding_uuid>
<public_key_sha256_lower_hex>
<policy_version>
<policy_document_sha256_lower_hex>
<precise_audience_policy_sha256_lower_hex>
<issue_operation_uuid>
<confirm_operation_uuid>
<challenge_uuid>
<nonce_base64url>
<issued_at_epoch_seconds>
<expires_at_epoch_seconds>
<expected_incident_version>
<expected_deployment_version>
<expected_vehicle_version>
<reserved_generation>
```

Every UUID is canonical lowercase36-char; hash is64 lowercase hex; nonce is43
base64url chars; policy_version matches [A-Za-z0-9._-]{1,64}. Audience is a
server-configured environment/project-specific ASCII identifier≤128 chars
matching [A-Za-z0-9._:/-]+; never trust a client origin/header to select it.
Epoch seconds are canonical nonnegative UTC seconds set by server; expiry is
issue+120, not a phone clock. Driver authority episode is current canonical
incident_crew_members.id, not user name/phone ID; leader fallback requires a
new reviewed protocol variant, not replacing the DRIVER string opportunistically.
A recovery_epoch is server-controlled outside restored DB state; restore
invalidates old challenges/bindings and leaves gates OFF.

Server owns/validates every transcript field against the authenticated request,
current context and stored challenge. The client checks the returned frozen
context against the visible intended account/org/incident/vehicle before signing.
Unexpected action/audience/key/policy/versions is rejection, not silent correction.
Binding inactive is a separate action from consent, START, STOP, rotation and
sample signing; a BIND signature can never authorize those domains.

### 5.3 Issuance and verification sequence

All steps below are future design; no RPC or Edge verifier is installed.

1. Visible user requests enrollment for one current scoped deployment/vehicle.
   Existing capability remains OFF in M15A, so this cannot run now. Future server
   checks approved enrollment policy and currently authenticated ACTIVE actor,
   exact active organization/participant, REAL ACTIVE incident, active driver
   episode, live deployment, genuine active AVAILABLE same-org vehicle and
   inventory-unit→vehicle mapping. No FCM registration parameter.
2. Client proposes original issue/confirm operation UUIDs and proposed binding
   UUID plus public key and expected canonical versions. Freeze those IDs before
   dispatch. Server derives audience/actor/nonce/generation/policy hashes.
3. Server locks operation and canonical scope in the existing command order
   (sorted organizations/profiles, incident, deployment/inventory/vehicle, then
   new vehicle slot). Recheck authorization/version under lock. A live competing
   claim fails; no automatic takeover or ownership change.
   Issue timestamps are server clock_timestamp truncated to whole UTC seconds;
   expiry=issued_at+120s. The proposed writer assembles the fixed transcript from
   the now-reserved generation and authoritative columns, using PostgreSQL17
   pg_catalog.convert_to(text,'UTF8') and pg_catalog.sha256(bytea); no pgcrypto
   extension is assumed or added. It computes SPKI/nonce hashes from exact
   bytes; curve validation remains the trusted verifier's responsibility.
4. Exact issue replay returns its immutable issue receipt plus the **same**
   still-valid private challenge/nonce. Receipt stores challenge identifiers/
   hash/expiry, not raw nonce. Expired/cancelled replay returns current EXPIRED/
   REVOKED envelope with original receipt; it MUST NOT mint a new nonce or
   extend expiry. A new explicit attempt uses new operation IDs.
5. Only the original scoped client signs the exact bytes after verifying UI
   context. Persist frozen proof metadata securely if a future retry requires
   it; no private key export, coordinate, token or raw nonce in logs.
6. Edge authenticates again and checks original receipt/request first. If already
   committed, return minimal original proof plus current state; do not need an
   erased nonce to repeat a consumed action. Otherwise read the original
   still-ISSUED challenge and verify hash, key,
   audience, action and TTL and the signature using a vetted WebCrypto primitive.
   No database lock is held over this HTTP/auth/crypto phase.
7. Only trusted verifier may call the service-role-only commit RPC. Pass actor
   derived by verifier, original IDs, exact validated proof/transcript hashes.
   A user-controlled signature_verified boolean must never reach a public
   callable writer. DB cannot itself verify this ECDSA using any current repo
   helper; this privileged-verifier trust boundary must be explicitly reviewed.
8. In ONE DB transaction, acquire the same operation/scope/vehicle-slot locks;
   compare original request/receipt, key bytes/hash, stored challenge fields,
   current actor/driver/policy/REAL state and canonical versions AGAIN. Verify
   not consumed/revoked/expired and reserved generation still matches slot.
   Consume challenge, insert BOUND_INACTIVE credential, update slot, append
   bounded no-location binding metadata audit and canonical receipt atomically.
   Failed or rolled-back transaction leaves no usable binding/receipt.
9. Exact successful confirm replay returns the original immutable receipt,
   separately current binding status. A revoked/expired credential is NEVER
   reactivated by receipt replay. Same operation with another proof/request/
   actor/org is OPERATION_REUSED. Another operation cannot consume the challenge.
10. No stage creates consent, SHARING, a sharing lease, coordinate or command.
    BOUND_INACTIVE can only be used later under separately reviewed consent and
    START contracts. Existing #92 producer/readiness flags remain false even
    after hypothetical successful binding.

### 5.4 Proposed schema — UNIMPLEMENTED, NOT A MIGRATION

The following exact suggested DDL is a design for future review, not an
instruction to paste/run SQL. **No migration file contains it.** All new names
below are proposals; existing referenced public table keys were verified above.
It intentionally contains NO latitude/longitude/position, FCM/hardware ID,
active consent, sharing status, operational START/SAMPLE/STOP or GPS history.

```sql
-- DESIGN ONLY. DO NOT APPLY. Policies remain UNAPPROVED in M15A.
create table private.vehicle_phone_policy_versions (
 policy_version text primary key check(policy_version ~ '^[A-Za-z0-9._-]{1,64}$'),
 document_sha256 bytea not null check(octet_length(document_sha256)=32),
 audience_sha256 bytea not null check(octet_length(audience_sha256)=32),
 status text not null default 'DRAFT_UNAPPROVED'
   check(status in ('DRAFT_UNAPPROVED','APPROVED','WITHDRAWN')),
 decisions jsonb not null check(jsonb_typeof(decisions)='object' and octet_length(decisions::text)<=16384),
 created_at timestamptz not null, approved_at timestamptz,
 approved_by uuid references public.profiles(id),
 check((approved_at is null)=(approved_by is null)),
 check(status<>'APPROVED' or approved_at is not null)
);
create table private.vehicle_phone_bindings (
 id uuid primary key,
 actor_user_id uuid not null references public.profiles(id),
 organization_id uuid not null references public.organizations(id),
 incident_id uuid not null references public.incidents(id),
 incident_unit_id uuid not null, vehicle_id uuid not null,
 authority_episode_id uuid not null,
 policy_version text not null references private.vehicle_phone_policy_versions(policy_version),
 recovery_epoch uuid not null,
 public_key_spki bytea not null check(octet_length(public_key_spki) between 1 and 256),
 public_key_sha256 bytea not null unique check(octet_length(public_key_sha256)=32),
 generation bigint not null check(generation>0),
 state text not null check(state in ('BOUND_INACTIVE','REVOKED','EXPIRED')),
 version bigint not null default 1 check(version>0),
 created_at timestamptz not null, expires_at timestamptz not null,
 revoked_at timestamptz, revoke_reason text
   check(revoke_reason in ('USER_STOP','LEFT_VEHICLE','KEY_LOST','ROLE_LOST',
     'SCOPE_LOST','ROTATED','POLICY_WITHDRAWN','RESTORE_QUARANTINE')),
 issue_operation_id uuid not null unique,
 confirm_operation_id uuid not null unique,
 unique(id,vehicle_id,organization_id),
 foreign key(incident_unit_id,incident_id,organization_id)
   references public.incident_units(id,incident_id,organization_id),
 foreign key(vehicle_id,organization_id)
   references public.operational_vehicles(id,organization_id),
 foreign key(authority_episode_id,incident_id)
   references public.incident_crew_members(id,incident_id),
 check(expires_at>created_at),
 check((state='REVOKED')=(revoked_at is not null)),
 check((revoked_at is null)=(revoke_reason is null))
);
create unique index vehicle_phone_one_bound_deployment
 on private.vehicle_phone_bindings(incident_unit_id) where state='BOUND_INACTIVE';
create unique index vehicle_phone_one_bound_vehicle
 on private.vehicle_phone_bindings(vehicle_id) where state='BOUND_INACTIVE';
create unique index vehicle_phone_one_bound_actor
 on private.vehicle_phone_bindings(actor_user_id) where state='BOUND_INACTIVE';
create index vehicle_phone_binding_scope
 on private.vehicle_phone_bindings(actor_user_id,organization_id,incident_id,state);
create index vehicle_phone_binding_expiry
 on private.vehicle_phone_bindings(expires_at) where state='BOUND_INACTIVE';

create table private.vehicle_phone_challenges (
 id uuid primary key, issue_operation_id uuid not null unique,
 confirm_operation_id uuid not null unique, proposed_binding_id uuid not null unique,
 actor_user_id uuid not null references public.profiles(id),
 organization_id uuid not null references public.organizations(id),
 incident_id uuid not null references public.incidents(id),
 incident_unit_id uuid not null, vehicle_id uuid not null,
 authority_episode_id uuid not null,
 policy_version text not null references private.vehicle_phone_policy_versions(policy_version),
 recovery_epoch uuid not null,
 audience text not null check(length(audience) between 1 and 128 and audience ~ '^[A-Za-z0-9._:/-]+$'),
 public_key_spki bytea not null check(octet_length(public_key_spki) between 1 and 256),
 public_key_sha256 bytea not null check(octet_length(public_key_sha256)=32),
 policy_document_sha256 bytea not null check(octet_length(policy_document_sha256)=32),
 precise_audience_sha256 bytea not null check(octet_length(precise_audience_sha256)=32),
 nonce bytea check(octet_length(nonce)=32),
 nonce_sha256 bytea not null check(octet_length(nonce_sha256)=32),
 transcript_sha256 bytea not null check(octet_length(transcript_sha256)=32),
 request_sha256 bytea not null check(octet_length(request_sha256)=32),
 expected_incident_version bigint not null check(expected_incident_version>0),
 expected_deployment_version bigint not null check(expected_deployment_version>0),
 expected_vehicle_version bigint not null check(expected_vehicle_version>0),
 generation bigint not null check(generation>0),
 state text not null check(state in ('ISSUED','CONSUMED','EXPIRED','REVOKED')),
 issued_at timestamptz not null, expires_at timestamptz not null,
 consumed_at timestamptz, consumed_binding_id uuid references private.vehicle_phone_bindings(id),
 unique(id,vehicle_id,organization_id), unique(vehicle_id,generation),
 foreign key(incident_unit_id,incident_id,organization_id)
   references public.incident_units(id,incident_id,organization_id),
 foreign key(vehicle_id,organization_id)
   references public.operational_vehicles(id,organization_id),
 foreign key(authority_episode_id,incident_id)
   references public.incident_crew_members(id,incident_id),
 check(expires_at=issued_at+interval '120 seconds'),
 check((state='CONSUMED')=(consumed_at is not null)),
 check((consumed_at is null)=(consumed_binding_id is null)),
 check((state='ISSUED' and nonce is not null) or (state<>'ISSUED' and nonce is null))
);
create index vehicle_phone_challenge_scope
 on private.vehicle_phone_challenges(actor_user_id,organization_id,incident_id,state);
create index vehicle_phone_challenge_expiry
 on private.vehicle_phone_challenges(expires_at) where state='ISSUED';
create table private.vehicle_phone_binding_slots (
 vehicle_id uuid primary key, organization_id uuid not null,
 generation bigint not null default 0 check(generation>=0),
 pending_challenge_id uuid, current_binding_id uuid,
 foreign key(vehicle_id,organization_id)
   references public.operational_vehicles(id,organization_id),
 foreign key(pending_challenge_id,vehicle_id,organization_id)
   references private.vehicle_phone_challenges(id,vehicle_id,organization_id),
 foreign key(current_binding_id,vehicle_id,organization_id)
   references private.vehicle_phone_bindings(id,vehicle_id,organization_id),
 check(pending_challenge_id is null or current_binding_id is null)
);
alter table private.vehicle_phone_policy_versions owner to postgres;
alter table private.vehicle_phone_bindings owner to postgres;
alter table private.vehicle_phone_challenges owner to postgres;
alter table private.vehicle_phone_binding_slots owner to postgres;
alter table private.vehicle_phone_policy_versions enable row level security;
alter table private.vehicle_phone_bindings enable row level security;
alter table private.vehicle_phone_challenges enable row level security;
alter table private.vehicle_phone_binding_slots enable row level security;
revoke all on private.vehicle_phone_policy_versions,private.vehicle_phone_bindings,
 private.vehicle_phone_challenges,private.vehicle_phone_binding_slots
 from public,anon,authenticated,service_role;
```

These FKs prevent cross-org vehicle/deployment references, but cannot themselves
prove deployment.inventory_unit.vehicle_id equals chosen vehicle, actor equals
the authority-episode user, crew role DRIVER/ACTIVE, or immutable request/key/hash
consistency. Trusted locked writers MUST rejoin/check all of those and reject
identity changes. Future identity guards protect binding/challenge immutable
columns; only documented lifecycle/version transitions may update them.
No SELECT policy/direct DML grant is proposed for clients or service_role;
only narrowly authorized SECURITY DEFINER functions would access private rows.
No table permits active sharing. A policy row cannot enable a nonexistent producer.

One BOUND_INACTIVE credential per actor/vehicle/deployment is a **proposed
conservative P07 policy**, not a newly approved product rule. An expired binding
must be transitioned EXPIRED under the same slot lock before another explicit
enrollment; no TTL expression in a partial index or automatic takeover.
At issuance, create/lock vehicle slot, ensure no nonexpired current/pending claim,
increment server generation once and reserve pending_challenge_id. Replays
reuse that reservation. Confirmation swaps pending→current atomically.
Expired/revoked challenge clears reservation under lock; generation never
decreases/reuses. Revocation clears current and increments slot generation,
so in-flight old challenges cannot commit. Expiry cleanup is metadata-only here;
its retention duration still requires P13 approval. Binding expires_at is
server-derived from the approved finite binding lifetime in P05/P13, never caller
input; no default duration is invented before approval. CONSUMED challenges are
terminal immutable proof: subsequent revocation changes the binding/slot, not
that challenge back to ISSUED/REVOKED.

proposed_binding_id has deliberately no FK until binding creation; confirm checks
it against the new binding and consumed_binding_id in the same transaction.
Operation UUIDs refer logically to canonical receipts written atomically;
there is no preexisting receipt at challenge insertion, so do not add a
premature FK requiring nonexistent successful receipts.

### 5.5 Exact proposed RPC surfaces and authority — NOT IMPLEMENTED

No name below is an existing endpoint. Do not add any to Android/Web allowlists
until separately authorized. All return jsonb. Future write functions are
SECURITY DEFINER, owner postgres, search_path='', lock_timeout1500ms; fully
qualified relations/functions; bounded inputs and metadata-only outputs.
Revoke EXECUTE from PUBLIC, anon, authenticated and service_role first, then
grant only the specific role shown. No caller-supplied actor is trusted except
at the **service-role-only verified Edge boundary**.

| Proposed function/signature | Only EXECUTE role | Transaction / safe result |
|---|---|---|
| public.vehicle_phone_binding_challenge_create(p_actor uuid,p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_expected_version bigint,p_payload jsonb) | service_role verifier only | trusted Edge authenticates actor, makes secure nonce, then locked create/reservation + canonical issue receipt. Payload strictly contains confirm_operation_id, proposed_binding_id, incident_unit_id,vehicle_id,authority_episode_id,public_key_spki,nonce,expected_deployment_version,expected_vehicle_version,policy_version; caller cannot select audience/epoch/generation or approved policy |
| public.vehicle_phone_binding_challenge_read(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid) | authenticated, auth.uid-derived owner only | current approved enrollment authority + scope; no other actor's challenge. Exact outstanding bytes/context/TTL for original owner, never FCM ID/private key |
| public.vehicle_phone_binding_confirm(p_actor uuid,p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_challenge_id uuid,p_proof jsonb) | service_role verifier only | proof contains exactly transcript_sha256 and signature_sha256 (64-char lowercase hex); checks stored challenge and current authority under lock, consumes + inactive binding/slot + receipt/audit together. Required attestation blocks v1 rather than adding an unverified result flag |
| public.vehicle_phone_binding_revoke(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,p_binding_id uuid,p_expected_generation bigint,p_reason text) | authenticated, auth.uid-derived owner only | one-way own-binding revoke, including when command role/org membership lost; no other credential enumeration. Revoke current exact binding only, never a later replacement; record original receipt. No GPS read or ACTIVE effect |
| public.vehicle_phone_binding_receipt(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid) | authenticated owner only | receipt-first minimal proof FOUND/ABSENT/IDENTITY_MISMATCH/SCOPE_UNAVAILABLE with no public key/nonce; absence is UNKNOWN, not failure |

Public challenge_read must use the actual caller, not an actor parameter. Trusted
Edge uses a caller-scoped client for it and a separate private service client only
after signature verification. service_role does not get public authenticated
read grants by default. Keys/tokens stay server-side; no service role in Android/Web.

Nonce/hash/proof fields use one documented base64url/hex representation in JSON.
Request identity is phase-specific normalized JSONB, compared by full JSONB
equality (not just a digest):
- ISSUE includes action/actor/org/incident, original issue/confirm/binding IDs,
  driver/deployment/vehicle/key and policy identity plus every client expected
  version. Server-generated nonce/time/generation/transcript hash are OUTPUTS,
  not client intent: a replay must reuse the saved challenge, not compare a
  newly generated nonce or mint one. Edge checks original issue receipt first.
- CONFIRM includes action/actor/org/incident, original confirm/challenge/binding
  IDs and exact transcript/signature digests. Re-signing/malleating a proof is a
  changed request under that operation, not a new accepted replay.
- REVOKE includes action/actor/org/incident, exact original binding/generation
  and bounded reason; do not rebase it to the latest holder.
The confirm proof object has only transcript_sha256/signature_sha256; the DB
computes its normalized request digest itself, avoiding a self-referential
request-hash field. Auxiliary request_sha256 hashes server-normalized JSONB; it never replaces full
request equality or signature verification. No client semantic field is omitted.
The signature itself is input to verification, not a freely replaceable flag.
Response receipt_core remains immutable; live availability/revocation status is
a separate current_status envelope. Existing receipt table request≤64KiB is
respected by the tighter16KiB protocol bound.

Proposed new canonical command codes BIND_CHALLENGE/BIND_CONFIRM/BIND_REVOKE
are design only. Reuse private.incident_operation_receipts without shape changes
and private.write_audit(org uuid,actor uuid,event text,kind text,entity uuid,
before_data jsonb,after_data jsonb), whose seven-argument signature exists in
20260918090000_review_bootstrap_audit.sql. Audit allowlists only binding/challenge/
operation IDs, coarse transition/time/reason and actor/org required by P13;
no nonce, signature, key, GPS or full request. No generic incident timeline,
FCM or Broadcast event should contain this private material. No canonical incident
version/timeline mutation is implied merely by an inactive device binding.

First new operation checks live authority before exposing state/version errors.
Operation replay follows original actor/org/request equality and returns only
authorized minimal immutable evidence; it cannot bypass current state for use.
Proposed safe errors: 42501 NOT_AUTHORIZED; P0001 POLICY_UNAPPROVED,
BINDING_DISABLED, CLAIM_CONFLICT, CHALLENGE_EXPIRED, CHALLENGE_CONSUMED,
BINDING_REVOKED, STALE_VERSION, OPERATION_REUSED, VALIDATION_FAILED.
No proof/key/coordinate detail in errors. Lock/serialization/timeouts/rate limits/
auth unavailability remain uncertain, not definitive first business rejection.
Do not add these codes to D1's first-rejection allowlist before real canonical
functions and no-earlier-unknown evidence exist.

Proposed abuse limits:120s challenges, at most one pending vehicle reservation,
three outstanding challenges per actor, five issue attempts/minute/actor and
bounded10k service-wide outstanding rows. These are unapproved technical design
limits requiring server implementation and load/security review, **not** new
current approved limits. A future rate limiter must be server-owned and atomic,
not process-local or bypassable through different HTTP instances; no new scheduler
or counters are implemented here.

## 6. Consent, lease, STOP and failure state machine — future only

Runtime M15A only exposes existing DISABLED or UNAVAILABLE. POLICY_UNAPPROVED is
an explanatory denial, not a local approved-consent state. The other states below
are requirements for later work, not states reachable in this PR.

| From → to | Required guard/effect / operation semantics |
|---|---|
| DISABLED → POLICY_UNAPPROVED | explain missing approval only; no key/permission/RPC enrollment |
| POLICY_UNAPPROVED → DEVICE_UNBOUND | future reviewed enrollment code + approved policy version and enrollment gates; M15A cannot transition |
| DEVICE_UNBOUND → CHALLENGE_ISSUED | deliberate visible ceremony, current DRIVER/REAL/vehicle/actor scope; original issue/confirm IDs frozen |
| CHALLENGE_ISSUED → BOUND_INACTIVE | valid exact proof; atomic consumption and inactive-binding receipt; no sharing lease or location |
| CHALLENGE_ISSUED → EXPIRED/REVOKED | server TTL/context/policy loss/cancel; clear reservation, preserve original immutable evidence |
| BOUND_INACTIVE → CONSENT_PENDING | user reads approved audience/purpose/version/lease/withdrawal/retention notice; no OS permission implies acceptance |
| CONSENT_PENDING → AUTHORIZED_READY | explicit consent to exact current version/audience, verified binding, live role, physical-cleanup readiness and compatible approved code; no capture yet |
| AUTHORIZED_READY → STARTING | future explicit START UUID/request, visible Activity, permitted OS state; no remote/admin/FCM trigger |
| STARTING → SHARING | confirmed same-request server receipt + independent finite generation-bound server sharing lease; not optimistic UI |
| STARTING → UNKNOWN_OUTCOME | transport ambiguity; preserve original UUID/request, no duplicate START, no implicit local capture |
| UNKNOWN_OUTCOME → SHARING/STOPPED/REVOKED/EXPIRED | original matching receipt AND current lease/authority; absent/mismatched proof remains unknown; never infer success/failure from later validation error |
| SHARING → STOP_REQUESTED | STOP/LEAVE/account-org-incident switch: local capture and buffered uploads stop immediately; freeze bounded no-coordinate revoke intent |
| STOP_REQUESTED → STOPPED | server atomically revokes exact lease/generation and physically removes current coordinate; exact STOP receipt; no waiting to stop phone |
| Any usable state → REVOKED | driver/role/membership/vehicle/incident/policy/key loss; server live predicate denies samples/precise reads immediately |
| Any leased state → EXPIRED | server lease/credential expiry; no late request can renew/reactivate; new explicit ceremony required |
| STOPPED/REVOKED/EXPIRED → DEVICE_UNBOUND | only a new, authorized, visibly reviewed operation/key/context, never retrying old START or consent |

A binding's finite lifetime is distinct from a sharing lease and point expiry.
P05 must specify lease duration/renewal; there is **no numerical live-sharing
lease default here**. Renewal requires current auth, driver, binding generation,
policy and fresh owner action rules. Expired offline sessions cannot upload.
START/STOP/LEAVE must each have separate action-domain signing bytes, operation
UUIDs and receipts; never reinterpret BIND_INACTIVE proof.

Consent version lifecycle: DRAFT_UNAPPROVED → APPROVED only by named authorized
owner process outside this PR → WITHDRAWN/REPLACED. Published document/audience
hash is immutable; amendments create a new version. Existing consent cannot
silently migrate. Withdrawal/changed precise audience invalidates old authorization
immediately; fresh notice/acceptance required. No phone-local boolean can approve
policy or extend any lease.

Role/driver loss, terminal/released vehicle and org/account switch invalidate
source use independently of background teardown messages. Offline STOP cannot
instantly contact other viewers: local stop is immediate, remote hiding occurs
when authenticated revoke arrives or the separately bounded server lease expires.
UI must disclose this risk; never promise immediate remote deletion offline.
A future durable revoke must use an approved extension of the existing durable
architecture, not a parallel queue; M15A adds no operation type/dispatch.

Key lost/uninstalled/restored: fail DEVICE_UNBOUND or REVOKED, never copy private
keys from backup or infer possession from a saved alias/public key. Keep original
receipt evidence; receipt success does not prove present key access. Stolen phone
has no special operator override to start tracking. Lost-key owner revocation
uses freshly verified account authentication and one-way own-binding semantics,
without requiring the missing key or still-valid controller role. This only
reduces the original actor's access and may be abused for denial of service if
their bearer is stolen; it must never grant another actor read/START authority.
An offline revoke remains tagged to its original account/context and is not sent
under a new account's JWT; future same-account recovery or finite lease expiry
bounds the disconnected interval.

## 7. Physical deletion and privacy operations — approval required

A marker hidden at900s is not evidence of database deletion. A latest-only UPSERT
is not evidence that WAL, replicas, snapshots or PITR contain no prior values.
DELETE of a live row is not a promise of immediate forensic erasure from disk.
These distinctions must be explicit in P09/P11/P12 and user notice.

Proposed future owner-approved architecture:
1. A narrowly privileged independently scheduled database maintenance task, owned
   and monitored by the operator, deletes expired/revoked latest-coordinate rows
   in bounded indexed batches even with zero readers/writers. No new job, Cron,
   scheduler, Edge worker, secret or coordinate table is created by M15A.
2. Every sample/read must independently enforce current consent/role/session and
   absolute source expiry. STOP online deletes current row and revokes generation
   in the same locked transaction. Display-side hiding is additional defense,
   never the deletion mechanism.
3. Owner sets maintenance cadence C, maximum batch backlog, deletion delay D,
   clock tolerance and outage SLA. Nominal removal deadline can be bounded by
   expiry+C+D only under the approved healthy infrastructure assumptions. No
   absolute deletion guarantee during database outage is claimed. Health failure
   disables future source enrollment/uploads, alerts owner without coordinates,
   and requires recovery/removal review before re-enable.
4. Retention work reports only safe counts/deadlines/status, not row bodies,
   user tracks or coordinates. Maintenance cannot delete original incident
   operations, task receipts, attachments or immutable audit.
5. Consent/key/revocation evidence has separate P13 limits and access. Retain
   only operation/context/policy hashes/action/time required by approved purpose;
   no precise values/nonce/signature/private key in general audit/receipt/logs.
   Proposed challenge nonce is purged on consume/revoke/expiry; opaque evidence
   remains only for the approved metadata duration and exact-replay protection.
6. Backups/PITR/WAL/replicas/caches require an explicit maximum protected retention,
   encryption/access controls, restore procedure and lawful response/deletion
   policy. Do not silently exempt them or claim a live-table TTL covers them.
   If “no recoverable historical point anywhere” is required, ordinary
   PostgreSQL backup/PITR may be incompatible: leave producer OFF until an
   approved compatible design is selected.
7. Restoration runs quarantined with producer/viewer OFF, separate environment
   audience and rotated recovery epoch outside the restored database; revoke
   old leases/bindings, delete expired/revoked live points and reconcile original
   operation receipts before any access. Never restore GPS into TRAINING as a
   “real” observation or silently restart a phone.
8. Web/Android future precise cache, if any, must be scoped, bounded, revocable
   and expire independently of B1 task availability. No new GPS cache is
   created in Room16/Web storage here. Authorized field tasks and pending
   evidence must survive GPS-only revocation.

Coordinates are forbidden in M10/Realtime/FCM, generic timeline, URLs/query
parameters, routine analytics/errors/receipts/logs. Binding public keys,
signatures/challenges and pseudonymous driver links are also sensitive; minimize
and protect them. Rights requests and access audits need an owner procedure,
not an unauthenticated bulk export or manager “override.”

## 8. Threat model / failure handling

| Threat or failure | Required future mitigation | M15A truth / remaining gate |
|---|---|---|
| Bearer token stolen | fresh authenticated ceremony + independent signing possession + current scope; proposed inactive binding never sufficient to share | attacker-supplied key with stolen bearer can still create its own possession proof unless stronger human/auth/device assurance is required; A01/P02 must decide. No enrollment endpoint now |
| Stolen unlocked phone | restricted key usage, finite lease, owner/key revoke, visible stop; no remote restart | Keystore cannot prevent all use by compromised authorized process; no tracking starts |
| Replayed proof / signature malleation | domain-separated challenge, exact frozen request/signature digest, nonce TTL/single consumption, original operation receipt | no proof API; no claim of exactly-once network delivery |
| Concurrent driver claims | slot row lock + canonical locks + generation/CAS; explicit fail-closed competing claim | no takeover semantics approved; unique binding design is unimplemented |
| Rebound FCM installation | ignore installation/token for device authority | existing M10 untouched; no transfer of GPS rights |
| Replaced key / rotation | fresh key + ceremony/operation; revoke old generation, never update historical public key in place | no rotation API |
| Key lost / backup restore / new login | no exported private key; fresh proof/reauthorization, restore quarantine and recovery epoch | AES auth decryption/login alone never proves sharing key |
| Current driver/role/org removed | server revalidation at commit and each future sample/read; invalidate exact private source | preserves independent B1 tasks, cursor, field lease and immutable pending intents |
| Cross-org/historical access | default precise DENY; exact scope/REAL ACTIVE/policy at every read | current callsign/history visibility never grants precise location |
| Old request after account switch | UI/repository scope fence + server actor/context signature and receipt equality | #92 cancellation/identity checks retained; no frozen enrollment to relabel |
| Offline STOP / lost response | immediate local stop; durable bounded identifier-only revoke; original receipt-first recovery; finite server lease bounds remote risk | cannot promise instantaneous remote hiding offline; not implemented |
| Server auth/network/lock failure | fail closed for new enrollment/source; preserve UNKNOWN and original IDs, no automatic rebasing | #92 remains unverified/OFF without revoking valid field projection |
| False GPS / mock provider | signature proves key only, not truthful position; future validated accuracy/time/jump rules and policy | no GPS input/parser and no device integrity assumption |
| Logging/observer leakage | dedicated private contract, redacted errors/audit, no coordinates in hints/timeline, minimize key/nonce retention | no new data transport or credentials |
| Compromised verifier/service role | narrowly reviewed internal commit surface, current DB rechecks, key/proof audit without secrets, isolate service credentials | privileged verifier remains trusted; a forged “verified” digest from a compromised service is not independently checked by current DB. Gate requires security review, not a claimed cryptographic DB guarantee |
| Maintenance unavailable/backlog | owner-approved independent cleanup, safe health alarm/gate, bounded source expiry | no physical deletion SLA asserted |
| Restore old generations/receipts | recovery epoch outside backup + producer OFF/quarantine | cannot reset generation from a restored row and claim old device revoked |
| Policy changed after challenge | immutable policy/audience hashes + current approved-version check at commit, new explicit ceremony | draft never approved locally |
| Third-party UI uses future ON response | #92 exact supported disabled schema rejects, producer literal false | no feature flag enables missing producer |

No notification, receipt, task ACK/START/COMPLETE, route intent or command-map
selection is executed as a side effect of binding design. COMMAND INTENT,
ROUTING PLAN and OBSERVED REAL GPS remain distinct.

## 9. Android/Web integration constraints and source verification

Android current path inspected: VehicleLocationCapability.kt/
VehicleLocationCapabilityUi.kt → IncidentViewModel.vehicleLocationCapability →
IncidentRepository.vehicleLocationCapability, IncidentMapScreen Units,
KeystoreSessionManager, AndroidManifest, ForegroundLocation and Room16.
No code change needed for this milestone. Existing localized card already states
policy/device/deletion blockers; its UI exposes no START. There is no local
consent-approved preference. Do not call ForegroundLocation, generate a signing
key, register a challenge, request permission or declare a new service as part
of showing this draft. Existing own-phone map/navigation remains independent.

Web current path inspected: same-origin incidents API read allowlist, manual
VehicleLocationCapability component, exact disabled decoder, RealUnitPosition,
IncidentCop and LiveProvider's existing Web scope fingerprint. No route/API or
map source change. Existing account/org/incident/fingerprint key disposes old
requests; unsupported/missing capability stays OFF. No new polling, localStorage,
telemetry cache, filename/nonce/proof storage or logging.

Official primary API sources reviewed2026-11-03 (design references, not executed):
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore):
  nonexportable key operations do not prevent every compromised-process use.
- [KeyGenParameterSpec EC signing example](https://developer.android.com/reference/android/security/keystore/KeyGenParameterSpec):
  supports P-256 signing with SHA256withECDSA; proposed ceremony not implemented.
- [Android attestation verification](https://developer.android.com/privacy-and-security/security-key-attestation):
  hardware assurance needs remote chain/security/revocation verification.
- [W3C WebCrypto Recommendation, ECDSA](https://www.w3.org/TR/webcrypto-1/#ecdsa-operations):
  raw fixed-width r||s interoperability; no assumption that DER equals WebCrypto signature.
- [Supabase getUser](https://supabase.com/docs/reference/javascript/auth-getuser),
  [JWT verification](https://supabase.com/docs/guides/auth/jwts):
  authenticated identity still requires separate current authorization/session policy.
- [PostgreSQL17 binary functions](https://www.postgresql.org/docs/17/functions-binarystring.html):
  built-in sha256(bytea) supports proposed transcript digest without assuming pgcrypto.
No SDK upgrade, generated code or imported library is made.

## 10. Future M15B/M15C dependency contract — not authorization to start

Suggested M15B work package: reviewed inactive key-possession enrollment/rotation/
revocation after enrollment-purpose/device-assurance decisions, privacy approval
and compatible verified deployment. Implement/review exact future migration,
verifier, guarded APIs, deterministic interoperability and hostile replay tests
under the owner's later instructions. Still no coordinates, active consent,
tracking/FGS or producer true. No shipping the design DDL piecemeal as an
operational credential service before approval.

Suggested M15C work package: separately approved consent/finite lease, physical
no-traffic retention+backup plan, immediate local STOP/durable revoke, real source,
current precise-reader policy, Android FGS/privacy notice and bounded source-
specific map integration. Needs M15B, all relevant P01–P14/A01 sign-offs, completed
owner rollout and independently reviewed/verified implementation. Existing
120/900s constants do not satisfy those approvals. No M15B/C implementation here.

## 11. Owner-only rollout and compatibility

M15A adds **no SQL migration and no callable signature**. Proposed DDL/functions
are documentation only; do not execute them. No installation is necessary for
the document; all apps remain usable with #82–92 migrations missing because
their runtime files are unchanged and #92's old-server OFF fallback remains.
Do not infer those deployments succeeded from merged GitHub source.

Owner future order, recording exact project/object/function/version/result:
1. Review pinned PR; only owner merges. Preserve existing developer-local files
   and pending evidence. No reset/automatic checkout or stash was performed here.
2. Reconcile actual #82 field pilot, #83 snapshot protocol, #84 private Realtime,
   #85 scoped messages; reported manual application is not verified in this run.
3. Resolve the owner-reported #86
   `20261030160000_incident_private_attachments.sql` 42601/partial-install
   blocker with a separately reviewed source/DB correction. Do not blindly
   replay SQL Editor migrations or assume migration ledger is complete.
4. Only then reconcile unapplied #87
   `20261030180000_android_unit_leadership.sql`, #88
   `20261030200000_incident_field_map.sql`, #89
   `20261102100000_incident_field_receipt_recovery.sql`, #90
   `20261102120000_incident_field_reliability.sql`; #91 has no SQL.
5. Review/apply #92 `20261102140000_incident_vehicle_location_capability.sql`
   only with compatible prerequisites; it is structurally OFF, not activation.
6. Verify private evidence Edge/Storage and B2 Realtime independently; owner
   builds/deploys compatible Web/Android, retains Room16 and validates offline
   pending operations. M15A requires no Edge/Storage/Realtime/Cron change.
7. Owner records policy/device/retention approval separately from source merge.
   Future migrations must be forward-only after the actual latest merged file;
   M15A reserves no timestamp or RPC name operationally. No GPS can be enabled
   by changing a draft policy row or client flag in this branch.

Documentation backout is an ordinary forward documentation correction, not a
schema rollback. Do not edit old installed migrations/receipts. If a later feature
ever stores coordinates, backout must revoke producers/leases, remove live points
and apply approved backup/restore handling; hiding a marker alone is insufficient.

## 12. Owner-run acceptance — all UNEXECUTED

No acceptance, automated harness, SQL probe or runtime experiment was executed.
Source-only cases verify the retained contract later; design cases need a
future approved implementation. GPS-dependent cases are BLOCKED_BY_POLICY.

| ID | Owner case | Required evidence / expected result | Status |
|---|---|---|---|
| M15A-001 | Merge dependency | GitHub #92 merged flag and ancestry, not merely matching files; this PR starts from recorded main. | UNEXECUTED |
| M15A-002 | Open PR inventory | No competing GPS foundation PR before branching; later fixes stay in this PR. | UNEXECUTED |
| M15A-003 | Local preservation | No attached checkout/dirty-status claim; existing local review artifacts untouched. | UNEXECUTED |
| M15A-004 | Policy sheet | P01–P14 and A01 remain UNAPPROVED; no blank field implies approval. | UNEXECUTED |
| M15A-005 | Actual versus proposed names | Every new DDL/RPC/protocol clearly UNIMPLEMENTED; no migration/enrollment endpoint shipped. | UNEXECUTED |
| M15A-006 | Server capability OFF | Existing incident_vehicle_location_capabilities returns DISABLED and all six flags false. | UNEXECUTED |
| M15A-007 | Android OFF | Existing producer constant false and supported state only DISABLED/UNAVAILABLE; no START control. | UNEXECUTED |
| M15A-008 | Web OFF | Existing exact disabled decoder rejects an ON/unknown response; no permission to track. | UNEXECUTED |
| M15A-009 | Missing #92 RPC on old server | Manual check shows unverified/OFF without losing cached field tasks or pending operations. | UNEXECUTED |
| M15A-010 | No implicit permission | Opening docs/map/Units never asks location or creates a key/consent. | UNEXECUTED |
| M15A-011 | Android identity switch | Existing keyed UI/repository scope fence prevents late optional results entering new account/org/incident. | UNEXECUTED |
| M15A-012 | Web identity/scope switch | Existing abort and keyed account/org/incident/head scope prevent old response restoration. | UNEXECUTED |
| M15A-013 | Room/worker compatibility | Room16, B1 atomic cursor/projection, D1/D2 receipts and existing worker unchanged. | UNEXECUTED |
| M15A-014 | No private browser persistence | No new localStorage/sessionStorage/cache/proof/coordinate write. | UNEXECUTED |
| M15A-015 | REAL/SIM/NAV separation | SIM source remains SIMULATED; NAV ACTUAL_POSITION still unavailable; route/intent/blue dot not observations. | UNEXECUTED |
| M15A-016 | Notification identity boundary | Installation UUID/FCM token not accepted as signing or GPS identity; M10 unchanged. | UNEXECUTED |
| M15A-017 | Localized disabled UX | Existing default/Sl/De OFF explanation retained once, no second card or approved-consent flag. | UNEXECUTED |
| M15A-018 | No operational schema | No new GPS/credential/challenge/active-consent tables or grants installed by M15A. | UNEXECUTED |
| M15A-019 | No hidden service or trigger | No foreground/background service, permission, receiver, new worker/Cron/poller or deployment. | UNEXECUTED |
| M15A-020 | Owner rollout ledger | #86 42601 unresolved; no assumption later SQL/Edge/client deployed; owner reconciles actual signatures before rollout. | UNEXECUTED |
| M15A-021 | Key generated only on future ceremony | No key on login/open/push/boot; current M15A cannot enroll. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-022 | Key export attempt | Private key remains nonexportable; public SPKI only; compromised-process limitation documented. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-023 | Wrong curve/key encoding | Only validated EC P-256 SPKI; reject other algorithms, trailing/invalid ASN.1 and overlength. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-024 | Canonical SPKI hash | Exact validated bytes hashed, no PEM/JWK reserialization or key relabeling. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-025 | DER/raw interoperability | Android DER signing converted to64byte r||s; correct WebCrypto SHA256 verification, no double hash. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-026 | Signature scalar boundaries | Reject invalid lengths/sign/zero/out-of-range scalars and malformed conversion. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-027 | Exact transcript LF/encoding | UTF-8 ASCII ordered fields plus final LF; CR/BOM/missing line/extra whitespace rejected. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-028 | Wrong environment audience | Project/env-specific fixed audience and recovery epoch reject proof replay elsewhere. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-029 | Wrong account/org/incident | Signature and current actor authorization mismatch rejected before binding. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-030 | Wrong deployment/vehicle | Verified composite FKs plus current inventory-unit→vehicle join; no arbitrary crew/task fake vehicle. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-031 | Wrong driver episode | Current ACTIVE DRIVER user/org/unit required; LEADER fallback not silently substituted. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-032 | Inactive/unavailable vehicle or released unit | Live eligibility fails at commit even if challenge was valid earlier. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-033 | TRAINING enrollment | Authoritative scenario membership denies; same physical asset cannot convert SIM into REAL. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-034 | Policy still draft | No challenge/binding/use permitted by a draft document or local acceptance flag. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-035 | Policy/audience changes during challenge | Compare immutable version/hash and current approval; new review, not silent migration. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-036 | Nonce security | Server32byte secure randomness, no caller nonce/Math.random/time-derived challenge. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-037 | Challenge TTL boundary | Future clock/expired exactly at server expiry denied; issue replay never extends120s. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-038 | Out-of-order/consumed challenge | Only original confirm consumes once; different operation rejected. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-039 | Lost issue response | Original operation returns same challenge/reservation while valid, no new generation/nonce. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-040 | Lost confirm response | Receipt-first original request returns proof plus current inactive state; no duplicate binding. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-041 | Confirm replay after revocation | Immutable success evidence does not reactivate revoked/expired binding. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-042 | Same UUID/different proof | Canonical request/signature digest mismatch produces OPERATION_REUSED. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-043 | Signature malleated/re-signed retry | Freeze exact submitted bytes; altered proof not silently accepted under original operation. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-044 | Atomic rollback | Challenge consumption, binding, slot, audit and receipt roll back together. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-045 | Concurrent vehicle claims | One slot lock/generation; fail closed competing claim, no dual ownership. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-046 | Same actor two vehicles | Proposed single-bound-actor rule must be explicitly approved under P07 before enforced. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-047 | Expired slot reservation | Explicit expiration/lock before new claim; generation never reused. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-048 | Public client spoofs verified=true | No public commit/DML; trusted verifier role only, DB rechecks current context. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-049 | Forged service input / verifier trust | Document privileged-verifier threat; no independent DB ECDSA guarantee claimed. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-050 | Stolen bearer enrolls attacker key | Possession proof alone insufficient for hardware/person; A01/P02 assurance gate decides, no current enrollment. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-051 | Attestation required but unavailable | Fail closed; no self-signed/client-claimed hardware or automatic software downgrade. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-052 | Key loss / reinstall | DEVICE_UNBOUND or revoked, never infer possession from saved alias/public key/login. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-053 | Account switch during proof | Cancel/quarantine original scope; no UUID/key relabeling into another account. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-054 | Driver/role revocation during verification | Recheck at commit under canonical locks; retain only permitted original evidence. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-055 | Own revoke after membership loss | One-way own-binding revoke without missing controller role; no coordinate read or another actor enumeration. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-056 | Old revoke after replacement | Targets original binding/generation; cannot clear a later holder or new account binding. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-057 | Unknown transport / receipt missing | UNKNOWN preserved; no definitive rejection or replacement UUID from absence/later error. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-058 | Rate/cap/lock/schema failure | Atomic rate bounds future-only; uncertain/compatibility errors not blanket first-rejection4xx. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-059 | Restore/PITR old binding | Quarantined producer OFF, new recovery epoch; no restored generation resurrected. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-060 | Metadata cleanup/rights request | Nonce purged on consume/revoke/expiry; approved key/receipt/consent evidence retention/access, no broad private export. | UNEXECUTED — DESIGN_NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| M15A-061 | Explicit consent/START | Only approved version/audience, fresh role/device and deliberate user action; binding alone never starts. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-062 | No manager remote activation | Admin/commander call cannot silently activate somebody else's phone. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-063 | Finite independent sharing lease | Owner-approved expiry/renewal; binding lifetime or cached B1 lease not substituted. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-064 | Locked-screen foreground operation | Only future visible user-started approved FGS, persistent stop notification, no covert restart. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-065 | Permission denial/coarse/provider disabled | No capture or fake precision; ordinary map/field work continues. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-066 | STOP/LEAVE online | Local callbacks/buffer stop immediately; authoritative revoke+coordinate deletion atomic. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-067 | STOP offline | Persist bounded identifier-only revoke under original identity; no fix uploads while awaiting server. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-068 | Account/org switch during sharing | Immediate local stop, old-scope revoke preserved; never dispatch it as new account. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-069 | Late sample races STOP | Server generation/lease lock rejects old sample; no resurrection on replay. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-070 | Lease expiry offline / process death | No restart/backlog; exact source becomes unavailable under approved timing. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-071 | Reconnect many fixes | Only latest valid authorized observation; no stored/transmitted trail. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-072 | Real accuracy/time/source | Server-confirmed genuine fix only; signed payload does not alone prove GNSS truth. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-073 | 120s stale /900s expiry | Age from actual observation with trusted anchor; expire earlier on revoke/lease loss; no green offline. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-074 | Precise IC/crew/cross-org visibility | Approved specific reader policy at every read; callsign/command hierarchy alone insufficient. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-075 | Current GPS versus task/route/SIM | No manual/SIM/target fallback; no auto ACK/arrival/complete or status effects. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-076 | Deletion without any traffic | Approved independent task physically removes expired latest rows; inspect actual capacity/SLA evidence. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-077 | Maintenance failure/backlog | Redacted alert and source OFF, no false deletion compliance claim. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-078 | Backup/PITR/WAL/caches | Owner-approved protected retention/restore policy;900s UI/live-row expiry not erasure of backups/media. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-079 | No coordinate in metadata transports | Check FCM/Realtime/M10/timeline/URLs/analytics/errors/receipts/logs; no trail or private key/proof leakage. | UNEXECUTED — BLOCKED_BY_POLICY |
| M15A-080 | Operational activation sign-off | All required approvals, vetted device/security review, deployed compatible code and owner-run acceptance; M15A never enables it. | UNEXECUTED — BLOCKED_BY_POLICY |

## 13. Remaining gates, results and exclusions

80 owner acceptance cases above: all UNEXECUTED;60 marked BLOCKED_BY_POLICY,
including40 also DESIGN_NOT_IMPLEMENTED. None PASS. No proof/crypto/GPS
interoperability, SQL correctness/performance or Android/Web behavior has been
executed or certified. DDL is a source-reviewed proposal, not validated SQL.

Actual M15A changes: this document and factual SPEC progress note only.
No new migration/signature/production component. Existing #92 source preserves
permanent OFF and old-server compatibility. P01–P14/A01, #86 rollout uncertainty,
independent physical retention, session-revocation assurance, device/key security
and eventual human acceptance remain open. No M15B/C work or policy approval
is implied by merging this documentation.

No tests added/modified/run; no build, lint, typecheck, CI/monitoring, Gradle sync,
emulator/browser/runtime checks, Supabase/project inspection, SQL execution/
migration application, Edge execution, Web deploy, Android install, real GPS/
notification, credentials/secrets/Cron/dependency/KAPT/KSP/Room/generated-schema
changes, local file writes or merge. Source reads of GitHub/official API docs and
requested local directory/git-status inspection are the only checks performed.
Owner alone merges, applies migrations, deploys, approves policy and releases.
