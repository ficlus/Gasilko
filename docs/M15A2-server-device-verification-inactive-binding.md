# M15A.2 — server device verification and inactive-binding boundary

2026-11-03 · **GPS DISABLED · P01–P14/A01 UNAPPROVED · SOURCE ONLY**
**No build, test, crypto execution, SQL, runtime validation or deployment performed.**

## 1. Baseline and actual result

Base main `b4955da25fb65783af35a9ea66c9805f558a1931`.
PR #94 is confirmed CLOSED/MERGED; reviewed head
`de3f6b9b22e3d4cc8e4ef8c01c643f5d8ef3e28b` is an ancestor
(compare head→main ahead2/behind0; merge commit
`8b081a8ad7c6a7a8faa14dd623caddf15150fb38`). No overlapping open PRs at initial inspection.
A new branch is based on this current main; owner local files are untouched.

The permitted §4/§9 fallback is implemented: an isolated standards-based
**pure cryptographic verifier**, not an exposed enrollment service. No approved
policy hashes, recovery-epoch authority or registered device credential contract
currently exists. Adding inert credential tables without safe usable issuance/
verification/retention would not establish those dependencies. No SQL migration,
RPC, HTTP handler, private row, grant, service secret or config change is added.

Files: new `supabase/functions/_shared/deviceProofV1.ts`, this document and a
factual M14 SPEC note. The module has no imports, Deno.serve, fetch, database,
clock/randomness source, registration/nonce issuance or consumption. No existing
Edge/Web/Android function imports/calls it. A successful result is explicitly
SIGNATURE_VALID_ONLY, not PROOF_VALIDATED_INACTIVE, pairing/consent approval or
a server receipt. It is actual crypto code, not an accept-all/fake verifier.

Read AGENTS, primary/M14 SPEC, M15A/M15A.1, C2/C3, B1/B2/C1/D1/D2/unit leadership,
M10/NAV docs and root/SPECS references/queue. Root M15A.2 assignment controls this
scope; queue is a planning snapshot. The explicit no-test/no-execution owner rule
overrides ordinary AGENTS validation requirements here; release checks remain open.

## 2. As-found contract matrix

