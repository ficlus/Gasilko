Gasilko — Hydrant Management Platform
![Android](https://github.com/ficlus/Gasilko/actions/workflows/android.yml/badge.svg)
![Web](https://github.com/ficlus/Gasilko/actions/workflows/web.yml/badge.svg)
![Database](https://github.com/ficlus/Gasilko/actions/workflows/database.yml/badge.svg)
![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
Gasilko is an offline-first platform for recording, inspecting and locating fire hydrants and for planning inspection rounds. It is built for fire departments, municipalities, water utilities and similar organizations, and has three parts:
Android field app — Kotlin, Jetpack Compose, Room and MapLibre; keeps working without a connection.
Web administration portal — Next.js, for managers and administrators.
Backend — Supabase: PostgreSQL with row-level security, Auth, Storage and Edge Functions.
The interface is available in Slovenian and German.
> [!NOTE]
> **Pre-release.** Nothing is deployed: no production Supabase project is linked and CI deploys nothing. Several features need external configuration before they work end to end (see [Configuration](#configuration)). The authoritative product specification is [docs/SPEC.md](docs/SPEC.md).
Features
Android field app
Sign-in and access. Email/password or Google sign-in. New users request access to an organization and wait for approval. The session is encrypted with the Android Keystore.
Hydrant registry. Create, edit, change the status of and deactivate hydrants; search and filter; create a hydrant from the current GPS position. Human-readable hydrant codes are allocated centrally after sync, so two offline devices can never collide.
Offline-first. Every change is written to a local Room database first and synchronized later by WorkManager. Retries are idempotent, and a stale edit becomes a conflict instead of overwriting newer data. Offline access to organization data is limited to 30 days since the last online check, with warnings 7 days and 1 day before it expires.
Map. MapLibre map with hydrant layers, your GPS position and nearby hydrants. Offline map downloads become available once a licensed map style is configured.
Inspections. QUICK, GUIDED and CLASSIC modes; status, accessibility, damage, pressure and flow, notes; append-only history; inspection intervals per organization with optional per-hydrant overrides.
Photos. Capture or pick photos for hydrants and inspections. Photos are resized (1,920 px long edge) and queued for upload with retry, and stay on the device until the server confirms receipt.
Inspection plans. See assigned teams and plans, work through plan stops (inspect or skip) and follow turn-by-turn navigation with online rerouting.
Push notifications. Plan assignments and activations and, optionally for managers, hydrant alerts, delivered through Firebase Cloud Messaging.
Web administration portal
Access requests and users. Managers review firefighter requests; admins also review manager requests. Admins manage users, roles, organization positions and hierarchy, and send email invitations.
Hydrants and map. Hydrant registry with search and filters, and a MapLibre map.
Teams and plans. Create inspection teams and plans, assign hydrants geographically, calculate road routes and reassign work manually.
Import and export. CSV, XLSX and legacy XLS import with preview, validation, history and reusable mapping profiles; CSV and XLSX export within the caller's authorized scope.
Audit. Security and administrative events are append-only and visible to organization admins.
Incident operations (early). Multi-agency incidents with participants, command roles and command transfer. Database and web only so far; see docs/SPEC-M14-INCIDENT-OPERATIONS.md.
Backend
Supabase (PostgreSQL 17, Auth, Storage, Edge Functions). The schema changes only through versioned SQL migrations.
Row-level security on every protected table. Roles are per organization (`FIREFIGHTER`, `MANAGER`, `ADMIN`) and account states are `PENDING_APPROVAL`, `ACTIVE`, `SUSPENDED` and `REJECTED`. Signing in never grants organization access by itself.
Trusted server-side logic in database RPCs and three Edge Functions: `plan-routes` (road routing; OSRM is the primary provider with GraphHopper as fallback), `notification-delivery` (FCM) and `organization-invite`.
Multi-country geography with an arbitrary administrative hierarchy. The development seed contains sample areas for Slovenia and Austria only.
Project status
Milestone numbers follow the repository history. M0–M6 follow the plan in docs/SPEC.md; from M7 the project extends that plan.
Milestone	Delivered
M0	Monorepo, CI, localization foundation
M1	Email/password and Google sign-in, geography, organizations, roles, access requests, review and audit
M2	Hydrant registry: data model, authorization API, Android and web registry, search and filters
M3	Room, local writes, WorkManager sync, conflict handling, 30-day offline authorization
M4	MapLibre map, hydrant layers, GPS and nearby hydrants, offline maps
M5	Inspections: QUICK / GUIDED / CLASSIC, measurements and intervals, history
M6	Photos: capture and picker, gallery, inspection photos, offline upload queue
M7	Inspection teams and plans, geographic assignment, road routing, field execution, reassignment, turn-by-turn navigation
M8	Web administration: foundation, hydrants and map, teams and plans, users, roles, invitations and audit
M9	CSV / XLS / XLSX import and export
M10	Push notifications and navigation refinements
M14.0–M14.2	Incident operations: foundation, incident core, multi-agency command (database and web)
Not done yet:
QR scanning and `hydrant://` deep links.
Incident operations M14.3–M14.10: common operating picture, units and resources, tasks, mobilization, realtime, Android field mode, CAD/112 integration and closure reports.
General hardening, pilot and production deployment (M11–M13).
Production setup for the pieces that need external services: notification scheduler and Firebase credentials, a routing provider, a licensed map style for offline downloads, and SMTP.
Automated RLS tests for the later tables. The pgTAP suite currently covers authentication, organizations, hydrants and search; inspection teams and plans, photos, notifications, organization administration and incidents still need allowed/denied access tests.
Architecture
```text
Android   Compose UI → ViewModel → Repository → Room ⇄ Sync engine ⇄ Supabase
Web       Next.js (server-rendered, cookie session) → Supabase
Backend   PostgreSQL (RLS + RPCs) · Auth · Storage · Edge Functions · FCM push
```
The code and tests are built around these principles:
Offline-first. The UI reads and writes Room and does not talk to Supabase directly for normal data. Pending changes and photos are removed only after the server acknowledges them.
Idempotent writes. Client-generated UUIDs and operation IDs make retries safe; nothing is duplicated.
No silent last-write-wins. Hydrant master data uses optimistic versioning, so a stale edit becomes a conflict. Inspections are append-only.
Authorization in the database. RLS and RPCs authorize every request; the UI only reflects the result.
No secrets in clients. The apps carry only the public project URL and a publishable key.
Auditable. Audit entries are written by trusted database code and cannot be edited by clients.
The Android sync engine is in `android/app/src/main/java/si/gasilko/app/feature/hydrants/data/HydrantSyncEngine.kt` and `core/sync/HydrantSyncWorker.kt`.
Repository layout
```text
.github/workflows/          Android, Web and Database CI
android/                    Android app (one `app` module with core/ and feature/ packages)
web/                        Next.js App Router portal; messages/sl.json and de.json
supabase/                   config.toml, migrations/, functions/, seed.sql, tests/
packages/shared-contracts/  Reserved for shared contracts
docs/                       Specifications and design notes
AGENTS.md                   Mandatory development rules
.env.example                Placeholders for public and server configuration
SPEC-1-Hydrant-Management-Platform.md   Original copy of the MVP spec (docs/SPEC.md is authoritative)
```
Getting started
Prerequisites
Node 24.19.0 (24 LTS) and pnpm 11.19.0
JDK 17, Android SDK platform 36 and build-tools 35.0.0, and Android Studio with AGP 8.13 support (minimum Android API is 26)
Supabase CLI 2.117.0 and Docker with Linux containers
Set `JAVA_HOME` to JDK 17 and `ANDROID_HOME` to the SDK, or use the git-ignored `android/local.properties`. Install SDK packages with Android Studio or `sdkmanager`.
Web portal
```sh
git clone https://github.com/ficlus/Gasilko.git
cd Gasilko
corepack enable
corepack prepare pnpm@11.19.0 --activate
pnpm install --frozen-lockfile
pnpm web:dev
```
On Node 24 distributions without Corepack, install pnpm 11.19.0 from its official instructions (or `npm install --global pnpm@11.19.0`).
Open http://localhost:3000/sl or `/de`; `/` redirects to Slovenian. Building needs no environment variables; signing in needs the public Supabase configuration described under Configuration. To run the production build, use `pnpm web:build` and then `pnpm --dir web start`.
Supabase (local)
Run from the repository root with Docker running:
```sh
supabase start
supabase db reset --local            # applies migrations and seed; destroys local data
supabase migration up --local
supabase db lint --local --level warning
supabase test db
supabase stop
```
`supabase status` prints the local API URL and keys. Local Auth requires email confirmation, and Mailpit/Inbucket is at http://localhost:54324. A fresh database has no organizations or users; see First administrator. No linked or production project is used by this repository or its CI.
Android
```sh
cd android
./gradlew lintDebug
./gradlew testDebugUnitTest
./gradlew assembleDebug
./gradlew connectedDebugAndroidTest   # needs an emulator or a connected device
```
On Windows use `.\gradlew.bat`. Install `app/build/outputs/apk/debug/app-debug.apk` or run from Android Studio. Set `ANDROID_SUPABASE_URL` and `ANDROID_SUPABASE_PUBLISHABLE_KEY` in the build environment before building. The app requires an HTTPS endpoint, so use a development HTTPS tunnel or a staging project for device testing.
Configuration
Only public values may reach a client. Never put a Supabase secret or service-role key, a Firebase service-account file or a CLI token into a web or Android environment. `.env.example` is a placeholder inventory for the core variables; the variables below are the ones the code reads.
Variable	Where	Purpose
`NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`	Web (`web/.env.local`, git-ignored)	Project URL and `sb_publishable_…` key; required for sign-in
`NEXT_PUBLIC_MAP_STYLE_URL`	Web	HTTPS MapLibre style from a licensed provider (browser-visible, no private key)
`GEOCODING_ADAPTER_URL`, `GEOCODING_ADAPTER_TOKEN`, `GEOCODING_ADAPTER_PROTOCOL`, `GEOCODING_USER_AGENT`	Web, server only	Optional address search adapter; protocol is `normalized` or `nominatim`
`ANDROID_SUPABASE_URL`, `ANDROID_SUPABASE_PUBLISHABLE_KEY`	Android build environment	Project URL (HTTPS) and publishable key; the build rejects non-publishable keys
`ANDROID_AUTH_REDIRECT_SCHEME`	Android build environment	OAuth callback scheme, default `si.gasilko.app`; keep Supabase's redirect allow-list in sync
`ANDROID_MAP_STYLE_URL`	Android build environment	Online map style; defaults to MapLibre demo tiles, for development only
`ANDROID_OFFLINE_MAP_STYLE_URL`	Android build environment	Exact style URL allowed for offline downloads. Empty (the default) disables downloads; set it only after confirming the provider's terms permit offline use
`ANDROID_FIREBASE_APPLICATION_ID`, `ANDROID_FIREBASE_PROJECT_ID`, `ANDROID_FIREBASE_SENDER_ID`, `ANDROID_FIREBASE_API_KEY`	Android build environment	Firebase client configuration for push
`OSRM_BASE_URL`, `OSRM_USERNAME`, `OSRM_PASSWORD`	Edge Function secrets (`plan-routes`)	Primary routing provider; all three are required together and the URL must be HTTPS
`GRAPHHOPPER_API_KEY`	Edge Function secret (`plan-routes`)	Routing fallback, or the only provider when OSRM is not configured
`NOTIFICATION_DISPATCH_SECRET`, `FIREBASE_SERVICE_ACCOUNT_JSON`	Edge Function secrets (`notification-delivery`)	Delivery authorization and FCM credentials; a scheduler must call the function periodically (for example every minute)
`WEB_INVITATION_REDIRECT_URL`	Edge Function secret (`organization-invite`)	`https://<web-host>/auth/callback`, without query or hash
`SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID`, `SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET`	Supabase Auth provider settings	Google sign-in, server side only; see docs/GOOGLE_AUTH.md
For email/password sign-up, enable it in Supabase Auth, require email confirmation and passwords of at least 8 characters, configure SMTP for production, set the Site URL and allow the exact redirect URLs: `https://<web-host>/auth/callback?locale=sl`, the same with `locale=de`, and `si.gasilko.app://auth-callback`. The local configuration in `supabase/config.toml` already enables this flow for localhost. Invitation emails need extra Auth template configuration, described in docs/WEB_ADMINISTRATION.md.
First administrator
A fresh database has no organizations or users. Create an organization with trusted SQL, sign up through the normal flow, then promote the first `ADMIN` with the private bootstrap procedure in docs/ADMIN_BOOTSTRAP.md. There is no global super-admin and no bootstrap screen. After that, new users request access (country → area → organization and role) and a manager or admin approves them in the web portal; an applicant's open Web or Android session picks up the result without a new login.
Testing and CI
```sh
# Web
pnpm web:lint
pnpm web:typecheck
pnpm web:test
pnpm web:build

# Android (from android/)
./gradlew lintDebug testDebugUnitTest assembleDebug
./gradlew connectedDebugAndroidTest

# Database (repository root, Docker running, after `supabase db reset --local`)
supabase db lint --local --level warning
supabase test db
node supabase/tests/auth.integration.mjs
node supabase/tests/review.concurrency.mjs
node supabase/tests/hydrant.concurrency.mjs
node supabase/tests/hydrant.authorization.integration.mjs
node supabase/tests/hydrant.authorization.concurrency.mjs
node supabase/tests/hydrant.search.integration.mjs
```
The Node scripts exercise real Auth and REST requests and competing transactions; they target the disposable local stack only.
Three GitHub Actions workflows run on every push and pull request. Android runs lint, unit tests, the debug build and emulator tests. Web runs lint, type check, tests (including translation completeness) and the production build. Database resets from a clean state, replays the seed twice, lints, runs the pgTAP suite and the Node integration and concurrency scripts. A failing check is never ignored.
Some checks cannot be automated and are manual acceptance steps on a configured staging project:
Web: both language URLs show translated text with a matching HTML `lang`; `/` redirects to `/sl`; unsupported locales return 404.
Android: check the Slovenian and German locales, rotate the device, and test foreground/background, network loss and retry on physical devices, including sign-out and encrypted session persistence.
Access flow: bootstrap a test `ADMIN`; approve and reject requests as manager and admin in both languages; confirm the applicant's existing session shows the correct membership.
Sign-in: email delivery and confirmation in both languages; sign in on Web and Android; expire or revoke a test session; disconnect during session restore and sign-out, then retry; confirm direct admin routes stay protected. Google provider checks are in docs/GOOGLE_AUTH.md.
Documentation
Document	Contents
docs/SPEC.md	Authoritative product specification (MVP)
docs/SPEC-M14-INCIDENT-OPERATIONS.md	Incident operations extension, M14.0–M14.10
AGENTS.md	Mandatory development rules
docs/DATABASE.md	Schema, authorization and RPC contracts, migration policy
docs/HYDRANT_API.md, docs/HYDRANT_SEARCH.md	Hydrant mutation API and search contract
docs/SYNC.md	Offline-first architecture overview
docs/SECURITY.md	Security model and boundaries
docs/GOOGLE_AUTH.md	Google sign-in setup and manual acceptance
docs/ADMIN_BOOTSTRAP.md	First `ADMIN` procedure
docs/WEB_ADMINISTRATION.md	Users, roles, positions, invitations, audit
docs/IMPORT_EXPORT.md	CSV/XLSX import and export
docs/NOTIFICATIONS_NAVIGATION_M10.md	Push notifications and navigation
supabase/functions/plan-routes/README.md	Road routing function
docs/VERSIONS.md	Initial toolchain and dependency decisions
Security
The repository contains no secrets; clients carry only the public project URL and a publishable key, and privileged keys live in Edge Function or server secret stores. See docs/SECURITY.md for the model. Please report vulnerabilities privately to the maintainer through their GitHub profile (@ficlus) instead of opening a public issue.
Contributing
Contributions are welcome. Read docs/SPEC.md and AGENTS.md first; the rules in AGENTS.md apply to every contributor, including AI coding agents.
Keep a change scoped to one task or milestone and preserve the architecture above.
Change the database only with a new versioned migration in `supabase/migrations/`, and add allowed and denied access tests for every RLS change.
New behavior needs tests. Do not delete or weaken tests to get CI green; all three workflows must pass.
Put user-facing strings in the localization resources (Slovenian and German), never in code.
Justify any new dependency: maintained, compatible and license-checked.
Never commit secrets.
License
Released under the MIT License.
Third-party notes: maps and routes use OpenStreetMap-based data, so keep the required attribution (© OpenStreetMap contributors) and check the terms of your tile, routing and geocoding providers, especially for offline downloads, before deploying. Server-side spreadsheet parsing uses SheetJS Community Edition (Apache-2.0).
