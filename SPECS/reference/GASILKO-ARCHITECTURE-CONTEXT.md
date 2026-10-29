# GASILKO — ARCHITECTURE CONTEXT
**Snapshot:** 2026-10-28  
**Repository:** https://github.com/ficlus/Gasilko  
**Canonical source of truth:** `docs/SPEC.md`, `docs/SPEC-M14-INCIDENT-OPERATIONS.md`, schema and source, existing `AGENTS.md`.

> Orientation document for another architect/Work/Codex agent; does **not** override canonical specifications. Some statuses are user-reported and should be reverified. Distinguish source implementation, merged code, database migration applied, deployed worker, and human-verified runtime.

## 1. Purpose & target users

Gasilko is a Slovenian/German offline-first platform for firefighters, fire departments, municipalities and water utilities. It originated as a hydrant registry/inspection and rounds platform. Its incident extension supports multi-agency incident command, units/crews/resources, incident tasks and a comprehensive **TRAINING/SIM** environment.

Longer-term product ambition: a usable real-world operational field tool with commander → unit leader → crew workflows, contextual task issuing, acknowledgments, situational map, hydrants, scoped navigation, controlled sharing and authorized history. **Not** an official 112/CAD/dispatch substitute and never a replacement for ZA-RE critical voice communications.

## 2. Technology & component boundaries

```text
Android (Kotlin, Compose, coroutines/Flow)
    UI → ViewModel → Repository → Room
                                   ↕
                         existing Sync Engine + WorkManager
                                   ↕
                            authenticated Supabase RPC

Web (Next.js App Router, TypeScript, MapLibre)
    Authenticated SSR/API → Supabase RPC / scoped reads

Supabase Cloud (PostgreSQL, Auth, Storage, RLS, RPC)
    Canonical domain, immutable operation receipts, audit, authorized projections
    Edge Functions: notification delivery, SIM runner, navigation as applicable
    Cron: existing five-second SIM runner (one job, do not duplicate)

FCM: existing M10 delivery / Android messaging service
Realtime: future scoped private incident hints; PR #82 uses push/foreground/poll fallback
Map: MapLibre; navigation uses existing route provider OSRM/GraphHopper where configured
```

Never introduce independent client authoritative calculations for incidents or SIM physics. All domain mutations are server-validated. No client service-role credentials.

## 3. Canonical domains

### Identity & organization
`profiles`, `organizations`, `user_organizations`, geographic hierarchy and existing account states `PENDING_APPROVAL`, `ACTIVE`, `SUSPENDED`, `REJECTED`. Organization roles `FIREFIGHTER`, `MANAGER`, `ADMIN` govern organization access only; they **do not automatically confer incident command authority**. Exact organization membership and current incident participation matter. Hierarchy is not an implicit write grant.

### Hydrant registry, inspections, planning
Existing hydrant UUIDs, human-readable centrally allocated codes, inspection histories and photographs, planning assignments, user/team rosters and notifications. Android offline Room plus WorkManager and 30-day cached **organization** authorization. No destructive cleanup of unsynchronized data. No second hydrant store; SIM water sources do not alter real hydrant state.

### Incident aggregate (M14.0–M14.6 domain)
Canonical incident UUID and version, participants, role assignments, timeline, sectors, map objects, units/crews, task assignment episodes, resource use, mobilization/turnout, lifecycle and closure guards. Incidents and organizations have distinct identities. Current Incident Commander/Agency/Sector/Unit Leader powers are server checked and scoped; no client shortcuts.

### M14.5A task and assignment domain
`incident_tasks`, `incident_task_assignments`, `operational_action_definitions`, `operational_action_definition_versions`; action definition labels are NOT behavior identifiers. Task is not identical to its recipient episode. Each recipient ACK/START/BLOCKED/RESUME/UNABLE/COMPLETE follows existing versioned transitions; multiple recipients progress independently. Unit Leader can issue to eligible subordinate **crew** in scope, not arbitrarily command unrelated units. Notification delivery and opened task are **not** acknowledgement or execution.

### Web RTS / Command Map
Context-aware unit → target → action, sector/hydrant/object overlays, explicit confirmations, map geometry, leader permissions, action/timeline read model, grouped selection, active route presentation; Web and Android must use same backend task identity.

### TRAINING/SIM (M14.6A–D)
- Quick training presets versus versioned scenario templates/library (different semantics).
- Scenario drafts, copy/revise/save/publish/start, immutable published versions, event plans, hazard plans.
- M14.6B deterministic dynamic events and hidden/reveal semantics.
- M14.6B1 fast movement/map snapshots, stable routes, overlapping units map UX.
- M14.6C `STRUCTURE_FIRE`/`WILDFIRE`, five **simulated** second hazard steps, grid-based wildfire spread, smoke/heat, visibility controls, private history; simplified training model, not predictive CFD.
- M14.6C.2 unified library/editor, safe pending SAVE recovery, operation-receipt reconciliation, TRAINING lifecycle finish versus incident close.
- M14.6D instructor-armed explicit water effects, finite simulated inventories/supply links/consumption/suppression effects; MOVE_TO never implies APPLY_WATER. RESET intentionally does not restore consumed water; fresh exercise needed for an initial-stock replay.
- Simulation hazard batch runs via existing protected Edge Function / five-second Cron; no separate physics engine.
- REAL incident GPS and real hydrant properties must never come from SIM data.

