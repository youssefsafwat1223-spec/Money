# Qirsh — external requirements

**As of 2026-09-02.** Every dependency that engineering cannot satisfy from this
machine. Discovered from source: the app's `String.fromEnvironment` inputs, the
Edge Functions' `Deno.env.get` reads, and the platform configuration files.

**No secret values appear in this document, and none ever should.** Names only.

## Status values

`AVAILABLE` · `MISSING` · `EXPIRED` · `ROTATION REQUIRED` · `EXTERNAL APPROVAL` ·
`DEVICE REQUIRED` · `NOT NEEDED`

---

## Blocking a production release

| Dependency | Purpose | Required for | Status | Environment | Secret name | Owner action |
|---|---|---|---|---|---|---|
| Google Play permissions declaration | Justify `RECEIVE_SMS` under the SMS-based money management exception | Publishing Android at all | **EXTERNAL APPROVAL** | Play Console | — | Submit the draft in `Qirsh Production/18_Android_SMS_Capture/play_declaration_draft.md`, then await review |
| Play Data Safety form | Required disclosure | Publishing Android | **MISSING** | Play Console | — | Submit `data_safety_draft.md`; must be reconciled with the declaration first (see Blockers) |
| Physical Android device | SMS receipt, background execution, permission flow, banner render | Any BETA claim | **DEVICE REQUIRED** | — | — | Connect a device over USB with developer mode; run `Qirsh Production/18_Android_SMS_Capture/device_qa_plan.md` |
| Physical iPhone | Share extension, App Groups, APNs, Shortcuts | Any BETA claim | **DEVICE REQUIRED** | — | — | Same, plus a provisioning profile |
| Supabase dashboard access | Read the real migration ledger | Resolving the 0084/0072 contradiction | **MISSING** — Management API returns 403 | Supabase | — | Grant this account privileges, or read `supabase_migrations.schema_migrations` from the dashboard and report the highest applied version |
| Apple Developer 2FA | Provisioning, App IDs, APNs key | iOS release | **MISSING** | Apple Developer | — | Provide a 2FA code from a trusted device; the client is currently unavailable |
| Android upload keystore enrolment | Play App Signing | Android release | **MISSING** | Play Console | `ANDROID_KEYSTORE_*` | Enrol; the keystore exists locally and is gitignored |

---

## Blocking specific features (not the release)

| Dependency | Purpose | Required for | Status | Environment | Secret name | Owner action |
|---|---|---|---|---|---|---|
| AdMob app IDs | SDK init | Any ad serving | **MISSING** | Build | `ADMOB_APP_ID_IOS`, `ADMOB_APP_ID_ANDROID` | Create the AdMob app; supply both to the native build setting **and** the dart-define |
| AdMob interstitial units | Report-export ad | Interstitial revenue | **MISSING** | Build | `ADMOB_INTERSTITIAL_IOS/_ANDROID` | Create two units |
| AdMob banner units | Transactions banner | Banner revenue | **MISSING** | Build | `ADMOB_BANNER_IOS/_ANDROID` | Create two units |
| `app-ads.txt` | AdMob app verification | Serving to a newly configured app | **MISSING** | qirsh.site | — | Publish at `https://qirsh.site/app-ads.txt` with the real publisher ID. Required for new apps since Jan 2025. A placeholder is worse than absence |
| AdMob refresh interval | The banner has **no client timer** by design | Banner fill rate | **MISSING** | AdMob console | — | Set the banner unit's refresh interval |
| `SKAdNetworkItems` | iOS bidding demand | iOS ad revenue | **MISSING** — one entry today | `ios/Runner/Info.plist` | — | Add Google's currently published list |
| APNs auth key | Push delivery | Notifications | **MISSING** | Supabase secrets | `APNS_PRIVATE_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` | Create a `.p8` in the Apple portal; store as Edge secrets, never in the repo |
| Gemini API key | Cloud AI parse assist | AI capture **and the Play SMS declaration** | **DECISION REQUIRED — do not set until the tier is pinned** | Supabase secrets | `GEMINI_API_KEY` | Commit to a **no-training** tier (paid Gemini API or Vertex AI) and record the terms version + date. The free tier permits Google to use submitted content to improve its products — an independent purpose that would void the SMS-based-money-management exception and flip Data Safety to *Shared: YES*. Both reviewers made this the pivot of the declaration. |
| Gemini shadow key | Proof shadow traffic | Proof measurement | **MISSING** | Supabase secrets | `GEMINI_SHADOW_API_KEY` | Only needed **after** the Proof engine is wired — it has no call site today |
| Google Maps/Places key | Merchant enrichment | `enrich-merchant` | **MISSING** | Supabase secrets | `GOOGLE_MAPS_API_KEY` | Create a restricted key |
| Affiliate network account | Real offers and commissions | Coupons monetization | **MISSING** | — | `AFFILIATE_<NETWORK>_KEY` | Sign an agreement; **read the browser-extension and attribution clauses** before building anything further |
| Affiliate postback secret | Verify conversion webhooks | Attribution | **MISSING** | Supabase secrets | `AFFILIATE_FIXTURE_POSTBACK_SECRET` (fixture) / per-network | Provision when a network exists |
| Worker secrets | Authorize cron workers | Scheduled jobs | **UNKNOWN** — verify | Supabase secrets | `AFFILIATE_WORKER_SECRET`, `NOTIFICATION_RETRY_WORKER_SECRET`, `PURGE_WORKER_SECRET` | Confirm each is set in the project |
| Sentry DSN | Error reporting | Diagnostics | **UNKNOWN** | Build | `SENTRY_DSN` | Confirm |

---

## Already satisfied

| Dependency | Status | Note |
|---|---|---|
| Supabase project | **AVAILABLE** | Linked ref `rjwphwsefnuotpbtuycf` |
| `SUPABASE_URL` / `SUPABASE_ANON_KEY` | **AVAILABLE** | Build-time dart-defines |
| Domain + DNS + TLS | **AVAILABLE** | `qirsh.site` live, legal pages deployed |
| Privacy policy and Terms | **AVAILABLE** | §8 describing SMS capture is **live** |
| `LEGAL_BASE_URL` | **AVAILABLE** | Production default |
| Android upload keystore | **AVAILABLE** locally | Gitignored, never committed |

---

## Rotation

No credential is known to have been exposed. The tracked-file scan found no
JWTs, API keys or private keys — only PEM header string literals inside APNs
parsing code.

**One caveat that is not a finding but is worth stating:** `app/android/key.properties`
exists on disk. It is gitignored and absent from every commit, but it is real key
material sitting in a source tree, and anything that archives the working
directory (a zip, a backup, a `git add -f`) would carry it. Consider relocating
it outside the repository.
