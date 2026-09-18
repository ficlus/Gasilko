# Hydrant authorization API — M2.2

All permissions require an authenticated ACTIVE profile and membership in the relevant organization. Roles are scoped per organization, never inferred from provider metadata or a role in another organization. Anonymous has no table/RPC access. Pending, suspended, rejected and unaffiliated identities read no protected rows and cannot mutate. Read policies retain membership-based historical access when an organization is inactive; all mutations additionally require the organization to be active.

| Operation | FIREFIGHTER | MANAGER | ADMIN |
| --- | --- | --- | --- |
| Read own active hydrants | Yes | Yes | Yes |
| Read own inactive hydrants | No | Yes | Yes |
| Create own hydrant | Yes | Yes | Yes |
| Change operational status | Active hydrants | Active/inactive | Active/inactive |
| Edit master data | No | Yes | Yes |
| Deactivate/reactivate | No | Yes | Yes |
| Read active global types | Yes, with membership | Yes | Yes |
| Read own active types | Yes | Yes | Yes |
| Read own inactive types | No | No | Yes, for administration |
| Create/edit/deactivate/reactivate own types | No | No | Yes |
| Mutate global types or foreign organizations | No | No | No |
| Physical delete, assign actors/code/version/timestamps | No | No | No |

## Direct tables and private boundary

Authenticated receives SELECT only on `hydrants` and `hydrant_types`, filtered by RLS. There are no client INSERT/UPDATE/DELETE policies or grants, including column grants; UPSERT and TRUNCATE are also denied. Clients must use the six RPCs below for writes. No raw allocator, private helper or audit write is exposed. service_role still has no hydrant table or RPC grants: BYPASSRLS alone does not authorize it. Existing M1 audit reads remain restricted to the organization's ACTIVE ADMIN.

All six public functions are postgres-owned SECURITY DEFINER, use fixed empty search_path and qualified names, and grant EXECUTE only to authenticated. Every mutation explicitly obtains `auth.uid()`, checks profile and scoped role, and never accepts an actor argument. The read-only private global-type policy helper returns only a caller-specific membership boolean. All other new private helpers have no API EXECUTE grant.

## RPC contracts

UUIDs below are PostgreSQL uuid arguments. JSON objects are jsonb. Functions return the complete authorized hydrant/type record after the operation; use the returned version. Supabase exposes these under `/rest/v1/rpc/<function>`.

| RPC signature | Authorized role | Behavior |
| --- | --- | --- |
| `create_hydrant(organization, hydrant_type, fields={}, hydrant_id=gen_random_uuid())` | Any member role | Creates active hydrant; validates fields/type/location; derives both actors; allocates code atomically; emits one creation event. |
| `change_hydrant_status(organization, hydrant_id, new_status, expected_version)` | Any member role; FIREFIGHTER active rows only | Changes status and server metadata only. |
| `update_hydrant(organization, hydrant_id, changes, expected_version)` | MANAGER/ADMIN | Patches permitted master fields and optionally status. |
| `set_hydrant_active(organization, hydrant_id, is_active, expected_version)` | MANAGER/ADMIN | Deactivates/reactivates while preserving UUID/code and references. |
| `create_hydrant_type(organization, type_code, type_name, type_id=gen_random_uuid())` | ADMIN | Creates active organization-specific type; organization must be non-null and authorized. |
| `update_hydrant_type(organization, type_id, changes)` | ADMIN | Patches only code/name/active on an own-organization type; supports reactivation. |

`fields` accepts exactly `latitude`, `longitude`, `address`, `location_description`, `status`, `notes`, `inspection_interval_months`. `changes` for master edits additionally accepts `hydrant_type_id`. These objects must be JSON objects; unknown keys are rejected, not silently ignored. Numbers must be JSON numbers/null; text/UUID fields strings/null. Missing patch keys preserve the current value; explicit null clears nullable fields. Creation defaults status to UNKNOWN only when omitted. M2.1 constraints remain authoritative for coordinates, usable location, type ownership/activation, status and positive intervals. Security metadata and active cannot be smuggled into these objects.

Allowed operational statuses are WORKING, NOT_WORKING, NEEDS_INSPECTION and UNKNOWN. `update_hydrant_type` accepts only string code/name and boolean active. Ownership/identity cannot change; ordinary clients cannot create or mutate global types. Inactive types remain valid on existing references but cannot be newly selected. Type-code uniqueness and global/local precedence remain as documented in DATABASE.md. Admins can read inactive local definitions to reactivate them. Type edits serialize but have no version column or expected-version API in M2.2.

### Creation identity and code

