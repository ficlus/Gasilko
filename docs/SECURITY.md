# Security foundation

## M2.1 hydrant default-deny boundary

`hydrants` and `hydrant_types` have RLS enabled with no policies. All table privileges are revoked from PUBLIC, anon, authenticated and service_role; no temporary CRUD/read/delete access exists, including for ACTIVE organization ADMIN. Existing M1 authorization is unchanged. Only trusted database maintenance can manipulate the foundation until M2.2 defines scoped CRUD and actor authorization.

The postgres-owned, empty-search-path `private.assign_hydrant_code(uuid,uuid,uuid)` is inaccessible to all API roles, including service_role. Its explicit organization/hydrant pair prevents accidental cross-organization allocation; row locking and an atomic per-organization counter prevent duplicate issuance. The private reservation ledger authorizes the first code assignment without trusting client-settable session flags. Direct assignment, replacement and clearing are rejected by the hydrant trigger. Private counters and reservations have no API privileges and retain committed identifiers even after trusted physical deletion. They are permanent operational records and must not be purged. Prefixes remain reserved after organization renames; conflicting reuse fails closed. See DATABASE.md for the precise allocation/retry contract.

Database triggers enforce global/same-organization type ownership, immutable identities/ownership, server timestamps and server versioning. Profile FKs require valid actor identities; they do not establish actor authority. M2.1 has no client mutation path. M2.2 must derive actors from authenticated identity, authorize membership/account state/role, and control editable columns before exposing CRUD or allocation. Future optimistic sync requires an expected-version condition; the server-maintained version column alone is not a conflict API. No M2.2 policy or M3 sync is implemented here.

## M1.5 current administrative boundary

Review authority is ACTIVE + organization role: MANAGER reviews only FIREFIGHTER; ADMIN reviews FIREFIGHTER/MANAGER. Queue projection exposes display name and request/organization metadata only. Server-rendered Web review routes revalidate Auth identity, profile status and own reviewer membership, while RPC checks remain authoritative on every action. The existing ADMIN-only root shell remains ADMIN-only; managers receive only `/[locale]/admin/requests`.

Approval, membership creation, allowed activation, review metadata and audit commit atomically. Rejection never activates or creates membership. SUSPENDED/REJECTED applicants cannot be approved. No global profile-edit grant is added. Existing memberships return ALREADY_MEMBER and are not overwritten. Direct request mutation remains denied.

Every direct membership write passes a database trigger, preserving M1.2 role restrictions and serializing on a private organization row. Authority is checked again after the lock, preventing stale authorization from concurrent role removal. Final ADMIN removal/demotion is rejected. Actual serialization-row updates also protect stronger isolation levels by forcing stale writers to abort. Deadlocks/serialization failures are safe rollbacks requiring whole-transaction retry.

First-admin bootstrap is a private postgres-only operation, inaccessible to anon/authenticated/service_role and absent from exposed schemas. It validates eligible target, active organization and zero ADMIN under the same lock. [ADMIN_BOOTSTRAP](ADMIN_BOOTSTRAP.md) specifies verified operator attribution and staging/production steps. No bootstrap UI or global super-admin exists.

Audit writes come from private database functions/triggers; client-supplied actor/time or provider metadata is never accepted. Application writes use auth.uid(), bootstrap uses its trusted verified operator, and raw maintenance uses a clearly marked database-system principal. Audit is append-only, with no client/service-role write grants and mutation/truncate rejection triggers. Only ACTIVE organization ADMIN can read that organization's security history. No email/profile enumeration is introduced.

The previous milestone sections below are historical; M1.5 supersedes their deferred approval/bootstrap/audit/last-admin notes. External Google provider and physical-device acceptance remain manual; CI covers real local Auth, approval with an existing session, adversarial SQL/RPC calls, audit rollback, and independent-connection concurrency.

## M1.4 Google and request boundary

