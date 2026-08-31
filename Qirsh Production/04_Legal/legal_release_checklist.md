# Legal Release Checklist

Canonical production host: **`https://qirsh.site`** (no trailing slash).

Live over TLS on the Qirsh VPS, `/privacy` and `/terms` return **200 directly**.
Migrated 2026-08-30 from `https://qirsh-legal.albaraai-dev.workers.dev`, which stays
live as the rollback — see [`domain_status.md`](domain_status.md).

- [x] `python3 tools/build_site.py` run against current `docs/legal/`
- [x] Deployed to the Qirsh VPS; `/privacy` and `/terms` return **200 directly**
      (nginx `try_files` — no trailing-slash redirect)
- [x] Both pages render on a mobile browser, Arabic and English
- [x] TLS: Let's Encrypt, chain valid, HSTS, `certbot renew --dry-run` succeeded
- [x] Built-in default migrated to `https://qirsh.site`; pinned tests updated
- [x] `legalUrlsArePlaceholder` retired — replaced by
      `legalBaseUrlIsBuildOverride`
- [x] **Privacy Policy update deployed 2026-08-31** — §1, §6, §7, §8 (auto-SMS
      disclosure, retention split, AI-provider row, iOS Shortcuts path). Only
      `/privacy` and `/en/privacy` were replaced; the other six routes were
      verified byte-identical before and after. Live bytes match the approved
      artifact hashes exactly. Rollback copy of the previous pages kept on the
      VPS at `/home/qirsh/rollback/privacy-<UTC-stamp>/` (path in
      `/home/qirsh/rollback/LATEST`).

      | Route | SHA-256 of the deployed page |
      |---|---|
      | `/privacy` | `294000631423210a1f053a95ded3b4c39da1df8517562b1cd9ef4829dba26ed6` |
      | `/en/privacy` | `9fa9b94ae32e512c4b335a09948116c39ccc59e33ea160af85753250a5752449` |

      `tools/build_site.py` is deterministic, so regenerating and comparing is a
      real check: a mismatch means the source moved and the live page did not.
- [ ] **`LEGAL_BASE_URL` set in the Codemagic `supabase` variable group —
      REQUIRED for production release configuration.** Not optional. The
      built-in live default is a safety fallback for users, not a substitute
      for configuring the release. A missing variable no longer produces broken
      legal URLs, but it is still a **release-configuration defect** and must be
      caught before signing.
- [ ] Release build made with the define
- [ ] Workers rollback host retired (only once no shipped build points at it)
- [ ] Both links verified from inside the installed app
- [ ] Privacy URL entered in App Store Connect
- [ ] Privacy URL entered in Play Console
- [ ] Store privacy declarations match `docs/legal/PRIVACY_POLICY.md`

## Claims the policy makes that the app must keep true

| Claim | Enforced by |
|---|---|
| Financial data is local, in an encrypted database | SQLCipher, fail-closed |
| Cloud sync is **off by default** | `ConsentAuthority`, capabilities `unknown` |
| The **categoriser** runs on device with no network access | on-device classifier |
| Message text reaches an AI provider **only** with cloud processing **and** AI assistance on | `ConsentAuthority` — `aiProcessing` returns `cloud && aiConsentGranted` |
| Every recipient is first-party or a service provider — nothing is *shared* under Play's definition | see the provider gate below |
| We do not sell data; no ad profile from transactions | no such pipeline exists |

If any becomes untrue, the policy must change **before** the behaviour ships.

The earlier row read "the AI runs on device; no message text goes to an AI
provider". That was an absolute claim the code does not support — `process-ios-sms`,
`bank-discovery` and `parse-sms` all reach Gemini when `allowAi` is forwarded.
The consent gating is real, so the honest claim is conditional, and the policy
now states it that way.

## ⛔ Provider gate — before enabling any production AI or diagnostics provider

**Verify against that provider's current terms** — not a memory of them — that it
processes only on Qirsh's behalf, has no independent-purpose use of submitted
content, and does not train on it. If any of the three fails, that recipient
becomes **Shared: YES** in Data Safety and the privacy policy must say so first.

`GEMINI_API_KEY` is not set on production, so no call can be made today. That is
a config state, not a guarantee — the code path exists. Full reasoning and the
per-recipient table: [`../18_Android_SMS_Capture/data_safety_draft.md`](../18_Android_SMS_Capture/data_safety_draft.md).

## Do not overreach

The policy claims **local-database encryption**, which is what the code does. It
must not claim end-to-end encryption, which it does not do. A privacy claim that
overstates is worse than the silence it replaced.