### Android field pilot (M14.7A/M14.8A — PR #82 OPEN)
New source introduced on PR branch (not yet merged or verified): `IncidentRepository.kt`, `IncidentViewModel.kt`, `IncidentScreen.kt`, `IncidentFieldCache.kt`, `IncidentCommandDraft.kt`, Room 14→15, scoped `incident_field_snapshot` RPC, existing auth/M10 notifications/WorkManager/MapLibre integration, field read lease max 24 hours. Firefighter receives personal/unit task scope and explicitly acknowledges; UNIT_LEADER sees current unit/crew and issues to eligible crew online. FCM only hints; private Realtime deferred; bounded foreground refresh/poll. Scope of first pilot = real human accounts **on a controlled TRAINING incident**. Not emergency production readiness.

## 4. Real versus training safety invariants

| Concern | REAL | TRAINING/SIM |
|---|---|---|
| Position | Only real consented/authorized telemetry, if implemented | Virtual unit positions, H1/B1 interpolation |
| Task ACK | Explicit actual user RPC | Human ACK remains human; SIM agent events not impersonations |
| Water | No simulated inventory mutation | Explicit finite, configured virtual inventory |
| Fire/smoke | No fictitious official model on REAL incident | Bounded educational hazard model |
| Alerting | Only authorized real notifications, no unapproved CAD/112 dispatch | Clearly labeled training notifications |
| Closure | Authoritative incident lifecycle | SIM `FINISH` separate from incident `CLOSE` |

No arbitrary cross-organization reads, no borrowed command powers, no real dispatch, no inferred arrival/complete from map gesture.

## 5. Operational correctness invariants

1. UUID identity and immutable operation payload before sending; network retry reuses SAME UUID and payload, expected version and scope. Receipt lookups bind actor/org/action/request.
2. Missing receipt is **OUTCOME_UNKNOWN**; do not infer the command failed.
3. SQL mutation is locked/versioned, audited and idempotent. No write based solely on a client role badge or Web UI check.
4. Offline queue is durable, scoped to account/org/incident, with dependency ordering. Local intent ≠ server acknowledgment. Failure/revocation requires review.
5. Revoked identity/role/incident access invalidates visible cache. Incident lease ≤24h, organization registry lease ≤30 days; separate concepts.
6. Notification, Realtime and local Web polling are hints. Server-authorized read remains truth. Push cannot ACK.
7. `SECURITY DEFINER` uses explicit search_path, exact grants and actor scope; no broad SELECT/raw private timeline disclosure.
8. Simulated progression is tied to authoritative simulation clock; one actual debit per step, bounded concurrent processing, FINISH prevents new effects.
9. Historical state, timeline and audit are append-only or preserved per domain rules.
10. Slovenian (`sl`) and German (`de`) localization; neutral stored codes, UTC server time, WGS84 `[longitude, latitude]`.

## 6. Reference files and current implementation entry points

| Area | Useful files/functions (verify on latest current branch) |
|---|---|
| Canonical specs | `docs/SPEC.md`, `docs/SPEC-M14-INCIDENT-OPERATIONS.md`, `AGENTS.md` |
| Web incident | `web/features/incidents/IncidentArea.tsx`, `TemplateLibrary.tsx`, `SimulationHome.tsx`, `SimulationProvider.tsx`, `SimulationHazards.tsx`, `EventPlanEditor.tsx`, `HazardPlanEditor.tsx` |
| Web bridge | `web/app/api/incidents/route.ts` |
| SIM SQL | `simulation_template_command`, `simulation_hazard_batch`, `simulation_operational_command`, `simulation_operation_resolve` |
| Simulation runner | `supabase/functions/incident-simulation-runner/index.ts` |
| Android planned PR82 | `feature/incidents/IncidentRepository.kt`, `IncidentViewModel.kt`, `IncidentScreen.kt`, `IncidentCommandDraft.kt`, `core/database/IncidentFieldCache.kt` — paths may include package directory; locate in branch |
| Android existing | `RegistryDatabase.kt`, `HydrantSyncWorker`, `HydrantSyncScheduler`, `SupabaseAuthGateway.kt`, `KeystoreSessionManager.kt`, `MapScreen.kt` |
| Notifications | `20261005140000_notifications.sql`, existing `notification-delivery` function and FCM Android service |

Exact function signatures and Kotlin package paths must be read from current source, not guessed from these names.

## 7. External services / development operating environment

Development host: Windows PowerShell; typical checkout `C:\Users\t.arnus\StudioProjects\Gasilko`. Supabase project reference used during troubleshooting: `vkaspwiuisdcecgackhm` (public project identifier, not a secret). Local web command previously used: `npx --yes pnpm@11.19.0 --dir web dev` → `http://localhost:3000/sl`. Platform versions may evolve; inspect repo and current lockfiles before library-specific work.

Never include keys, auth tokens, SMTP credentials or SIM runner secrets in documents. **Do not copy old runtime data out of production without authorization.**

## 8. Design debt and intentional limits

- PR #82 lacks secure private Realtime transport, complete M14.7 snapshot/change cursors and incident turn-by-turn.
- Android controlled pilot requires SQL execution, human Room v15 build/export and multi-device manual acceptance.
- SIM hazard spread is deliberately simplified; STRUCTURE_FIRE behavior differs from cell-spreading WILDFIRE. Time, catch-up, runner status and fire ignition must be explicitly observable.
- Real GPS opt-in/shared location remains later, with retention and privacy design.
- Official CAD/112 integration only under official provider agreement.
- M14.10 sealed after-action reporting remains planned.
- Simultaneous route planning of many SIM units is a known performance observation requiring measurement before optimization.
- Existing foundation README can lag behind merged M14 functionality; check SPEC and source first.

## 9. Safety for new agents

This is a safety-relevant operational product. No feature is deemed fit for actual emergency deployment based on source review alone. Ask for human verification of SQL, Android upgrade, permissions, offline flows, notification behavior, operational training results and a fallback critical voice channel. Human owns merge and deployment.
