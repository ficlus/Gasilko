# CODEX V2 FULL IMPLEMENTATION SPECIFICATION — M14.7C — operational scoped messages

**V2 document status:** detailed design/implementation task, not a production runtime specification. The author has not run builds, SQL, tests, deployments or verified target environment. Concrete names and schemas outside cited current source are **design proposals**, to be validated by Codex against HEAD before implementation.

**Execution approval:** No task in this archive is approved for autonomous dispatch merely by inclusion. Only owner approval and merged dependencies authorize implementation. Use exactly the existing PR for a still-open PR correction; use one new PR for a newly approved milestone. Never merge or deploy.

**Authority order:** actual current code/schema and current `docs/SPEC.md`, `docs/SPEC-M14-INCIDENT-OPERATIONS.md`, `AGENTS.md` > current owner decisions > this V2 packet > historical V1 summary. If a constraint conflicts (for example AGENTS.md asks for tests but owner asked Codex not to run tests), report the conflict and follow the explicit owner restriction for this task, without rewriting AGENTS.md silently.


## V2.0 — Domain integration targets

**Inspect and map these concrete areas first:** M14.7 bounded audience messages; existing `incident_participants`, unit and sector role scope, `incident_timeline`, M10 notification pipeline.

Before touching a file, identify its exact authoritative owner and lifecycle. Submit a brief source-level inventory in the PR description: what existed, what is extended, what stays unchanged, and why this milestone does not duplicate an existing service. For any proposed new object name, search all current migrations and client imports for the same capability.

## V2.1 — Definition of scope and baseline discipline

This prompt specifies source-level implementation, not permission to operate the software in production. Before editing, inspect the canonical domain contracts and current GitHub `main`, compare the latest open PRs, and write down exact existing function signatures, version fields, RLS helper names, Kotlin package paths and notification interfaces. The repository may have advanced after this document was prepared; stop with a no-op or explicit dependency blocker if the capability already exists or a required upstream PR is unmerged.

Do not force the example data model below into the project if a canonical table/RPC already holds the same facts. Treat it as a minimum conceptual field-and-invariant checklist. Minimize migrations, extract shared logic only when it prevents duplicated business authority, keep data and command semantics server-authoritative and make the user-visible status reflect only confirmed data.

**Deliverable must be independently implementable by contractors:** code, schema changes when necessary, migration ordering, permissions, UI adapters, error code mapping, documentation and a human-run acceptance guide. No unresolved TODO stubs for the core milestone; if an external service/dependency is truly unavailable, implement the safe permitted subset, explain the restriction and do not present a fake working integration.


## V2.2 — Detailed domain data and immutable contracts

Conceptual `incident_messages(id uuid, incident_id, author_id, acting_org_id, audience_kind INCIDENT|AGENCY|SECTOR|UNIT|DIRECTED, audience_id?, body text, created_at, revision, status)`. Append-only message records; redaction/retraction via linked events, not destructive edits. Bound UTF-8 message to 2k characters initially, max 50/page. No `chat_members` second role system; recipient read authorization derives from effective command tree at request time.

**Contract requirements:** For every relevant record specify canonical PK, FK into real existing entities, allowed nulls, uniqueness, actor/organization scope, stable version, indexes for listed reads, retention and audit provenance. If this section describes a conceptual table, first prove an existing canonical table is not already sufficient. No implicit privileged writes to public tables.

**RPC/API design:** For each command/read document a short signature table in milestone docs: name, purpose, input (UUIDs, expected versions and bounded structured parameters), output (entity/version and safe status), allowed actor scope, immutable operation receipt, error codes and paging. Infer **actual signatures from source**; do not take the illustrative names or types here as facts. All state-changing RPCs must be locked, actor-derived and idempotent; all read projections must enforce the same current actor/org/incident visibility used by canonical domain.

## V2.3 — Deterministic application algorithm

