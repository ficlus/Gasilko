# Gasilko — Hydrant Management Platform

[![Android](https://github.com/ficlus/Gasilko/actions/workflows/android.yml/badge.svg)](https://github.com/ficlus/Gasilko/actions/workflows/android.yml)
[![Web](https://github.com/ficlus/Gasilko/actions/workflows/web.yml/badge.svg)](https://github.com/ficlus/Gasilko/actions/workflows/web.yml)
[![Database](https://github.com/ficlus/Gasilko/actions/workflows/database.yml/badge.svg)](https://github.com/ficlus/Gasilko/actions/workflows/database.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Gasilko** is an offline-first platform for fire departments, municipalities and water utilities to **record, inspect, locate and round-plan fire hydrants**.

The product UI is **Slovenian and German** (`sl` / `de`).  
*Izdelek je v slovenščini in nemščini. / Die Oberfläche ist auf Slowenisch und Deutsch.*

> [!NOTE]
> **Pre-release.** Nothing is deployed. There is no production Supabase project and CI deploys nothing. Several features need extra services before they work end to end. The product contract is [docs/SPEC.md](docs/SPEC.md).

| | Android field app | Web administration | Backend |
| --- | --- | --- | --- |
| Role | Crews in the field, including offline | Managers and admins | Source of truth |
| Stack | Kotlin, Jetpack Compose, Room, MapLibre | Next.js App Router | Supabase (PostgreSQL 17, Auth, Storage, Edge Functions, RLS) |

**Not a CAD, not 112 dispatch, not a fleet tracker.** Incident operations exist as an early web/database slice only.

---

## Contents

- [Who it is for](#who-it-is-for)
- [What works today](#what-works-today)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Testing and CI](#testing-and-ci)
- [Documentation](#documentation)
- [Security](#security)
- [Contributing](#contributing)
- [License](#license)

---

## Who it is for

Hydrant books still live in spreadsheets, paper cards and tribal knowledge. Gasilko gives a shared registry that field crews can use **without a network**, and that office staff can administer in the browser.

| Role | Typical work |
| --- | --- |
| Firefighter | Find a hydrant, inspect it, take photos, follow a round |
| Manager | Approve access, plan rounds, assign teams, import legacy lists |
| Admin | Users, roles, organization hierarchy, audit, invitations |

Organizations are isolated. Signing in does **not** grant access. A user requests a country → area → organization + role; a manager or admin approves. Account states: `PENDING_APPROVAL`, `ACTIVE`, `SUSPENDED`, `REJECTED`. Roles: `FIREFIGHTER`, `MANAGER`, `ADMIN`.

---

## What works today

Legend: **ready** in this repo · **needs config** (external key/service) · **not built**

| Capability | Android | Web | Status |
| --- | :---: | :---: | --- |
| Email/password and Google sign-in, access requests | yes | yes | Google and SMTP **need config** |
| Hydrant registry (create, edit, status, deactivate, search, GPS create) | yes | yes | **ready** locally |
| Human-readable codes allocated centrally after sync (no offline collisions) | yes | — | **ready** |
| Offline-first Room + WorkManager sync, 30-day offline window | yes | — | **ready** |
| MapLibre map, GPS, nearby hydrants | yes | yes | demo tiles locally; licensed style **needs config** |
| Offline map downloads | yes | — | **needs** a style whose terms allow offline use |
| Inspections QUICK / GUIDED / CLASSIC, measurements, append-only history | yes | history | **ready** |
| Photos (capture/picker, 1920 px, queued upload) | yes | — | **ready** locally (Storage) |
| Teams, geographic assignment, plan execution, skip/inspect | yes | yes | **ready** |
| Road routing and turn-by-turn | yes | plan routes | **needs** OSRM and/or GraphHopper |
| CSV / XLS / XLSX import and export | — | yes | **ready** |
| Push (plan assignment/activation, optional hydrant alerts) | yes | — | **needs** Firebase + scheduler |
| Audit log | — | yes | **ready** |
| Multi-agency incidents, command roles, command transfer | — | early | web + DB only |
| QR scan and `hydrant://` deep links | — | — | **not built** |
| Incident COP, units, tasks, mobilization, CAD/112, Android field mode | — | — | **not built** (M14.3–M14.10) |
| Production / pilot hardening | — | — | **not built** (M11–M13) |

Milestone numbers (M0–M10 shipped, then M14.0–M14.2) follow repository history. M0–M6 match [docs/SPEC.md](docs/SPEC.md); later work extends it. See that spec and [docs/SPEC-M14-INCIDENT-OPERATIONS.md](docs/SPEC-M14-INCIDENT-OPERATIONS.md) for the full backlog.

Known test gap: pgTAP covers auth, organizations, hydrants and search. Teams/plans, photos, notifications, org admin and incidents still need allowed/denied RLS tests.

---

## Architecture

```text
Android   Compose UI → ViewModel → Repository → Room ⇄ Sync engine ⇄ Supabase
Web       Next.js (server-rendered, cookie session) → Supabase
Backend   PostgreSQL (RLS + RPCs) · Auth · Storage · Edge Functions · FCM
```

Principles the code and tests are built around:

- **Offline-first.** Android UI reads and writes Room. It does not talk to Supabase for normal domain data. Pending rows and photos are dropped only after the server acknowledges them.
- **Idempotent writes.** Client UUIDs and operation IDs make retries safe.
- **No silent last-write-wins.** Hydrant master data is versioned; a stale edit is a conflict. Inspections are append-only.
- **Authorization in the database.** RLS and RPCs decide; the UI only shows the result.
- **No secrets in clients.** Apps carry the public project URL and a publishable key only.
- **Auditable.** Audit rows are written by trusted database code and are not client-editable.

Sync design: [docs/SYNC.md](docs/SYNC.md). Security model: [docs/SECURITY.md](docs/SECURITY.md).

Edge Functions: `plan-routes` (OSRM primary, GraphHopper fallback), `notification-delivery` (FCM), `organization-invite`.

Geography is a tree of administrative areas. The development seed includes sample areas for **Slovenia and Austria** only; the model is multi-country.

---

## Repository layout

```text
.github/workflows/     Android, Web, Database CI
android/               Field app (one `app` module: core/ and feature/)
web/                   Next.js portal (`messages/sl.json`, `messages/de.json`)
supabase/              config.toml, migrations/, functions/, seed.sql, tests/
docs/                  Specifications and design notes
AGENTS.md              Mandatory rules for every contributor (including AI agents)
.env.example           Placeholder inventory — not a copy-paste client env
SPEC-1-Hydrant-Management-Platform.md   Historical MVP copy; docs/SPEC.md is authoritative
```

`packages/shared-contracts/` is reserved and unused.

---

## Quick start

### Prerequisites

- Node 24.19.0 (24 LTS) and pnpm 11.19.0
- JDK 17, Android SDK platform 36, build-tools 35.0.0, Android Studio / AGP 8.13 (min API 26)
- [Supabase CLI 2.117.0](https://supabase.com/docs/guides/cli) and Docker (Linux containers)

Set `JAVA_HOME` to JDK 17 and `ANDROID_HOME` to the SDK, or use git-ignored `android/local.properties`.

### 1. Clone and install

```sh
git clone https://github.com/ficlus/Gasilko.git
cd Gasilko
corepack enable
corepack prepare pnpm@11.19.0 --activate
pnpm install --frozen-lockfile
```

If Corepack is missing: `npm install --global pnpm@11.19.0`.

### 2. Local backend

From the repository root, with Docker running:

```sh
supabase start
supabase db reset --local    # migrations + seed; destroys local data
```

`supabase status` prints the local API URL and keys. Auth emails go to Mailpit/Inbucket at <http://localhost:54324>. This repository does not link a remote or production project.

Useful extras: `supabase db lint --local --level warning`, `supabase test db`, `supabase stop`.

### 3. Web portal

```sh
pnpm web:dev
```

Open <http://localhost:3000/sl> or `/de`. `/` redirects to Slovenian. The production build is `pnpm web:build` then `pnpm --dir web start`.

Building needs no env. **Signing in** needs the two public Supabase values in `web/.env.local` (see [Configuration](#configuration)). A fresh database has no users — [bootstrap the first admin](docs/ADMIN_BOOTSTRAP.md) (trusted SQL; there is no bootstrap screen and no global super-admin). After that, people request access in the app and a manager/admin approves them. An already-open session picks up the result without a new login.

### 4. Android

```sh
cd android
./gradlew lintDebug testDebugUnitTest assembleDebug
./gradlew connectedDebugAndroidTest   # emulator or device
```

On Windows: `.\gradlew.bat`. APK: `app/build/outputs/apk/debug/app-debug.apk`.

Set `ANDROID_SUPABASE_URL` and `ANDROID_SUPABASE_PUBLISHABLE_KEY` in the build environment. The app requires **HTTPS**, so use a tunnel or a staging project for a physical device. The build rejects non-publishable keys.

---

## Configuration

Only **public** values may reach a client. Never put a Supabase secret / service-role key, a Firebase service-account file, or a CLI token into a web or Android environment.

`.env.example` is a placeholder inventory. The names below are what the code actually reads.

### Minimum to sign in locally (web)

| Variable | Where | Purpose |
| --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | `web/.env.local` (git-ignored) | Project URL |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | `web/.env.local` | `sb_publishable_…` key |

### Minimum to sign in (Android)

| Variable | Where | Purpose |
| --- | --- | --- |
| `ANDROID_SUPABASE_URL` | Android build env | HTTPS project URL |
| `ANDROID_SUPABASE_PUBLISHABLE_KEY` | Android build env | Publishable key |
| `ANDROID_AUTH_REDIRECT_SCHEME` | Android build env | OAuth callback, default `si.gasilko.app` — keep the Auth allow-list in sync |

### Everything else

| Variable | Where | Purpose |
| --- | --- | --- |
| `NEXT_PUBLIC_MAP_STYLE_URL` | Web | Licensed HTTPS MapLibre style (browser-visible, no private key) |
| `GEOCODING_ADAPTER_URL`, `GEOCODING_ADAPTER_TOKEN`, `GEOCODING_ADAPTER_PROTOCOL`, `GEOCODING_USER_AGENT` | Web **server only** | Optional address search; protocol `normalized` or `nominatim` |
| `ANDROID_MAP_STYLE_URL` | Android build env | Online map style; defaults to MapLibre demo tiles (dev only) |
| `ANDROID_OFFLINE_MAP_STYLE_URL` | Android build env | Exact style allowed for offline downloads; empty disables them |
| `ANDROID_FIREBASE_APPLICATION_ID`, `ANDROID_FIREBASE_PROJECT_ID`, `ANDROID_FIREBASE_SENDER_ID`, `ANDROID_FIREBASE_API_KEY` | Android build env | FCM client config |
| `OSRM_BASE_URL`, `OSRM_USERNAME`, `OSRM_PASSWORD` | Edge secret `plan-routes` | Primary router; all three together; HTTPS |
| `GRAPHHOPPER_API_KEY` | Edge secret `plan-routes` | Fallback, or the only router if OSRM is unset |
| `NOTIFICATION_DISPATCH_SECRET`, `FIREBASE_SERVICE_ACCOUNT_JSON` | Edge secret `notification-delivery` | Delivery auth + FCM; a scheduler must call the function (e.g. every minute) |
| `WEB_INVITATION_REDIRECT_URL` | Edge secret `organization-invite` | `https://<web-host>/auth/callback` with no query or hash |
| `SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID`, `SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET` | Supabase Auth settings | Google sign-in; [docs/GOOGLE_AUTH.md](docs/GOOGLE_AUTH.md) |

Email/password: enable in Supabase Auth, require confirmation, min 8-character passwords, SMTP in production. Site URL + exact redirects:

- `https://<web-host>/auth/callback?locale=sl`
- `https://<web-host>/auth/callback?locale=de`
- `si.gasilko.app://auth-callback`

`supabase/config.toml` already enables this for localhost. Invitation email templates: [docs/WEB_ADMINISTRATION.md](docs/WEB_ADMINISTRATION.md).

---

## Testing and CI

```sh
# Web
pnpm web:lint
pnpm web:typecheck
pnpm web:test
pnpm web:build

# Android (from android/)
./gradlew lintDebug testDebugUnitTest assembleDebug
./gradlew connectedDebugAndroidTest

# Database (root, Docker up, after `supabase db reset --local`)
supabase db lint --local --level warning
supabase test db
node supabase/tests/auth.integration.mjs
node supabase/tests/review.concurrency.mjs
node supabase/tests/hydrant.concurrency.mjs
node supabase/tests/hydrant.authorization.integration.mjs
node supabase/tests/hydrant.authorization.concurrency.mjs
node supabase/tests/hydrant.search.integration.mjs
```

The Node scripts hit real Auth/REST and competing transactions. They target the **local** stack only.

On every push and PR: **Android** (lint, unit, debug APK, emulator), **Web** (lint, typecheck, tests including translation completeness, production build), **Database** (clean reset, seed replayed twice, lint, pgTAP, Node integration/concurrency). Failures are never ignored.

Manual staging checks (locales, access-request approval, session restore, Google) live next to the feature docs, especially [docs/GOOGLE_AUTH.md](docs/GOOGLE_AUTH.md) and [docs/ADMIN_BOOTSTRAP.md](docs/ADMIN_BOOTSTRAP.md).

---

## Documentation

| Document | Contents |
| --- | --- |
| [docs/SPEC.md](docs/SPEC.md) | Authoritative product specification (MVP) |
| [docs/SPEC-M14-INCIDENT-OPERATIONS.md](docs/SPEC-M14-INCIDENT-OPERATIONS.md) | Incident operations, M14.0–M14.10 |
| [AGENTS.md](AGENTS.md) | Mandatory development rules |
| [docs/DATABASE.md](docs/DATABASE.md) | Schema, authorization, RPC contracts, migration policy |
| [docs/HYDRANT_API.md](docs/HYDRANT_API.md), [docs/HYDRANT_SEARCH.md](docs/HYDRANT_SEARCH.md) | Hydrant mutation and search contracts |
| [docs/SYNC.md](docs/SYNC.md) | Offline-first architecture |
| [docs/SECURITY.md](docs/SECURITY.md) | Security model |
| [docs/GOOGLE_AUTH.md](docs/GOOGLE_AUTH.md) | Google sign-in |
| [docs/ADMIN_BOOTSTRAP.md](docs/ADMIN_BOOTSTRAP.md) | First `ADMIN` |
| [docs/WEB_ADMINISTRATION.md](docs/WEB_ADMINISTRATION.md) | Users, roles, positions, invitations, audit |
| [docs/IMPORT_EXPORT.md](docs/IMPORT_EXPORT.md) | CSV/XLSX import and export |
| [docs/NOTIFICATIONS_NAVIGATION_M10.md](docs/NOTIFICATIONS_NAVIGATION_M10.md) | Push and navigation |
| [supabase/functions/plan-routes/README.md](supabase/functions/plan-routes/README.md) | Road routing function |
| [docs/VERSIONS.md](docs/VERSIONS.md) | Toolchain decisions |

---

## Security

No secrets in the repo. Clients carry only the public URL and a publishable key. Privileged keys live in Edge Function / server secret stores. Model: [docs/SECURITY.md](docs/SECURITY.md).

Report vulnerabilities **privately** via [@ficlus](https://github.com/ficlus) — do not open a public issue.

---

## Contributing

Read [docs/SPEC.md](docs/SPEC.md) and [AGENTS.md](AGENTS.md) first. AGENTS.md applies to every contributor, including AI coding agents.

- Keep a change scoped to one task or milestone; do not silently change architecture.
- Database changes = a new versioned file in `supabase/migrations/` plus allowed **and** denied RLS tests.
- New behavior needs tests. Do not delete or weaken tests to go green. All three workflows must pass.
- User-facing strings go in localization resources (Slovenian and German), never in feature code.
- Justify new dependencies (maintained, compatible, license-checked).
- Never commit secrets.

---

## License

[MIT](LICENSE).

Maps and routes use OpenStreetMap-based data: keep © OpenStreetMap contributors and check tile, routing and geocoding terms (especially offline downloads) before deploying. Server-side spreadsheet parsing uses SheetJS Community Edition (Apache-2.0).
