# Database foundation

Versioned SQL under supabase/migrations is authoritative. Manual production schema changes are prohibited. Do not change already-applied migrations; add a migration instead. No declarative schema generator is enabled.

M0 migration 20260917000000_restrict_public_schema.sql revokes CREATE on the API-exposed public schema from PUBLIC, anon and authenticated. M1.1 adds the four foundation tables in 20260917120000_geography_organizations_profiles.sql. Every later protected table and storage object must enforce organization isolation using RLS, explicit grants, and allowed/denied tests.

## M1.1 tables and relationships

- `countries`: server-generated UUID, unique two-letter uppercase code, nonblank name, active flag.
- `administrative_areas`: server-generated UUID, required country, optional parent in that same country, nonblank name/type, optional JSONB boundary and active flag. Types are free text because administrative levels vary by country. No fixed depth or geographic extension is introduced.
- `organizations`: server-generated UUID, optional administrative area, nonblank name, unique code, constrained type, positive inspection interval (default 12 months), optional `sl`/`de` language and active flag.
- `profiles`: UUID primary key is also a foreign key to `auth.users.id`, allowing at most one application profile per Auth identity. Email/display name are optional application metadata, not authorization inputs. Status defaults to `PENDING_APPROVAL`; start screen to `DASHBOARD`; inspection mode to `GUIDED`. Profiles are not automatically provisioned by this migration; auth/signup integration is outside M1.1.

Foreign keys restrict deletion of referenced countries, areas and Auth identities. Deactivation preserves geography and organizations. Future account deletion must be an explicit retention workflow; deleting an Auth user cannot silently erase a profile.

The parent composite FK rejects cross-country links; a check rejects self-parenting. A recursive trigger also rejects longer cycles. Structural area writes serialize on the country row with a no-value-change UPDATE, so concurrent reparenting is checked against committed ancestry. Stale repeatable-read/serializable writes fail instead of trusting an old snapshot. Trusted maintenance code must retry serialization/deadlock failures and requires UPDATE privilege on the country row. The trigger has invoker security and a fixed search path; it is not an authorization bypass. No geography-editing API is introduced here.

## Organization codes and CHECK constraints

Organization codes are globally unique across countries and active/inactive records. Codes use canonical uppercase ASCII letters/digits, with optional hyphens/underscores after the first character. Lowercase or whitespace-padded codes are rejected rather than silently normalized. This avoids ambiguous organization identifiers and supports future globally unique human-readable hydrant codes. It does not implement hydrant numbering or reserve any particular prefix format.

Named CHECK constraints enforce organization types (`MUNICIPALITY`, `FIRE_DEPARTMENT`, `WATER_UTILITY`, `OTHER`), all SPEC account statuses/start screens/inspection modes, supported optional languages (`sl`, `de`), nonblank names and positive inspection intervals. No arbitrary upper interval limit or PostgreSQL ENUM is added. Extend value sets with reviewed migrations. Nullable language means no preference/default selected yet.

## Timestamps and indexes

Organizations and profiles share a BEFORE INSERT OR UPDATE trigger. Inserts set both timestamps to database `statement_timestamp()`, ignoring supplied timestamps; updates retain original `created_at` and replace `updated_at` with database statement time. All rows changed by a statement use the same time. Clients cannot backdate or future-date these audit fields through ordinary writes.

Primary keys and country/organization unique codes provide their own indexes. The area `(country_id, id)` unique index supports country lookup and its same-country parent FK; `parent_id` is indexed for child traversal and referential checks. Organization `administrative_area_id` is indexed for geographic lookup and its FK. Profiles already index their Auth FK through their primary key. No unused status, language, JSONB, spatial or timestamp indexes are added.

## M1.2 memberships and authorization

Migration 20260917140000_memberships_roles_rls.sql adds user_organizations with composite primary key (user_id, organization_id), restrictive profile/organization foreign keys, a constrained role and default database creation time. The primary key supports caller membership lookups; the organization_id index supports rosters and reverse FK checks. No seed memberships or global profile role are introduced.

