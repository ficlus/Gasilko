# M0 version decisions (2026-09-17)

| Tool | Pin | Reason |
|---|---|---|
| AGP / Gradle / JDK | 8.13.2 / 8.13 / 17 | Official compatible baseline; AGP 8.13.2 supports Kotlin 2.3 |
| Kotlin / Compose compiler plugin | 2.3.21 | Matched compiler versions; stable patch |
| Android SDK | compile/target 36, min 26 | Compatible AGP; min exceeds Room/WorkManager minimum |
| Compose BOM | 2025.12.01 | Stable aligned Compose/Material 3 baseline for SDK 36 |
| Activity | 1.12.4 | Stable patched SDK 36 baseline |
| Coroutines / Room / WorkManager | 1.10.2 / 2.8.4 / 2.11.2 | Required Android runtime foundations; no domain logic or processor yet |
| Android test runner | 1.7.0 | Instrumentation launch test |
| Node / pnpm | 24.19.0 / 11.19.0 | Available Node LTS and pinned workspace package manager |
| Next / React | 16.3.5 / 19.3.0 | Stable official registry releases; matching React DOM |
| TypeScript | 5.9.3 | Stable established Next-compatible compiler baseline |
| ESLint / Next config | 9.39.4 / 16.3.5 | ESLint flat configuration; lint is a separate gate |
| Supabase CLI / PostgreSQL | 2.117.0 / 17 | Pinned CLI and local database major |

Direct runtime/build dependencies are MIT (Next, React, pnpm, ESLint, Supabase CLI) or Apache-2.0 (Kotlin, AndroidX, Coroutines, Gradle, TypeScript). Android test JUnit transitively uses EPL-1.0. No map, auth, Firebase, import/export, Supabase client or UI utility dependencies are introduced speculatively. Node's built-in test runner avoids another web testing dependency. The pnpm lockfile pins transitive web dependencies.

Official sources consulted before selection:

- https://developer.android.com/build/releases/agp-8-13-0-release-notes
- https://developer.android.com/build/kotlin-support
- https://developer.android.com/develop/ui/compose/bom
- https://developer.android.com/jetpack/androidx/releases/activity
- https://developer.android.com/jetpack/androidx/releases/room
- https://developer.android.com/jetpack/androidx/releases/work
- https://github.com/Kotlin/kotlinx.coroutines/releases
- https://nextjs.org/docs/app/getting-started/installation
- https://nextjs.org/docs/app/api-reference/config/eslint
- https://supabase.com/docs/guides/local-development/cli-workflows
- https://supabase.com/docs/guides/local-development/database-migrations

Package versions and peer compatibility were also checked against the official npm registry. This deliberately uses compatible stable releases rather than prerelease SDKs or every newest major. Reassess pins through verified upgrades.