Sender selects audience and previews eligible scope; server validates effective authority, stores message and audit receipt atomically; M10 event references message ID; Android inbox opens via authenticated read; read marker optional per user but must not equal command acknowledgement. Prohibit '@everyone' escaping scope. Authorized retraction produces event and hides body when appropriate; audit preserved. Pagination keyset `(created_at,id)`.

**Acceptance of algorithm:** Write down the exact source-level order of read → authorization → version/lock → side effects → append-only receipt/audit → response → client reconciliation. Specify which operations must be in one DB transaction and where a two-phase protocol is unavoidable (e.g. network/Storage), with an explicit recovery state. Define a deterministic ordering key for simultaneous events and a bounded retry/backoff policy. A duplicate request must not produce duplicate domain effects. Do not hard-code guesses about actual server version increments.

## V2.4 — Failure-state matrix

Message sent then FCM fails → durable message still exists. Recipient's unit reassigned → current authorization decides visible scope, history rules explicit. Message mistaken for tactical command → UI clearly directs to canonical M14.5A task. Retraction after offline caching → synchronize tombstone. Dangerous content/privacy → bounded sanitizer, text not HTML. Duplicate UUID retry → single visible message/event.

**Required error classification:**

| Failure class | User-visible result | Server and client action |
| --- | --- | --- |
| Definitive validation/authorization rejection | Clear SI/DE reason, no success badge | Preserve evidence and allow corrected NEW request only after explicit user review |
| Stale version or changed authority | Conflict/permission changed | Refresh authoritative scope, compare state, never silently rebase in-flight payload |
| Lost HTTP reply / timeout | Outcome unknown, original action available | Reconcile original immutable operation receipt; exact retry UUID/payload if safe |
| Missing permission to read cached data | Access unavailable | Hide protected cache immediately; retain unsynced local evidence securely |
| Duplicate delivery / repeated event | No duplicate state change | Deduplicate by durable event/operation identity, then refetch canonical state |
| Corrupted/partial client state | Incomplete, not confirmed | Preserve last complete generation and use explicit recovery; no destructive database reset |
| Unsupported external capability | Clearly unavailable | Safe documented fallback or stop with dependency report, never fabricated integration |

Only implement rows applicable to this domain; add domain-specific safe error codes rather than leaking raw internal SQL details.

## V2.5 — Android/Web/SIM user workflow

Compact incident communications tab, channel audience pill, composer showing recipient scope, no false read/ACK. High-priority tactical orders routed to task creation, not text. Optional unread count separate from assignment count; localized SL/DE.

**User flow specification:** Write a concrete UI state transition map in the PR notes with entry/navigation, role gate, loading/empty state, review, explicit confirmation, server-pending, confirmed, rejected, unknown, retry and historical read. Keep the presented action’s visible title/recipient/target/version identical to the frozen command. Source state from repository/Room or authenticated Web read, not from optimistic UI guesses. Error wording is Slovenian/German; stored protocol codes stay language-neutral.

## V2.6 — Explicit invariants, non-goals and owner decisions

No general-purpose public chat, no voice replacement for ZA-RE, no automatic task creation from text.

Preserve legitimate behavior already implemented in previous M14.5A, M14.6, M14.7A/M14.8A and M10 scopes even when the milestone is unrelated. If an external agreement, privacy policy, runtime evidence or owner sign-off is a prerequisite, do not interpret this file as that authorization; stop with the missing dependency and an implementation-ready recommendation rather than shipping a pretend integration.

## V2.7 — Implementation sequence with reviewable commits

Structure the implementation so a human PR reviewer can reason about each layer in order:

