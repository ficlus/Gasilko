# GASILKO — DEVELOPMENT STATE / HANDOFF
**As-of:** 2026-10-28  
**Update this file after every PR merge, SQL migration, deployment and pilot.**

## Read this first

Status words are intentionally **different**:

- `PR OPEN`: code under review, not in `main`.
- `MERGED`: code exists in GitHub `main`, not proof of SQL installation/deployment.
- `MIGRATION APPLIED`: exact SQL migration executed in intended Supabase project.
- `EDGE DEPLOYED`: server function code actually updated.
- `ANDROID BUILT`: owner ran build and Room schema export.
- `HUMAN VERIFIED`: scenario/permission/offline/runtime behavior tested and recorded.
- `UNKNOWN`: not established from available evidence. Never quietly upgrade this to successful.

This snapshot was reconciled with public GitHub PR pages on 28 October 2026 and with the owner's previous reports. Production DB state is **not** accessible from the repo.

## 1. PR history

| PR | Scope | GitHub state on snapshot | Evidence/notes |
|---|---|---|---|
| #74 | M14.6A scenario templates | MERGED | `20261015140000_simulation_templates.sql` |
| #75 | M14.6B dynamic events | MERGED | `20261016140000_simulation_dynamic_events.sql` |
| #76 | M14.6B1 fast map samples | MERGED | `20261019120000_command_map_fast_samples.sql` |
| #77 | M14.6C hazard/fire/smoke | MERGED 2026-10-20 | `20261019150000_simulation_hazard_models.sql`; runner addition |
| #78 | M14.6C.2 SIM workflow recovery | MERGED 2026-10-23 | `20261021120000_simulation_workflow_recovery.sql` |
| #79 | M14.6D operational effects/water | MERGED 2026-10-26 | `20261023120000_simulation_operational_effects.sql` |
| #80 | P0 hazard batch ambiguity hotfix | MERGED 2026-10-26 | `20261026110000_fix_simulation_hazard_batch_aliases.sql` |
| #81 | M14.6D final hardening | MERGED 2026-10-26 | `20261026120000_harden_simulation_operational_effects.sql` |
| #82 | M14.7A/M14.8A Android field pilot | **OPEN** 2026-10-28 | Branch `codex/m14-7a-8a-android-field-pilot`; reported head `5e5896b`; SQL `20261027100000_incident_android_field_pilot.sql` |

PR links: https://github.com/ficlus/Gasilko/pull/74 through https://github.com/ficlus/Gasilko/pull/82.

### State of #82 — P0 open source defect

The latest visible branch SQL file was inspected 2026-10-28:
`supabase/migrations/20261027100000_incident_android_field_pilot.sql`

- `private.field_task_projection` at approximately line 32 starts `as $` and at line 47 ends `$;`. Invalid dollar quote.
- `public.incident_field_snapshot` starts `AS $$` but later closes with `END; $;` at approximately line 138. Mismatched delimiter.
- Do **not** merge / apply this migration until fixed on the same PR branch and independently reviewed again.
- Earlier PR #82 correction `5e5896b` reportedly addressed catalog version identity, offline dependencies, timeline privacy, access and notification race conditions. **Do not infer runtime success**.
- `configuration.id` was confirmed in source review as the immutable Action Definition version ID for the catalog response; do not revert this contract.
- Room 14→15, Gradle unchanged, schema export deferred to human build.

**Immediate next Codex instruction:** fix two dollar quote defects **on PR #82**, inspect full migration for analogous syntax/security defects, preserve existing field auth and offline version reconciliation; no new PR/merge/deploy/test/build by Codex.

## 2. Migration ledger (deployment state NOT yet confirmed)

| Migration | Needed before | Repo status | Database status |
|---|---|---|---|
| `20261015100000_sim_automatic_execution.sql` | H1 SIM navigation | merged earlier | UNKNOWN |
| `20261015120000_incident_command_map_read.sql` | H2 map read | merged earlier | UNKNOWN |
| `20261015140000_simulation_templates.sql` | B/C template | MERGED | UNKNOWN |
| `20261016140000_simulation_dynamic_events.sql` | B events | MERGED | USER REPORTED applied 19 Oct; verify |
| `20261019120000_command_map_fast_samples.sql` | B1 fast sampling | MERGED | USER REPORTED applied 19 Oct; verify |
| `20261019150000_simulation_hazard_models.sql` | C | MERGED | observed function exists by 26 Oct; exact ledger UNKNOWN |
| `20261021120000_simulation_workflow_recovery.sql` | C.2 | MERGED | RPC previously observed; full ledger UNKNOWN |
| `20261023120000_simulation_operational_effects.sql` | D | MERGED | `simulation_operational_command` observed running 26 Oct; full ledger UNKNOWN |
| `20261026110000_fix_simulation_hazard_batch_aliases.sql` | P0 #80 | MERGED | **NOT CONFIRMED APPLIED** |
| `20261026120000_harden_simulation_operational_effects.sql` | D hardening #81 | MERGED | **NOT CONFIRMED APPLIED** |
| `20261027100000_incident_android_field_pilot.sql` | Android #82 | OPEN/defective | **DO NOT APPLY** |

The user frequently applies SQL through Supabase SQL Editor. In that path migration-history tracking may not record application. Never infer "not applied" from missing `supabase_migrations.schema_migrations` entry alone; verify exact functions/behavior and keep an independent human ledger. Never automatically re-run migrations.

