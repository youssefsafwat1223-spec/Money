# Secrets & Configuration Inventory

Traced from actual repository usage (`Deno.env.get`, `String.fromEnvironment`,
Gradle env reads) — not from a historical list.

**No real secret value appears in this repository or in any document here.**

## Platform-injected — do NOT set these

Supabase injects them into every Edge Function. Setting them manually is wrong.

`SUPABASE_URL` · `SUPABASE_ANON_KEY` · `SUPABASE_SERVICE_ROLE_KEY`

## Edge Function secrets

| Name | Req? | Used by | From | Sensitivity | If absent |
|---|---|---|---|---|---|
| `PURGE_WORKER_SECRET` | **required** | `purge-scheduled-deletions` | `openssl rand -base64 32` | **secret** | worker returns **403 to everything**; scheduled deletions stop |
| `NOTIFICATION_RETRY_WORKER_SECRET` | **required** | `process-notification-retries` | `openssl rand -base64 32` | **secret** | worker returns **401 to everything**; push retries stop |
| `APNS_KEY_ID` | required for push | `_shared` | Apple Developer → Keys | secret | iOS pushes cannot be signed |
| `APNS_TEAM_ID` | required for push | `_shared` | Apple membership page | low | as above |
| `APNS_BUNDLE_ID` | required for push | `_shared` | `com.youssefsafwat.mali` | not secret | as above |
| `APNS_PRIVATE_KEY` | required for push | `_shared` | the `.p8`, downloadable **once** | **secret** | as above |
| `GEMINI_API_KEY` | **optional** | `parse-sms`, `bank-discovery`, `process-ios-sms` | Google AI Studio | **secret** | AI fallback returns `upstream_unavailable`; **local operation continues normally** |
| `GEMINI_MODEL` | optional | same three | model name | not secret | in-code default is used |
| `GOOGLE_MAPS_API_KEY` | optional | `enrich-merchant` | Google Cloud, Places API enabled | **secret** | enrichment degrades to local heuristics — deliberate soft-fail |

The two worker secrets **must be freshly generated and distinct from the
service-role key.** That separation is the design: a leaked worker secret must
not confer database superpowers.

```bash
supabase secrets set NAME=value
supabase secrets list        # names only — values are never echoed
```

## App build-time `--dart-define`

| Name | Req? | Purpose | Sensitivity | If absent |
|---|---|---|---|---|
| `SUPABASE_URL` | for cloud features | project URL | ships in app, not secret | cloud features unavailable; app still runs |
| `SUPABASE_ANON_KEY` | for cloud features | anon key | ships in app, **public by design** | as above |
| `LEGAL_BASE_URL` | **yes, for store submission** | host serving `/privacy`, `/terms` | not secret | falls back to a host that does not resolve |
| `SENTRY_DSN` | optional | crash reporting | low | reporting disabled, no crash |
| `APP_VERSION` | set by CI from pubspec | `X-App-Version` targeting | not secret | version-targeted rules cannot match (F-024) |

> `LEGAL_BASE_URL` must be **absent or non-empty**. An empty define is honoured
> over `defaultValue` and produces a hostless URI. Guarded in
> `app/lib/core/config/legal_urls.dart` and asserted by test.

## Android signing

| Name | Req? | Sensitivity | If absent |
|---|---|---|---|
| `ANDROID_KEYSTORE_PATH` | required for release | path | **release build fails with a named error** — never falls back to the debug key |
| `ANDROID_KEYSTORE_PASSWORD` | required | **secret** | as above |
| `ANDROID_KEY_ALIAS` | required | low | as above |
| `ANDROID_KEY_PASSWORD` | required | **secret** | as above |
| `ADMOB_APP_ID_ANDROID` | optional | not secret | warns; ships with ads off. **Malformed value fails the build** (it would crash at process start) |

Local alternative: `app/android/key.properties` (gitignored).

## Verifying without exposing anything

```bash
supabase secrets list                     # names only
grep -c "dart-define=LEGAL_BASE_URL" codemagic.yaml    # expect 3
git status                                # must show no key.properties / *.jks
git log -p | grep -iE "service_role|BEGIN PRIVATE KEY"  # expect no output
```