1. **Inventory and collision check:** inspect current canonical migrations, actual RPC signatures/return structures, Android/Web source, AGENTS.md and the latest PRs; list exactly what can be reused. Check committed upstream dependencies and whether the feature already exists under a different name.
2. **Explicit invariants:** write down actor, resource, incident, organization and mode constraints before coding. Distinguish actor authentication from role and participation authorization. Record the current version to be locked on each mutation.
3. **Contract and schema decisions:** choose the smallest existing canonical aggregate to extend; document conceptual proposal versus actual adopted schema. SQL must use stable PK/FK constraints, indexes for bounded read paths, provenance, and conservative grants.
4. **Read side:** add/extend actor-bound, paginated, privacy-scoped projections before UI screens. Never return raw internal JSON to a broader audience because a UI can hide it.
5. **Write side:** implement existing versioned command/RPC or a narrowly scoped replacement only if missing. Use an immutable operation UUID and request identity, receipt reuse and locked optimistic revision for every state-changing command.
6. **Historical records:** preserve append-only timeline/audit and stable identity. No deletion or destructive rewrites of previous incident, hydrant or SIM records.
7. **Client integration:** hook the existing Web and/or Compose → ViewModel → Repository → Room pipeline where relevant; do not put service keys or authoritative state changes in UI logic.
8. **Offline/realtime:** separate local intent, unknown delivery and confirmed outcome; preserve original request identity on transport ambiguity; cache authorization must expire conservatively.
9. **Interface usability:** implement SI/DE labels, correct role-specific controls, retry/attention states and a clear empty/error path. Never make a safety-critical action happen merely on navigation, notification tap or map selection.
10. **Performance:** bound query rows, byte payload, retries and background processing. Avoid N+1 queries and over-eager map remounting/notification fanout. Describe expected indexes and backpressure.
11. **Migration plan:** add only forward-only migrations after the latest deployed migration; no old migration rewrites. Document the operator's exact order and the compatibility window between old Android/Web and new RPCs.
12. **PR handoff:** report exact changed files, merged prerequisites, API surface, security design, manual migration/build steps, known limitations and explicit NOT TESTED/NOT DEPLOYED status. Stop with ONE PR; human alone merges.


## V2.8 — Correctness obligations and invariants

For every applicable new RPC, hook or UI action, the PR must answer these questions in its documentation or code comments without exposing secrets:

- **Identity:** Which canonical UUID is the subject, which UUID is the actor, and where is the effective organization/incident participation derived? Display names, room IDs or locale labels must never substitute for authoritative IDs.
- **Permission:** What exact current membership, active incident role, recipient episode or owner scope authorizes the action? Check authorization within the mutation transaction, not merely when the screen loaded.
- **Version:** Which expected version/revision is compared under lock? A `STALE_VERSION` failure must not silently rebase or overwrite another user's work.
- **Receipt:** What immutable `(operation_id, actor, organization, action, normalized request)` identity is stored? On identical retry return the previous result; on identity mismatch reject as `OPERATION_REUSED`.
- **Ambiguity:** If an HTTP response is lost, how does the client hold the original request and distinguish UNKNOWN from definitive rejection? An absent receipt alone cannot prove the earlier operation never committed.
- **Privacy:** Which sensitive fields are omitted at SQL projection, FCM payload, Realtime hint, local Room scope, private Storage or exported report boundary?
- **Lifecycle:** Which transitions are legal in ACTIVE/PAUSED/STABILIZED/FINISHED/CLOSED conditions, and who can issue them? No task completion on notification, navigation arrival or simulation effect.
- **Data mode:** Which records are TRAINING/SIM-only and which are REAL? Simulated water, virtual agents and fabricated positions must not cross to real operations or hydrant registry state.
- **Failure isolation:** Which bounded transaction can fail without starving another incident, unit or task? How is a failed job resumed or escalated without duplicating effects?
- **Retention:** What authoritative history must remain append-only, and what cache/transient data may expire? State precise time/size limits only when already approved or justify suggested defaults.
- **Backwards compatibility:** Do previously issued tasks, old Android app versions, published templates, cached Room databases and archived incidents still load without destructive reset?
- **Operational evidence:** What should a human see in SQL logs, Web and Android to distinguish a working feature from superficially successful HTTP 200? Do not claim verified until human observes it.

