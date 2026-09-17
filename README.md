# Gasilko — Hydrant Management Platform

Foundation for an offline-first Android field application and Next.js administration portal backed by Supabase. The authoritative product and architecture specification is [docs/SPEC.md](docs/SPEC.md); agent rules are [AGENTS.md](AGENTS.md). M0 intentionally provides no hydrant or account business functionality.

~~~text
.github/workflows/       Android, web and database CI
android/                Compose application; core/ and feature/ boundaries
web/                    Next.js App Router; messages/sl.json and de.json
supabase/               config, versioned migrations, seed, functions, tests
packages/shared-contracts/  Reserved shared contracts
docs/                   SPEC, DATABASE, SYNC, SECURITY, VERSIONS
.env.example            Public/server/Android/web/Supabase/Firebase placeholders
AGENTS.md               Mandatory development rules
~~~

## Prerequisites

Node 24.19.0 (24 LTS), pnpm 11.19.0, JDK 17, Android SDK platform 36 and build-tools 35.0.0, Supabase CLI 2.117.0, and Docker with Linux containers. Use Android Studio with AGP 8.13 support. Android minimum API is 26. Set JAVA_HOME to JDK 17 and ANDROID_HOME to the SDK (or use ignored android/local.properties). Install SDK packages with Android Studio or sdkmanager. Supabase requires Docker running; CLI can be installed from its official release or package-manager instructions.

## Local setup and web

~~~sh
git clone https://github.com/ficlus/Gasilko.git
cd Gasilko
corepack enable
corepack prepare pnpm@11.19.0 --activate
pnpm install --frozen-lockfile
pnpm web:dev
~~~

Node 24 distributions without Corepack: install pnpm 11.19.0 using its official installation instructions (or npm install --global pnpm@11.19.0). Open http://localhost:3000/sl or /de; / redirects to Slovenian. No environment variables are required to build or run M0. Do not copy server configuration into client environments. Future configuration guidance is in [SECURITY](docs/SECURITY.md).

~~~sh
pnpm web:lint
pnpm web:typecheck
pnpm web:test
pnpm web:build
pnpm --dir web start
~~~

Web tests check translation completeness. To manually verify the production server: both language URLs must show translated text and matching HTML lang; / must redirect to /sl; unsupported locales must return 404. No domain/E2E workflows exist yet.

## Android

~~~sh
cd android
./gradlew lintDebug
./gradlew testDebugUnitTest
./gradlew assembleDebug
./gradlew connectedDebugAndroidTest
cd ..
~~~

On Windows replace ./gradlew with .\gradlew.bat. The last command requires an emulator or connected device. Install app/build/outputs/apk/debug/app-debug.apk or run from Android Studio. Check Slovenian and German locales and rotate the device. The instrumentation test launches the actual activity and checks localized visible content. No domain JVM unit tests exist in M0; the task may report NO-SOURCE, which is not test coverage.

## Supabase

Run from repository root with Docker running:

~~~sh
supabase start
supabase db reset --local
supabase migration up --local
supabase db lint --local --level warning
supabase test db
supabase stop
~~~

Reset destroys local data. No linked/production project is used. See [DATABASE](docs/DATABASE.md) for migration policy and [SYNC](docs/SYNC.md) for the offline architecture. M0 pgTAP tests cover client schema privileges; domain/RLS tests begin alongside protected tables in M1.

## CI and scope

Pushes and pull requests run Android lint/unit-test/debug build plus an emulator launch test, web frozen dependency install/lint/typecheck/localization tests/build, and a clean Supabase start/reset/database lint/pgTAP test. Failed checks are never ignored. No deployment is configured. Required check protection must be configured by a repository administrator before merging. M1+ features are intentionally absent.
