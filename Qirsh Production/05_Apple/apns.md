# APNs

## Create the key

Certificates, Identifiers & Profiles → **Keys** → **+**

- Name: `Qirsh APNs`
- Enable **Apple Push Notifications service (APNs)**
- Continue → Register → **Download** the `.p8`

> **The download happens exactly once.** Apple will not let you retrieve it
> again. Store it in your password manager immediately.

**Record the Key ID** shown next to the key.

## One key, both environments

A single APNs key serves development and production. `aps-environment` in the
build selects which environment the token targets — no second key needed.

## Feeding it to Supabase

```bash
supabase secrets set APNS_KEY_ID=<key id>
supabase secrets set APNS_TEAM_ID=<team id>
supabase secrets set APNS_BUNDLE_ID=com.youssefsafwat.mali
supabase secrets set APNS_PRIVATE_KEY="$(cat AuthKey_XXXXXXXXXX.p8)"
```

`APNS_PRIVATE_KEY` is the **full file contents including the BEGIN/END lines**.

Consumed by `supabase/functions/_shared/` for push signing.

## Verifying — device only

1. Install a signed build on a **real iPhone** and grant notifications.
2. Confirm a `register-push-token` row appears server-side.
3. Trigger a notification (Settings → أدوات الإشعارات → اختبار إشعارات قرش).
4. Verify delivery **foreground, background, and app terminated** — they are
   three different code paths.
5. Verify the lock-screen actions «تأكيد ✓» and «تجاهل».

A simulator cannot validate any of this.

## If pushes do not arrive

| Check | Meaning |
|---|---|
| `aps-environment` matches the build type | a development token cannot receive production pushes |
| `APNS_BUNDLE_ID` exactly `com.youssefsafwat.mali` | a mismatch is rejected silently by APNs |
| `.p8` copied whole, BEGIN/END included | a truncated key fails signing |
| Key ID and Team ID not transposed | a common and confusing mix-up |