Where a requirement does not apply, explicitly write “not applicable” with reason rather than inventing a parallel subsystem.


## V2.10 — Milestone-specific manual acceptance and negative checks

**Specific human checks:** Web IC message visible to authorized Android unit only, never unauthorized agency; messages survive missed FCM; offline stale message is visibly stale; task state unchanged after message read; message retreated retains audit.

The operator's manual acceptance record MUST cover at least: valid actor flow; denied actor; inactive org/member; stale revision; duplicate UUID; lost response; revoked visibility; offline/reconnect if applicable; actor/org switch; REAL/TRAINING boundary; SI/DE; safe empty/unsupported state; role-specific UI; source/report history preservation. For irreversible or sensitive commands, include explicit confirmation and no automatic implementation of consequences from map taps, push delivery, state hints or mere navigation.

Add **at least 12 numbered, domain-specific human-run cases** to the milestone documentation, derived from actual behavior in the current implementation. Do not run them, seed test production data, or claim passing results. For optional future concepts, all evaluation must occur in an explicitly approved sandbox/training context, never through unauthorized official/emergency interfaces.

## V2.9 — Human-only rollout and acceptance protocol

After Codex opens or updates the PR, the owner performs these steps independently (Codex must not execute them): review PR diff at a pinned SHA; verify deployment/migration dependencies and outstanding blockers; merge only if satisfied; use a safe Git stash/fetch/fast-forward/restore workflow to preserve local Android/Gradle changes; apply only unapplied forward-only SQL migrations in correct sequence in Supabase SQL Editor; update Web/Edge only when this specific PR requires it; perform local human Android build/Room schema export if applicable; carry out the concrete manual acceptance cases; document actual results and correlation codes; maintain backout/forward-fix plan.

Git pull transfers *files*, not applied Supabase SQL. Do not report deployed simply because a migration exists on `main`. For field/pilot features, use TRAINING incidents with real approved human accounts, Web commander plus two Android devices, and a radio/voice fallback; never claim suitability for emergency response based on source review alone.

Codex may inspect source as necessary to implement but must **not** add or run automated tests, build, lint, typecheck, Gradle sync, emulator, CI, SQL execution, migration application, cloud deployment, runtime validation, manual acceptance, storage bucket changes, Cron changes or secret rotation. No Gradle/KAPT/KSP/dependency or generated Room schema edits without explicit owner permission. One PR; no merge. Use `[skip ci]` per established implementation convention. Document deviations that a current AGENTS.md rule would ordinarily require, without silently changing repository-wide policy.


## V2.10A — Domain-specific recovery and acceptance cases (human-run only)

The following cases are part of the implementation contract. Build the correct code paths and describe the expected authoritative outcomes. Do not run them; they are the human operator's later verification scenarios.

