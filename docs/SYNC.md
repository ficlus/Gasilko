# Offline-first architecture

~~~text
UI
 ↓
ViewModel
 ↓
Repository
 ↓
Room ←→ Sync Engine ←→ Supabase
~~~

Room is the Android UI's local source; Supabase is the central system of record. Domain operations are written locally first. WorkManager will drive durable retries. Unsynchronized field records and photographs remain until explicit server acknowledgement. Client UUIDs make retries idempotent. Hydrant master-data conflicts use optimistic concurrency, while independent inspections remain append-only.

Synchronization, queues, repositories, entities and offline authorization are implemented in later milestones. M0 only establishes boundaries and runtime dependencies. Do not connect Compose screens directly to Supabase. The future 30-day offline authorization limit, Keystore protection and clock-tampering safeguards remain required by SPEC.