Google uses existing Supabase authorization and provisioning. Web uses SSR PKCE; Android validates exact callback scheme/host, rejects fragments/errors/duplicate or missing codes, then exchanges using the encrypted persisted verifier. Callback possession alone grants no app access. Provider secrets stay in Supabase; never log codes/tokens. Identity linking is delegated to Supabase with no client-email merge.

Pending/active users discover exactly organization id/name/code/type/administrative_area_id through a scoped RPC, limited to active, geographically assigned organizations. Geography remains authenticated reference data. Own history additionally reveals historical organization name and request role/status/time. Protected organization/profile/membership policies remain unchanged.

Creation accepts organization and role only, derives auth.uid(), validates account/organization/area/country and own membership, locks applicant profile and relies on a partial unique pending-pair index. Direct client mutations and history deletion are denied. Definers have explicit ownership, empty search paths, qualified names and authenticated-only EXECUTE. Requests never grant membership or activate profiles.

New tests cover impersonation, ADMIN, forged approval/reviewer/time, edits/deletion, cross-user reads, duplicates, inactive organizations and existing members; real local Auth integration tests concurrent submissions. Previous RLS suites remain. Google metadata fixtures exercise the same trigger. External provider/device acceptance is manual: see [Google authentication](GOOGLE_AUTH.md).

M1.5 must independently authorize reviewers, lock applicant profile before pending request, and atomically change membership/review/allowed account status with trusted audit and bootstrap safeguards. Existing membership permissions do not constitute a request approval endpoint. No client review or bootstrap path is implemented.

## Existing foundation and milestone history

Client applications contain no privileged secrets. Public Supabase URLs and publishable keys may be mapped explicitly into clients later; Supabase secret/service-role keys, CLI tokens and Firebase admin credentials belong only in trusted server environments. M0 reads no environment secrets and initializes no SDK clients. Never enumerate all environment variables into Next config or Android BuildConfig. Any future server secret reader must be guarded with Next.js server-only boundaries and authorization tests.

Authentication is not authorization. RLS is mandatory for protected domain tables and storage objects. Approved membership, account state and role must restrict every organization request, including direct API calls; UI visibility is insufficient. Pending, suspended and cross-organization access must be denied. Privileged operations execute in trusted database functions or backend code and explicitly authorize the actor even when using a key that bypasses RLS.

Use Android Keystore to protect tokens and sensitive cached authorization material when authentication is introduced. Do not store plaintext passwords. Device backup is disabled for the foundation app. Offline authorization is limited to 30 days since verified online authorization, as specified; no authorization is implemented in M0.

.env.example is a reference inventory of placeholders, not a file to copy wholesale into clients. Keep web public values in ignored web/.env.local and backend secrets in a secret store. Android local.properties is ignored; never add service credentials to it for bundling. Firebase configuration is deferred. Ignore rules cover local env files, signing keys and service files. Rotate and report any credential discovered in Git history; deleting the latest copy is insufficient.

The initial database migration removes client schema-creation privileges. M1 must add protected tables with explicit grants and RLS in the same migration. There is no protected domain data in M0.

## M1.2 authorization boundary

The database access matrix and helper contracts are in DATABASE.md. Authentication provides auth.uid() only; account status and organization-specific roles are read from authoritative database rows. User-controlled JWT metadata never grants privileges. Status changes and membership removal affect subsequent statements; no stale role is embedded in a claim. In-flight statements retain normal PostgreSQL snapshot semantics.

RLS and column grants work together. ACTIVE users can update only four safe own-profile fields. FIREFIGHTER cannot mutate memberships. MANAGER can add/remove FIREFIGHTER memberships only within their managed organizations, and cannot change either side of a role update to MANAGER/ADMIN. ADMIN can manage all roles only in their administered organizations. Organization writes, self-activation and profile provisioning remain privileged. Pending, suspended and rejected users have no protected access even if membership rows remain present. Geography is non-secret authenticated reference data, including for unaffiliated users.