1. **Negative case 1:** Message sent then FCM fails → durable message still exists. The implementation must demonstrate a controlled, server-authoritative outcome rather than a UI-only workaround. Record the actual canonical status, which operation/receipt is retained, which actor may recover, and whether any protected data remains visible. A human operator later verifies this with a permitted scenario; Codex must not execute it.
2. **Negative case 2:** Recipient's unit reassigned → current authorization decides visible scope, history rules explicit. The implementation must demonstrate a controlled, server-authoritative outcome rather than a UI-only workaround. Record the actual canonical status, which operation/receipt is retained, which actor may recover, and whether any protected data remains visible. A human operator later verifies this with a permitted scenario; Codex must not execute it.
3. **Negative case 3:** Message mistaken for tactical command → UI clearly directs to canonical M14.5A task. The implementation must demonstrate a controlled, server-authoritative outcome rather than a UI-only workaround. Record the actual canonical status, which operation/receipt is retained, which actor may recover, and whether any protected data remains visible. A human operator later verifies this with a permitted scenario; Codex must not execute it.
4. **Negative case 4:** Retraction after offline caching → synchronize tombstone. The implementation must demonstrate a controlled, server-authoritative outcome rather than a UI-only workaround. Record the actual canonical status, which operation/receipt is retained, which actor may recover, and whether any protected data remains visible. A human operator later verifies this with a permitted scenario; Codex must not execute it.
5. **Negative case 5:** Dangerous content/privacy → bounded sanitizer, text not HTML. The implementation must demonstrate a controlled, server-authoritative outcome rather than a UI-only workaround. Record the actual canonical status, which operation/receipt is retained, which actor may recover, and whether any protected data remains visible. A human operator later verifies this with a permitted scenario; Codex must not execute it.
6. **Negative case 6:** Duplicate UUID retry → single visible message/event. The implementation must demonstrate a controlled, server-authoritative outcome rather than a UI-only workaround. Record the actual canonical status, which operation/receipt is retained, which actor may recover, and whether any protected data remains visible. A human operator later verifies this with a permitted scenario; Codex must not execute it.
7. **Happy-path / boundary case 1:** Web IC message visible to authorized Android unit only, never unauthorized agency; messages survive missed FCM; offline stale message is visibly stale; task state unchanged after message read; message retreated retains audit. The PR documentation must name the relevant source read/RPC and expected final persistent state; no positive observation is claimed until the owner performs the check.

## V2.11 — Deliverable completion contract

- Implement a self-contained source-level feature, not only demo screens or prose. If blockers make implementation impossible without a forbidden action, stop and report the exact missing capability; never claim completion.
- Document actual changed functions, tables, UI components, data flow, allowlisted errors, migration order, manual user acceptance and backwards compatibility. Include an unambiguous `OUT OF SCOPE` subsection for adjacent milestones.
- Maintain the authoritative M14 SPEC with a scoped progress note; do not rewrite earlier historical statements. Place documentation in `docs/` under the current naming convention.
- Final Codex report: PR URL, base commit SHA, branch, changed files, source inspection, migrations, recipient/capability matrix, exact operation receipt behavior, SI/DE, known limitations, operator rollout steps and `NOT TESTED / NOT DEPLOYED`.
- Owner alone merges; owner alone applies SQL, deploys apps/Edge, authorizes real operational use and approves subsequent milestones.

---

## V1 retained scope — original milestone obligations

The following is the original roadmap instruction retained verbatim as a scope/reference baseline. The V2 details above refine it; current authoritative repository contracts still prevail. Do not carry out a stale instruction just because it appeared in this October 28 planning snapshot.


**Gasilko repository:** https://github.com/ficlus/Gasilko  
**Scope:** COMMUNICATIONS | **Priority:** P1 | **Gate:** AFTER_MERGE  
**Dependencies:** 02, 03 preferred  
**Prepared:** 2026-10-28 | **Prompt status:** DRAFT FOR FUTURE HUMAN/WORK SELECTION — not automatically approved for dispatch.

> This is a standalone ready-to-send English task. The dispatcher MUST first check current GitHub main, open PRs, owner approvals and prerequisites. If the feature has been implemented since preparation, stop with a no-op report rather than repeat it. Only the owner may approve milestone start.

## 0. Mission and exact scope

Implement brief incident/organization/unit operational messages as supplemental situational communication. Critical tactical orders remain M14.5A tasks requiring explicit ACK; text messages never replace ZA-RE radio or issue authority.

## 1. Canonical domain contracts / data model

Canonical model `incident_messages`: UUID, incident ID, sender user/acting org, audience INCIDENT/ORGANIZATION/UNIT, audience_org_id or unit_assignment_id, body <=4000 chars, sent_at, supersedes_id for append-only corrections, immutable history. Validate issuer audience and viewer at commit/read.

## 2. Implementation instructions (server, Android, Web, UX)