| Object | Exact existing columns/signature | Authorization / security guarantee | Missing / planned change |
|---|---|---|---|
| [supabase/migrations/20261007100000_operational_inventory_schema.sql:9](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/supabase/migrations/20261007100000_operational_inventory_schema.sql#L9) | operational_vehicles id,organization_id,active,availability,version; operational_units id,organization_id,vehicle_id,unit_kind,version; same-org composite vehicle FK | owned canonical assets, optional unit vehicle | no device credential; unchanged |
| [supabase/migrations/20261007100000_operational_inventory_schema.sql:25](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/supabase/migrations/20261007100000_operational_inventory_schema.sql#L25) | incident_units id,incident_id,participation_id,organization_id,unit_id,status,version; UNIQUE(id,incident_id,organization_id) | same org/incident participant + inventory unit FKs | future verifier must rejoin actual current vehicle; unchanged |
| [supabase/migrations/20261007100000_operational_inventory_schema.sql:36](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/supabase/migrations/20261007100000_operational_inventory_schema.sql#L36) | incident_crew_members id,incident_id,unit_assignment_id,user_id,membership_organization_id,crew_role,status,version | current DRIVER/ACTIVE episode available | role is not consent/key possession; unchanged |
| [supabase/migrations/20261027100000_incident_android_field_pilot.sql:2](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/supabase/migrations/20261027100000_incident_android_field_pilot.sql#L2) | private.field_unit_leader(uuid,uuid,uuid), field_unit_visible(uuid,uuid,uuid), incident_assignment_effective(uuid) | current active crew/effective command and exact field scope | leader/admin not automatically authorized for device binding |
| [supabase/migrations/20261030100000_incident_snapshot_protocol.sql:400](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/supabase/migrations/20261030100000_incident_snapshot_protocol.sql#L400) | public.incident_sync_head(p_acting_organization_id uuid,p_incident_id uuid) RETURNS jsonb | incident_sync_lock, active actor/exact-org membership/current can_read_incident and participation; salted scope fingerprint | field/name visibility is not precise GPS permission |
| [supabase/migrations/20261006120000_incident_core.sql:2](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/supabase/migrations/20261006120000_incident_core.sql#L2) | private.incident_operation_receipts operation_id PK,actor_user_id,acting_organization_id,incident_id,command_code,request≤64KiB,result,created_at | private immutable original operation/request/result | no binding command/receipt reuse added; future transactional contract required |
| [supabase/migrations/20261005140000_notifications.sql:69](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/supabase/migrations/20261005140000_notifications.sql#L69) | register_notification_device(installation uuid,token text,enabled boolean=true) RETURNS void; notification_devices installation/user/token/active/revision | caller supplies UUID/token; row may rebind actor | NOT proof of possession, unchanged |
| [android/app/src/main/java/si/gasilko/app/core/auth/KeystoreSessionManager.kt:26](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/android/app/src/main/java/si/gasilko/app/core/auth/KeystoreSessionManager.kt#L26) | KeystoreSessionManager AndroidKeyStore AES/GCM SDK session/PKCE/authorization/lease | secure local auth persistence | not asymmetric device identity, unchanged |
| [android/app/src/main/java/si/gasilko/app/core/security/deviceproof/DeviceProofProtocol.kt:53](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/android/app/src/main/java/si/gasilko/app/core/security/deviceproof/DeviceProofProtocol.kt#L53) | DeviceProofChallengeV1.bytes() exact27 lines; typed Long versions/timestamps | canonical ASCII/UUID/nonce/window encoding | authoritative Android byte contract, unchanged |
| [android/app/src/main/java/si/gasilko/app/core/security/deviceproof/DeviceProofEncoding.kt:42](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/android/app/src/main/java/si/gasilko/app/core/security/deviceproof/DeviceProofEncoding.kt#L42) | DeviceProofEncoding publicKey/derToRaw/rawToDer |91-byte canonical SPKI, scalar/point validation | server implementation mirrors profile |
| [android/app/src/main/java/si/gasilko/app/core/security/deviceproof/LocalDeviceProofKeys.kt:91](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/android/app/src/main/java/si/gasilko/app/core/security/deviceproof/LocalDeviceProofKeys.kt#L91) | LocalDeviceProofKeys.prepareProof, createNew/openExisting/access epoch/namespace cleanup | explicit local P-256 sign/correspondence verify; no read regeneration | no server credential, consent or enrollment; unchanged |
| [supabase/migrations/20261102140000_incident_vehicle_location_capability.sql:4](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/supabase/migrations/20261102140000_incident_vehicle_location_capability.sql#L4) | incident_vehicle_location_capabilities(uuid,uuid) RETURNS jsonb; SECURITY DEFINER search_path='',postgres owner, authenticated EXECUTE only | DISABLED; enabled/producer_available/reader_available/policy_approved/retention_ready/device_binding_ready=false | unchanged, no local success may turn flags on |
| [supabase/functions/incident-evidence/index.ts:53](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/supabase/functions/incident-evidence/index.ts#L53) | incident-evidence Deno.serve; user JWT forwarded to authorized RPC, separate service-only object verification; existing crypto.subtle.digest | existing protected evidence trust boundary, not device verifier | NOT reused/modified for device proof; new library only |
| supabase/config.toml | private schema not exposed; existing function settings | no device-proof handler or JWT exception | unchanged; no verify_jwt=false workaround |
| web/app/api/incidents/route.ts | same-origin ACTIVE account + X-Gasilko-Account, RPC allowlist | current caller read/mutation gates | no new route/allowlist or success-flag finalizer |
| [android/app/src/main/java/si/gasilko/app/core/database/RegistryDatabase.kt:130](https://github.com/ficlus/Gasilko/blob/b4955da25fb65783af35a9ea66c9805f558a1931/android/app/src/main/java/si/gasilko/app/core/database/RegistryDatabase.kt#L130) | RegistryDatabase version16, B1 cursor/projection, original pending operations | atomic existing cache/receipt recovery and leases | no migration/queue/worker; unchanged |
| Current GitHub inventory/M15A docs | no installed-source vehicle credential/challenge/enrollment/claim/finalize objects; proposed names only | none to reuse operationally | callable path BLOCKED_BY_POLICY/BLOCKED_BY_INFRASTRUCTURE |
| NAV/SIM/C3 source | NAV ACTUAL_POSITION unavailable; SIM CHECK SIMULATED; C3 null positions | routing/task intent != observed REAL source | unchanged; no GPS/readiness inferred |

Existing SDK/toolchain/dependencies and generated schemas are untouched.
No claim is made about actual installed Supabase objects. Owner reports #86
failed42601; #87–90/#92 and incident-evidence Edge deployment remain unconfirmed.

## 3. Implemented pure module and input provenance

Exports:
- encodeDeviceProofTranscriptV1(value: unknown): Uint8Array
- verifyDeviceProofV1(input: unknown): Promise<DeviceSignatureEvidenceV1>
- readonly in-memory types and bounded DeviceProofFailure codes.

These are ES-module functions, NOT RPCs or deployed Edge endpoints.
The verifier input has exactly challenge/credential/context/proof. Records must
be plain data with the exact own fields; unexpected keys (including verified,
private key or replacement SPKI in client proof), accessors/symbols are rejected.
Every field and byte array is copied before the first await. Mutable caller
buffers cannot retarget the in-flight mathematical check.

The types are **not proof of origin**. Future trusted code must obtain:
- challenge from a current private authoritative issued/claimed row;
- credential from trusted registered storage, never a client replacement key;
- context from verified JWT actor, current authorized SQL scope/versions and
  server-configured audience/epoch/policy plus trustworthy server time;
- proof only from the matching frozen client submission.

There is no registered storage/lookup, JWT verifier or current DRIVER query
inside the module. Supplying an arbitrary object called “credential” cannot
enroll a key or establish authenticated ownership. No runtime caller exists.
A malicious privileged server caller can fabricate snapshots; this library
cannot replace the future trust/authorization boundary.

In-memory objects (not guessed SQL columns or a wire/JSON endpoint):
- DeviceProofScopeV1: account,organization,incident,deployment,vehicle,
  authorityEpisode (canonical non-nil lowercase UUIDs).
- DeviceProofChallengeV1: protocolVersion=1,scope and exact fields in §4.
- DeviceCredentialSnapshotV1: protocolVersion=1,credentialId,scope,generation,
  lifecycleStatus INACTIVE|REVOKED,publicKeySha256,publicKeySpkiDer Uint8Array.
- DeviceProofContextV1: account,organization,scope,audience,recoveryEpoch,
  policyVersion,policyDocumentSha256,preciseAudienceSha256,incidentVersion,
  deploymentVersion,vehicleVersion,generation,serverNowSeconds.
- DeviceProofSubmissionV1: protocolVersion=1,credentialId,challengeId,
  issueOperationId,confirmOperationId,signatureEncoding=P1363_RAW64,
  signatureRaw Uint8Array,transcript Uint8Array. NO public-key parameter.
- Evidence: kind=SIGNATURE_VALID_ONLY,protocolVersion,credentialId,challengeId,
  issue/confirm IDs,reservedGeneration,publicKeySha256,transcriptSha256,
  signatureSha256. No nonce/raw signature/key/coordinate is returned.

Evidence is immutable metadata, **not an authorization token, receipt, claim
lease or proof of one-time consumption**. It must never be accepted from an HTTP
client as signature_valid/verified=true. The signature digest is auxiliary
verification evidence, not an idempotency key. No receipt/request state exists
in this pure module; original UUID + full normalized immutable request must
govern future recovery, never signature bytes alone.

## 4. Exact Android v1 compatibility

The in-memory protocolVersion=1 tag selects this parser; it is NOT a28th signed
line. All signed text is reconstructed explicitly in Kotlin order, never sorted/
trimmed/canonicalized from client text. Exactly27 ASCII lines, UTF-8 LF separators
and ONE terminal LF:

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

Audience1..128 ASCII [A-Za-z0-9._:/-]; policyVersion1..64 [A-Za-z0-9._-];
hashes64 lowercase hex. UUID profile exactly mirrors Android's canonical
lowercase/non-nil rule, without inventing a UUID-version-bit restriction.
Nonce exactly43 unpadded base64url chars; decode32 bytes and identical re-encode.
No random nonce or approved policy hash is minted here.

ALL Long-compatible values are canonical decimal STRINGS at this JS boundary;
numbers, signs, whitespace, exponent/fraction/leading zeros are rejected.
BigInt checks0..9223372036854775807; versions/generation strictly positive.
Issue≤Long.MAX-120 and expiry exactly issue+120; issue/confirm UUIDs distinct.
A future JSON adapter must preserve PostgreSQL/Kotlin bigint precision.

Submission transcript bytes must equal rebuilt bytes. BOM, CRLF, missing/extra
terminal LF, reordered fields, JSON, whitespace or altered values are rejected;
no parsing/coercion of raw text. The context's trusted-time snapshot must satisfy
issue≤now<expiry. This checks supplied time only, not a live server clock source.
Future finalize must check actual time/authority again after async verification.

The pure check compares challenge/credential scope to context, actor/org to
scope, expected audience/recovery epoch, policy version/hashes, entity versions
and generation. Credential must be INACTIVE, matching UUID/generation/hash.
Revoked snapshot fails. This does not detect revocation occurring after snapshots:
TX-B must re-read under lock. Metadata policy equality is NOT policy approval.

## 5. Cryptographic verification, encodings and errors

Only91-byte canonical RFC5480 DER SPKI with id-ecPublicKey, namedCurve P-256 and
uncompressed04||x[32]||y[32] is accepted, matching Android's fixed prefix.
Reject private-key formats/other curves/compression/extra data. Check x,y<p and
on-curve y²=x³−3x+b modp using NIST P-256 constants; infinity has no accepted
encoding. Compute SHA-256 over the stored copied SPKI and require both stored
and signed fingerprints match. No client replacement key is consulted.

Signature is explicitly tagged P1363_RAW64 and exactly64 bytes r[32]||s[32].
Require1≤r,s<n. No DER auto-detection/conversion, normalization, low-S rewrite,
weaker algorithm or alternate curve. Android must call its derToRaw/rawSignature
path. A DER-tagged/non64 submission is INVALID_ENCODING. A mislabeled64-byte
stream is necessarily interpreted as raw (intent cannot be inferred from bytes)
and must pass scalar and mathematical verification; no permissive DER fallback.

Use crypto.subtle.importKey("spki",...,{name:"ECDSA",namedCurve:"P-256"},false,
["verify"]), then crypto.subtle.verify({name:"ECDSA",hash:"SHA-256"},key,
rawSignature,rebuiltTranscript). Hash the message once inside ECDSA; do not sign/
verify a prehashed transcript digest. SPKI point checks are format validation,
not custom ECDSA; actual signature math uses standards-based WebCrypto.
False verification throws INVALID_SIGNATURE, never returns positive evidence.
Unsupported/unavailable crypto fails CRYPTO_UNAVAILABLE without fallback.

Bounded codes only: INVALID_INPUT, INVALID_ENCODING, INVALID_PUBLIC_KEY,
INVALID_SIGNATURE, UNSUPPORTED_PROTOCOL, CREDENTIAL_MISMATCH,
CREDENTIAL_REVOKED, SCOPE_MISMATCH, TRANSCRIPT_MISMATCH, EXPIRED,
CRYPTO_UNAVAILABLE. No raw input/provider error/cause is logged or returned.
No HTTP4xx/recovery classification or D1 allowlist changed.

Official primary references, source-only review2026-11-03:
[Deno WebCrypto](https://docs.deno.com/api/web/crypto/),
[W3C ECDSA](https://www.w3.org/TR/webcrypto-1/#ecdsa-operations),
[NIST SP800-186 P-256 parameters](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-186.pdf),
[RFC5480](https://www.rfc-editor.org/rfc/rfc5480).
The current backend already uses WebCrypto digest; actual deployed ECDSA/runtime
compatibility and Android↔server vectors remain NOT_VERIFIED_AT_RUNTIME.
PostgreSQL pgcrypto ECDSA/SPKI verification is not invented or assumed.

## 6. Operational boundary, concurrency and replay — design only

Current classifications:
| Component | Classification / actual status |
|---|---|
| Android local signer/encoder from #94 | IMPLEMENTED source, NOT_VERIFIED_AT_RUNTIME; unchanged, no automatic callers |
| New pure transcript/crypto verifier | IMPLEMENTED source, NOT_VERIFIED_AT_RUNTIME; library only |
| JWT/current driver/vehicle authority for this ceremony | DESIGN_ONLY, BLOCKED_BY_INFRASTRUCTURE; existing incident reads do not authorize enrollment |
| Registered credential/challenge storage and revocation writer | DESIGN_ONLY, BLOCKED_BY_POLICY, BLOCKED_BY_INFRASTRUCTURE |
| Issue/CLAIM/FINALIZE endpoints, claim token and receipt recovery | DESIGN_ONLY, BLOCKED_BY_POLICY, BLOCKED_BY_INFRASTRUCTURE |
| Approved policy/precise audience/recovery epoch source | BLOCKED_BY_POLICY; draft hashes are not approval |
| GPS producer/consent/lease/position viewer | BLOCKED_BY_POLICY, NOT_IMPLEMENTED; forbidden in this milestone |

The future callable protocol must use the assignment's TWO transactions. The
older M15A preverify/finalize sketch is not a claim that an Edge await is atomic.
No SELECT→await verify→UPDATE transaction guarantee exists in this PR.

Future ISSUE (DESIGN_ONLY): trusted JWT + current exact-org incident/ACTIVE
designated DRIVER + canonical live deployment→inventory unit→active vehicle,
REAL eligible lifecycle, approved ceremony policy. Server generates32-byte nonce,
fresh challenge UUID/120s expiry, freezes exact27 fields and original issue/
confirm operations, bounded outstanding count, entity versions/generation.
Do not issue when doing so constitutes unapproved operational pairing. Current
source lacks approved policy hashes/recovery-epoch contract/registered credential,
so issuance stays blocked. No nonce replacement or retargeting on retry.

Future TX-A CLAIM (DESIGN_ONLY): user-authenticated SQL boundary derives auth.uid,
locks challenge/credential and canonical scope consistently, validates actor/org/
current driver/policy/REAL lifecycle/vehicle relationship/versions/revocation/
server expiry and full immutable request. Require ISSUED; atomically reserve a
random opaque short-lived claim token/generation bound to that exact operation,
record CLAIMED, commit. Claim lease is bounded by challenge expiry, never extends
it. Client gets no privileged finalization credential. No locks held across HTTP.

OFF-DB VERIFY (only mathematical module IMPLEMENTED): trusted adapter supplies
TX-A snapshots/registered key/current expected context to this library. Never
take a replacement public key or verification result from the client.
Signature failure cannot become VERIFIED_INACTIVE.

Future TX-B FINALIZE (DESIGN_ONLY): a narrowly granted trusted verifier identity,
not a public verified=true API, locks original challenge/credential/claim and
canonical authority again. Validate exact unexpired claim token/generation,
same original operation/request, current driver/org/incident/vehicle/policy/
entity versions and current expiry/revocation. Only after genuine server crypto
success may it atomically set VERIFIED_INACTIVE/consumed_at and write an immutable
verification receipt in the same transaction. No approval, sharing or active
session follows. service_role bypasses RLS; it is not proof of user authority.
TX-B must derive stored actor/context from the original user-authorized claim
and revalidate it, not trust arbitrary user IDs from a service payload.

Concurrency/failure requirements, **not implemented**:
- Parallel TX-A attempts serialize or conditional-update exactly one ISSUED row.
- Parallel TX-B attempts can commit at most one terminal consume/receipt.
- Revoke locks the same credential/claim; finalization must observe it and fail.
- Edge crash after claim means UNKNOWN, never success. Expired claim can only be
  recovered for the original immutable operation/request, with fresh claim token/
  generation so the old delayed worker cannot finalize. Do not mint a new nonce.
- Invalid signature follows a bounded explicit failure policy; no success receipt.
- Exact replay reads the original receipt first. Same UUID/changed request fails;
  another operation on consumed challenge fails. Original receipt after revoke
  is historical evidence, not a new grant. Preserve UNKNOWN after absent/mismatched
  proof or a later rejection following an ambiguous attempt.
- Competing vehicle bindings need an authoritative single-holder/generation
  transaction. This module does not provide distributed locks or replay state.

Sequence below is the FUTURE callable path; dashed design components do not
exist. Current code can be invoked only as an internal library with supplied
snapshots; it does not contact those components:

```mermaid
sequenceDiagram
  participant A as Android signer (IMPLEMENTED; runtime unverified)
  participant B as Authenticated Supabase boundary (DESIGN_ONLY / BLOCKED)
  participant D as Private credential/challenge DB (DESIGN_ONLY / BLOCKED)
  participant V as Trusted signature verifier library (IMPLEMENTED; runtime unverified)
  participant R as Challenge receipt storage (proof use DESIGN_ONLY)
  A->>B: Future original issue request / public credential reference
  B->>D: Future live authority + issue nonce / frozen context
  D-->>A: Future authoritative 27-field challenge
  A->>A: Sign exact bytes; DER to raw64; retain original IDs
  A->>B: Future original confirm / raw64
  B->>D: Future TX-A: current auth + atomic CLAIM
  D-->>B: Future private snapshots + bounded claim token
  B->>V: Expected context + stored SPKI + exact proof
  V-->>B: SIGNATURE_VALID_ONLY or bounded failure
  B->>D: Future TX-B: token + rechecks; consume only after genuine verify
  D->>R: Future atomic original immutable outcome
  R-->>A: Future authoritative inactive-only receipt / current status
  Note over A,R: No callable path/SQL or GPS activation implemented by this PR
```

## 7. Lifecycle, privacy, compatibility

Snapshot lifecycle INACTIVE verifies mathematically; REVOKED is rejected. No
persistent inactive credential is created/revoked/rotated here. Generation is
compared as canonical integer text but never incremented by the module.
Server revocation/rotation must invalidate pending claims and prevent stale
receipts/late workers from restoring a generation. Local revoke/key loss is not
a confirmed server revoke. Logout/scope ABA handling remains #94's explicit
ephemeral epoch contract, not a new automatic enrollment/logout integration.

P01–P14/A01 all UNAPPROVED. No legal basis, device attestation, driver identity,
policy/consent, active binding, precise audience or finite sharing lease is
established by a mathematical signature. No signature can turn on the existing
six false C2 flags. Android/Web false producer constants and OFF UI are untouched.
No new controls, permissions/FGS, location samples/history/trails/store/markers/
polling, Room migration, second queue/worker/channel, M10 token changes or NAV/SIM
position inference. Missing backend stays existing DISABLED/UNAVAILABLE fallback.

No metadata or nonce row is stored, so no new retention/deletion job or promise.
For future challenge rows: expiry forbids use even if row remains; this does not
physically delete it. Bounded approved independent maintenance, audit/credential
metadata retention, backups/PITR/WAL/logs/caches and restore-after-revocation
quarantine need owner decisions. GPS physical deletion remains outside this
milestone and unapproved. No coordinate/JWT/private key in logs/FCM/Realtime/
timeline/URLs/receipts; module has no logging/notification/storage at all.

Known limitations: only pure cryptography and snapshot-consistency are delivered.
There is no current-user authentication, registered-key origin guarantee,
live role/REAL query, authoritative clock, nonce uniqueness/consumption, distributed
concurrency, recovery receipt or inactive binding result. Snapshot revocation can
occur during async verify and is invisible to a pure function; future TX-B is
mandatory. Deno/Android interoperability and deployment behavior are unverified,
not security/operational readiness PASS.

## 8. Owner rollout and future dependencies

No migration filename, SQL tables/constraints, RPC signatures/grants or HTTP
function are installed by M15A.2. M15A conceptual DDL is not silently adopted.
Do not deploy this _shared file as an endpoint; existing functions do not import it.
No config/JWT verify_jwt exception, service credential or infrastructure change.

Owner-only order:
1. Review pinned source; owner alone merges. Preserve developer local files and
   original Room pending operations. Git merge is not deployment.
2. #82–85 were reportedly applied; reconcile actual installed state independently.
3. Owner reports complete #86 file copied correctly but
   20261030160000_incident_private_attachments.sql failed SQLSTATE42601,
   “syntax error at end of input” near line109. Do NOT blame clipboard truncation.
   This PR does not fix/retry it. Determine actual source SQL syntax problem and
   partial-install state through separately authorized owner rollout/correction.
4. #87 20261030180000_android_unit_leadership.sql;
   #88 20261030200000_incident_field_map.sql;
   #89 20261102100000_incident_field_receipt_recovery.sql;
   #90 20261102120000_incident_field_reliability.sql;
   #92 20261102140000_incident_vehicle_location_capability.sql are NOT confirmed
   applied. incident-evidence Edge deployment is also unconfirmed. No blind rerun.
5. #91/#93/#94 and M15A.2 add no SQL. Future credential/claim migrations must be
   forward-only after actual latest existing migrations, at least after #92.
   No timestamp reserved or old migration edited here.
6. Owner performs permitted local crypto interoperability/build/security/manual
   acceptance later. No standalone service/SQL/Android installation requested
   or executed by this source-only deliverable.
7. Before M15B callable enrollment: approved policy/metadata retention/device
   assurance, current authority/recovery-epoch source, registered credentials and
   reviewed authenticated CLAIM/service-only FINALIZE boundary + receipts.
   M15C consent/GPS/lease/STOP/physical-retention work needs separate approval.
   Neither future milestone is implemented or automatically authorized.

Backout removes the unreferenced library through normal reviewed source change;
no DB/Room/credential rollback or deletion is needed. A future enrolled system
would require explicit authenticated revocation/recovery, not UI hiding.

## 9. Manual acceptance — exactly36 cases, all UNEXECUTED

These are owner-run specifications, not executed tests or added test code.
No positive outcome or installed callable path is inferred from the module.

| ID | Owner case | Expected evidence / implemented boundary | Status |
|---|---|---|---|
| A01 | Compare Android/server transcript bytes | Owner compares DeviceProofChallengeV1.bytes() to encodeDeviceProofTranscriptV1 for identical typed values. Expect exact27 lines, UTF-8 and one terminal LF; no trimming/coercion. | UNEXECUTED |
| A02 | Sign canonical transcript with registered P-256 key | Pure in-memory key/snapshot exercise can yield SIGNATURE_VALID_ONLY. Registered-key lookup and authoritative inactive result do not exist; no PROOF_VALIDATED_INACTIVE claim. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| A03 | Alter organization without signing again | Mismatched expected scope is SCOPE_MISMATCH; if all untrusted supplied text is rebuilt consistently, old signature fails INVALID_SIGNATURE. No state change. | UNEXECUTED |
| A04 | Alter policyVersion/hash | Expected trusted-policy metadata mismatch rejects; altered transcript with old signature fails. Metadata equality never approves policy or consent. | UNEXECUTED |
| A05 | DER supplied where raw64 required | Wrong encoding tag/non64 DER is INVALID_ENCODING. Mislabeled64-byte input is interpreted only as raw and must pass scalar/math checks; no DER fallback. | UNEXECUTED |
| A06 | r=0, s out of range or truncated signature | Raw length64 and1≤r,s<n enforced; reject INVALID_ENCODING. | UNEXECUTED |
| A07 | Wrong curve/noncanonical SPKI | Fixed91-byte P-256 prefix/field/point and WebCrypto import reject INVALID_PUBLIC_KEY; no weaker algorithm. | UNEXECUTED |
| A08 | Malformed/padded nonce | Require43 canonical unpadded base64url characters decoding32 bytes with exact re-encode; INVALID_ENCODING otherwise. | UNEXECUTED |
| B09 | Repeat issue UUID/same request | Future issuer must return same authoritative nonce/challenge/expiry. No issue endpoint in this PR; pure math does not issue. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| B10 | Repeat issue UUID/changed vehicle or request | Future immutable operation conflict (conceptual OPERATION_CONFLICT; exact RPC error contract not installed). Never retarget or mint new nonce. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| B11 | Concurrent confirm of same challenge | Future TX-A/TX-B allows at most one authoritative finalization. Stateless repeated crypto may both be mathematically valid and is NOT consumption. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| B12 | Confirm after expiry while row exists | Pure supplied-time check returns EXPIRED. Actual database challenge/claim expiry and retained-row scenario require future storage/finalize. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| B13 | Verifier crash after CLAIM | Future claim lease retains UNKNOWN; recovery original operation only, never false success. No claim transaction implemented. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| B14 | Consumed challenge/new operation | Future ALREADY_CONSUMED-style denial, no new finalization/nonce. No current consumed row/receipt contract. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| B15 | Revoke during verify | Revoked input snapshot is rejected locally. A revocation after snapshot requires TX-B re-read under lock, not available here; no automatic inactive result. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| B16 | Invalid signature/valid challenge values | WebCrypto false throws INVALID_SIGNATURE; no positive evidence, receipt or VERIFIED_INACTIVE transition. | UNEXECUTED |
| C17 | Membership from another organization | Tuple mismatch rejected by pure consistency check, but real current membership must be checked by future authenticated DB boundary. No membership authorization claimed. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| C18 | No ACTIVE DRIVER; leader/admin only | Future live canonical DRIVER authority must deny; key possession or admin/unit-name visibility insufficient. Module cannot query roles. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| C19 | Driver removed between issue/confirm | Future current driver episode/version recheck at finalization denies; pure snapshot cannot observe later removal. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| C20 | Vehicle reassigned between issue/confirm | Expected snapshot version/scope mismatch rejected; future actual current DB assignment/version must be re-read at TX-B. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| C21 | Android account switch and switch back | Existing #94 access-epoch identity prevents stale signer reuse; new module does not alter this or auto-create keys. | UNEXECUTED |
| C22 | Incident closed or TRAINING/SIM | Future authenticated issue/finalize must query live REAL/eligible lifecycle and reject. Fixed REAL transcript literal is not evidence that this is a REAL incident. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| C23 | Same vehicle/wrong deployment UUID | Credential/challenge/expected scope tuple mismatch is SCOPE_MISMATCH. Actual deployment→vehicle FK/joins still require future DB authorization. | UNEXECUTED |
| C24 | Public/anon private-table access | No new credential/challenge tables, grants or RPCs exist. Future private table/RLS/EXECUTE negative cases must be verified only after reviewed implementation. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| D25 | Restore app without original private key | Existing openExisting fails KEY_UNAVAILABLE/no silent regeneration. Server module never generates or exports private keys. | UNEXECUTED |
| D26 | Local revoke offline | Never report server revocation confirmed. No server revoke endpoint or fake Leave vehicle flow; future finite lease/safe durable revoke needed. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| D27 | Stolen FCM token as proof | Not a public key/record identity; proof has no installation/token field and no replacement SPKI. Wrong shape/type rejects, never enrolls. | UNEXECUTED |
| D28 | Inspect data/log/timeline for leakage | Library has no DB/logger/timeline/push/URL/telemetry writes; bounded errors only, no JWT/private key/coordinate accepted as material. | UNEXECUTED |
| D29 | New client/old backend | Android/Web unchanged; existing missing-RPC behavior remains DISABLED/UNAVAILABLE, no READY based on math. | UNEXECUTED |
| D30 | Inspect six GPS capability flags | Existing RPC/Android/Web gates unchanged; all six false, no policy/readiness flag in mathematical evidence. | UNEXECUTED |
| D31 | Finalize with verified=true only | No callable finalizer installed; pure records reject extra success flags. Future privileged commit cannot trust client-supplied evidence/boolean. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| D32 | Expired row remains/no new traffic | No new rows/job here; future authorization expiry independent of physical cleanup. Supplied-time math guard does not claim deletion or server revocation. | UNEXECUTED — NOT_IMPLEMENTED / BLOCKED_BY_POLICY |
| E33 | Android/manifest/Room diff | Android source/manifest/dependencies/generated schema unchanged; Room16, no location permission/FGS or new worker. | UNEXECUTED |
| E34 | Web/MapLibre/capability diff | No Web/API/map changes, location polling or REAL marker/private-key exposure; no library consumer added. | UNEXECUTED |
| E35 | SQL migration review if present | NONE. No old migration edited; any future migration after actual latest/#92 with private constraints/narrow grants and trusted two-TX boundary. | UNEXECUTED |
| E36 | Rollout/acceptance record review | Exactly36 cases all UNEXECUTED; #86 source syntax42601 remains explicitly unresolved pending owner review, not blamed on clipboard. | UNEXECUTED |

## 10. Remaining limitations and execution record

36 owner scenarios, all UNEXECUTED.17 also NOT_IMPLEMENTED/BLOCKED_BY_POLICY.
No observed PASS, claim that a credential is enrolled, authoritative inactive
outcome, deployed endpoint, physical erasure or GPS readiness. The safe fallback
is deliberate and permitted by the root assignment: pure verification is useful
now; operative issuer/claim/finalize/registry/receipts remain absent until policy
and trusted boundary exist.

Owner still needs source/security review and approved interoperability/runtime
acceptance, actual #86 correction/install-state reconciliation, policy/device
assurance/metadata retention, current auth/role/version/token/finalization design
and compatible deployment before callable enrollment. No M15B/C implementation.

No tests added/modified/run; no build/lint/typecheck/CI/monitoring/Gradle sync,
Android Studio/emulator/browser/runtime verification, crypto/key/signature exercise,
SQL/remote Supabase inspection/migration application, deployment/Edge execution/
Android installation, notifications/GPS capture, secrets/Cron/config/dependency/
KAPT/KSP/generated-schema/local developer-file changes or merge. GitHub and
official documentation source reads only. Implementation commit uses [skip ci].
Owner exclusively merges, applies SQL, deploys, builds/installs and accepts policy/
runtime/operations. Existing AGENTS release checks are not claimed passed.
