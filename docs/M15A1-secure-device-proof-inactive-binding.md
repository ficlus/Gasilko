# M15A.1 — secure local device proof and future inactive vehicle binding

2026-11-03 · **SOURCE IMPLEMENTATION ONLY — NOT BUILT/RUN/DEPLOYED.**
**GPS DISABLED. P01–P14 AND A01 ALL UNAPPROVED. NO SERVER ENROLLMENT OR BINDING.**

## 1. Baseline and scope

Base main: `f945fa12b6cfd3a321914825e22f5126ae2c81df`.
PR #93 is confirmed MERGED; head `5dd8254c46d926f97badb25cbdf4174ee5e42ef0`;
its merge is this main HEAD. GitHub comparison ahead1/behind0 proves ancestry.
No open/overlapping PR at initial inspection. Work is one fresh branch/PR;
later corrections stay on that PR. No local developer files are modified.

Read AGENTS, primary/M14 SPEC, M15A, C2/C3, C1/unit leadership, B1/B2, D1/D2,
M10/NAV docs, root C2/NAV prompts and SPECS C2/queue. Queue is historical
orientation, not proof of installation/approval. Explicit owner no-test/no-
execution rules override AGENTS' normal validation expectations; no policy file
or tests are edited to conceal outstanding release checks.

Implemented three small internal Android files using existing Android/JCA/Kotlin/
coroutines only. They provide real local key generation/signing, strict byte
encoding and an immutable result for exact retry. They have **no runtime callers**
in UI/auth/map/notifications/workers, network or persistence adapters.
No dummy credential registry, mock verification endpoint, inert SQL tables,
permissions, GPS API, worker, queue or enable flag is added.

## 2. As-found source contract matrix

