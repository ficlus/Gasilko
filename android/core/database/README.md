# core/database

M3.1 implementation lives in `app/src/main/java/si/gasilko/app/core/database` (the project still builds one `:app` module).

`RegistryDatabase` version 1 persists organizations/membership roles, organization-visible global/local types, and complete registry hydrants including nullable code, UUID, version, creation/update timestamps and actors. Account columns partition cached server UUIDs between signed-in users; every hydrant DAO read additionally requires an organization. UUID ordering and keyset pages of 100 are deterministic. Search uses normalized Unicode lowercase columns and SQL `instr`, so `%` and `_` remain literal; type/status/active filters combine with AND.

`RoomHydrantRepository` serves normal reads from Room. Explicit metadata and organization refreshes call the existing authorized online repository. All types and hydrant pages are fetched before one transaction replaces that organization's server snapshot. Failure or cancellation during fetching leaves its previous rows intact. An empty successful snapshot clears obsolete rows. No destructive migration fallback is enabled. Room exports versioned schema JSON under `app/schemas` during compilation; retain these when adding migrations.

The account gate remains unchanged. These stored roles are not a new offline authorization mechanism. Local data is not a substitute for Supabase RLS; refresh and existing online writes use the signed-in client. Pending rows do not exist in M3.1. M3.2 must make snapshot replacement pending-aware before introducing offline writes; the real sync engine arrives in M3.3.

The added compiler matches the already-declared Room runtime (2.8.4); KAPT matches the existing Kotlin plugin (2.3.21). This enables required DAO generation without an unrelated runtime upgrade or new database library. Room/AndroidX and Kotlin use Apache 2.0. [Room configuration and maintained releases](https://developer.android.com/jetpack/androidx/releases/room) document KAPT and schema export.
