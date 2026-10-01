# Web Admin organization foundation (M8.1)

`/[locale]/admin` selects an authorized organization and redirects to
`/[locale]/admin/org/[organizationId]`. Every page revalidates cookie-based
Supabase auth and calls `web_admin_context`; the URL and switcher are not authority.
Only ACTIVE users with an explicit MANAGER/ADMIN membership in an active organization
enter the shell. A FIREFIGHTER membership alone does not enable it.

Apply `20261001140000_web_admin_organization_foundation.sql` manually through the
normal migration process before using these routes. This task does not apply it.

## Configuration and compatibility

- `organization_types` references existing `countries` and supplies localized names.
- Organizations gain `organization_type_id`. Existing UUIDs, memberships and legacy
  `type` values remain unchanged. Global compatibility types are backfilled; old
  inserts still resolve their legacy type through a database trigger.
- `administrative_areas` remains geographic hierarchy, not organizational authority.
- Slovenia supplies GZS / region / GZ / PGD / PIGD definitions, administrative rules,
  and 26 position definitions. Existing fire departments are **not** guessed to be
  PGD/PIGD or attached to an invented federation.
- To configure another country, a trusted operator adds country-scoped type rows,
  localized names, relationship rules and positions, then maps actual organizations
  and relationships. No schema or country-specific application branch is required.
- Template, relationship and member-position maintenance is trusted-operator-only
  in M8.1. There is no service credential in the normal Web runtime and no editing UI.
  Set `gasilko.audit_actor` for trusted maintenance so audit records identify the operator.
- End/deactivate records rather than deleting them. Names/active state are editable;
  type and position identities/scopes are immutable. Suggested roles are advisory only.

## Authorization

`private.web_admin_scope` starts at the current ACTIVE user's exact MANAGER/ADMIN
memberships in active organizations. A recursive `UNION` follows only enabled,
currently valid edges with an enabled rule and `inherits_read=true`. Duplicate IDs
are removed, so mixed-graph cycles cannot make authorization recursion unbounded.
Inactive country-specific templates/organizations stop inherited traversal.

`private.can_read_organization` combines direct active membership with that read scope.
It is used for organization metadata and new foundation tables. Hydrant, inspection,
photo, team, plan and audit-domain RLS is deliberately unchanged; M8.2+ can adopt this
read primitive explicitly. `private.can_manage_organization` requires direct
MANAGER/ADMIN membership in the exact active organization. Existing role/member
helpers retain their exact-membership semantics, protecting existing mutation RPCs.

Graph writes serialize through a private revision row. Hierarchical relationship
types reject cycles, including active scheduled edges. This also guards changing a
relationship type to hierarchical. Active duplicates/self-links are rejected.
Position assignments require a matching active membership, but historical assignments
do not prevent later membership removal. Positions never enter authorization helpers.

Breadcrumbs follow configured read-hierarchy priority (then relationship code and
parent UUID), expose only accessible ancestors and stop at visited nodes. Missing
ancestors are not disclosed. No last-organization preference is stored in M8.1.

The Users entry embeds M1 access-request review for direct MANAGER/ADMIN only.
`list_organization_access_reviews` scopes before pagination; review still uses the
unchanged `review_organization_access` RPC and its bootstrap/final-admin safeguards.

## Deployment and next milestones

Next uses `output: 'standalone'`. Existing environment-based public Supabase URL/key
configuration remains in place; no host/IP/Caddy settings are added. A future ARM64
production build must include the generated standalone server, static assets and
public assets (if present). No build/deployment was performed here.

New-shell hydrant/map/inspection/team/plan modules, directory/invitations, organization
editing and audit browsing remain placeholders for M8.2/M8.3/M8.4. Existing legacy
web registry routes remain unchanged. No Android, Room or routing changes.
