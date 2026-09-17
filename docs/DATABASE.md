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