| Contract | Actual identity/signature/security | Source / confirmed gap |
|---|---|---|
| Vehicle | public.operational_vehicles(id PK,organization_id,active,availability,version), UNIQUE(id,organization_id) | [supabase/migrations/20261007100000_operational_inventory_schema.sql:9](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/supabase/migrations/20261007100000_operational_inventory_schema.sql#L9); genuine owned asset, no device key |
| Operational unit | operational_units(id,organization_id,unit_kind,vehicle_id,active,version), same-org vehicle FK | [supabase/migrations/20261007100000_operational_inventory_schema.sql:13](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/supabase/migrations/20261007100000_operational_inventory_schema.sql#L13); optional vehicle, not every unit qualifies |
| Deployment | incident_units(id,incident_id,organization_id,unit_id,participation_id,status,version), UNIQUE(id,incident_id,organization_id) | [supabase/migrations/20261007100000_operational_inventory_schema.sql:25](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/supabase/migrations/20261007100000_operational_inventory_schema.sql#L25); same incident/org participant and unit FKs |
| Driver | incident_crew_members(id,incident_id,unit_assignment_id,user_id,membership_organization_id,crew_role,status,version); DRIVER/ACTIVE exists | [supabase/migrations/20261007100000_operational_inventory_schema.sql:36](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/supabase/migrations/20261007100000_operational_inventory_schema.sql#L36); current driver is distinct from signing-key possession or consent |
| Effective leader | private.field_unit_leader(uuid,uuid,uuid) RETURNS boolean + private.incident_assignment_effective(uuid) | [supabase/migrations/20261027100000_incident_android_field_pilot.sql:2](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/supabase/migrations/20261027100000_incident_android_field_pilot.sql#L2); leader fallback not approved by this task |
| Membership/read | private.incident_acting_member(uuid), private.is_active_user(), private.can_read_incident(uuid) | [supabase/migrations/20261006120000_incident_core.sql:35](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/supabase/migrations/20261006120000_incident_core.sql#L35); current auth/exact org/incident needed on server |
| B1 head | incident_sync_head(p_acting_organization_id uuid,p_incident_id uuid) RETURNS jsonb; current scope/locks, salted fingerprint | [supabase/migrations/20261030100000_incident_snapshot_protocol.sql:400](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/supabase/migrations/20261030100000_incident_snapshot_protocol.sql#L400); not GPS-reader permission |
| D1 receipts | private.incident_operation_receipts(operation_id PK,actor_user_id,acting_organization_id,incident_id,command_code,request≤65536bytes,result,created_at); immutable guards | [supabase/migrations/20261006120000_incident_core.sql:2](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/supabase/migrations/20261006120000_incident_core.sql#L2); no device-proof receipt/RPC implemented |
| M10 device | register_notification_device(installation uuid,token text,enabled boolean=true) RETURNS void; private.notification_devices installation/user/token/revision | [supabase/migrations/20261005140000_notifications.sql:69](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/supabase/migrations/20261005140000_notifications.sql#L69); supplied UUID/FCM can rebind, not possession proof |
| KeystoreSessionManager | AndroidKeyStore AES/GCM gasilko_auth_v1; SDK session/PKCE/authorization/incident lease | [android/app/src/main/java/si/gasilko/app/core/auth/KeystoreSessionManager.kt:26](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/android/app/src/main/java/si/gasilko/app/core/auth/KeystoreSessionManager.kt#L26); unrelated to new asymmetric keys; left unchanged |
| SDK/manifest | min26/compile36/target36; current fine/coarse/notification permissions, no location FGS/background location | [android/app/build.gradle.kts:9](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/android/app/build.gradle.kts#L9); Android/JCA EC signing available without new dependencies |
| C2 OFF RPC | incident_vehicle_location_capabilities(uuid,uuid) RETURNS jsonb; owner postgres, SECURITY DEFINER search_path='', authenticated EXECUTE, no table grants | [supabase/migrations/20261102140000_incident_vehicle_location_capability.sql:4](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/supabase/migrations/20261102140000_incident_vehicle_location_capability.sql#L4); DISABLED and all six flags false, unchanged |
| Android/Web OFF | VEHICLE_LOCATION_PRODUCER_ENABLED=false / vehicleLocationProducerEnabled=false; exact OFF decoder/manual account-scoped read | [android/app/src/main/java/si/gasilko/app/feature/incidents/VehicleLocationCapability.kt:8](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/android/app/src/main/java/si/gasilko/app/feature/incidents/VehicleLocationCapability.kt#L8); [web/lib/incidents/vehicleLocationCapability.ts:2](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/web/lib/incidents/vehicleLocationCapability.ts#L2); no local consent flag or START UI |
| Repository/UI | IncidentRepository.vehicleLocationCapability(org,incident), ViewModel, IncidentMapScreen Units; secure field lease and identity cancellation | [android/app/src/main/java/si/gasilko/app/feature/incidents/IncidentRepository.kt:115](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/android/app/src/main/java/si/gasilko/app/feature/incidents/IncidentRepository.kt#L115); no new crypto call wired to these |
| Room/local position | RegistryDatabase16, field cursor+projection; ForegroundLocation is local display/navigation only | existing source unchanged; no coordinate output used by new code |
| SIM/NAV | simulation_unit_positions CHECK source=SIMULATED; NAV ACTUAL_POSITION throws NAV_POSITION_UNAVAILABLE | 20261009140000 /20261012100000; no route/task/SIM coordinate is accepted here |
| Backend primitive | Deno Edge code already uses crypto.subtle.digest SHA-256 | [supabase/functions/incident-evidence/index.ts:90](https://github.com/ficlus/Gasilko/blob/f945fa12b6cfd3a321914825e22f5126ae2c81df/supabase/functions/incident-evidence/index.ts#L90); stack has WebCrypto primitives, not an implemented trusted ECDSA enrollment verifier |
| Actual credential infrastructure | M15A DDL/signatures are design text only; no current binding/challenge/consent tables/functions | pinned GitHub inventory/M15A; no assumption of installed objects |
| Deployment | owner-reported #86 attachment42601; #87–90/#92 installation unconfirmed | not inspected remotely, repaired, retried or assumed applied |

## 3. Implemented API and lifecycle

Package: `si.gasilko.app.core.security.deviceproof`. All types are internal,
regular final classes; sensitive objects' toString is redacted. No serialization
or logging is added. Public export means **public-key material**, not public
Android exported components or API grants.

| Implemented component | Actual behavior |
|---|---|
| DeviceProofScope | canonical non-nil UUIDs for account/org/incident/deployment/vehicle/driver episode; immutable, no proof of actual authorization |
| DeviceProofChallengeV1 | strictly typed M15A v1 fields, bounded ASCII/hash/nonce/version/time checks; exact transcript bytes; no challenge issuance |
| DeviceProofEncoding | canonical32-byte base64url nonce, SHA-256, canonical91-byte uncompressed P-256 SPKI validation, minimal DER↔raw64 ECDSA conversion |
| LocalDeviceProofAccess | ephemeral identity-epoch object with explicit expected audience/recoveryEpoch plus atomic revoke; thread-safe current-owner callback must return the SAME object, not merely same account strings |
| LocalDeviceProofKeys.createNew() | explicit IO call, fresh credential UUID and P-256 AndroidKeyStore key; no constructor/login/map/push generation or overwrite |
| openExisting(id,expectedPublicKeySha256) | reads only matching scoped key; checks original public hash; missing/invalidated/replaced key fails, NEVER generates replacement |
| prepareProof(credential,challenge) | checks current epoch/scope/expected audience+recoveryEpoch/key hash/credential ID/local window, signs SHA256withECDSA, validates DER and verifies local public/private correspondence, rechecks epoch/window; returns frozen local proof |
| PreparedLocalDeviceProof | defensive-copy transcript/DER/raw signature and public SPKI; retry original result bytes rather than signing again |
| revokeLocalAccess() / access.revoke() | immediate local rejection of future results/use; does NOT revoke a server credential or delete original operation evidence |
| deleteScopeKeys() | first revokes access, then deletes only its own namespace under shared mutex if no different access epoch is current; old logout cannot delete new-login keys; no auth AES/Room/files/receipt deletion |

Alias (environment/recovery epoch are part of the local namespace):
`gasilko_device_proof_v1_<SHA256(scope UUIDs + audience + recoveryEpoch)>_<fresh credential UUID>`.
Scope identity is six UUID strings in account/org/incident/deployment/vehicle/
driver-episode order separated by LF, followed by LF + expected audience + LF +
recoveryEpoch from the ephemeral access owner. No raw account/phone identifier in alias.
Credential UUID is local key identity, not a server binding receipt. Keys never
rotate in place: a deliberate new ceremony creates a new UUID/key. The signed
reservedGeneration is a positive server-claimed generation, not a locally verified
counter/lease; the future authoritative verifier must compare it under lock.

The key uses AndroidKeyStore EC/secp256r1, PURPOSE_SIGN and SHA-256 only.
Private-key handle is passed only to JCA; no private encoded bytes, tokens,
FCM installation or auth AES key are read/exported. Public SPKI is exported.
No software-key fallback, attestation, StrongBox requirement or biometric/user-
authentication prompt is implemented. setUserAuthenticationRequired(false) is
explicit for this local primitive: it is NOT consent or human-presence assurance.
If A01 later requires stronger use/hardware guarantees, review a new key policy;
do not silently claim these keys meet it. Possession is not genuine GNSS/driver
identity and an already compromised app may use a Keystore key.

Future caller obligations are explicit and **not integrated** into existing auth:
create access only for a deliberate local ceremony; source currentAccess from a
thread-safe authenticated scope owner; revoke/replace the epoch immediately on
logout/account/org/incident/role/capability/policy/environment change; discard in-flight proof UI;
perform own-namespace deletion when appropriate. Same-account logout/login must
create a fresh epoch object (ABA protection). No persisted “approved” access.

Methods serialize with one process-wide mutex, check coroutine cancellation and
scope before/after crypto. Creation attempts cleanup of its newly generated key
if it cannot finish; existing keys are not silently replaced/deleted on sign
failure. Process death or cancellation at the final delivery boundary may leave
an unregistered key in this isolated namespace; future explicit cleanup must
handle it. No enrollment/network effect or GPS can result. The APIs are not an
atomic auth/logout transaction and a future caller must recheck identity at
durable enqueue/network use; server revalidation remains essential.

Uninstall/key loss/restore: openExisting fails unavailable or invalidated; there
is no regeneration path on read. A restored public reference is not possession.
Errors expose only DeviceProofError enum names, no provider exception cause/body.
Cleanup failure is reported while preserving coroutine cancellation; it never
returns a successful credential. Local deletion alone is NOT server revocation.

## 4. Canonical v1 transcript, SPKI and signatures

This implements the byte encoder proposed by M15A, not a new server protocol.
Exactly27 ordered ASCII lines, UTF-8, LF-only and ONE final LF, no BOM/CR/JSON:

```text
GASILKO-VEHICLE-PHONE-BINDING-V1
audience
recoveryEpoch
BIND_INACTIVE
scope.account
scope.organization
scope.incident
REAL
scope.deployment
scope.vehicle
scope.authorityEpisode
DRIVER
credentialId
publicKeySha256
policyVersion
policyDocumentSha256
preciseAudienceSha256
issueOperationId
confirmOperationId
challengeId
nonceBase64Url
issuedAtSeconds
expiresAtSeconds
expectedIncidentVersion
expectedDeploymentVersion
expectedVehicleVersion
reservedGeneration
```

UUIDs canonical lowercase/non-nil; audience1..128 ASCII [A-Za-z0-9._:/-];
policy version1..64 [A-Za-z0-9._-]; hashes exactly64 lowercase hex.
Nonce exactly43 unpadded base64url chars decoding to32 bytes with identical
re-encoding. Timestamps are nonnegative signed64-bit seconds, checked against
overflow; expiry exactly issue+120. Versions/generation are positive signed64-
bit values serialized canonically as decimal, not JS floating point. Issue and
confirm operation UUIDs must differ. No source mode/authority-kind parameter can
replace fixed REAL/DRIVER; these literals are claims, NOT server authorization.

Local sign-window check uses supplied nowSeconds (default device wall seconds):
issued≤now<expiry. It is advisory and can reject clock-skewed input; it is NOT
trusted server time or replay protection. A changed device clock cannot grant
server authority because none exists here; future server must enforce its own
clock, live scope, exact original challenge, nonce and single consumption.

SPKI accepts only canonical DER id-ecPublicKey with namedCurve prime256v1 and
uncompressed point:91 bytes; fixed algorithm prefix, exact re-encoding, full
curve parameters, finite field bounds and on-curve check. Reject compressed,
alternate/nonnamed curves, invalid/infinity points, trailing/oversized input.
This is a deliberately narrow local encoding profile, refining the unimplemented
M15A ≤256-byte proposal; future verifier must adopt/review the same contract.

SHA256withECDSA emits DER SEQUENCE of two minimal positive INTEGER scalars.
derToRaw requires8..72 bytes, short canonical lengths/tags, no negative/
redundant sign/trailing bytes and1≤r,s<curve order. Raw is exactly64 bytes,
unsigned r[32]||s[32], as used by WebCrypto. rawToDer preserves exact r,s,
using required sign padding; no low-S normalization/re-signing is performed.
JCA signing/verifying hashes transcript once; never pass an already-SHA256
digest as the message. Crypto itself uses platform primitives, not a custom
ECDSA implementation; strict format parsing is local boundary validation.

The returned proof is immutable by defensive copies and has no automatic
transport/storage. A second prepareProof call may yield a different valid
ECDSA signature: it is **not** an idempotent server command. Future retries must
retain the first PreparedLocalDeviceProof and immutable operation identity.
After process death, durable exact-proof retention/recovery needs separate
approved integration; this PR supplies no queue, draft or claim ledger.

## 5. Server contract review — NOT IMPLEMENTED

Deno WebCrypto provides ECDSA verification primitives; checked-in Edge code
already uses WebCrypto hashing. There is **no actual trusted device verifier,
challenge issuance/consumption endpoint or private binding schema** in source.
No pgcrypto ECDSA verification function is invented. pgcrypto's hashing/PGP APIs
are not a drop-in verifier for this DER/SPKI protocol.

A future trusted verifier would authenticate the Supabase JWT, import canonical
SPKI as ECDSA/P-256 and verify SHA-256 over these exact bytes using raw64 signature.
JWT authentication, current active DRIVER authority, key possession and informed
human GPS consent are FOUR separate conditions. A successful local JCA verify
proves only local key correspondence. No result here is PROOF_VALIDATED_INACTIVE
or a server receipt, let alone sharing authorization.

New trusted Edge/service-role boundary and current DB rechecks require review;
do not modify existing evidence/NAV/M10/SIM Edge handlers or expose a verifier
boolean/direct credential DML to Android/Web. M15A's proposed private DDL,
signatures/owner/search_path/grants remain **design only**, not installed.
No inert tables are shipped without a safe complete verifier; no migration.

Future transactional consumption requirements:
1. Secure server-random32-byte nonce,120s server TTL, original actor/org/
   incident/deployment/vehicle/key/purpose/audience/policy/recovery epoch/
   operation/generation binding. Scope/policy/version changes invalidate.
2. Authenticate/verify outside any long-held DB transaction; then acquire
   canonical operation/org/profile/incident/vehicle-slot locks and recheck live
   REAL ACTIVE driver/deployment/vehicle/membership, policy and exact challenge.
3. Atomically claim only ISSUED/unexpired/unrevoked challenge (locked row or
   conditional UPDATE with consumed_at), inactive binding/slot, audit and
   original immutable canonical receipt in ONE transaction. Two concurrent
   consumes cannot both succeed. No implicit competing-device takeover.
4. Compare full normalized phase-specific request and original actor/org/
   operation. ISSUE reuses server-generated nonce/time/generation outputs;
   CONFIRM freezes transcript/signature digests. Same UUID/different request
   is OPERATION_REUSED. Missing receipt or ambiguous dispatch remains UNKNOWN;
   a later validation rejection cannot prove an earlier unknown failed.
5. Receipt replay after revocation returns immutable evidence/current revoked
   status separately, never reactivates a generation. Restoration requires
   owner quarantine/epoch policy, not resetting old counters.
6. Future SQL: forward-only, private tables, verified composite FKs, owner
   postgres, SECURITY DEFINER search_path='', qualified names, narrow grants,
   no PUBLIC/anon/direct client table access. No existing receipt/queue shape
   or D1 classification changed in anticipation.

Proposed architecture remains in M15A §5; M15A.1 installs no new SQL signature,
grants, credential, active consent or START/SAMPLE/STOP/LEAVE RPC. Backend runtime
support is source/API capability, not remotely verified compatibility or deployed
functionality. No remote Supabase inspection/SQL occurred.

## 6. States and safety gates

DeviceProofPhase defines the requested vocabulary only:
UNAVAILABLE, POLICY_UNAPPROVED, DEVICE_UNBOUND, PROOF_PENDING,
PROOF_VALIDATED_INACTIVE, BINDING_PENDING_APPROVAL, BOUND_INACTIVE,
REVOKED, EXPIRED, OUTCOME_UNKNOWN. There is no transition engine, SHARING state,
JSON authorization parser or automatic promotion. PreparedLocalDeviceProof is
only a local signed payload, never a server-validated or approved state.

Existing public runtime stays DISABLED. C2 six false flags, Android/Web false
producer constants/exact decoders remain unchanged. No key operation is wired
to the current OFF card, login, map, registry, FCM or worker. No clickable pairing/
START/permission UI, duplicate notice, polling or local “consent approved” flag.
Default/Sl/De existing explanations/accessibility retained.

P01–P14 and A01 all remain UNAPPROVED. Local key creation/signing is not approval.
No GPS collection, coordinate/sample/history/trail/store/viewer, location
permissions/FGS/background service, new worker/queue/Cron/channel, telemetry
metadata or position inference from NAV/tasks/SIM. Room16, field B1 atomic
projection/cursor, D1/D2 original UUID/requests/receipts, registry/photos and
current role/command hierarchy remain unchanged.

Physical privacy gate:120s challenge TTL is separate from120s stale marker/
900s intended position expiry. Stale UI suppression is NOT physical deletion.
Future no-traffic scheduled deletion/alerts/SLA, backups/PITR/WAL/restore, logs/
caches and offline withdrawal risk need owner approval. Offline STOP cannot
instantly revoke server state; finite lease + safe durable revoke are future
requirements, not implemented APIs here.

## 7. Threats / implemented versus future-only mitigation

| Attack/failure | Implemented locally | Future-only / limitation |
|---|---|---|
| Stolen phone | app-owned nonexportable key, explicit scope epoch revoke and namespace deletion APIs | no hardware/biometric/human-presence assurance; compromised process may sign; stolen-phone server revoke/finite lease not implemented |
| Stolen session/FCM | no token/installation used as key identity; no enrollment endpoint | JWT alone cannot justify new driver key; current auth/driver/consent + assurance policy needed |
| Wrong org/incident/vehicle | immutable scope and credential/challenge match before sign, expected audience/recoveryEpoch | IDs are typed claims, actual canonical joins/authorization must be rechecked server-side |
| Replaced/invalidated key | expected SPKI hash + exact scoped alias + no read regeneration; sanitized unavailable/invalidated error | key rotation/replacement approval, new server generation/receipt |
| Restored app without key | openExisting fails; no copied private key or local approval recovered | fresh owner-initiated ceremony; restore quarantine and recovery-epoch policy |
| Logout/account switch/ABA | revocable ephemeral access identity; pre/post checks, cancelled result rejected | future authenticated owner MUST revoke/replace and cleanup; no existing logout/enrollment flow is modified |
| Malformed DER/SPKI/public injection | strict bounded formats, curve/point/range checks, own local signature verification | remote malicious-key validation and trusted verifier absent |
| Signature replay/duplicate claims | exact immutable bytes available for retry; local encoding cannot consume or enroll | original receipt-first request comparison, transactional nonce claim and single holder lock/CAS are NOT IMPLEMENTED |
| Scope/driver/policy changes mid-confirm | local access epoch can reject old result | current role/policy/deployment/vehicle/state checks under server lock, including revocation after crypto check |
| Clock skew/future/expired nonce | typed exact120s interval + advisory local sign window | true server time/randomness/one-time consumption absent; device clock is not authority |
| Unknown response / stale receipt | no network or state promotion; PreparedLocalDeviceProof retained by caller only | durable same-proof retry/UNKNOWN/receipt recovery after process death and revoke never reactivation |
| Concurrent operations | process-wide mutex prevents local create/delete/sign races; atomic local revoke need not wait | distributed competing binding/parallel consume transactions and idempotency absent |
| Offline STOP | no active sharing/STOP method can run | immediate local capture stop is not immediate server revoke; finite lease and durable non-coordinate revoke needed later |
| Backup/log/privacy leakage | no logging/serialization/private export/network/cache/coordinate added; redacted objects and safe exceptions | approved protected metadata retention, live-row deletion, backups/PITR/WAL/logs/cache policy and alerts remain open |
| Device “truth” | signature proves key correspondence only | does not prove hardware, present driver or actual GPS; attestation/spoof policy remains A01/P08 |

No operation UUID is generated for a server mutation. createNew creates only a
fresh local key UUID; it is not an idempotent enrollment command. Calling it twice
deliberately creates two local keys, not two server holders. Future ceremony
must create once and retain/open the original key, never use createNew for
unknown-response retries. No automatic recovery claims or server success.

## 8. Dependencies, sources and owner rollout

M15B future work: approved enrollment/privacy/device assurance, fresh authenticated
owner integration, trusted ECDSA verifier + current canonical authority/transaction
logic, bounded secure original-proof metadata persistence and receipt recovery.
M15C future work: separately approved consent/finite sharing lease, STOP/offline
revoke, independently running physical deletion/backup plan, producer and private
current-point projection. Neither milestone is authorized/implemented by this PR.
P01–P14/A01 remain open; local proof cannot make any C2 capability flag true.

Official primary API sources reviewed2026-11-03:
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
  and [KeyGenParameterSpec](https://developer.android.com/reference/android/security/keystore/KeyGenParameterSpec):
  AndroidKeyStore EC signing API and nonexportability/compromised-process limits.
- [RFC5480](https://www.rfc-editor.org/rfc/rfc5480): EC SPKI algorithm/curve/point encoding.
- [W3C WebCrypto ECDSA](https://www.w3.org/TR/webcrypto-1/#ecdsa-operations):
  raw fixed-width r||s, distinct from JCA DER.
- [Deno Crypto](https://docs.deno.com/api/web/crypto/):
  WebCrypto primitive availability, not deployment of this protocol's verifier.
- [PostgreSQL17 pgcrypto](https://www.postgresql.org/docs/17/pgcrypto.html):
  no invented ECDSA verification interface assumed.
These are source/API references, not execution or device/backend compatibility
results. No downloaded SDK, package, toolchain or dependency change.

No migration, new SQL signature, grant/RLS/schema/index/credential row or Edge
function. M15A's detailed DDL remains design only. Owner append/order:
1. Review source/merge only as owner; preserve local files and pending evidence.
2. Reconcile installed #82–85 independently; do not assume SQL Editor ledger or
   reported source merge proves installation.
3. Current owner-reported #86 attachment migration
   20261030160000_incident_private_attachments.sql failed42601. DO NOT retry/fix/
   apply it here; obtain actual partial-install evidence and separate correction.
4. #87 20261030180000_android_unit_leadership.sql;
   #88 20261030200000_incident_field_map.sql;
   #89 20261102100000_incident_field_receipt_recovery.sql;
   #90 20261102120000_incident_field_reliability.sql and
   #92 20261102140000_incident_vehicle_location_capability.sql are NOT confirmed
   applied. #91/#93 have no SQL. Resolve prerequisites and apply only correct
   unapplied migrations in owner-approved order; no blind replay.
5. M15A.1 has no SQL or Edge to install. Owner's later Android build may include
   unused local primitives; app behavior/Room16/server compatibility remains
   unchanged. There is no key generation or GPS simply from installation.
6. Any future verified binding migration must be forward-only after actual latest
   merged migration (at least #92's timestamp), with explicit narrow owner/grants,
   verifier, current authorization, idempotency and manual acceptance. None now.
7. Owner alone builds/installs/deploys/runs SQL and signs policy/operations off.

Rollback: remove unused primitive integration/source through normal forward
review if needed; no server/Room/schema rollback. If owner manually exercised
local key methods, explicit deleteScopeKeys targets only that exact protocol/
scope/environment namespace. It does not revoke server state or erase pending
evidence, auth AES, metadata backups or originals; future remotely enrolled
credentials would require authenticated revoke/reconciliation before backout.
No feature enabled, private data uploaded, observer notified or operational
release asserted by this source change.

## 9. Owner manual scenarios — all UNEXECUTED

No test, automated harness, build, SQL/runtime/device check or real key generation
was performed by the agent. Local cases require a later owner-authorized explicit
developer exercise of these internal APIs; there is no product pairing button.
Cases requiring missing verifier/policy are NOT_IMPLEMENTED/BLOCKED_BY_POLICY.

| ID | Scenario | Expected result / required evidence | Status |
|---|---|---|---|
| A1-001 | Passive construction/class load | No key, prompt, callback, network, worker or permission created. | UNEXECUTED |
| A1-002 | Explicit createNew | P-256 key stored only in AndroidKeyStore; new UUID, public SPKI returned, no server credential. | UNEXECUTED |
| A1-003 | Alias namespace | Versioned scope UUIDs + audience + recoveryEpoch hash and credential UUID; no raw phone/token/account alias. | UNEXECUTED |
| A1-004 | Fresh credential on explicit rotation | New UUID/key, never overwrites old alias or implies new server generation. | UNEXECUTED |
| A1-005 | openExisting same reference | Original scoped public SPKI hash matches; no generation side effect. | UNEXECUTED |
| A1-006 | Missing alias | KEY_UNAVAILABLE; never silently regenerates old credential identity. | UNEXECUTED |
| A1-007 | Restored public metadata/no private key | Read/sign fails; no approval or enrollment reconstructed. | UNEXECUTED |
| A1-008 | Invalidated/unrecoverable key | Sanitized KEY_INVALIDATED/KEY_UNAVAILABLE or safe crypto failure; no software fallback. | UNEXECUTED |
| A1-009 | Wrong expected public hash | PUBLIC_KEY_MISMATCH and no sign/new key. | UNEXECUTED |
| A1-010 | Private-key export/log inspection | No private encoded bytes/token/log call; only public SPKI and signature/transcript APIs. | UNEXECUTED |
| A1-011 | Canonical public SPKI | 91-byte uncompressed P-256 named curve, exact encoding/hash. | UNEXECUTED |
| A1-012 | Wrong key algorithm/curve | Reject RSA/other EC parameters or compressed/alternate profile. | UNEXECUTED |
| A1-013 | Malformed/oversized/trailing SPKI | Reject prefix/length/re-encoding mismatch; no valid credential returned. | UNEXECUTED |
| A1-014 | Invalid/infinity/off-curve public point | Reject null/out-of-field/not-on-curve point. | UNEXECUTED |
| A1-015 | Exact v1 transcript | 27 lines, LF and one final LF; byte-for-byte M15A order and fixed BIND_INACTIVE/REAL/DRIVER. | UNEXECUTED |
| A1-016 | Canonical UUIDs | Reject uppercase, malformed/noncanonical and nil IDs. | UNEXECUTED |
| A1-017 | Audience delimiter injection | Reject newline/CR/unicode/oversized audience, no ambiguous signing bytes. | UNEXECUTED |
| A1-018 | Policy version injection | Reject invalid characters or length; no local approved flag. | UNEXECUTED |
| A1-019 | Hash syntax | Reject non64 lowercase hex key/policy/audience hashes. | UNEXECUTED |
| A1-020 | Nonce32 canonical base64url | Decode/re-encode identical43 chars, unpadded, no whitespace. | UNEXECUTED |
| A1-021 | Invalid nonce encoding | Reject padding/bad alphabet/noncanonical trailing bits/wrong size. | UNEXECUTED |
| A1-022 | Challenge interval | Expiry exactly issue+120, no negative issue/overflow. | UNEXECUTED |
| A1-023 | Positive versions/generation | Reject0/negative; preserve Long precision in decimal transcript. | UNEXECUTED |
| A1-024 | Distinct issue/confirm operations | Same UUID rejected; no operation silently replaced. | UNEXECUTED |
| A1-025 | Local clock before issue | EXPIRED local guard, no proof returned; no claim of trusted server time. | UNEXECUTED |
| A1-026 | Local clock exactly expiry | No proof at expiry;119s boundary can be exercised with controlled owner clock callback. | UNEXECUTED |
| A1-027 | Wrong scope challenge | Account/org/incident/deployment/vehicle/authority episode mismatch denied locally. | UNEXECUTED |
| A1-028 | Wrong environment/recovery epoch | Challenge audience/epoch mismatch denied and key namespace isolated. | UNEXECUTED |
| A1-029 | Wrong credential ID/hash | No signing under a different local credential. | UNEXECUTED |
| A1-030 | Local sign and correspondence verify | JCA SHA256withECDSA over original bytes, own public key verifies, no server-validation state. | UNEXECUTED |
| A1-031 | DER positive high-bit padding | Preserve required INTEGER sign byte; raw r/s zero-padded32 each. | UNEXECUTED |
| A1-032 | DER negative/redundant padding | Reject nonminimal/negative/zero integer. | UNEXECUTED |
| A1-033 | DER wrong tags/long lengths/truncation | Reject before valid result; no permissive ASN.1 fallback. | UNEXECUTED |
| A1-034 | DER trailing/extra INTEGER | Reject leftover bytes or third scalar. | UNEXECUTED |
| A1-035 | Scalar zero/order/overflow | Require1≤r,s<curve order and at most256-bit magnitude. | UNEXECUTED |
| A1-036 | Raw signature conversion | Exactly64 bytes; deterministic minimal DER preserves r/s. | UNEXECUTED |
| A1-037 | DER/raw distinct API | Never pass DER to WebCrypto or raw directly to JCA verify. | UNEXECUTED |
| A1-038 | Frozen result defensive copies | Mutating returned transcript/signature/SPKI cannot modify stored immutable result. | UNEXECUTED |
| A1-039 | Repeated sign vs exact retry | Retain returned bytes for retry; second prepare may sign differently, no idempotency claim. | UNEXECUTED |
| A1-040 | Same-account ABA | Replace access object on logout/login; old object rejected even if UUIDs match again. | UNEXECUTED |
| A1-041 | Revoke during sign/create | Atomic revoke is immediate; postcheck rejects new result; failed-new-key cleanup attempted. | UNEXECUTED |
| A1-042 | Scope cleanup | Only owned namespace keys deleted; auth AES/Room/queue/other scopes/environment untouched. | UNEXECUTED |
| A1-043 | Cancellation/process death handoff | No remote enrollment; possible orphan local key requires later explicit namespace cleanup, no fake cleanup guarantee. | UNEXECUTED |
| A1-044 | Sanitized errors/redacted objects | Enum-only errors and redacted toString; no provider cause/private key/nonce/token logging. | UNEXECUTED |
| A1-045 | Trusted verifier unavailable | No inactive binding/credential/proof-validated state until real verified Edge + DB boundary implemented. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-046 | JWT/driver/key/consent separation | Each condition independently checked; valid local proof/JWT is insufficient. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-047 | Stolen bearer/new attacker key | Owner A01/P02 assurance decision required; no device enrollment in current app. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-048 | Wrong driver or leader fallback | Canonical current DRIVER episode and exact org required; UNIT_LEADER fallback remains unapproved. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-049 | Role revoked between challenge/confirm | Server current recheck under lock; no stale authority from local typed context. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-050 | Vehicle reassigned/released | Invalidate old challenge/generation; original selection/frozen intent unchanged. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-051 | Incident terminal/TRAINING | Deny future enrollment/use; SIM remains SIMULATED, no ACTUAL_POSITION fallback. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-052 | Server nonce randomness/TTL | Secure server32-byte one-use challenge, server120s clock validation, no client nonce issuance. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-053 | Parallel consume | Transactional conditional claim/row lock; at most one successful authoritative consume. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-054 | Parallel competing vehicle binding | Single holder/generation lock/CAS, no automatic takeover or duplicate ownership. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-055 | Issue response lost | Original operation returns same nonce/time/generation, never a new challenge under same operation. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-056 | Confirm response lost | Receipt-first exact original proof/request; no new UUID/owner merely because timeout. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-057 | UUID reuse changed request | OPERATION_REUSED and no new binding. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-058 | Expired/revoked generation replay | Original receipt never reactivates holder; current status separately returned. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-059 | Unknown then validation rejection | Preserve UNKNOWN; later error/absent receipt cannot prove first attempt failed. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-060 | Current membership/org/account denial | No cross-scope server credential or read; original immutable evidence retained. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-061 | Attestation required | No claim of hardware/driver/GNSS proof from self-signed certificate or client flag. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-062 | Offline STOP | No current STOP/SHARING; future immediate local stop is not instant remote revoke; finite lease required. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-063 | Physical retention/PITR | Independent no-traffic deletion plus backups/WAL/cache policy; TTL marker suppression not erasure. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-064 | Approved consent/START/GPS viewer | Not implemented; all P01–P14/A01 unapproved, no source position or active capability. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A1-065 | C2 public capability | DISABLED; six readiness flags false, no change after local proof API use. | UNEXECUTED |
| A1-066 | Current application launch/map/FCM | No primitive caller/key creation/enrollment on login/map/notification registration. | UNEXECUTED |
| A1-067 | No GPS permissions/FGS | Manifest unchanged; no background location/service or runtime permission request added. | UNEXECUTED |
| A1-068 | No coordinates/sample/trails | New package has no location/GeoPoint or transport integration; NAV/SIM/tasks not observations. | UNEXECUTED |
| A1-069 | Android/Web old server | Existing missing capability schema stays unverified/OFF and ordinary field use remains. | UNEXECUTED |
| A1-070 | SI/DE/default UI | Existing one OFF card/accessible labels retained, no fake pairing/START button or repeated notice. | UNEXECUTED |
| A1-071 | Room16/registry/photos | Schema, cached registry/field, inspections/photos and original pending data unchanged. | UNEXECUTED |
| A1-072 | D1/D2/B1 compatibility | No cursor/receipt/queue/authorization/role behavior changed; pending IDs/dependencies/history preserved. | UNEXECUTED |
| A1-073 | No new infrastructure | No SQL table/RPC/grant, Edge worker/channel/Cron/secret or deployment. | UNEXECUTED |
| A1-074 | Owner rollout order | #86 failed42601 remains unmodified; #87–90/#92 unconfirmed; no migration until future safe forward design. | UNEXECUTED |
| A1-075 | Delayed old-epoch logout cleanup after new login | Shared key mutex + current owner guard rejects old cleanup; fresh epoch keys are not deleted. | UNEXECUTED |

## 10. Results and remaining gates

75 scenarios: all UNEXECUTED;20 NOT_IMPLEMENTED/BLOCKED_BY_POLICY.
Source implementation is not runtime, build, crypto-device interoperability,
backend verifier, enrolled credential, approved policy or operational release.

Remaining: owner local crypto/API-level provider checks, exact interoperability
with a future trusted verifier, authenticated lifecycle integration, durable
original-proof retry/revocation, policy/device assurance, no-traffic physical
retention/backups, reported SQL #86 and unconfirmed rollout. No new SPEC behavior
deviation: safe local-only primitives implement the requested subset; server
binding/GPS remain deliberately absent. No production role or consent decision
is invented to make a check pass.

No tests created/modified/run; no build, lint/typecheck/CI/monitoring, Gradle sync,
Android Studio/emulator/browser/runtime/key generation/signature exercise,
SQL/remote Supabase inspection/execution/application, deploy/install or merge.
No Gradle/KAPT/KSP/dependency/generated Room/manifest/local settings changes,
secrets/Cron/M10/NAV/SIM runner edits or policy approval. [skip ci] implementation
commit. Owner alone performs rollout and acceptance.
