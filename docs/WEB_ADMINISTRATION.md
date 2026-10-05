# M8.4 Web administration

Based on merged M8.3 (PR #49). No migration, Edge Function or application deployment was performed while implementing this change. No tests, build, lint, typecheck or CI were run, as requested. Review and staging verification are still required before release.

## Migration and compatibility

`supabase/migrations/20261002150000_web_administration.sql` adds organization invitations, immutable ended-membership history, administration RPCs and scoped audit projections. It adds `names` and `display_order` to the existing `hydrant_types` table and appends localized type metadata to the existing Web read view. Existing names, IDs, global/local sharing and historical hydrant references remain unchanged. No Android/Room changes or migrations.

Membership presence continues to mean current membership throughout the existing backend/Android contracts. Ending membership uses the existing guarded DELETE, archives the old membership within the same transaction, ends descriptive positions, revokes older outstanding invitations for that person/organization and retains the established team-membership revocation behavior. No unrelated memberships or global account states are changed. Ended-member reactivation requires an ACTIVE account and a new, explicit administrator decision. The directory retains ended members; its history preview shows the latest 50 endings, with the immutable audit viewer available for older activity.

The new user/role/position/invitation APIs require exact organization ADMIN. Managers and hierarchy-inherited readers only read these screens. The existing M1 access-request review RPC and `/admin/requests` screen remain available under their existing permissions; they are not broadened or repurposed by M8.4. Pending invitation acceptance can approve its own eligible pending account, like existing access-request approval, but cannot reactivate a suspended or rejected account.

Writes serialize on existing organization/structure locks, compare row/member revisions (invitation versions), and record an immutable audit receipt keyed by operation UUID. Forms freeze requests after uncertain responses, so an explicit retry uses the same UUID and payload. A reused UUID with different contents is a conflict. Failed validation rolls back the whole operation. No automatic conflict overwrite.

## Invitations and trusted email delivery

1. Exact ADMIN creates `organization_invitations` through the user-scoped RPC, with organization, normalized email, security role, optional positions and message. The pending invitation is durable before sending email. There is one pending logical invitation per organization/email; expired invitations can be renewed with Resend.
2. The same-origin Next bridge `/api/organization-invite` authenticates the session and invokes `organization-invite` using the user's JWT. Next uses only existing public/publishable configuration and user-scoped cookies. It never receives a service key.
3. The Edge Function validates the JWT with Auth and rechecks exact ADMIN plus live invitation/organization authorization through `web_invitation_delivery` immediately before delivery. New Auth users use the trusted Auth Admin invitation endpoint. Existing users use the normal passwordless email endpoint with `create_user=false`; a concurrent signup is rechecked and handled as an existing user instead of abandoning the invitation.
4. Email verifies identity and establishes a normal Supabase session. `/auth/callback` additionally accepts the documented invite/email token-hash flow and sends the person to `/{locale}/invitations`. Existing PKCE/Google/password flows stay in place. No callback automatically grants a membership.
5. The recipient explicitly accepts. The database checks the **current verified Auth email**, account eligibility, expiry/version, active organization and the approving administrator's still-current explicit ADMIN authority. Membership, optional positions, account approval if eligible, invitation state and audit commit atomically. Repeat acceptance returns acknowledgement without duplicate membership/positions. An existing membership with a different role produces a conflict rather than silently changing it.

Invitation states are PENDING, ACCEPTED, REVOKED and derived EXPIRED (`expires_at`). Resend renews a pending/expired invitation with the current administrator's approval; revoked or accepted invitations are not silently reopened. Revocation does not remove an already accepted membership: use membership management. If an approver loses authority, another exact ADMIN must explicitly renew the pending invitation before it can be accepted.

Email delivery is an external side effect, not an exactly-once transaction. A lost email response may result in duplicate email on explicit retry, but never duplicate invitation or membership. If sending fails, the invitation remains listed with separate Send/Resend actions; no false delivery acknowledgement is stored. The optional message is shown on the authenticated invitation page, not passed as authorization metadata to Auth.

### Required manual configuration (not performed)

- Review/apply the versioned migration through the existing release process.
- Deploy `supabase/functions/organization-invite/index.ts` with JWT authentication retained. Do not disable the function's in-handler Auth verification. No browser CORS access or anonymous delivery path is needed.
- The Edge runtime requires its Supabase `SUPABASE_URL`, `SUPABASE_ANON_KEY` and server-only `SUPABASE_SERVICE_ROLE_KEY`, plus `WEB_INVITATION_REDIRECT_URL=https://<web-host>/auth/callback` (no query/hash). For local development only, localhost HTTP is accepted. No privileged key belongs in Next or any `NEXT_PUBLIC_*` variable.
- Allowlist the Web callback URLs with `?locale=sl` and `?locale=de` in Supabase Auth redirect configuration. Keep existing Google, signup and Android redirect entries.
- Configure SMTP/email delivery and the **Invite user** and **Magic Link** templates to use the token-hash callback. The function always sets `RedirectTo` to the allowlisted callback including `?locale=sl|de`, so the links for this flow are:

  Invite: `{{ .RedirectTo }}&token_hash={{ .TokenHash }}&type=invite`

  Magic Link: `{{ .RedirectTo }}&token_hash={{ .TokenHash }}&type=email`

  Ensure any other passwordless-email consumer also supplies a callback URL with the locale query before sharing this template. Do not change the signup confirmation/reset-password templates as part of this rollout. Standard fragment-token invitation templates are not sufficient for this server-cookie flow.
- Review Auth rate limits and email error handling in staging. The application deliberately returns sanitized delivery errors rather than provider bodies, credentials or tokens.

References: [Supabase email templates](https://supabase.com/docs/guides/auth/auth-email-templates), [passwordless email](https://supabase.com/docs/guides/auth/auth-email-passwordless), [Auth Admin invitation](https://supabase.com/docs/reference/javascript/auth-admin-inviteuserbyemail).

## Organizations, positions and hierarchy

The existing configurable country/type/rule/relationship model remains authoritative. A child create validates the chosen relationship and atomically inserts the organization, edge and creator's **explicit** ADMIN membership. A private transaction-scoped capability table permits only this bootstrap and verified invitation acceptance through the existing membership guard. It has no client/service-role table privileges and is cleaned within the transaction; there is no caller-controlled session bypass flag.

Existing-organization links/reparenting check exact ADMIN on **all old and new endpoints**, or the separately enrolled trusted operator. They require a review checkbox, optimistic revision and existing graph/template validation. Updating a link ends the old edge and creates its successor; there is no subtree move/cascade or inherited write authority. Read access still uses the configured, active, valid-date read graph. Organization type changes reject incompatible active edges.

Organizations can be edited/deactivated; a separate Account → organization administration page permits an exact ADMIN to reactivate its own inactive organization. This does not enable domain access to inactive organizations. Reactivation requires an active administrator. Descriptive positions retain validity intervals/history and never derive a security role from `suggested_role`.

## Trusted configuration enrollment

M8.1 configuration and first-admin bootstrap were SQL-operator-only. M8.4 exposes a reviewed configuration UI through a **private, SQL-maintained allowlist**, not a public/global application role. Ordinary organization ADMIN, MANAGER, public Auth metadata and service-role PostgREST calls cannot enroll operators. The allowlist does not grant general national user/audit access. Its UI exposes bounded configuration and organization/relationship metadata; organization user/audit screens still use explicit/hierarchy read scope. System audit shows only organization-null configuration events.

After verifying the operator identity through the existing trusted operational process, a database administrator may enroll an already ACTIVE profile. This is an operational authorization decision, not automatic migration seed data:

```sql
begin;
select set_config('gasilko.audit_actor', '<verified-operating-profile-uuid>', true);
insert into private.web_configuration_operators(user_id, active)
values ('<verified-configuration-operator-profile-uuid>'::uuid, true)
on conflict (user_id) do update set active = excluded.active;
commit;
```

Revoke by updating `active=false` under the same verified audit context; do not delete. Enrollment/revocation is audited and the UI checks both current enrollment and ACTIVE account. The allowlist is not populated by this migration. Existing `private.bootstrap_first_admin` remains SQL-only. The new system area is reachable through Account → organization administration only for enrolled operators.

System editors cover countries/templates, localized organization types, relationship kinds/read inheritance, allowed type pairs and localized positions/suggested-role metadata. Configuration identity/scope is immutable where the existing model requires it; create a successor definition instead. Every change requires explicit impact confirmation and audit. The country/type graph is data-driven; Slovenia is an existing template, not an application-coded hierarchy. A trusted operator can create a new root organization with its own explicit initial ADMIN membership.

Global/shared hydrant types are operator-editable only. Local types require exact organization ADMIN. Reordering and localized names affect presentation only; deactivation/rename never rewrites hydrants or inspection history. Usage counts are restricted to the reader's authorized scope (operators may see the global type count). No delete action exists.

## Lists, audit and account isolation

Directories, invitations, requests, configuration selectors, organizations, relationships and audit use server pages of 50 plus a has-more row. No national personnel dump or browser hierarchy traversal. Account/organization selection scopes every personnel and audit query; auth changes clear client views. Server authorization is authoritative on every RPC, and periodic scope revalidation clears revoked views.

Audit filters cover time, actor UUID, organization/descendants, action, entity type/UUID and security-related events. Before/after payloads are recursively sanitized for credential/token/URL/Storage fields; array previews cap at 100. Audit remains append-only, without export/edit/delete APIs. Dashboard administrative counts cap at 1,000 and the recent event query is bounded. Organization summaries use existing scoped membership data.

SI/DE labels are in `web/lib/administration/messages.ts`; configured names are read from data. No new dependency, Android, routing or sync changes. M9 imports/exports and M10 QR/push remain out of scope.

## Manual release verification

- Before production: review migration syntax/privileges and apply only to disposable staging through the normal release process. No automated validation was run during implementation.
- Direct ADMIN vs MANAGER vs FIREFIGHTER; inherited-read parent and unrelated org; suspended/rejected/pending accounts; inactive organization and final active-admin protections. Exercise direct RPC calls, not only hidden controls.
- Existing/new Auth email invitation; correct email templates/cookies; repeated acceptance; expired/revoked invite; changed email, suspended account, revoked approving admin; delivery failure and concurrent signup; duplicate/lost-response retry; optional positions and role-conflicting existing membership.
- Role changes in A leave B unchanged. End/reactivate member, preserve position/end history and team revocation; old invite cannot restore ended access. Final active ADMIN cannot be demoted/ended. Ordinary admin cannot suspend global accounts or enroll operators.
- Multiple positions/date ranges, mismatching country/type, optional `suggested_role`, historic ended assignments.
- Child creation atomic failure/rollback; creator explicit ADMIN; hierarchy cycles/self/duplicate edges/wrong type/country/date; reparent with ADMIN only on one side denied; stale revision and replayed operation UUID.
- Deactivate/reactivate the sole accessible organization through Account administration; previously inherited descendant access disappears as configured.
- Operator enrollment/revocation; authorization-impact confirmation; alternate country hierarchy; shared vs local hydrant types; edited translations/order in registry/plans without changing stored hydrants.
- All list/search/filter/page combinations; parent audit vs unrelated audit; sanitized payloads and immutable history; bounded dashboard; account/org switch and revocation; SI/DE narrow-screen forms.
- Regression-check existing email/password/Google login, signup/access requests/M1 review, organization switcher, M8.2 registry/map and M8.3 teams/plans after manual deployment.
