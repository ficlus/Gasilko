# GASILKO — ROADMAP & MASTER TODO
**Prepared:** 2026-10-28  
**Types:** [P0] deployment blocker; [P1] pilot safety/quality; [P2] next product value; [P3] exploratory.  
**Status:** `[x]` source merged/known; `[ ]` unfinished; `[?]` verify source/runtime. `MERGED` ≠ tested/deployed.

This is a **proposed execution plan**, not a change to approved SPEC. If milestone names conflict with `docs/SPEC-M14-INCIDENT-OPERATIONS.md`, the SPEC remains canonical. Existing M14.6 SIM *submilestone* labels and the core SPEC's M14.6 Mobilization are parallel naming history; explicitly clarify before renumbering.

## NOW — Gate A: PR #82 and existing runtime

- [ ] [P0] Fix `AS $`/`$;` and `END; $;` dollar-quote syntax in #82 SQL, keep same PR.
- [ ] [P0] Focused source inspection of SQL grants, `security definer`, privacy of task history, unit/crew episode RLS, M10 compatibility.
- [ ] [P0] Check Android Kotlin/Compose and Room entity/migration source for obvious issues; no Gradle/build by Codex.
- [ ] [P0] Review latest head diff and authorize #82 merge **human only**.
- [ ] [P0] Verify missing #80/#81 SQL in intended Supabase environment; apply only missing migrations by human, in order.
- [ ] [P0] Prove fire hazard batch stops returning `HAZARD_BATCH_UNAVAILABLE`; step advances; record last error and processing ms.
- [ ] [P0] Check `OP_CATCHUP_REQUIRED` clears when fire model catches up; controlled instructor APPLY_WATER affects training inventory/intensity.
- [ ] [P0] Verify critical SQL migration from #82 is correct before human applies it.
- [ ] [P0] Human Android build with Room schema export v15; fix concrete compile/migration failures in new PR if #82 already merged (or same PR if open).
- [ ] [P0] No actual emergency field deployment based solely on source merges.

## Pilot Gate B — M14.7A/M14.8A human acceptance

- [ ] [P1] Approved human accounts, ACTIVE exact org, command chain, one unit, leader, subordinate.
- [ ] [P1] One explicitly labeled TRAINING incident; no 112/CAD or real push alarm.
- [ ] [P1] Web commander issues canonical task; Android user sees without relying on FCM.
- [ ] [P1] FCM generic notification is delivered when configured; tap never ACKs.
- [ ] [P1] User explicitly ACK/START/BLOCKED/RESUME/UNABLE/COMPLETE; Web sees same assignment version.
- [ ] [P1] Unit leader can issue subordinate crew task; cannot command another unit or allocate units.
- [ ] [P1] Offline ACK survives restart; same UUID retry and dependent versions; conflict shown for human review.
- [ ] [P1] Reassign/revoke/switch account while offline: no unauthorized upload or stale protected data.
- [ ] [P1] Incident lease 24h warning 2h; organization 30d lease stays separate; fail closed.
- [ ] [P1] Room 14→15 upgrade preserves unsynced hydrants/inspections/photos.
- [ ] [P1] SI/DE, maps, target locations, cold-start/deep links, denied notification permission, tablet UX.
- [ ] [P1] Full manual 55-item pilot checklist in PR #82 docs with dated evidence.

## M14.7B — True field realtime, snapshots and operational communications (proposed next)
**Goal:** timely authorized field state without polling-only semantics; complete core M14.7 SPEC scope.

- [ ] [P1] Scoped authenticated PRIVATE Realtime incident channels; authorization/revocation; hints `{incident_id, revision, timeline_sequence}` only.
- [ ] [P1] Server-authoritative snapshot manifest pinned revision/sequence, bounded keyset paging and 5min TTL; change cursors with retention/rebuild.
- [ ] [P1] Reconnection, duplicate/missing hints, session/organization changes, safe manifest invalidation.
- [ ] [P1] Audience-scoped incident messages (INCIDENT / ORGANIZATION / UNIT) with corrections and retention.
- [ ] [P2] Private attachments with target audience, explicit access, hash/size, revocation; never public Storage URL.
- [ ] [P1] M10 FCM/Realtime integration without a second notification worker, avoiding push/ACK conflation.
- [ ] [P1] Review library/dependency changes only through separate authorized scope (no implicit Android Gradle churn).

## M14.8B — Android unit leadership & controlled field commands (proposed)
- [ ] [P1] Broader unit status/arrival/release/crew changes with canonical permissions and online-only authority.
- [ ] [P1] Robust unit-task and crew-task inbox with commander acknowledgement statuses, issue/reassign as role permits.
- [ ] [P1] Role handover, revoked leadership, 2 simultaneous devices, conflicts and audit.
- [ ] [P2] Field tablet layout and reduced cognitive load for firefighter in gloves; task map target/quick actions.

