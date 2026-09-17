# AGENTS.md

## Purpose

This repository implements the Hydrant Management Platform defined in:

`docs/SPEC.md`

`docs/SPEC.md` is the primary source of truth for product behavior,
architecture, security, data ownership, offline behavior,
synchronization, and acceptance criteria.

This file defines mandatory operating rules for Codex and other AI
coding agents working in this repository.

------------------------------------------------------------------------

## 1. Read Before Coding

Before changing code:

1.  Read `docs/SPEC.md`.
2.  Read this `AGENTS.md`.
3.  Inspect the existing repository and relevant tests.
4.  Identify the requested milestone/task.
5.  Produce a short implementation plan before making substantial
    changes.

Do not implement unrelated future milestones.

If the requested task conflicts with `docs/SPEC.md`, stop and report the
conflict instead of silently choosing a different architecture.

------------------------------------------------------------------------

## 2. Architecture Is Not Optional

Do not silently change approved architecture.

Approved high-level architecture:

``` text
Android
  Compose UI
      ↓
  ViewModel
      ↓
  Repository
      ↓
  Room ←→ Sync Engine ←→ Supabase
```

Web:

``` text
Next.js
  ↓
Supabase
```

Central backend:

-   Supabase PostgreSQL
-   Supabase Auth
-   Supabase Storage
-   Supabase Row Level Security
-   Supabase Edge Functions where trusted server-side execution is
    required

Push delivery:

-   Firebase Cloud Messaging

Map:

-   MapLibre
-   offline-capable map source whose license/terms explicitly permit the
    intended use

The Android UI must not bypass the repository/offline architecture by
directly using Supabase for normal domain reads/writes.

------------------------------------------------------------------------

## 3. Offline-First Is a Core Requirement

Android must remain functional when internet access is unavailable.

Room is the local source used by the UI.

Field operations must be written locally first and synchronized later.

Never design a critical field workflow that requires an immediate
successful network request.

At minimum, offline operation must support:

-   viewing cached hydrants;
-   searching cached hydrants;
-   filters;
-   offline map;
-   GPS;
-   nearby hydrants;
-   creating hydrants;
-   inspections;
-   notes;
-   photographs queued for later upload;
-   QR lookup for locally cached hydrants.

------------------------------------------------------------------------

## 4. Never Lose Unsynchronized User Data

This is a critical invariant.

A locally confirmed field operation must not be deleted merely because:

-   the network is unavailable;
-   upload failed;
-   application was closed;
-   Android killed the process;
-   device restarted;
-   server returned a transient error.

Pending records and photographs may only transition to synchronized
state after explicit server acknowledgement.

Never implement cleanup code that can remove unsynchronized field data.

------------------------------------------------------------------------

## 5. Idempotency

Client-created domain entities use UUIDs generated before
synchronization.

Retrying the same create operation must not create duplicate:

-   hydrants;
-   inspections;
-   photograph metadata;
-   other synchronized domain entities.

Network retries are expected behavior.

All synchronization code must be safe under repeated execution.

------------------------------------------------------------------------

## 6. Conflict Handling

Do not implement silent last-write-wins for conflicting hydrant
master-data changes.

Hydrant master data uses optimistic concurrency via `hydrants.version`.

A stale update must produce a conflict instead of overwriting newer
server data.

Inspections are append-only in the normal application workflow.

Two independent inspections must both remain in history.

Never resolve inspection conflicts by deleting one inspection.

------------------------------------------------------------------------

## 7. Database Changes

All database schema changes must be implemented as versioned SQL
migrations under:

``` text
supabase/migrations/
```

Never rely on manual production database changes.

A clean database must be reproducible using repository migrations and
seed data.

When changing the database:

1.  create migration;
2.  update generated/shared types if applicable;
3.  update seed data if needed;
4.  update database tests;
5.  update RLS tests;
6.  run migrations from a clean state.

Do not edit old migrations that may already have been applied merely to
make current development easier. Add a new migration unless the
migration is explicitly known to be unreleased.

------------------------------------------------------------------------

## 8. Row Level Security

RLS is mandatory.

Do not rely on UI hiding or client-side checks as authorization.

Authorization must be enforced by Supabase/PostgreSQL.

Users may access only organizations for which they have active
membership and sufficient role.

Every RLS change requires tests covering both allowed and denied access.

At minimum test:

-   anonymous user;
-   `PENDING_APPROVAL`;
-   `ACTIVE FIREFIGHTER`;
-   `ACTIVE MANAGER`;
-   `ACTIVE ADMIN`;
-   `SUSPENDED`;
-   cross-organization access.

A user from Organization A must not be able to retrieve Organization B
hydrants, inspections, photographs, or protected organization data
through direct API calls.

------------------------------------------------------------------------

