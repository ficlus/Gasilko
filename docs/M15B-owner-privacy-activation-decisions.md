# M15B — owner privacy and activation decisions

2026-11-04 · **ALL UNAPPROVED · GPS PRODUCTION OFF**
Source implementation and a GitHub merge do not approve privacy, install SQL,
deploy code, prove GNSS authenticity or authorize surveillance.

| ID | Decision | Implemented boundary / exact owner decision | Status |
|---|---|---|---|
| P01 | Purpose, legal basis, controller/contact and versioned notice | Owner supplies default/SI/DE text; exact normalized notice SHA256; legal review required | UNAPPROVED |
| P02 | Who may initiate | Code permits current ACTIVE DRIVER only; leader/admin fallback NOT_IMPLEMENTED | UNAPPROVED |
| P03 | Vehicle/unit/crew and incident lifecycle | Code accepts exact canonical vehicle/live deployment in ACTIVE REAL incident only | UNAPPROVED |
| P04 | Precise audience and cross-org sharing | Cross-org denied. Private per-deployment reader grant plus current required role; no ordinary COP inheritance | UNAPPROVED |
| P05 | Lease, maximum duration and mobile OS restrictions | Explicit approved fields:30–90s lease,20–120s interval with2×interval≤lease, absolute maximum≤3600s; no seed values | UNAPPROVED |
| P06 | STOP/LEAVE/offline withdrawal wording | Local stop first; remote result may remain UNKNOWN until ACK/lease expiry | UNAPPROVED |
| P07 | Handover/competing devices | No silent takeover; unique live vehicle session; LEFT revokes own binding/key; new explicit ceremony | UNAPPROVED |
| P08 | Reporting, accuracy, source, speed, skew and abuse | Owner sets interval/movement/accuracy/lag/future-skew/speed bounds; no automatic GNSS authenticity claim | UNAPPROVED |
| P09 | Latest-only versus history | One raw latest row per vehicle. No route/history; bounded non-coordinate ACK metadata is separate | UNAPPROVED |
| P10 | Fresh/stale/display expiry | CURRENT<120s; LAST_KNOWN120–899 only when allowed and still effective/unexpired;≥900 never rendered | UNAPPROVED |
| P11 | Independent erasure SLA and backups | Owner-installed private cleaner+alerts; TTL+cleanup SLA is the physical primary-store bound, not display TTL alone | UNAPPROVED |
| P12 | Logs, security metadata, support and data-subject workflow | Approve command/credential/consent retention, bounded sample hashes, quotas, local encrypted STOP journal, WAL/PITR/log/cache retention | UNAPPROVED |
| P13 | Consent/revocation evidence | Exact policy/hash/actor/time and immutable command receipts; key proof never consents | UNAPPROVED |
| P14 | REAL versus TRAINING evaluation and rollout | No TRAINING source accepted. Owner chooses approved isolated nonproduction REAL evaluation before any real tracking | UNAPPROVED |
| P15 | Legal/privacy sign-off | Named reviewer must approve the full deployment/notice/audience/retention practice; source merge is not approval | UNAPPROVED |
| P16 | Operational sign-off | Named owner approves staged deployment, OS behavior, battery, key trust, release epoch, retention/alerts, rollback and64 manual cases | UNAPPROVED |
| A01 | Device assurance and initial enrollment trust | Per-key owner approval mandatory after out-of-band fingerprint comparison. Hardware attestation/MFA enrollment ceremony NOT_IMPLEMENTED; decide whether required | UNAPPROVED |

## Evidence required before activation

- Named controller/reviewer, approved purpose/legal basis, notice translations and
  precise audience. These decisions are owner responsibilities; no approval/legal
  basis is inferred by the code or this document.
- New private policy row with explicit approved parameters, approver/time/expiry
  and matching notice/document/audience hashes. DRAFT is not effective consent.
- Private readiness sign-off for legal, reader, verifier, Android, Web and explicit
  manual activation; all default false. No application role may set these.
- Per-credential private trust approval matching the actual SPKI fingerprint,
  with approver/time/expiry. A stolen bearer can at most register/prove a candidate;
  it cannot approve that key. The operator must compare via an independently
  approved physical-driver/managed-device process, not trust a message sent through
  the possibly stolen session. No automated approval ceremony is implemented.
- Explicit per-deployment precise-reader grants with approver/time and a current
  required DRIVER/command role. Unit-name visibility/ADMIN alone is insufficient.
- Owner-configured non-secret VEHICLE_LOCATION_RELEASE_EPOCH in trusted Edge,
  matching the approved policy recovery_epoch. No value is supplied by this PR.
  It is outside DB backups; rotate/disable before restores. No client may choose it.
- Owner-installed retention job, successful no-traffic deletion acceptance, job
  failure alerting and current cleanup heartbeat. Merely creating the SQL function
  does not set retention_ready. Edge reachability evidence must also be recent.
- Approved app release and controlled manual acceptance; no automatic START.

## Parameter sheet (no approved defaults)

All runtime values must be entered in an owner-approved policy, not copied from a
draft or generated to satisfy NOT NULL. The schema bounds are safety ceilings,
not field/legal approval:

| Parameter | Source bound | Owner value |
|---|---|---|
| lease_seconds |30–90 | UNAPPROVED |
| maximum_seconds |lease…3600 | UNAPPROVED |
| interval_seconds |20–120 and2×interval≤lease | UNAPPROVED |
| movement_metres |0–100;0 allows fresh stationary observations | UNAPPROVED |
| accuracy_cm |1–10000 | UNAPPROVED |
| observed_lag_seconds |1–30 | UNAPPROVED |
| future_skew_seconds |0–5 | UNAPPROVED |
| maximum_speed_mps |1–100; uncertainty allowance on reported accuracy | UNAPPROVED |
| position_seconds |120–900 | UNAPPROVED |
| allow_stale |explicit boolean | UNAPPROVED |
| cleanup_sla_seconds |15–120 | UNAPPROVED |
| precise roles/grants, audience/hash, recovery epoch |explicit reviewed values | UNAPPROVED |

The primary-store raw lifetime is at most the approved position TTL **plus actual
cleanup delay/SLA when maintenance is healthy**.900s display expiry is not a
guarantee of deletion at900s. If policy requires a900s physical maximum, approve a
compatible shorter TTL+SLA (which may shorten last-known display) or require a
reviewed tighter erasure design before activation. Job outage can leave expired
rows physically present; reads reject them and readiness fails closed. No claim
of erasure from WAL/PITR/backups is made. Their separate retention/restore policy
requires explicit approval.

## Sign-off record — blank, never completed by agent

| Evidence | Approver/date/reference | Status |
|---|---|---|
| P01–P16/A01 decisions and notices | — | UNAPPROVED |
| Device trust/out-of-band process/attestation choice | — | UNAPPROVED |
| Exact precise-reader audience | — | UNAPPROVED |
| SQL dependencies including separate #86 correction | — | UNCONFIRMED |
| Trusted Edge deployment and external epoch | — | NOT DEPLOYED BY THIS PR |
| Android/Web release and64 manual cases | — | UNEXECUTED |
| Independent erasure and alerts/no-traffic acceptance | — | NOT INSTALLED/VERIFIED |
| Pilot scope and kill-switch/restore rehearsal | — | UNAPPROVED |

Use the rollout/rollback procedure in
[M15B source implementation and manual acceptance](M15B-end-to-end-real-vehicle-gps.md).
Owner alone approves, executes, deploys, installs, monitors and merges.
