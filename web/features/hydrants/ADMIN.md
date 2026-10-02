# M8.2 Web Hydrants + Map

This module extends the M8.1 organization shell. Existing Android APIs, Room,
routing and team/plan behavior are unchanged. Web remains online-only.

## Migration (manual review/application required)

`supabase/migrations/20261001220000_web_hydrants.sql` is **not applied**.
It adds hierarchy-aware SELECT policies, bounded query RPCs, exact-organization
web mutation wrappers, inspection entry metadata and private report attachments.
No completed inspections or existing organizations are rewritten or deleted.

`private.web_subtree(root)` starts only at a root authorized by M8.1 and follows
its enabled read edges. Registry/dashboard queries include that root and its
readable descendants. Owning organization remains explicit. Domain SELECT RLS
and private photo downloads accept this inherited access. Existing exact-role
membership helpers and Android mutation RPCs are unchanged.

All new web write RPCs use the existing serialized
`authorize_hydrant_write(..., ['MANAGER','ADMIN'])` for the exact owner.
Web create/edit/status/activation reuse the existing mutation functions, code
allocator, row version checks and audit. A separate mandatory reason accompanies
web status changes. Existing Android status/inspection contracts remain callable
with their original roles/signatures; browser identity is not treated as a new
authorization principal.

## Query and map strategy

- Registry: server filtering, literal substring search, deterministic sorting,
  50-row pages. Inspection history: 25-row pages. Galleries: 12-row pages.
- Viewport: 300 ms move debounce, at most 2,000 features plus a truncation flag.
  A visible warning requests zoom/filter refinement when truncated. Cluster counts
  refer to the loaded viewport features, never an invented national total.
- MapLibre GeoJSON source/layers cluster points. Outer organization ring comes
  from a stable UUID hash; inner status has a separate color. Text/legend provide
  organization and status identification without relying on color alone.
- List selection centers the map; marker selection includes the corresponding
  row even if it was outside the current page, and opens a private-photo popup.
- Dashboard counts are calculated in PostgreSQL; no browser-wide dataset fetch.
  Latest valid inspection and preview-photo lookups use indexed lateral queries
  in the same request. Inspection photo counts are returned with history; galleries
  only load when expanded. New indexes cover viewport, code order, valid inspection
  chronology, permanent previews, document parent, audit scope and write receipts.
- Realtime invalidates queries for at most 20 currently represented organization
  IDs across hydrants, inspections and both photo tables. No unfiltered subscription.
  Explicit refresh and a 60-second refresh remain the fallback. Editors do not
  apply incoming values over unsaved changes. Session changes clear module state.

## Manual inspection and evidence

The existing model has completed events only: no server drafts are introduced.
`completed_at` is reused as the authoritative performed time (the manual RPC
accepts it as `performed_at`; manual `started_at` is the same time).
`source` distinguishes `ANDROID_FIELD` (default for existing APIs/rows) and
`WEB_MANUAL`. `inspector_id` remains the authenticated entry actor for compatibility;
manual records separately store `performer_id` or free-text `performer_name` and
optional external organization. Selecting a known performer requires current
active exact membership. Completed records remain immutable; a correction is a
new event with a same-hydrant `corrects_inspection_id`.

Manual completion locks the hydrant and checks all relevant existing completed
inspection times. PASS/PASS_WITH_ISSUES/FAIL use the established status mapping
only when strictly newer than existing relevant events. NOT_INSPECTED never
changes status. Equal-time events preserve the already established status.
Due state uses the latest non-NOT_INSPECTED event, interval override/organization
interval and the SPEC's 30-day due-soon window.

Web images are orientation-corrected and re-encoded as JPEG with a maximum
1920-pixel edge, removing EXIF. Existing photo reservations, private
`hydrant-photos` paths, immutable uploads and confirmation are reused. The newest
active uploaded permanent photo is the preview; no primary-photo field is added.
Inspection-condition photos remain separate from permanent photographs.

Paper reports use `inspection_documents` and a separate private
`inspection-documents` bucket, accepting JPEG/WebP or PDF up to 10 MB. PDFs are
downloaded as authenticated blobs, not embedded as executable content. No public
or bearer-signed URLs are created. Live scope is checked by Storage policies.

