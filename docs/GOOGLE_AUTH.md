# Google authentication and manual acceptance

Web starts Supabase Google OAuth and exchanges its PKCE code at `/auth/callback?locale=sl` or `locale=de`. Android opens the provider in the browser and exchanges only a validated callback code. Its verifier and session are encrypted with Android Keystore, including across process recreation. Both clients use the existing authoritative account status and Auth insert trigger. Google metadata cannot create memberships or activate profiles.

## Provider configuration

1. Configure Google's consent screen, audience/test users and standard identity scopes. Create a Web application OAuth client for this browser-based flow. Add `https://<project-ref>.supabase.co/auth/v1/callback` as Google's authorized redirect URI, using the exact callback shown by Supabase. Local provider testing uses `http://127.0.0.1:54321/auth/v1/callback`.
2. Enable Google in Supabase Auth providers; store the client ID and secret there. Example server variables: `SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID` and `SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET`. They are never client build variables. Optional local config is commented in `supabase/config.toml`; CI requires no provider credentials.
3. Set Supabase's Site URL and allow exact redirects: `https://<web-host>/auth/callback?locale=sl`, `https://<web-host>/auth/callback?locale=de`, and `si.gasilko.app://auth-callback`. Local Web variants are in config. Avoid broad production wildcards.
4. Android's public `ANDROID_AUTH_REDIRECT_SCHEME` defaults to `si.gasilko.app`; Gradle maps it to SDK and manifest. If changed, update Supabase's allowlist too. Host remains `auth-callback`. The single-task activity handles warm/cold callbacks. Custom schemes can be claimed by other apps; PKCE prevents code exchange without this installation's verifier. Test target devices and use distinct schemes for separately installed environments.

Official references: [Google provider](https://supabase.com/docs/guides/auth/social-login/auth-google), [identity linking](https://supabase.com/docs/guides/auth/auth-identity-linking). Supabase automatically links eligible same-email identities, applying verification protections and removing unconfirmed identities when appropriate. Gasilko performs no email-based merge or manual identity linking. Profiles follow Auth UUIDs, preserving an existing linked user's status. Email signup after OAuth may return an obfuscated response without a new email; it does not create a password. Identities not linked by Supabase do not share profiles/memberships.

## Manual acceptance

Real Google OAuth is not exercised by deterministic CI. Run on configured staging, in both languages and clients:

- Complete first Google sign-in; verify one PENDING_APPROVAL/DASHBOARD/GUIDED profile, no membership, denied protected/admin access. Repeat login and test a verified email/password account with the same Google email; inspect Auth identity/UUID and unchanged profile count/status.
- Cancel/deny consent, use an expired/replayed code, interrupt exchange, and retry. Check Android cold launch/process recreation, rotation, browser return and signout. Never log callback URLs/codes/tokens.
- Browse SI, AT and a deeper staging hierarchy; submit both roles to different active organizations; refresh/restart and verify pending history. Double-submit, call the RPC for an inactive organization, and request an existing membership: verify safe results with no membership/activation.
- Switch accounts and fail a history reload; previous history must disappear. Use trusted fixtures to display APPROVED/REJECTED history with no review controls. Verify pending users cannot navigate directly to Web admin routes.
