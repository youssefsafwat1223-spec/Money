# Remaining Work Before Production

Everything here needs something outside this repository. Ordered by whether it
blocks the critical path.

## Critical path — start these first, they are independent of each other

| # | Item | Owner | Needs |
|---|---|---|---|
| 1 | Create the new Supabase production project | Youssef | Supabase account |
| 2 | ~~Host the legal site~~ — **DONE**, live at `qirsh-legal.albaraai-dev.workers.dev` (approved temporary production host) | — | — |
| 3 | Apple Developer configuration | Youssef | $99/yr membership |
| 4 | Android production keystore | Youssef | local `keytool`, two backup locations |

## Future — does NOT block this release

| Item | Owner | Status |
|---|---|---|
| **Migrate legal hosting to the final Qirsh custom domain** | Youssef (domain, stores) + Claude (source, docs) | Final domain not purchased, not configured, not named. A branding/infrastructure task. The current approved temporary host is production-safe and approved for store submission, so this blocks nothing while it stays healthy. Ordered migration steps: [`../04_Legal/domain_status.md`](../04_Legal/domain_status.md) |

## Dependent

| # | Item | Owner | Blocked by |
|---|---|---|---|
| 5 | Set Edge Function secrets | Claude `[AUTH]` | 1 |
| 6 | Apply migrations 0001–0092 | Claude `[AUTH]` | 1, 5 |
| 7 | Deploy 24 Edge Functions | Claude `[AUTH]` | 1, 5 |
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
