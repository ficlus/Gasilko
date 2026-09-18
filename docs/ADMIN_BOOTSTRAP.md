# First ADMIN operational procedure

Bootstrap is an administrative PostgreSQL operation, not a public RPC or application screen. `private.bootstrap_first_admin(org uuid, target uuid, operator_id uuid)` is owned by postgres; PUBLIC, anon, authenticated and service_role have no EXECUTE. The private schema is not exposed through PostgREST. There is no global application administrator role and no server credential in either client.

## Development

1. Start/reset the disposable Supabase stack using README commands. Create an organization through trusted SQL and sign up the intended administrator through normal Auth, so its profile exists. The operator must also have a profile; for initial development the verified target/operator may be the same person.
2. Verify the organization UUID, target Auth/profile UUID and operator profile UUID. Confirm the target person outside the application and record the change authorization. Never select a target by unverified client email.
3. Connect as the database administrator (`docker exec -it supabase_db_gasilko psql -U postgres -d postgres` locally). Use the following template, replacing placeholders with verified UUIDs:

```sql
begin;
select private.bootstrap_first_admin(
  '<organization-uuid>'::uuid,
  '<target-profile-uuid>'::uuid,
  '<verified-operator-profile-uuid>'::uuid
);
-- Expect BOOTSTRAPPED. Check membership and the related audit rows before COMMIT.
select user_id, role from public.user_organizations
where organization_id = '<organization-uuid>'::uuid;
select action, user_id, entity_id, created_at from public.audit_log
where organization_id = '<organization-uuid>'::uuid order by created_at desc;
commit;
```

Use ROLLBACK if inspection is unexpected. Other bounded outcomes are ADMIN_EXISTS, INELIGIBLE, UNAVAILABLE and INVALID_OPERATOR. The function requires an active organization and a pending/active target. It creates ADMIN, or promotes the eligible target's existing membership, activates a pending target and audits everything atomically. Any existing ADMIN membership blocks bootstrap, including a suspended ADMIN's membership. Recovery of a suspended administrator is a separate trusted account operation, never a reason to rerun bootstrap.

## Staging and production

Apply the reviewed versioned migration through the established release process; do not paste ad-hoc DDL. Run the development procedure with synthetic staging identities first, including a second call (ADMIN_EXISTS), denied ordinary-client execution, and refreshed Web/Android access. Production requires the approved change record, verified operator/target identities, a backup/recovery plan and administrator access to the correct Supabase project's SQL editor or secured PostgreSQL connection. Execute the same transaction template in that project, review the result/audit and record the resulting audit IDs in the change record. Keep connection credentials in the operational secret store; never copy them into client configuration, command history, source or this document. This repository does not deploy or bootstrap production automatically.

Concurrent bootstrap attempts serialize on the organization security row. One succeeds; the other sees ADMIN_EXISTS. Deadlocks/serialization errors abort the entire operation; retry the whole transaction after refreshing state, never just the membership insert.

Audit is append-only. Application actions identify the JWT actor; bootstrap identifies the explicitly verified operator. Other trusted SQL maintenance without operator context uses the reserved all-zero UUID as the database-system audit principal and records `actor_source=trusted_database` plus the database session principal. This UUID is not an Auth account, membership or authorization role. Do not use raw maintenance writes for normal bootstrap or request review.
