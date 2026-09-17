# Database foundation

Versioned SQL under supabase/migrations is authoritative. Manual production schema changes are prohibited. Do not change already-applied migrations; add a migration instead. No declarative schema generator is enabled.

M0 migration 20260917000000_restrict_public_schema.sql revokes CREATE on the API-exposed public schema from PUBLIC, anon and authenticated. No domain tables, users, policies or storage buckets are created. Seed is intentionally empty. Domain schema begins in M1; every protected table and storage object must enforce organization isolation using RLS, explicit grants, and allowed/denied tests.

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

The pgTAP test checks that anonymous and authenticated clients cannot create objects. RLS role and organization-isolation tests are explicitly deferred until protected domain tables exist in M1. Before a future remote migration, review it and validate staging through the approved release process; M0 deploys nothing.