## 9. Secrets

Never commit secrets.

Never place privileged secrets in:

-   Android source;
-   browser JavaScript;
-   repository files;
-   example configuration containing real credentials;
-   logs;
-   tests committed to Git.

Never expose the Supabase secret/service-role key to Android or browser
clients.

Use environment variables and deployment secret stores.

`.env.example` contains placeholders only.

If a secret is discovered in source control, report it immediately. Do
not merely move it to another file.

------------------------------------------------------------------------

## 10. Authentication vs Authorization

Authentication does not automatically grant organization access.

Google sign-in confirms identity only.

A user without approved organization access must not receive
organization data.

Respect account states:

-   `PENDING_APPROVAL`;
-   `ACTIVE`;
-   `SUSPENDED`;
-   `REJECTED`.

Do not weaken this model for implementation convenience.

------------------------------------------------------------------------

## 11. 30-Day Offline Authorization

Android may use cached organization data offline only within the
configured authorization window defined by the SPEC.

Store the last successful online authorization verification securely.

Do not store plaintext passwords.

Use Android Keystore for secrets/tokens where applicable.

The implementation must provide warnings before offline authorization
expiry.

After expiry, protected organization data must remain locked until
successful online re-verification.

Do not implement an obvious bypass based solely on a user-controlled
wall clock if a safer platform-supported approach is available.

------------------------------------------------------------------------

## 12. Hydrant Identity

`hydrants.id` UUID is the technical identity.

Human-readable hydrant codes are secondary identifiers.

An offline-created hydrant must not invent a final sequential code that
could collide with another offline device.

Final sequential/human codes are allocated centrally and atomically
after synchronization.

Code generation must be concurrency-safe and idempotent.

------------------------------------------------------------------------

## 13. Deletion

Do not physically delete hydrants through normal application workflows.

Use deactivation (`active = false`) to preserve history.

Historical inspections and audit information must remain available
according to authorization and retention rules.

Any true destructive deletion requires an explicitly specified
administrative/data-retention workflow.

------------------------------------------------------------------------

## 14. Photographs

Permanent hydrant photographs and inspection photographs are separate
concepts.

Inspection photographs belong to an inspection.

Hydrant photographs belong to the hydrant.

Offline photographs must remain locally available until upload is
confirmed.

Before upload, optimize images according to the SPEC.

Do not include personal names or sensitive information in Storage
filenames.

Storage authorization must follow organization permissions.

------------------------------------------------------------------------

## 15. Map Data

Do not bulk-download tiles from public OpenStreetMap tile infrastructure
unless the selected service explicitly permits the intended offline
usage.

Before integrating a production map provider, verify its current:

-   offline terms;
-   attribution requirements;
-   licensing;
-   API limits;
-   pricing constraints.

Do not hard-code a provider that violates the required offline workflow.

------------------------------------------------------------------------

## 16. Dependencies

Do not add a dependency simply because it makes a small task easier.

Before adding a library:

1.  check whether existing dependencies already solve the problem;
2.  verify the library is actively maintained;
3.  verify compatibility with the current project stack;
4.  verify its license;
5.  justify the dependency in the PR/task summary.

For security-sensitive or foundational dependencies, use current
official documentation rather than assumptions from model memory.

Do not perform unrelated dependency upgrades during a feature task.

------------------------------------------------------------------------

## 17. Localization

MVP languages:

-   Slovenian (`sl`);
-   German (`de`).

Do not hard-code user-facing strings in feature code.

Use localization resources.

Database/user-entered notes are not automatically translated.

Architecture must permit adding languages later.

------------------------------------------------------------------------

## 18. Testing Requirements

New behavior requires tests.

Bug fixes should include a regression test whenever practical.

Do not delete, skip, or weaken tests merely to make CI pass.

Relevant test categories include:

-   unit;
-   database;
-   RLS/security;
-   synchronization;
-   offline;
-   import/export;
-   UI/integration;
-   end-to-end.

If a required test cannot reasonably be automated, document the manual
acceptance procedure.

------------------------------------------------------------------------

## 19. Mandatory Critical Scenarios

Changes affecting these areas must preserve the corresponding SPEC
acceptance tests:

### Offline creation

``` text
airplane mode
→ create hydrant
→ persist in Room
→ reconnect
→ synchronize
→ no duplicate
```

### Interrupted photograph upload

``` text
start upload
→ lose network
→ retain local photo
→ reconnect
→ retry
→ successful upload
```

### Concurrent hydrant update

``` text
device A: version N
device B: version N

B syncs → server version N+1
A syncs stale version N

expected result: CONFLICT
```

### Independent inspections

Two inspections must both survive synchronization.

### Organization isolation

Organization A must never gain protected Organization B data.

------------------------------------------------------------------------

## 20. Import / Export

