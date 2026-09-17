# Security foundation

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
