# Auth Configuration

Splitting the work by where it happens, because the three consoles each hold one
piece and the order matters.

| Step | Where | Depends on |
|---|---|---|
| 1. App ID + capabilities | Apple Developer | membership |
| 2. Services ID + Sign-in key | Apple Developer | step 1 + the **new** Supabase ref for the return URL |
| 3. Apple provider config | Supabase Dashboard | step 2 |
| 4. Google provider config | Supabase Dashboard | the iOS client id already in the repo |
| 5. Redirect URLs | Supabase Dashboard | — |
| 6. Entitlements | repository — **already done** | — |

## Apple — Sign in with Apple

**Return URL** (Apple Developer, Services ID → Configure):
```
https://<NEW_REF>.supabase.co/auth/v1/callback
```
This is why the Services ID cannot be finished before the Supabase project
exists.

**Supabase** → Authentication → Providers → Apple:

| Field | Value |
|---|---|
| Services ID | `com.youssefsafwat.mali.signin` |
| Team ID | your 10-character team id |
| Key ID | the Sign-in-with-Apple key id |
| Private key | full `.p8` contents |

## Google

The app already ships an iOS client id — see `CFBundleURLSchemes` in
`app/ios/Runner/Info.plist`.

**Supabase** → Authentication → Providers → Google:

| Field | Value |
|---|---|
| Client IDs | that iOS client id |
| **Skip nonce checks** | **ON** |

> The nonce setting is not cosmetic. Google Sign-In on iOS supplies a nonce the
> default Supabase flow rejects. Left off, Google sign-in fails **on device**
> while passing in tests — a failure mode that costs a debugging session.

## Redirect URLs

Authentication → URL Configuration:
- `com.youssefsafwat.mali://login-callback`
- your legal site URL as the Site URL

## Already in the repository — no action

`app/ios/Runner/Runner.entitlements` already declares:

- `com.apple.developer.applesignin` = `Default`
- `aps-environment` = `$(APS_ENVIRONMENT)`
- App Group `group.com.youssefsafwat.mali`
- two Keychain groups, **app's own group first** — required, because
  `flutter_secure_storage` uses the default group and must keep reading the
  existing SQLCipher key

## Verifying

1. Dashboard shows both providers "Enabled".
2. On a **real device**, sign in with Apple → user appears in Authentication → Users.
3. On a **real device**, sign in with Google → same.
4. Sign out, sign back in → same user id, data intact.

Simulator sign-in is not evidence for either provider.