## M14.8C — Android incident map, target routing and scoped navigation (proposed)
- [ ] [P1] Canonical incident map objects/sectors/hydrant links, task target focus, layer filters and stale read indication.
- [ ] [P1] Route to a task point via existing NAV2/OSRM/GraphHopper boundaries; no second engine; arrival never auto-completes task.
- [ ] [P1] Offline map license/attribution and approved downloaded area.
- [ ] [P2] Unit map and safe optional *current* real position where approved, not SIM interpolation.
- [ ] [P2] Explicit short-lived opt-in foreground location sharing (if later approved): real `observed_at`, accuracy, TTL, revocation, retention, no permanent trail.

## M14.8D — Operational reliability, readiness and safety gate (proposed)
- [ ] [P0] Manual multi-device field acceptance with radio fallback.
- [ ] [P1] Disconnected operation recovery/lease, concurrent commands, notification loss, revoked JWT, expired session, battery/OS constraints.
- [ ] [P1] Metrics: command committed→hint→app read→human ACK, sync conflict/retry, unavailable FCM, dead-letter visibility.
- [ ] [P1] Security review, privacy/retention review, accessibility, incident simulation of network outage.
- [ ] [P1] Human-controlled staging/production rollout plan; rollback, backup, schema upgrade, smoke/manual verification.
- [ ] [P0] Explicit human go/no-go. Do not claim emergency readiness until proven.

## SIM follow-ups — names from earlier M14.6 roadmap (proposed, avoid naming clash)
- [ ] [P1] Source/runtime confirmation M14.6C/D under several RUNNING/PAUSED/FINISHED exercises; runner fairness and catch-up.
- [ ] [P2] Fast routing with ~20 simultaneous SIM units: instrument queue→OSRM→job→refresh; evaluate bounded safe concurrency and dedup; never just shorten Cron.
- [ ] [P2] Scenario lifecycle UX review: draft save receipt, event/hazard plan retention, preview/publish/start, activation/init, finish/close, historical read.
- [ ] [P2] M14.6E — enhanced bounded virtual behaviors (only after field pilot priority; must not invent tactical commands).
- [ ] [P2] M14.6F — scenario director / exercise controls; visibility and replay preparation.
- [ ] [P2] SIM replay and after-action metrics (different from core SPEC M14.10 official reports).
- [ ] [P2] Water network future: simulation-only source adapters (hydrant/reservoir/branching) only with explicit instructor-configured capabilities. Never infer real pressure/flow.
- [ ] [P1] Keep zero cross-contamination of REAL hydrants, inventory, dispatch and GPS.

## Core M14.9 — Official external incident intake (blocked on external agreement)
- [ ] [P3] Obtain legally supported provider/CAD/112 agreement and documented API.
- [ ] [P3] Signed provider adapter, replay defense, idempotent external receipt, mapping/quarantine, participant authority and strict audit.
- [ ] [P3] No scraping or invented 112 endpoints.

## Core M14.10 — Closure, reporting and archival
- [ ] [P2] Explicit outstanding work dispositions, resource release/transfer, commander closure confirmation.
- [ ] [P2] Immutable sealed closure snapshot and verified hash, authorized history/append-only amendments.
- [ ] [P2] After-action exports PDF/CSV/XLSX with privacy.
- [ ] [P2] No retrospective rewriting of task outcomes.

## Broader Gasilko platform backlog (deferred unless owner reprioritizes)
- [ ] [P2] Hydrant maps/offline tile licenses and NAV provider reliability.
- [ ] [P2] Hydrant registry quality, QR scanning, photo sync, M10 notification configuration, inspections/rounds acceptance.
- [ ] [P3] M11–M13 / reporting extensions, app store operational quality, organization onboarding, audit exports.
- [ ] [P3] Caddy/Oracle/Android dependency changes only by explicit scope; do not touch as side effect.
- [ ] [P2] Consider measurable SLOs, logging redaction and incident support/runbooks.
- [ ] [P2] Align README with actual merged milestone scope, retaining distinction between source and production readiness.

## Agent automation / documentation
- [ ] [P1] Commit these context docs through an owner-approved docs PR; no overwrite of `AGENTS.md`.
- [ ] [P1] Resolve explicit conflict: existing AGENTS "tests required/CI gate" vs owner's per-Codex "source-only no tests" instructions.
- [ ] [P1] Configure ChatGPT Project sources; check which Work/GitHub/PR triggers available; do not assert unsupported capability.
- [ ] [P1] Create read-only reviewer first; cap fix cycles at 2 per PR head.
- [ ] [P1] Enable optional Codex dispatch only after safe scoped credentials, budgets and human authorization.
- [ ] [P1] Protect main branch: no automated merge or deploy; human reviews all corrected diffs.
- [ ] [P1] Update `DEVELOPMENT-STATE` on GitHub merger/migration/deploy; no false automated status.

## Suggested execution order (not calendar commitments)

`PR82 SQL fix → review → owner merge → check/apply missing #80/#81 → apply #82 → Android Room v15 build → controlled 2-device pilot → M14.7B → M14.8B → M14.8C → M14.8D → optional SIM E/F & M14.9/10.`

Order may change based on actual pilot findings. Prioritize human safety and stable field ACK flow over additional SIM graphics.