A supplied UUID is accepted as technical identity. Authorization does not depend on guessing resistance. Duplicate UUID creation fails with 23505 and never returns, overwrites or moves the existing row, including when it belongs to another organization. This is a safe retry failure, not a payload-merging upsert. M3 may add a scoped idempotent create contract, but must never assume a duplicate error authorizes access to the colliding record.

Creation and M2.1 private allocation execute in one transaction. The stored row starts at version 1; allocating its first code is the existing meaningful update, so **online creation returns version 2**. Both actors are the authenticated caller. No separate status/update event is emitted for this internal code assignment. A failed allocation rolls back the entire create, counter reservation and audit. Code prefixes, exhaustion and permanent reservations follow M2.1 unchanged. Nullable codes remain available to trusted database workflows and future offline storage; M2.2 online creation always allocates centrally and never exposes an assign-code RPC.

### Expected versions and errors

All three existing-hydrant mutation RPCs require a positive, non-null bigint `expected_version`. After authorization, the database locks the exact organization/UUID row and compares the stored version. A mismatch raises SQLSTATE `P0001` with message `HYDRANT_VERSION_CONFLICT`, before any update or audit. Missing/nonpositive versions raise `22023` / `EXPECTED_VERSION_REQUIRED`. A no-op still must pass the version check.

Each meaningful mutation increments version once through the M2.1 trigger and sets updated_by to the authenticated caller and updated_at to statement_timestamp(). No-op mutations preserve version, timestamps and previous updater and emit no audit. A combined master/status change increments once but emits both relevant audit actions. M3 must use the returned version for subsequent work and refresh/reconcile on conflict; it must not retry stale content against a guessed newer version. No conflict queue, automatic merge or sync engine is implemented.

Unauthorized scope/role/state, missing or foreign target, or a firefighter's inactive target returns `42501` / `NOT_AUTHORIZED`; functions never return foreign row data. Invalid field objects return `22023` / `INVALID_HYDRANT_FIELDS` or `INVALID_TYPE_FIELDS`. M2.1 constraint, FK, uniqueness and exhaustion errors propagate and roll back atomically. API callers must map bounded codes/messages to localized UI when UI is introduced, not show raw database diagnostics.

### Concurrency and audit

Mutation authorization writes the existing M1.5 organization serialization row, then locks the ACTIVE caller profile and active organization FOR SHARE before locking the target hydrant/type. Membership changes use the same organization lock. Authority is rechecked after waits; stronger-isolation stale snapshots abort on the real lock-row write or profile lock. Concurrent same-version edits have one winner; demotion/removal, suspension, hydrant deactivation and type deactivation cannot leave a queued mutation using stale authority. Existing M1 review lock ordering can produce a safe deadlock rollback; 40P01/40001 require whole-transaction retry and reauthorization. Expected-version conflicts require reconciliation instead of blind retry. The organization lock deliberately serializes registry writes per organization for this MVP; measure throughput before narrowing it.

Audit writes share the mutation transaction and preserve `auth.uid()`, organization, entity type/UUID and database audit time. Actions:

- HYDRANT_CREATED
- HYDRANT_UPDATED
- HYDRANT_STATUS_CHANGED
- HYDRANT_DEACTIVATED
- HYDRANT_REACTIVATED
- HYDRANT_TYPE_CREATED
- HYDRANT_TYPE_UPDATED (also type reactivation)
- HYDRANT_TYPE_DEACTIVATED

Hydrant payloads contain code, version, status, active, type UUID, interval and changed-field names. They omit free-form notes/addresses/descriptions and location values. Type payloads contain code/active plus a name-changed flag. No credentials, JWTs or arbitrary request JSON are logged. Rejected/no-op mutations generate no event. Trusted raw database maintenance retains its separate M2.1 behavior; these application audit events are emitted by the controlled RPCs, not claimed for arbitrary owner SQL.

## Verification

`m22_hydrant_authorization.test.sql` covers the role matrix, blocked states, foreign reads/writes, forbidden direct fields/mixed edits, actor/metadata forgery, malicious upserts, type ownership/activation, expected-version conflicts and audit scope/no-op behavior. M2.1 integrity assertions are retained; only its intentionally temporary no-SELECT assertions now expect scoped reads.

`hydrant.authorization.integration.mjs` uses real local Auth sessions and PostgREST to verify allowed RPCs and denied direct REST/extra-argument attacks. `hydrant.authorization.concurrency.mjs` uses independent SQL connections for duplicate creation, code uniqueness, optimistic updates, rollback and authorization/type/deactivation races. Existing M1/Auth/M2.1 concurrency suites remain in CI. All integration fixtures are disposable and retained until reset to preserve audit/code reservations.
