# M2.5 search, filters and registry integration

Search is a literal substring of human `code`, `address` OR `location_description`. Leading/trailing whitespace is removed; blank search means no text predicate. Search is case-insensitive using PostgreSQL `lower` under the database locale, with accents significant (no fuzzy matching or transliteration). Search text is limited to 200 characters. `%`, `_`, quotes, backslashes, commas and parentheses are ordinary characters: `strpos` receives bound RPC arguments, never dynamic SQL or PostgREST OR syntax. Different filters combine with AND.

Both clients use dynamic type UUIDs, the four established statuses, and active/inactive/all states. FIREFIGHTER has active-only controls and normalized queries; RLS plus the RPC independently restrict manipulated queries. MANAGER/ADMIN may choose any active state. An inactive organization is still readable under the existing historical-access policy, with writes disabled. Organization changes reset all filters and pagination, then reload role, types and hydrants; no local type is carried into another organization.

Filter choices include all type definitions readable through existing RLS, including inactive local definitions for ADMIN. M2.2 deliberately hides inactive definitions from other roles; those hydrants remain findable through unfiltered/text/status/active queries, with an unavailable type label. A valid type UUID supplied in a shared URL can match a visible hydrant even if its definition is no longer readable; the label remains unavailable. No type policy or administration privilege is expanded. Global and local definitions with the same code remain distinct UUID choices.

## Query contract and security

Migration `20260921140000_hydrant_search.sql` adds `search_hydrants(organization uuid, search_text text='', type_id uuid=null, status_filter text=null, active_filter text='active', after_id uuid=null, page_size integer=50) returns setof hydrants`.

The function is STABLE, SECURITY INVOKER with an empty search_path, authenticated-only EXECUTE and no actor argument. It verifies the current ACTIVE account and own organization membership using existing RLS-protected reads. The subsequent hydrant SELECT retains M2.2 RLS and adds explicit organization/role predicates. Anonymous/service-role RPC execution is revoked. No direct-write grants, mutation RPCs, audit rules or type policies change. Invalid status/active/page size/search length returns SQLSTATE 22023; invalid UUIDs fail typed argument parsing; unauthorized organizations/accounts return 42501. Unknown/foreign type IDs cannot broaden the scoped result.

Ordering is ascending immutable UUID, with exclusive `id > after_id` keyset pagination. Web requests 50 rows, Android 100; RPC bounds are 1..100. A full page may expose a final empty next page; no count query or unbounded registry read is needed. Stable datasets have no duplicates/missing records across pages. Concurrent writes can change membership of a filtered result, so Refresh restarts from current query state (Android first page; Web current URL cursor). Keyset pages are not a snapshot transaction.

The new `(organization_id,id)` B-tree supports scoped ordered scans. Existing `(organization_id,active,status)`, type and primary-key indexes remain. At the required 2,000-row organization scale, literal substring evaluation within the organization is deliberately retained. No trigram extension/GIN indexes are added without evidence that their write/storage cost is justified. CI's disposable integration fixture creates 2,101 own plus 2,101 foreign hydrants, verifies every bounded page, and prints EXPLAIN ANALYZE/BUFFERS for the actual RPC and its representative scoped SELECT. Timings/plans are observations, not brittle performance pass thresholds.

## Clients

Web `HydrantQuery` contains organizationId/search/typeId/status/active/after. The service sends one bounded RPC; React never downloads the registry to filter it. URLs use `org`, `q`, `type`, `status`, `active=active|inactive|all`, `after`. UUIDs/enums are validated; repeated/invalid filter values normalize to defaults, overlong text is bounded, and unsupported numeric `page` is ignored. `after` is the validated cursor, not an offset/page number. Search is an explicit GET form submission, omits the old cursor and resets pagination. Next page and first page links retain filters; browser back/forward and refresh restore the URL. Organization switching navigates with a clean query. Search text is user-visible in shared URLs; the UI never adds notes, credentials or other record data to them.

Android `HydrantQuery` and draft/applied query state live in domain/ViewModel. The expandable mobile controls require explicit Search; typing makes no requests. Apply/clear reset rows/cursor; repository `list(query,after)` encapsulates the RPC. M3 can implement these semantics in Room without rewriting Compose. Query state is memory-only until M3; no cache, persistence or queue is added.

Successful mutations accept returned server versions. Android immediately reconciles visible rows against the query and reloads from the first page. Web details preserve query state in return links, so returning to the registry fetches current filtered results; status/activation changes cannot leave a stale cached row in the controller. Conflict reload/draft retention/explicit review retain their M2.3/M2.4 behavior. Query changes never rewrite mutation versions or replay mutations.

Integration review retained the common statuses, organization roles, human-code/UUID identities, dynamic types, master-field allowlists and dedicated status/activation RPCs. Android previously accepted exponent/hex floating-point coordinate syntax while Web accepted only decimal notation; Android now uses the same decimal/comma rules. Server location constraints and expected-version authority remain unchanged.

Distance / nearby → M4.
Inspection due / overdue → M5.

These filters are deliberately deferred. No M3 offline work, maps/GPS, inspections, photos, QR, notifications, analytics or import/export is introduced.

## Verification and manual acceptance

Database pgTAP tests cover protected identities, organization/type attacks, special characters, validation, literal case/trim semantics and 42 pages of 2,100 rows. Real Auth/REST tests cover another 2,101-row fixture, revocation, filtered activation results and query plans. Existing mutation/RLS/concurrency suites remain required. Android repository/ViewModel/Compose tests and Web query/controller/render tests cover search/filter reset, roles, URL/cursors, filtered mutations and conflict regressions. Run all Database, Android and Web workflows plus credential scanning.

Before deployment, verify both locales and narrow/large-font layouts with real staging organizations and historical type references; keyboard/screen-reader controls on Web; Android keyboard/scroll behavior; browser back/forward; concurrent cross-client status/edit/deactivation while filters are active. Physical-device/staging acceptance is not replaced by fixture tests.