The inspection/hydrant transaction commits first; files are then reserved,
uploaded without upsert and acknowledged individually. Metadata remains visibly
pending until acknowledgement. A failed attachment does not erase a completed
inspection. Submission data, operation/entity/photo UUIDs and prepared blobs are
frozen for retries within the open form. Lost-response retries reuse immutable
receipts. Do not close a form with pending uploads: web draft/offline persistence
is intentionally out of scope. Stale master versions are rejected, localized and
require explicit reload; no automatic merge occurs.

## Map and geocoding configuration

Install the pinned MapLibre dependency using the lockfile. `dev`/`build` copy the
matching worker and shared module into `web/public/maplibre`; include `public/`
with standalone deployment. The copy script was added but not executed here.
MapLibre 6 Next.js setup follows the
[official integration guidance](https://maplibre.org/maplibre-gl-js/docs/#esm).
It is the only new runtime library (BSD-3-Clause); no UI/map wrapper is added.

Set `NEXT_PUBLIC_MAP_STYLE_URL` to a browser-safe, licensed MapLibre style.
No tile provider is selected or hardcoded. Without it, a localized configuration
message appears and the registry/manual-coordinate forms remain usable.

No geocoder existed. Optional **server-only** `GEOCODING_ADAPTER_URL` (HTTPS)
and `GEOCODING_ADAPTER_TOKEN` configure an operator-provided adapter. `/api/geocode`
validates the user's exact organization write access using their normal Supabase
session, never a service key, then posts:

```json
{"query":"address or null","latitude":null,"longitude":null,"language":"sl","limit":5}
```

With `GEOCODING_ADAPTER_PROTOCOL=normalized` (default), reverse queries send
latitude/longitude and null query. The adapter returns at
most five `{ "label": "...", "latitude": 46.1, "longitude": 14.8 }` objects.
It has a five-second timeout, no redirects and no cache. No vendor, paid account
or public geocoding endpoint is assumed. An unconfigured adapter returns 503 with
a localized disabled message. Suggestions apply only after explicit selection;
address stays editable and coordinates authoritative.

Alternatively set `GEOCODING_ADAPTER_PROTOCOL=nominatim` and the base URL of an
operator-selected compatible service. The server adapter implements its
[search](https://nominatim.org/release-docs/latest/api/Search/) and
[reverse](https://nominatim.org/release-docs/latest/api/Reverse/) protocols, so this
option needs no separate custom adapter. Configure `GEOCODING_USER_AGENT` with
the operator's application/contact and comply with the selected service's terms.
No public endpoint is embedded. Both protocols cap responses at 64 KB and normalize
results before returning them to the browser.

## Manual verification before release

No tests were added/run; no build, lint, typecheck, CI, emulator, migrations or
deployment were run. Only source review and lockfile resolution with scripts
disabled were performed. Runtime/SQL/browser behavior remains unverified.

After manually reviewing/applying the migration and configuring a style, check:

1. Exact MANAGER/ADMIN writes; inherited read-only traversal; cross-org and
   suspended/revoked account denial through direct RPC, SELECT and Storage calls.
2. Parent metrics, organization filters/legend, pages/sort, viewport truncation,
   cluster expansion, list/marker selection, narrow List/Map switch and SI/DE.
3. Create with server code, location click/drag/manual entry, optional photo,
   master edits, status reason, confirm deactivation/reactivation and audit.
4. Concurrent Android/Web version conflict and explicit reload; lost responses
   retry without duplicate hydrants, inspections, reservations or acknowledgements.
5. Old/new/equal-time manual inspections, all results, measurements, known/external
   performers, correction linkage, immutable completion and unchanged field APIs.
6. Multiple photos/reports, gallery pagination, private viewer/download, partial
   upload failure/retry, sign-out and organization/account switching.
7. Realtime/fallback refresh, no overwriting dirty editors; configured/unconfigured
   geocoding, explicit suggestions, edited coordinates and provider failures.

Teams/Plans web functionality (M8.3), organization/user editors and full audit
administration (M8.4), bulk import/export and deployment remain deferred.