Protected access requires an ACTIVE profile and membership in the requested organization. Roles are independently evaluated per organization. An ACTIVE user without membership can read/edit their own profile but cannot read organizations. All clients remain unable to create, update or delete organizations.

| Caller | Geography SELECT | Profile | Organizations SELECT | Membership SELECT | Membership mutations |
| --- | --- | --- | --- | --- | --- |
| Anonymous | None | None | None | None | None |
| Pending, suspended, rejected | All reference rows | None | None | None | None |
| ACTIVE FIREFIGHTER | All reference rows | Own; safe edits | Own organizations | Own rows | None |
| ACTIVE MANAGER | All reference rows | Own; safe edits | Own organizations | Own rows and managed rosters | FIREFIGHTER rows in managed organizations only |
| ACTIVE ADMIN | All reference rows | Own; safe edits | Own organizations | Own rows and administered rosters | Any role in administered organizations only |

Geography also permits authenticated identities without a profile or organization, supporting future organization selection without exposing organizations. A non-null authenticated identity is required. Inactive historical reference rows remain readable; all geography writes remain privileged.

Profile UPDATE grants cover only display_name, preferred_language, start_screen and inspection_mode. Security status, identity, email and timestamps cannot be client-written. No client profile INSERT or DELETE is granted. Membership INSERT grants exclude created_at; UPDATE grants cover role only, preventing identity moves and timestamp forgery. Managers cannot promote even a FIREFIGHTER to MANAGER, modify another manager/admin, or elevate themselves. UPDATE policies check both the existing and resulting row. ADMIN may demote/remove their own membership; last-admin protection and initial-admin provisioning remain trusted operational responsibilities.

### RLS helpers

The non-API-exposed private schema grants authenticated callers USAGE, never CREATE. Helpers have an empty search_path, fully qualified references, explicit EXECUTE privileges and no anonymous/PUBLIC access:

- private.is_active_user(): STABLE, read-only SECURITY DEFINER boolean lookup of the caller's current profile.
- private.has_organization_role(org_id, roles[]): STABLE, read-only SECURITY DEFINER lookup joining the caller's current membership and ACTIVE profile. No arbitrary target-user argument or JWT metadata role is trusted.
- private.is_organization_member(org_id): SECURITY INVOKER wrapper checking the three allowed roles.

The two postgres-owned definer helpers are the narrow recursion boundary: invoker reads inside policies would re-enter profiles/membership RLS. They return only caller-specific booleans, execute no writes or dynamic SQL, and use primary-key lookups. Service-role CRUD remains trusted backend access bypassing RLS; never distribute privileged keys to clients. Existing deployed migrations remain unchanged.

## Development seed

`seed.sql` upserts fixed UUIDs for Slovenia (`SI`), Austria (`AT`) and seven sample administrative areas: three SI levels and four AT levels. These are labeled development examples, not a complete or authoritative geography dataset. No boundaries, real users or organizations are seeded. Parents are seeded before children; repeat resets and repeat seed execution preserve identities. The seed is for local/test environments only.

Install Supabase CLI 2.117.0 and Docker. From repository root:

~~~sh
supabase start
supabase db reset --local
supabase migration new descriptive_change
supabase migration up --local
supabase db lint --local --level warning
supabase test db
supabase stop
~~~

Reset discards only local database data and replays migrations plus seed. Never use --linked or a remote database URL for a local reset. No login, linked project or production keys are needed for local commands. The committed config already initializes the project; do not rerun init over it.

pgTAP tests exercise schema constraints, recursive hierarchy, defaults, Auth/profile identity, timestamps, seed repeatability and default-deny access. The RLS tests check both actual revoked privileges and row filtering after transaction-local test grants, which are rolled back. M1.2 tests use actual authenticated grants and JWT claims to exercise permitted operations, cross-organization isolation, inactive accounts, metadata forgery and direct escalation attempts. Before a future remote migration, review it and validate staging through the approved release process; this task deploys nothing.

