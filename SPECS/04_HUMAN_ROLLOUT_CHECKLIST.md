# GASILKO — HUMAN-OPERATED ROLLOUT & ACCEPTANCE RUNBOOK

**Not a Codex execution prompt.** Owner/human performs these steps; tool assistants must never claim them completed without evidence.

## 1. Git and source state

Confirm PR number and HEAD, comment review, then manually merge only after owner approval. Local Windows PowerShell: inspect `git status --short`; create a fresh labeled `git stash push -u` only if dirty; `git fetch origin main`; `git switch main`; `git pull --ff-only origin main`; conditionally `git stash apply <new stash hash>` only if it was created; inspect conflicts. NEVER `git reset --hard`, never blindly restore/delete Android local Gradle, `pnpm-lock.yaml`, `web/next-env.d.ts` or untracked Room schema files.

## 2. SQL ledger

Maintain explicit file/version, hash, Supabase project, applied_at, actor, SQL output and fresh RPC smoke evidence. Supabase SQL Editor runs do not necessarily register in `supabase_migrations.schema_migrations`. Never re-run a migration merely due to missing migration-history entry; verify exact installed signatures/behavior and previously recorded operator execution.

Historical reference filenames to check (do not assume unapplied):

- `20261019150000_simulation_hazard_models.sql`
- `20261021120000_simulation_workflow_recovery.sql`
- `20261023120000_simulation_operational_effects.sql`
- `20261026110000_fix_simulation_hazard_batch_aliases.sql` (#80)
- `20261026120000_harden_simulation_operational_effects.sql` (#81)
- `20261027100000_incident_android_field_pilot.sql` (#82; only AFTER fixed and merged)

Use exact current source migration ordering and do not guess status. Any SQLSTATE, failed or ambiguous outcome → STOP, capture error without credentials, resolve before applying next migration.

## 3. Web & Edge

Human runs local Web and Edge deployment only if actual diff requires it. #80 SQL alias fix did NOT require runner redeploy. Existing protected runner `incident-simulation-runner` and `gasilko-sim-runner-5s` Cron stay ONE. Do not publish runner secret or use --no-verify-jwt on human-token navigation function.

Prove actual inner runner `hazards` result and step progress; HTTP 200 or Cron succeeded is insufficient. October 26 failure: `HAZARD_BATCH_UNAVAILABLE`, underlying SQLSTATE 42702 `s.id` ambiguity; current DB state unknown without fresh evidence.

## 4. Android and Room

After #82 merge and approved migration: Human runs normal Android Studio build/sync and exports Room version 15 schema using established toolchain. No Codex Gradle/KAPT/KSP edits. Upgrade a device with real existing offline hydrant/inspection/photo queue, confirm no data loss. No destructive fallback. Keep at least one backup and known old APK distribution method.

## 5. Controlled TRAINING field pilot (not real emergency)

Prepare one approved organization, Web IC, current UNIT_LEADER and eligible crew member as distinct real accounts, one explicitly TRAINING incident, a real deployed unit/crew episodes and authorized Action Definition. On at least two Android devices: authorization, Web issue→Android read→explicit ACK→START→BLOCKED→RESUME→COMPLETE/UNABLE; Web sees same exact assignment; UNIT_LEADER can issue to own crew only. Validate denied permissions, FCM no auto ACK, offline airplane-mode ACK after restart + original UUID receipt, dependent task ordering, account/org switch and revocation, 24h incident cache lease, SI/DE, map task target and no REAL GPS fabricated.

## 6. SIM manual safety checks

For a new exercise verify: template SAVE with hazard/event plan, PUBLISH, START, command/activation/init, runner hazard step and last_error, SIM fire/smoke (STRUCTURE_FIRE vs WILDFIRE semantics), M14.6D finite tank water action after catch-up, depletion/no double debit, PAUSE/RESUME, FINISH≠CLOSE, historical read. No extra Cron or re-running old migration.

## 7. Release gate

Separate evidence of CI/build/testing/RLS/security/offline/backup-restore/manual field readiness (required by canonical SPEC) from Codex source-only implementation. No real emergency deployment until human signs a go/no-go, has fallback ZA-RE procedure, support/rollback and formal privacy/legal review where applicable.
