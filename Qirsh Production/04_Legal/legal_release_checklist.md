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
| The AI runs **on device**; no message text goes to an AI provider without consent | on-device classifier; Gemini double-gated |
| We do not sell data; no ad profile from transactions | no such pipeline exists |

If any becomes untrue, the policy must change **before** the behaviour ships.

## Do not overreach

The policy claims **local-database encryption**, which is what the code does. It
must not claim end-to-end encryption, which it does not do. A privacy claim that
overstates is worse than the silence it replaced.