Definer helper functions reside outside exposed API schemas, use fixed empty search paths, explicit ownership/EXECUTE ACLs and fully qualified names, accept no target-user identity, and perform only boolean reads. They avoid recursive RLS while preserving caller-scoped authorization. Direct-role pgTAP tests cover SELECT, INSERT, UPDATE, DELETE, UPSERT, forged metadata, cross-organization attacks and helper calls under real client grants.

### Audit integration and operational limits

No audit_log subsystem is implemented in M1.2. When introduced, membership INSERT/UPDATE/DELETE must emit transactional server-side audit records containing organization, actor auth.uid(), target user, operation, before/after role, database time and request correlation where available. Clients must not supply authoritative audit actor/time or mutate audit rows. Trusted service operations must record their verified actor separately when auth.uid() is absent. Audit writes must commit or roll back with membership changes; never log tokens or credentials.

Initial ADMIN membership requires a trusted provisioning process. No public organization discovery, access request/approval endpoint, last-admin removal guard, authentication UI or offline authorization cache is introduced. Later privileged endpoints must independently authorize their actor before using service-role access.

## M1.3 authentication and sessions

Email/password uses Supabase SDKs, never privileged keys. Database provisioning fixes account state and ignores authorization metadata; authentication never creates membership. A caller-only status RPC supports locked-account screens while existing protected-table policies remain unchanged. ACTIVE grants an account shell; Web admin shell additionally requires an own ADMIN membership. All later organization operations still need the requested organization's RLS checks; shell admission is not global admin authority.

Web uses @supabase/ssr browser/server clients and a Next.js proxy to refresh cookies. Each protected page validates the user with Auth getUser, then obtains current database status and scoped membership; it never trusts an unverified cookie/getSession response or a client redirect. Routes are dynamic and proxy responses private/no-store. Browser status refreshes on focus and each minute; every server navigation rechecks independently. SDK-managed browser cookies are accessible to JavaScript, as required for this browser auth flow: prevent XSS, avoid untrusted HTML, use HTTPS and never add shared caching of authenticated pages. PKCE signup confirmations exchange codes at a fixed callback destination; arbitrary next URLs are not accepted. Confirmation on another device may require ordinary sign-in after email verification.

Android Compose observes a lifecycle-aware ViewModel/Repository StateFlow. Startup and foreground refresh show loading before verification. SDK session events lock the shell on refresh failure or logout. Network/profile failures offer retry and signout without assuming authorization; no offline authorization window is implemented. SDK handles session restore, refresh and rotation. Its default SettingsSessionManager is not encrypted, so a small SessionManager persistence adapter encrypts the SDK's serialized session with AES-GCM and a non-exportable Android Keystore key. Passwords are transient input state, never saved instance state or disk. App backup remains disabled. SDK logging is disabled and provider exceptions are mapped to bounded localized messages.

Signout revokes the current session's refresh token via the SDK and clears its persisted session on success. Network failures remain locked with retry rather than falsely reporting successful revocation. Supabase access JWTs can remain valid until expiry after signout; short token lifetime and the database's live ACTIVE/membership gates remain relevant. Session restoration cannot grant privileges from stale user metadata. No tokens, passwords or provider response bodies are logged.

Public configuration accepts only publishable keys (sb_publishable_ prefix), not server secrets or legacy service-role JWTs. Android requires HTTPS. Web permits HTTP only for localhost development. Missing configuration displays a localized setup state and remains buildable in CI.

References: [Supabase SSR](https://supabase.com/docs/guides/auth/server-side/creating-a-client), [Auth provisioning](https://supabase.com/docs/guides/auth/managing-user-data), [SDK session persistence](https://github.com/supabase-community/supabase-kt/blob/3.6.0/Auth/src/settingsMain/kotlin/io/github/jan/supabase/auth/SettingsSessionManager.kt), [Android Keystore](https://developer.android.com/privacy-and-security/keystore).
