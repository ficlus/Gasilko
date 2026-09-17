-- M0 infrastructure only: API clients cannot create objects in the exposed schema.
-- Domain objects, explicit grants, and RLS policies arrive together in M1+.
revoke create on schema public from public, anon, authenticated;
