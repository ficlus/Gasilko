# Security foundation

Client applications contain no privileged secrets. Public Supabase URLs and publishable keys may be mapped explicitly into clients later; Supabase secret/service-role keys, CLI tokens and Firebase admin credentials belong only in trusted server environments. M0 reads no environment secrets and initializes no SDK clients. Never enumerate all environment variables into Next config or Android BuildConfig. Any future server secret reader must be guarded with Next.js server-only boundaries and authorization tests.

Authentication is not authorization. RLS is mandatory for protected domain tables and storage objects. Approved membership, account state and role must restrict every organization request, including direct API calls; UI visibility is insufficient. Pending, suspended and cross-organization access must be denied. Privileged operations execute in trusted database functions or backend code and explicitly authorize the actor even when using a key that bypasses RLS.

Use Android Keystore to protect tokens and sensitive cached authorization material when authentication is introduced. Do not store plaintext passwords. Device backup is disabled for the foundation app. Offline authorization is limited to 30 days since verified online authorization, as specified; no authorization is implemented in M0.

.env.example is a reference inventory of placeholders, not a file to copy wholesale into clients. Keep web public values in ignored web/.env.local and backend secrets in a secret store. Android local.properties is ignored; never add service credentials to it for bundling. Firebase configuration is deferred. Ignore rules cover local env files, signing keys and service files. Rotate and report any credential discovered in Git history; deleting the latest copy is insufficient.

The initial database migration removes client schema-creation privileges. M1 must add protected tables with explicit grants and RLS in the same migration. There is no protected domain data in M0.