## M1.3 Auth provisioning and status
 
The M1.4 request contracts below extend this provisioning model without changing it.

Migration 20260917170000_auth_profile_provisioning.sql adds an AFTER INSERT trigger on auth.users. The private, postgres-owned provisioning function inserts the matching profile in the same transaction, with fixed PENDING_APPROVAL/DASHBOARD/GUIDED values. It copies Auth email and only safe name/language metadata (bounded string name; sl/de language, otherwise sl). Authorization metadata is ignored. ON CONFLICT DO NOTHING makes retries and the migration's missing-profile backfill safe without resetting existing approvals/preferences. Signup fails transactionally if provisioning fails. No memberships are created. The function is not executable by API roles.

The no-argument get_my_account_status RPC returns only the caller's current account-status string (or null when absent). This fixed-search-path, read-only definer function permits pending/suspended/rejected account screens without broadening any M1.2 table policy. Anonymous execution is revoked. Clients must fail closed on missing/unrecognized status. Profile email is a signup snapshot, never an authorization input. Future email-change synchronization must use verified Auth events.

M1.1/M1.2 test fixtures now rely on automatic provisioning; their security assertions remain intact. The deliberately missing-profile fixture is explicitly removed by the test owner to retain failure coverage. No production client can delete it.

## M1.4 access-request contracts

Migration `20260918000000_organization_access_requests.sql` adds `organization_access_requests`: UUID id; required user/profile and organization FKs; requested_role FIREFIGHTER/MANAGER; status PENDING/APPROVED/REJECTED (default PENDING); database requested_at; nullable reviewed_by/profile FK and reviewed_at. FKs restrict deletion. Both review fields must be null for PENDING and present for closed rows. A partial unique index on `(user_id,organization_id) WHERE status='PENDING'` allows historical closed requests while preventing concurrent pending duplicates. User/time/id, organization and reviewer indexes support queries.

Anonymous has no table access. Authenticated has SELECT only with caller-only RLS; no INSERT/UPDATE/DELETE/TRUNCATE. Own history remains readable after account locking, though onboarding UI requires pending/active status. Service-role maintenance is trusted and never exposed to clients.

All three RPCs are postgres-owned definers with fixed empty search paths and authenticated-only EXECUTE:

- `discover_organizations(country uuid, area uuid default null, after_id uuid default null)`: exactly id, name, code, type, administrative_area_id; pending/active callers only. Organizations, assigned areas and country must be active. Area selects its active recursive subtree at arbitrary depth; null area selects active areas country-wide. Cross-country area returns no rows. UUID ordering/cursor, 50 rows per page. No contact/member/profile details. Unassigned organizations require trusted area assignment before discovery/requesting. Protected organization RLS is unchanged; geography retains authenticated reference access.
- `request_organization_access(organization uuid, desired_role text)`: derives auth.uid(), locks applicant profile, checks pending/active status, role, active organization/area/country and own membership. Inserts only PENDING with null review fields. Bounded JSON result: SUBMITTED (plus id), DUPLICATE_REQUEST, ALREADY_MEMBER, INVALID_ROLE, UNAVAILABLE, NOT_ALLOWED. Partial-index conflicts return DUPLICATE_REQUEST. No profile/membership writes occur.
- `list_my_access_requests(before_time timestamptz default null, before_id uuid default null)`: caller-only id, organization id/name, requested role, status and requested_at; newest first, 50 rows. Both cursor fields come from the last row. Historical organization names remain visible after deactivation; no other user's request or reviewer details are exposed by this RPC.

M1.5 inputs: request table, profiles, user_organizations, authoritative organization-role helpers and get_my_account_status. A separate trusted review transaction must authorize reviewer, lock applicant profile before pending request (matching creation), recheck status/membership, create approved membership, set trusted reviewer/time/status and any permitted activation atomically, with transactional audit. First-admin bootstrap is separate. M1.4 implements no review transition.
