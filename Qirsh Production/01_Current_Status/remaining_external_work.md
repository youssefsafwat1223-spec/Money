# Remaining Work Before Production

Everything here needs something outside this repository. Ordered by whether it
blocks the critical path.

## Critical path — start these first, they are independent of each other

| # | Item | Owner | Needs |
|---|---|---|---|
| 1 | ~~Create the new Supabase production project~~ — **DONE**, `rjwphwsefnuotpbtuycf`, migrations `0001–0092` applied | — | — |
| 2 | ~~Host the legal site~~ — **DONE**, canonical at `qirsh.site` over TLS on the Qirsh VPS | — | — |
| 3 | Apple Developer configuration | Youssef | $99/yr membership |
| 4 | Android production keystore | Youssef | local `keytool`, two backup locations |

## Pre-signing gates — must pass before any signed release build

| Gate | Why |
|---|---|
| **Re-run dedup/idempotency tests** after the parser session lands | the duplicate outcome comes from `add_transaction_usecase.dart`, under active refactor; a change there breaks idempotency silently — the capture still imports, just twice. Command in [`../18_Android_SMS_Capture/`](../18_Android_SMS_Capture/) |
| **Deploy the updated privacy page** to `qirsh.site` | the live page describes behaviour the app no longer has; Play cross-checks the policy against declared permissions |
| **Execute the Android device QA matrix** | the Kotlin prefilter has no automated test; this is its only execution evidence |

## Play publication gate — NEW, 2026-08-31

| Item | Owner | Status |
|---|---|---|
| **Google Play restricted-permission approval** (`RECEIVE_SMS`, SMS-based money management) | Youssef | **PENDING** — implementation and declaration draft complete; Play publication cannot proceed without approval. [`../18_Android_SMS_Capture/`](../18_Android_SMS_Capture/) |

## Future — does NOT block this release

| Item | Owner | Status |
|---|---|---|
| ~~Migrate legal hosting to the final Qirsh custom domain~~ — **DONE 2026-08-30**. `qirsh.site` is live over TLS and is the built-in default. Remaining: update the Codemagic `LEGAL_BASE_URL`, and eventually retire the Workers rollback host. [`../04_Legal/domain_status.md`](../04_Legal/domain_status.md) | — | — |

## Dependent

| # | Item | Owner | Blocked by |
|---|---|---|---|
| 5 | ~~Set Edge Function secrets~~ — **DONE**, both worker secrets set and rotated | — | — |
| 6 | ~~Apply migrations 0001–0092~~ — **DONE**, applied and verified live | — | — |
| 7 | **Deploy 24 Edge Functions** — **BLOCKED**: Management API 403, raised with Supabase Support | Claude `[AUTH]` | Supabase Support |
| 8 | Signed release builds | Youssef + Claude | 1, 2, 3, 4 |
| 9 | Physical-device QA + UX-035 | Youssef `[DEVICE]` | 8 |
| 10 | TestFlight / Play internal beta | Youssef | 9 |
| 11 | Prove + activate PUSH, then PULL | Claude `[AUTH]` | 10 |
| 12 | Store submission | Youssef | 11 |
| 13 | Staged rollout + monitoring | Youssef | 12 |

## Known environment limitation

**Android release build cannot be validated in the current sandbox.** Gradle's
JVM TLS handshake to `dl.google.com` is terminated, while `curl` to the same URL
returns 200. Plugin resolution succeeded, so the pinning is correct — this is
environmental. Build on your own machine or in Codemagic. The signing
configuration itself is covered by 10 structural tests.