Forward-only migration with `incident_message_send`, `incident_message_correct`, `incident_messages_read` (names adapt to actual RPCs). Exact incident read and effective unit scope, per-audience RLS, bounded pagination `(sent_at,id)`, server time, stable UUID receipt idempotency and audit/timeline summary without leaking private text. Android Compose message panel uses Room/cursor from M14.7B, online send initially, explicit correction instead of editing prior row; Web scoped panel shares DTO. M10 generic new-message notification event with recipient eligibility recheck.

## 3. Deterministic algorithm / dataflow

```text
Authenticated actor + current audience → server-authorized append-only message/attachment → scoped read → minimal M10/Realtime hint → client fetch.
```
A message is not a tactical task command.

Use stable canonical object UUIDs, expected versions and server receipts. Describe the source-of-truth state transition for this milestone in the documentation; when the operation is ambiguous, preserve original identity and reconcile rather than silently assuming failure. Keep bounded reads and idempotent writes.

## 4. Failure modes, security, compatibility and exclusions

Do not add free-form public chat, auto-translate private content, display private unit messages to incident-wide audiences or allow messaging to mutate tasks. Add rate/size limits and spam prevention without suppressing urgent authorized task commands.

**Out of scope:** Features assigned to another milestone, unapproved dependencies and replacement of canonical domain infrastructure.

## 5. Human-run acceptance targets (do NOT execute)

Human: incident audience, org audience, unit audience, cross-scope denial, correction lineage, offline read after authorized cache, no text in push/timeline, duplicate send dedupe, no false command ACK.

The human must additionally confirm actor/org scope, inactive or revoked access, optimistic concurrency, duplicate request/receipt replay, interrupted network, SI/DE and migration compatibility where applicable. Record *observed* results only after actual human execution.

## 6. Documentation and PR handoff

Update a scoped milestone document under `docs/` (use the current naming convention), adding:

- Current source architecture and exact reused functions/classes (with real signatures).
- Source-level additions, schema migrations and safe SQL ordering, if any.
- Authorization matrix and REAL/TRAINING boundary.
- Data flow, retry/idempotency and conflict handling.
- SI/DE UI and offline behavior where applicable.
- Manual runbook for owner: Git pull, Supabase migrations, Edge deploy if required, Web/Android build, Room export if required, human checks.
- Known limitations, feature-gate state and unresolved evidence.

PR description must separate source implementation from human validation. Mark as **NOT TESTED / NOT DEPLOYED**. Do not claim source inspection proves real-world readiness.

## A. MANDATORY REPOSITORY DISCOVERY (before implementation)

1. Read current `AGENTS.md`, `docs/SPEC.md`, `docs/SPEC-M14-INCIDENT-OPERATIONS.md`, and the relevant milestone documents. Read `docs/GASILKO-ARCHITECTURE-CONTEXT.md` and the latest `GASILKO-DEVELOPMENT-STATE.md` when present; documentation in this pack may not yet be committed to GitHub.
2. Inspect the ACTUAL latest GitHub `main` commit, current open PRs, authoritative Supabase schema/RPC signatures, Kotlin package paths and current code. The 2026-10-28 snapshot in this prompt is orientation, NOT confirmation of today's repo state.
3. Before coding, check whether the requested capability already exists or is under development in another PR. If so, integrate safely or stop with a source-backed no-op; do not duplicate an engine or create an unnecessary PR.
4. Read the current source implementations and the existing database constraints, grants, RLS, receipts and version policy rather than inventing functions or data fields. Read library documentation/current versions ONLY if selecting an API whose behavior materially depends on it.
5. Identify dependencies on unmerged PRs. **Never base an implementation on another PR's unmerged code unless explicitly approved by the owner.** Stop with a dependency report if the requirement cannot safely be implemented on merged `main`.

## B. INVARIANTS — NEVER BREAK

