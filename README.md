# Gasilko — Hydrant Management Platform

Foundation for an offline-first Android field application and Next.js administration portal backed by Supabase. The authoritative product and architecture specification is [docs/SPEC.md](docs/SPEC.md); agent rules are [AGENTS.md](AGENTS.md). M1.3 provides email/password authentication and account-state routing; domain workflows remain in later milestones.

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

Node 24 distributions without Corepack: install pnpm 11.19.0 using its official installation instructions (or npm install --global pnpm@11.19.0). Open http://localhost:3000/sl or /de; / redirects to Slovenian. No environment variables are required to build; authentication requires the public configuration below. Do not copy server configuration into client environments. Future configuration guidance is in [SECURITY](docs/SECURITY.md).

~~~sh
pnpm web:lint
pnpm web:typecheck
pnpm web:test
pnpm web:build
pnpm --dir web start
~~~

Web tests check translation completeness. To manually verify the production server: both language URLs must show translated text and matching HTML lang; / must redirect to /sl; unsupported locales must return 404. Authentication tests also exercise account routing and authorization decisions.

## Android

~~~sh
cd android
./gradlew lintDebug
./gradlew testDebugUnitTest
./gradlew assembleDebug
./gradlew connectedDebugAndroidTest
cd ..
~~~

On Windows replace ./gradlew with .\gradlew.bat. The last command requires an emulator or connected device. Install app/build/outputs/apk/debug/app-debug.apk or run from Android Studio. Check Slovenian and German locales and rotate the device. The instrumentation test launches the actual activity and checks localized visible content. Auth repository JVM tests and Compose/session-persistence instrumentation tests are included.

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

Pushes and pull requests run Android lint/unit-test/debug build plus emulator tests, Web lint/typecheck/tests/build, and clean Supabase reset/lint/pgTAP and local Auth integration tests. Failed checks are never ignored. No deployment is configured. Required check protection must be configured by a repository administrator before merging. Approval and first-admin bootstrap remain M1.5.

## M1.3 email/password setup

M1.4 adds Google sign-in and organization access requests. Follow [Google setup and manual acceptance](docs/GOOGLE_AUTH.md) for provider configuration, redirects, Android deep links and supported identity linking.

Pending/active users can open Request access, choose a country, navigate any number of area levels (or browse country-wide), choose an active organization and FIREFIGHTER/MANAGER, and confirm. Database validation returns a safe result. Multiple organizations have independent requests; own history displays PENDING/APPROVED/REJECTED with refresh and pagination. Requests never grant memberships or activate profiles. This online onboarding flow does not implement offline field workflows. See [DATABASE](docs/DATABASE.md) and [SECURITY](docs/SECURITY.md) for discovery scope and future review contracts.

In ignored web/.env.local set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY using the project's public URL and sb_publishable_ key. For Android set ANDROID_SUPABASE_URL and ANDROID_SUPABASE_PUBLISHABLE_KEY in the build environment, then rebuild. These are explicitly mapped public values only; never copy a secret/service key into either client. Android requires an HTTPS endpoint (use a development HTTPS tunnel or staging for device testing). Configuration is checked without logging key values.

Enable email/password signup in Supabase Auth, require email confirmation and at least 8-character passwords, configure production SMTP, set the Site URL, and allow the exact Web /auth/callback URLs with locale=sl and locale=de. Local config enables this flow and Mailpit/Inbucket is at http://localhost:54324. Apply versioned migrations first. No production project is modified by this repository's CI.

Signup collects email/password, display name and language. The Auth insert transaction creates one pending profile; after confirmation, sign in normally. Web same-browser confirmation can also exchange its PKCE code through /auth/callback. Android users confirm in their email client then return to sign in; no app deep-link flow is required. Existing-email responses are intentionally generic to avoid account enumeration.

Session restore verifies identity and current database status before showing the shell. Pending users see an approval explanation, request access, refresh and signout; suspended/rejected users remain locked. ACTIVE users see an account shell, and only an own ADMIN membership permits the Web /sl/admin or /de/admin shell. Approval UI and 30-day offline access remain later work.

After local database tests, run node supabase/tests/auth.integration.mjs to test real disposable Auth signup/login/refresh/logout and RLS. This script refuses nonlocal endpoints, uses generated ephemeral credentials, confirms only its own fixture through the local database, and cleans up afterward. It never prints tokens.

Manual acceptance with a configured staging project: verify real email delivery/confirmation in both languages; signup and sign in on Web and Android; restart/rotate/background the Android app; expire/revoke a test session; disconnect the network during restore/signout then retry; change the test account through pending/active/suspended/rejected in a trusted maintenance session; verify direct admin URLs remain protected and a firefighter never enters the admin shell. Verify signout and encrypted persistence on physical devices from supported vendors. No approval/provisioning UI is provided.
