# Database tests

After `supabase db reset --local`, run `supabase test db`. The existing M0 schema-creation privilege checks remain intact. M1.1 tests exercise real inserts/updates/deletes, constraints, arbitrary hierarchy, server timestamps, deterministic/repeatable seed and default-deny access on all four new tables.

Every test rolls back its fixtures. Auth identities exist only inside test transactions and use no real user credentials. M1.1 regression tests verify table-wide mutation grants remain absent, then temporarily grant CRUD within the test transaction to exercise row filtering. Their original deny-all SELECT assertions are updated for M1.2: ACTIVE users can read their own profile; protected organization access still requires membership. These test grants never become migrations or persistent policies.

CI replays the real seed twice after reset, before running pgTAP assertions on its exact IDs/parent links and absence of seeded organizations/profiles. To repeat that check locally, run the following from the repository root after reset (shell input redirection shown for bash):

```sh
docker exec -i supabase_db_gasilko psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/seed.sql
docker exec -i supabase_db_gasilko psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/seed.sql
supabase test db
```

This uses only the local container and does not require credentials. The test container mounts only the tests directory, so SQL test files must not include files outside it.

M1.2 authorization tests use production column grants, SET LOCAL ROLE and simulated request.jwt.claims. Fixtures cover anonymous, pending, suspended, rejected, missing-profile, unaffiliated and multi-organization identities plus all three roles. Tests exercise helpers, recursion-free reads, safe preferences, membership constraints, permitted manager/admin operations, revoked access, cross-organization CRUD, UPSERT escalation and forged JWT metadata. Denied operations either raise the expected SQLSTATE or affect zero rows; privileged final assertions verify protected state remains intact.