Import must validate before persistence.

Never silently discard invalid rows.

Provide preview/error information as required by the SPEC.

Large imports must not bypass authorization or database constraints.

Exports must respect the same authorization model as normal application
access.

Do not use privileged server credentials to accidentally export data
outside the user's permitted scope.

------------------------------------------------------------------------

## 21. Performance

Avoid obvious N+1 database/API patterns.

Use appropriate indexes for frequently queried/filterable fields.

Android search/filter operations expected to work offline should query
Room rather than repeatedly hitting the network.

Map marker rendering must be designed for the expected local dataset.

Performance work must be based on measurement rather than speculative
complexity.

Use the performance dataset defined in `docs/SPEC.md`.

------------------------------------------------------------------------

## 22. Auditability

Important administrative/security-sensitive operations must remain
auditable.

Do not make `audit_log` freely editable by normal clients.

Where audit integrity matters, generate entries through trusted
database/server-side mechanisms.

Do not log passwords, access tokens, refresh tokens, service keys, or
other secrets.

------------------------------------------------------------------------

## 23. Error Handling

Do not swallow exceptions silently.

User-facing errors should be understandable and actionable.

Technical logs should contain enough context for diagnosis without
exposing secrets or unnecessary personal data.

Network failure is a normal state for the Android application and must
not be treated as an exceptional unrecoverable condition.

------------------------------------------------------------------------

## 24. Git Workflow

Do not work directly on production infrastructure.

Recommended branch model:

``` text
main
develop
feature/*
```

Keep changes scoped to the requested task.

Avoid large unrelated refactors.

Do not rewrite unrelated code simply to match personal preferences.

------------------------------------------------------------------------

## 25. CI Gate

A task must not be considered complete if relevant CI checks fail.

Expected gates include:

``` text
Android lint
Android unit tests
Android build
Web lint
TypeScript check
Web tests
Web build
Database migrations
Database tests
RLS tests
Relevant integration/E2E tests
```

If a failure is unrelated and pre-existing, report it explicitly with
evidence rather than silently ignoring it.

------------------------------------------------------------------------

## 26. Definition of Done

Before reporting a task as complete, verify:

``` text
[ ] Requested scope implemented
[ ] No unrelated milestone implemented
[ ] Architecture preserved
[ ] Build succeeds
[ ] Relevant tests pass
[ ] Database migrations added if needed
[ ] RLS tests added/updated if needed
[ ] Offline behavior tested if relevant
[ ] Retry/idempotency tested if relevant
[ ] No secrets committed
[ ] User-facing strings localized
[ ] Documentation updated
[ ] Remaining risks reported
```

Do not claim completion if a required item is known to be failing.

------------------------------------------------------------------------

## 27. Required Agent Completion Report

At the end of every implementation task, report:

### Implemented

Brief description of completed behavior.

### Changed Files

List important files created/modified.

### Database

List migrations and schema/RLS changes, or state `None`.

### Tests

List tests added/updated and commands executed.

### Results

State which builds/tests passed.

### Manual Verification

List any required manual checks.

### Remaining Risks / TODO

List known limitations. Use `None` if there are none.

### SPEC Deviations

State `None` unless implementation differs from `docs/SPEC.md`.

Any deviation must be explicitly explained.

------------------------------------------------------------------------

## 28. Stop Conditions

Stop and ask for architectural/product clarification rather than
inventing a decision when:

-   SPEC requirements contradict each other;
-   implementation requires weakening security;
-   required offline behavior cannot be preserved;
-   a requested change crosses organization authorization boundaries;
-   a database migration would cause uncertain destructive data loss;
-   a new paid/external service is required but not specified;
-   a map/provider license conflicts with offline requirements;
-   a requested feature requires a major architecture change.

Small implementation details that are clearly implied by the SPEC do not
require unnecessary clarification.

------------------------------------------------------------------------

## 29. Task Scope Template

Implementation tasks should ideally follow this format:

``` text
Read docs/SPEC.md and AGENTS.md first.

Implement:
<task>

Milestone:
<Mx>

Scope:
<explicit files/features or behavior>

Acceptance criteria:
1. ...
2. ...
3. ...

Do not implement:
<out-of-scope items>

Before coding:
1. inspect the repository;
2. provide a concise implementation plan.

Then:
1. implement;
2. add migrations if required;
3. add/update tests;
4. run relevant checks;
5. fix failures;
6. provide the required completion report.
```

------------------------------------------------------------------------

## 30. First Implementation Rule

When starting from an empty repository, do not attempt to generate the
entire application in one pass.

Implement milestones in the order defined in `docs/SPEC.md`.

The first implementation target is **M0 --- Project and
Infrastructure**.

Only proceed to the next milestone after the current milestone's
acceptance criteria pass.
