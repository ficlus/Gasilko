# M9 Web data exchange

The Data / Import and Export section uses the existing signed-in Web Admin shell.
It does not change Android, inspections, routing or synchronization contracts.

## Architecture and formats

The browser uploads a bounded file to the authenticated Node route
`POST /api/exchange`. Spreadsheet parsing/writing runs in a disposable child
process with no inherited credentials. Supabase calls always use the caller's
session, never service-role credentials. Read-only preview precedes confirmation.
Confirmation freezes the manifest; subsequent requests apply 100-row batches
through the existing `web_hydrant_write` business API.

CSV and XLSX support import/export. Legacy OLE/BIFF XLS supports import only.
XLSM, encrypted workbooks, macro execution, HTML, external-resource fetching,
and formula evaluation are not supported. Formula cells require stored scalar
values. CSV accepts UTF-8/BOM and comma, semicolon or tab; ambiguous detection
requires a manual delimiter. Numeric ambiguity requires a decimal setting.

SheetJS CE `xlsx` **0.20.3** is pinned to the official
[distribution](https://cdn.sheetjs.com/xlsx-0.20.3/xlsx-0.20.3.tgz), following
[the Node installation guide](https://docs.sheetjs.com/docs/getting-started/installation/nodejs/).
Its bundled CommonJS reader handles BIFF/codepages and XLSX without a second
spreadsheet library. It is server-only. No changes to SheetJS source are made.
SheetJS Community Edition — https://sheetjs.com/ — Copyright (C) 2012-present
SheetJS LLC. [Apache-2.0 license](https://docs.sheetjs.com/docs/miscellany/license/).
Preserve the package's license/copyright files in distributed builds.

## Limits

| Resource | Limit |
| --- | --- |
| Upload | 10 MiB |
| Worksheets | 16 |
| Import data rows | 10,000, plus one header |
| Columns | 64 |
| Cell text | 4,096 characters |
| Workbook ZIP entries / expanded content | 1,000 / 64 MiB |
| Parser process | 256 MiB V8 heap, 30 seconds; two concurrent processes per server instance |
| Parsed request / frozen manifest | 16 MiB |
| Preview RPC | 250 rows maximum; route sends 200 |
| Apply transaction | 100 rows |
| Export RPC | 500 rows, UUID keyset pagination |
| Export | 50,000 rows or 24 MiB serialized data; XLSX output 32 MiB |
| History | 50 imports / 100 result rows per page |
| Mapping profiles | 32 KiB each; maximum 200 in a requested scope |

Limits are enforced in parser/route/SQL as appropriate, not only the browser.
No truncated export is returned. Narrow filters or split input when limits are
exceeded. ZIP content is decompressed under an actual output bound before
workbook parsing. The parser has no user-selected executable or file path.
Node hosting must support child processes and run from the Web working directory;
standalone tracing includes the worker and spreadsheet package. No Edge Function
or deployment configuration is required by this implementation.

## Import workflow

1. Upload; select a worksheet when multiple sheets exist; choose CSV delimiter
   if detection is ambiguous. The entire selected sheet is read before preview.
2. Review conservative SI/DE/English header suggestions; map remaining columns.
   A generic `id`/`code` header is intentionally not guessed. Duplicate column
   assignments fail. Map source status/type values to existing stable codes/UUIDs.
3. Optionally save an organization-scoped mapping profile. Profiles contain only
   column/value configuration, decimal policy and clear policy. Rename, update,
   activate/deactivate and selection are supported; source rows are not stored
   in profiles. Writes require exact Manager/Admin membership and use versioned
   audit receipts. Narrow organization scope if the profile limit is reached.
4. Run read-only validation for the entire file. Inspect field-by-field old/new
   values, classifications and the map. Invalid/missing coordinates do not become
   guessed positions. `(0,0)` and missing coordinates produce explicit warnings;
   out-of-range, mixed separators and excessive precision are rejected.
5. Select valid rows, exclude warnings or select only creates/updates. Warning
   rows need explicit acceptance. ERROR/CONFLICT rows cannot be applied. Supply
   a nonempty import/status-change reason and explicitly confirm.
6. Apply bounded batches. The page shows remaining work. Network failure stops
   processing; use the same operation or resume it from history.

The CSV template supplies machine headers. The XLSX template contains Hydrants,
Reference and Instructions sheets with authorized writable organization and
active type references, stable status codes and localized guidance.

### Identity, scope and field semantics

An exact ACTIVE Manager/Admin membership in each owning organization is required
at mutation time. Inherited read never grants import writes. A readable root may
contain several explicitly writable descendant targets. Authorization is checked
before hydrant identity lookup; invalid/inaccessible targets share the safe
`NOT_AUTHORIZED_OR_INVALID_TARGET` result.

UUID is matched first; a supplied code must agree. Otherwise an exact code may
match inside the authorized target organization. Unknown external UUIDs/codes do
not create hydrants. CREATE requires both identity fields blank: the database
freezes a generated UUID and the existing code allocator assigns the final code.
No import changes an existing UUID, code or organization. Types must already
exist and be valid for the organization; ambiguous global/local type codes require
explicit UUID mapping. Import does not create types, organizations or inspections.

File-wide UUID/code duplicates and multiple rows resolving to the same hydrant
are marked as errors, including contradictory rows and rows excluded by the user.
The database repeats duplicate detection over the complete frozen file.

Blank optional cells preserve values by default. Explicit clear affects mapped
optional fields only; unmapped fields remain unchanged. Required fields cannot be
cleared. Classification is CREATE, UPDATE, UNCHANGED, SKIP, CONFLICT or ERROR;
WARNING accompanies the intended action and can be filtered independently.
Status changes use the existing separate reason-bearing status API. Master-data
edits, activation and status changes retain the existing domain audit behavior.

### Concurrency, idempotency and partial completion

The preview version becomes the expected version. Confirmation and mutation
recheck it. Stale rows become CONFLICT; there is no automatic merge or stale
retry. Fixing a terminal row requires a new reviewed import.

The operation UUID identifies an immutable manifest: actor, root, filename,
format, file hash, reason, mapping, canonical rows, selection and warning choices.
A SHA-256 canonical JSON hash is recorded. Reusing an operation with different
contents is rejected. Target UUIDs and per-action operation UUIDs are generated
once and retained. The operation row lock serializes concurrent batch requests.
Existing hydrant receipts preserve version chaining and domain idempotency.

Each batch is one transaction containing both mutations and row receipts.
Expected row failures roll back that row's subtransaction, record its error and
allow other valid rows in the batch. An unexpected transaction failure rolls back
the batch. A lost response can safely resume: acknowledged rows are not repeated.
Successful earlier batches remain committed; the entire file is **not** atomic.
There is no automatic rollback of earlier batches.

Import confirmation/completion and per-row acknowledgements use the existing
append-only audit log, correlated with normal hydrant events and operation IDs.
Frozen manifests cannot be changed; history has no physical-delete interface.
Raw upload files are not stored in Storage or the database. Only sanitized file
metadata, canonical confirmed data, hashes and receipts remain. Unconfirmed
browser work is not a persisted draft and can be lost on page close.

## History and exports

History is paginated and filterable by pending/completed state. It shows scoped
classification counts, operation UUIDs, per-row before/after values and errors.
Only the original actor can resume a confirmed import. READ-authorized users may
inspect authorized result rows; losing a descendant scope removes its rows.
Result/error CSV downloads include conflicts in the error report.

Hydrant and inspection CSV/XLSX actions are available beside the existing
registry filters. The exchange page also exports teams and plans. Exports use
the existing hierarchy READ helpers and SQL filters, with explicit projections:

- Hydrants: identities, organization/type, status, coordinates, location text,
  active/version, latest valid inspection/result/measurements, due state/date.
- Inspections: immutable mode/result/times, measurements/notes, permitted performer
  and entry actor display names, source and correction reference.
- Teams: organization, UUID/name, active state, member count and timestamps.
- Plans: organization, UUID/name, status/timestamps, selected teams, progress,
  start/return settings and existing valid route provider/distance/duration summary.

No images, private Storage paths, signed URLs, auth metadata or routing requests
are included. Full member rosters and route geometry exports are intentionally
outside the basic operational export.

Server batches use deterministic UUID keysets and explicit total limits; no
national data dump is sent to the browser as JSON and no per-record HTTP calls
are made. CSV escapes quotes/newlines, includes a UTF-8 BOM and neutralizes
formula-like untrusted strings while retaining numeric values. XLSX emits typed
value cells, autofilters and practical column widths; metadata supplies generation
time, root, filters, locale, M9 version, status labels and type references. Frozen
headers are not emitted by the selected CE writer integration. No charts/macros.

## Delivery boundary

Migration: `20261005100000_data_exchange.sql` (not applied).
RPCs: `web_exchange_context`, `web_import_preview`, `web_import_confirm`,
`web_import_apply`, `web_import_history`, `web_import_profiles`,
`web_import_profile_save`, `web_exchange_export`.
One authenticated Node route dispatches parse, preview, confirmation, batch,
history/profile and download actions. New messages are Slovenian/German.

At the user's direction, no tests, builds, lint, typecheck, CI, migration,
deployment, smoke test or manual verification was performed. This is unvalidated
implementation. No Edge Functions, Web deployment or Android changes were made.
Deployment/acceptance remain outside this delivery. M10 work (QR, notifications,
Incident Operations or other separately approved scope) is not implemented here.
