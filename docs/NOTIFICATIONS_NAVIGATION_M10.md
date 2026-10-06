# M10 notifications and navigation configuration

Implementation only. No migration, function, application or infrastructure deployment was performed.

## Notifications

Apply `20261005140000_notifications.sql` in the normal release process, after independent review. It adds private event, category, installation, preference and delivery tables. It does not change Room. Domain-table triggers create the five supported events: `PLAN_ASSIGNED`, `PLAN_REASSIGNED`, `PLAN_ACTIVATED`, `HYDRANT_NEEDS_ATTENTION`, `HYDRANT_NOT_WORKING`. Current team recipients require exact owning-organization membership, an ACTIVE account, active organization/team/membership and an active selected plan team. Inherited read access is not a subscription. Hydrant alerts are limited to direct managers/admins and default off; assignments and activation default on.

Configure the trusted `notification-delivery` Edge Function with secret names only:

- `NOTIFICATION_DISPATCH_SECRET`: strong independent scheduler secret, sent in `x-dispatch-secret`.
- `FIREBASE_SERVICE_ACCOUNT_JSON`: Firebase service account with HTTP v1 messaging permission, including project ID, client email and signing key.
- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`: trusted runtime configuration.

The function's platform JWT check is disabled **only for this function** in repository configuration; its own mandatory dispatch-secret check replaces it. It accepts POST only and ignores request content. A trusted scheduler must invoke it periodically (for example once a minute); no scheduler or secrets were provisioned by this change. Never expose this secret or service-account JSON to Android, Web, logs or a public scheduler URL. Missing configuration leaves notifications unavailable without blocking field work.

Each invocation resolves at most 25 events and claims at most 50 deliveries, with five concurrent sends. Claims expire after five minutes, allowing recovery after process termination. Attempts are limited to five with exponential backoff; events expire after seven days. At most 1,000 terminal delivery records older than 90 days are pruned per invocation. Event source keys remain as deduplication history. Accepted means FCM accepted the request, **not** delivered/read. An ambiguous provider timeout may produce duplicate delivery; Android replaces notifications sharing an event UUID. Registration revision protects a rotated token from an older invalid-token response.

Additional event codes use the existing envelope; future categories can be added to the category catalog. Recipient policy and localized presentation must be added explicitly for any future incident event. No incident event, recipient policy or workflow is implemented here. Future mandatory security categories must not be marked user-editable.

Android uses only `com.google.firebase:firebase-messaging:25.1.3`, initialized without a Google Services plugin. Supply these **public client configuration** build environment variables for the Firebase Android application whose package is `si.gasilko.app`:

- `ANDROID_FIREBASE_APPLICATION_ID`
- `ANDROID_FIREBASE_PROJECT_ID`
- `ANDROID_FIREBASE_SENDER_ID`
- `ANDROID_FIREBASE_API_KEY`

These are Firebase client configuration, never the server service-account/private key. Messaging is the only Firebase product used; Analytics, Firestore and Firebase Auth are not added. Messaging auto-initialization is enabled after an authenticated account registration. Installation UUIDs are random and not hardware identifiers. Tokens stay in SDK storage and the private server registration table. Logout suppresses local receipt immediately, cancels registration work, requests token deletion and attempts server deactivation; offline logout may leave an old backend row until token rejection or the next account registration, but the account gate discards its payloads.

Preferences require connectivity; failures retain the last displayed settings. Android notification permission is requested only from the explicit enable action. Denial does not block the registry. Stable localized channels separate assignment, activation and hydrant alerts. Data-only FCM messages are presented with generic private lock-screen text in foreground/background; Android delivery restrictions, force-stop and battery policy can defer/drop messages. Taps carry identifiers only, verify the active account, and read the target through the existing authorized repository. Missing offline cache, a different account or an open form produces a recoverable message rather than granting access or discarding work.

## Navigation

The existing foreground `LocationManager` GPS/network listener previously requested 5 s / 5 m updates; the camera separately throttled/eased at 1 s. Outside navigation that location policy remains unchanged. Navigation requests 900 ms below 10 km/h or with unknown speed, 450 ms at 10–60 km/h and 300 ms above 60 km/h, with zero minimum displacement. Reconfiguration is limited to once per three seconds. These are requested intervals, not promises of device GPS cadence. Fixes older than 20 s, accuracy worse than 50 m and implausible jumps are excluded. No location history is stored or uploaded per fix.

MapLibre interpolates between real fixes with a shortened tracking-animation multiplier. Camera easing is 200 ms (300 ms on explicit recenter), with no previous 1 s throttle. Manual pan suspends follow until recenter; an acknowledged new navigation route restores follow. BLUE is only the remaining first provider leg to the actionable target; RED is future geometry. Travelled geometry is trimmed in 10 m display increments. Pending authoritative advancement never paints the old leg BLUE. Local inspection/skip state still follows the existing durable pipeline; GPS arrival never completes an inspection. Confirmed remaining-set/version changes request an updated route through the existing provider endpoint.

Direction arrows are MapLibre line symbols filtered to the active leg. One lifecycle-bound ValueAnimator changes symbol offset, not geometry, and is cancelled on style/view release. Static mode disables animation while retaining the arrows. Sources, layers and local icons are reused; road geometry updates only on route/progress changes. Cached maps/routes remain available; offline reroute is unavailable and the last usable road line remains displayed.

Wrong-way states: NORMAL → SUSPECTED → CONFIRMED → REROUTING. Confirmation requires speed above 10 km/h, accuracy within 25 m, reliable course (bearing accuracy within 25° when supplied), shortest angular difference above 110°, at least four consecutive fixes **and** four seconds **and** 12 m movement. A gap over three seconds or unreliable/low-speed input resets suspicion. Expected bearing comes from the matched active route and approximately 30 road metres ahead; it is not camera bearing or the final destination direction. Existing off-route detection remains separate. Both triggers share a 30 s cooldown and one in-flight job. Failed/offline rerouting keeps the old route and exposes retry; no guessed U-turn or straight-line route is generated.

The existing authenticated `plan-routes` NAVIGATE request optionally includes validated bearing. OSRM constrains only the current origin (±45°); other waypoint bearings are unconstrained. GraphHopper retains its existing fallback and ignores optional bearing. Authoritative snapshot filtering removes completed/skipped/inactive/reassigned-away targets while preserving road stop order and UUID fallback order. No provider limits, routing capacity, OSRM server configuration or Oracle files changed.

## Release work still outstanding

No tests, build, Gradle, lint, typecheck, CI, emulator, physical-device checks, manual smoke tests, Docker, migration application or deployment were run. Independently review/validate SQL, Android and function integration before release, provision messaging configuration, and exercise account switching, revoked access, offline taps, denied permission, token rotation, lost responses, low-speed bearings, road intersections, wrong-way/off-route overlap, manual pan/recenter and offline reroute recovery on real devices.

Before M14 Incident Operations, notification configuration and delivery behavior still need operational verification; incident-specific events, authorization/recipient policies and UI are separate work. QR, SMTP, routing-capacity expansion, offline-map infrastructure, the known FIX pack, M11 general hardening, M12 pilot and M13 production deployment remain on hold. JAVA_HOME/PATH and KAPT/KSP were not changed.

References: [FCM Android setup](https://firebase.google.com/docs/cloud-messaging/android/get-started), [FCM HTTP v1](https://firebase.google.com/docs/cloud-messaging/send/v1-api), [Firebase Android versions](https://firebase.google.com/support/release-notes/android), [OSRM bearing parameters](https://project-osrm.org/docs/v5.24.0/api/).