## 3. Edge and Web status

- Existing SIM Cron: `gasilko-sim-runner-5s`. Existing runner Edge Function: `incident-simulation-runner`, protected by `SIMULATION_RUNNER_SECRET` (never print/request). `incident-navigation` uses normal human JWT.
- 26 Oct: user showed Edge Function invocations approximately every five seconds with HTTP 200; `net._http_response` JSON repeatedly showed `"hazards":{"error":"HAZARD_BATCH_UNAVAILABLE"}`.
- Direct rollback diagnostic returned SQLSTATE **42702**: ambiguous `"s.id"` within `public.simulation_hazard_batch()` opening cursor; this motivated #80.
- #80 merged, but **no later reliable human runtime evidence** in conversation confirms SQL hotfix applied and hazard steps progressing.
- #81 runner/Cron unchanged, adds SQL + Web. Matching Web deployment and DB hardening state UNKNOWN.
- Android #82 not deployed/built. Its new SQL remains unapplied.
- Web local development command (reported): `npx --yes pnpm@11.19.0 --dir web dev`.

## 4. Human-observed SIM incident (26 Oct 2026)

Diagnostic query returned:
- Incident `2bb76dc6-6f30-4f02-b6f5-b9a910fe97ff`: RUNNING, 811 simulated seconds; required hazard step 162, processed step 0, `last_scan_at=NULL`, `last_error=NULL`.
- Another training incident `305eeb40-2e2e-42eb-8ddd-68284e5a21c3`: 234348 sim seconds, required capped step 5760, processed 5760; last scan Oct 23.
- `simulation_operational_command` rejected water action with `OP_CATCHUP_REQUIRED`.
- `net._http_response` showed hazards `HAZARD_BATCH_UNAVAILABLE` in 17–73ms, movement completed independently.
- `simulation_hazard_batch()` existed, SECURITY DEFINER, `service_role` EXECUTE true.
- `NOTIFY pgrst, 'reload schema'` did **not** resolve the error.
- A diagnostic `DO` block revealed the SQLSTATE 42702 source defect. **Do not repeat diagnostic mutating probes casually.**
- After #80/#81, need fresh evidence of ordinary hazards response, step increase, stable catch-up and `APPLY_WATER` correctness.

## 5. Unresolved blockers and observations

### P0 — block PR #82 merge
- Fix incorrect SQL function dollar quotes, inspect SQL function signatures, privileges, account/unit/crew authorization and Room migration.
- Manual SQL and Android build/export are **not** optional if owner wants to run the controlled pilot; Codex is only implementation.

### P0 — SIM runtime verification after #80/#81
- Verify actual SQL migrations applied in correct order, runner hazard normal response, processed step changing, fail count, and water effect.
- Verify FINISH vs incident CLOSE and no task auto-completion; verify TRAINING/REAL isolation.

### P1 — Android field pilot acceptance
- Source-level migration correctness; Room 14→15 preserves existing queues and photos.
- Two Android devices with real human accounts (RESPONDER and UNIT_LEADER), Web commander, TRAINING incident; validate ACK, START, BLOCKED, RESUME, UNABLE, COMPLETE, notification deep link, outage/retry, account switch, role revoke, lease.
- No real emergency pilot until operational readiness and communication redundancy are documented.

### P1 — reliability/observability
- SQLSTATE and sanitized correlation for hazard runner errors; avoid 200 masking failed phase.
- Measured performance under many active SIM routes; B1 path persistence and stale map issues from Oct 20 handoff remain to verify.
- Previous PostgREST `57014` timeout/HTTP 500 in general reads: needs diagnosis if recurring (do not assume root cause).
- Historical `HYDRANT_CONTEXT 503` observation should be verified if still reproducible.

### P2 — developer productivity
- Implement shared architectural memory/roadmap synchronization and safe automated review.
- Clarify current `AGENTS.md` testing/CI requirements versus explicit implementation-only instruction. This cannot be silently papered over.
- Create independent migration/deploy ledger with human confirmations.
- Keep project docs current after merge, not by auto-merge.

## 6. Source review problems previously caught

- JSX unmatched brace (`EventPlanEditor`, later `SimulationProvider`) caused Web compile failures.
- SQL malformed dollar delimiters in M14.6C.2 and open PR #82.
- PL/pgSQL variable/SQL alias collisions `s.id`/`m` caused SIM hazard runner to fail before first processed step.
- Generic `SERVER` / unknown outcome hid failed SAVE, and `sessionStorage` pending originally locked entire template library in one tab.
- Android offline dependent commands previously assumed version `+1`; corrected to authoritative re-read/reconciliation.
- Catalog Action Definition ID vs immutable version ID required source-of-truth confirmation.
- Never infer "API returned 200" means backend operation committed. Distinguish list READ from save WRITE.

## 7. Current owner workflow

- Human manually reviews/merges all PRs.
- Human manually pulls GitHub main and preserves local Android/Gradle/KAPT changes.
- Human applies SQL in Supabase SQL Editor, deploys Edge via Supabase CLI when needed, runs Web/Android.
- Codex implementation only; no tests/build/lint/typecheck/CI, no SQL execution/deploy, one PR per milestone; correction goes to SAME OPEN PR.
- Local changes historically in Android Gradle/`pnpm-lock.yaml`, `web/next-env.d.ts` and some Web files; **do not assume these files are clean**.
- Never reset hard/drop stash/restore broad changes as a shortcut.