- Gasilko is Slovenian/German (`sl`/`de`), offline-first with Android Kotlin/Compose → ViewModel → Repository → Room → existing Sync Engine/WorkManager → authenticated Supabase; Web Next.js/TypeScript → SSR/API → authenticated RPC; MapLibre and existing routing/provider stack.
- Account ACTIVE + exact organization membership + currently effective incident participation/role determine access. Organization ADMIN/MANAGER does not confer command authority. Unit leader controls ONLY current authorized subordinate crew/own unit; no borrowed command rights or inherited organization write access.
- Use canonical incident/task/action/assignment/unit/organization UUIDs. Every state-changing RPC uses existing authority, locked expected versions and immutable operation receipts: exact `(operation UUID, actor, organization, action, request)` replay; absent receipt is UNKNOWN, not confirmation of failure.
- Existing M14.5A tasks and recipient episodes are the only authority for orders and ACK. Notification delivery/tap is not ACK; MOVE_TO is not physical work; Android locally queued action is not server-confirmed.
- Android offline operations: never discard unsynced evidence, no destructive Room migration, no second worker/queue; revocation and account/org switch invalidate visible protected data. Incident cache lease ≤24 hours with 2-hour warning; registry org lease ≤30 days remains distinct.
- SIM/TRAINING vs REAL separation at database, client and notifications. No fabricated real GPS, hydrant pressure, casualty/medical data, actual dispatch, fake task completion or autonomous tactical command. Critical voice/radio ZA-RE remains necessary.
- Existing M10 only for FCM; existing protected `incident-simulation-runner` and ONE five-second Cron for SIM; no second scheduler/physics/task/routing/map engine.
- Forward-only SQL migrations newer than currently merged migration; never change already-applied migrations. Any `SECURITY DEFINER` must use safe search_path, restricted EXECUTE grants, bounded inputs, actor-derived identity and non-leaky error responses. Inspect PL/pgSQL dollar delimiters and alias-variable ambiguity, learned from PR #78/#80/#82.
- Protect user/organization/incident scoped private data, event/hazard instructor visibility, Storage and logs. Use UTC, WGS84 longitude/latitude, bounded paginated reads and SI/DE localization.

## C. IMPLEMENTATION AND DELIVERY CONTRACT — STRICT

This is **source implementation only** by Codex. Do **NOT** add or execute tests; do NOT run build, Gradle sync, lint, typecheck, CI, emulator, browser/runtime verification, Docker, Supabase local, SQL execution/migration apply, Web/Android/Edge deploy, real push sends, Cron modifications, secret rotation or real incident creation. Do not perform post-implementation validation. Do not modify Android Gradle/KAPT/KSP, version catalogs, dependencies, generated Room schemas or local developer files. Human operator later performs explicit manual build, SQL, deployment and acceptance. The repository `AGENTS.md` may require tests/CI: report this policy conflict honestly; do not silently suppress required release validation or claim it passed.

Implement a focused complete end-to-end slice, not disconnected mock screens. Do not introduce unrelated future milestones or speculative infrastructure. A current PR fix must update the SAME open PR; a NEW owner-approved milestone creates exactly ONE new PR targeting merged main. Use `[skip ci]` according to project conventions. **Never merge, deploy, apply SQL, purchase credits or modify main automatically.** Report exact files/functions/migrations, scope/security decisions, rollout order, runtime unknowns and explicit declaration that no tests/builds/SQL/deploy were performed. Stop after publishing/updating the ONE PR.

## D. MANUAL ACCEPTANCE AND RELEASE GATE

The checks described below are targets for a **HUMAN** operator after source review, merge, and approved migrations/build/deployment. Do not execute them or claim success. For an operational REAL feature, the presence of source code alone never establishes emergency readiness; require the separate field safety and radio fallback gate. For every new SQL/Android deliverable document forward-only migration order, existing data compatibility, current operator commands, permission matrix, ambiguous-response recovery and rollback/feature-disable boundaries.
