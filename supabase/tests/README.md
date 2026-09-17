# Database tests

`supabase test db` executes the pgTAP schema privilege checks. No domain tables or RLS policies exist in M0, so organization/role RLS cases are intentionally deferred to M1. Every protected table must ship with enable-RLS, grants and allowed/denied tests for anonymous, pending, active firefighter/manager/admin, suspended, and cross-organization access.
