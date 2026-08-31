# 15 — Codemagic

## Status: DEFERRED — FINAL CONSOLIDATED PRODUCTION CONFIGURATION PASS

**Owner decision, 2026-08-31.** All Codemagic production configuration is
deliberately deferred to a single consolidated pass near the end of production
readiness, rather than being set piecemeal as each requirement appears.

This is a sequencing choice, **not permission to forget anything**. Everything
outstanding is recorded below so the final pass starts from a list rather than
from memory.

---

## OUTSTANDING — must be set in the final pass

| Variable | Value | Group | Status |
|---|---|---|---|
| `LEGAL_BASE_URL` | `https://qirsh.site` | `supabase` | **PENDING** |

### Why this one is not urgent, and not optional

`app/lib/core/config/legal_urls.dart` already defaults to `https://qirsh.site`,
so **every build opens working legal links whether or not the variable is set**.
Nothing is broken.

What is missing is the *declaration*. A build whose legal host is implicit cannot
be reproduced or repointed without a code change, which is the entire reason the
define exists in all three workflows. Treat an absent or stale value as a
**release-configuration defect to catch before signing** — not as a breakage.

The variable currently holds the old Workers URL. That URL still resolves (it is
the retained rollback host), so a build made today would ship a working but
non-canonical host. See
[`../04_Legal/domain_status.md`](../04_Legal/domain_status.md).

---

## What the final pass must produce

One canonical document at:

```
Qirsh Production/15_Codemagic/CODEMAGIC_PRODUCTION_SETUP.md
```

Built by auditing the **real** `codemagic.yaml`, the application configuration,
signing requirements and production documentation — not by copying this list.
It must consolidate:

- every required environment variable
- every `--dart-define`
- variable groups, and which workflows consume each variable
- iOS signing configuration
- Android signing configuration
- App Store Connect credentials
- Google Play credentials
- Supabase client configuration
- `LEGAL_BASE_URL`
- optional Sentry configuration, if applicable
- required vs optional values
- secret vs non-secret values
- **values that must NEVER be placed in Codemagic**
- human/account actions
- verification commands and checks
- a final pre-signing checklist

### Documentation rule

**No secret VALUE ever enters this repository.** Document the secret's *name*,
*purpose*, *source* and *destination* only. That rule already holds across this
workspace and must hold in the final document too.

---

## Known inputs for that pass

Recorded now so the audit has a starting point. **The final pass must verify each
against source rather than trusting this table.**

| Variable | Non-secret | Workflows |
|---|---|---|
| `LEGAL_BASE_URL` | yes | all three |
| `SUPABASE_URL` | yes — ships in the app | all three |
| `SUPABASE_ANON_KEY` | yes — public by design | all three |
| `SENTRY_DSN` | optional | all three |
| `APP_VERSION` | derived from `pubspec.yaml` by CI | all three |
| `ADMOB_APP_ID_IOS` / `ADMOB_INTERSTITIAL_IOS` | optional | iOS |
| `ADMOB_APP_ID_ANDROID` / `ADMOB_INTERSTITIAL_ANDROID` | optional | Android |
| `ANDROID_KEYSTORE_BASE64`, `_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD` | **secret** | Android |

Related detail already written up: [`../13_AdMob/build_configuration.md`](../13_AdMob/build_configuration.md),
[`../06_Android/signing_keystore.md`](../06_Android/signing_keystore.md),
[`../05_Apple/signing.md`](../05_Apple/signing.md),
[`../02_Supabase/secrets_checklist.md`](../02_Supabase/secrets_checklist.md).

**Never in Codemagic:** the Supabase `service_role` key, the production database
password, and the Edge Function worker secrets. Those belong to the server, not
to a client build.
