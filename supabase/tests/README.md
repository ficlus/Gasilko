# Database tests

After `supabase db reset --local`, run `supabase test db`. The existing M0 schema-creation privilege checks remain intact. M1.1 tests exercise real inserts/updates/deletes, constraints, arbitrary hierarchy, server timestamps, deterministic/repeatable seed and default-deny access on all four new tables.

Every test rolls back its fixtures. Auth identities exist only inside test transactions and use no real user credentials. RLS tests first verify actual grants are absent, then temporarily grant CRUD within the test transaction to prove RLS independently hides rows and rejects writes. Pending, active, suspended and rejected identities all remain denied. These test grants never become migrations or persistent policies.

CI replays the real seed twice after reset, before running pgTAP assertions on its exact IDs/parent links and absence of seeded organizations/profiles. To repeat that check locally, run the following from the repository root after reset (shell input redirection shown for bash):

```sh
docker exec -i supabase_db_gasilko psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/seed.sql
docker exec -i supabase_db_gasilko psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/seed.sql
supabase test db
```

This uses only the local container and does not require credentials. The test container mounts only the tests directory, so SQL test files must not include files outside it.

Allowed membership roles and cross-organization policies do not exist yet. M1.2 must add tests for anonymous, pending, active firefighter/manager/admin, suspended, and cross-organization access alongside the implementation.
