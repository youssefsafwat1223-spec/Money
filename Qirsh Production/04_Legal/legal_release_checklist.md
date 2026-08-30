# Legal Release Checklist

Live host: **`https://qirsh-legal.albaraai-dev.workers.dev`** (no trailing slash).

- [x] `python3 tools/build_legal_site.py` run against current `docs/legal/`
- [x] Site uploaded; `/privacy` and `/terms` both return 200
      (via a 307 to the trailing-slash form — Workers Static Assets
      canonicalisation, accepted; browsers and `url_launcher` follow it)
- [x] Both pages render on a mobile browser
- [x] `legalUrlsArePlaceholder` retired — the default is now the live host, so
      the old "is the default still in use?" question no longer indicates
      anything. Replaced by `legalBaseUrlIsBuildOverride`.
- [ ] `LEGAL_BASE_URL` set in the Codemagic `supabase` variable group
      (optional now — the built-in default is the live host, so a build without
      it still opens working links)
- [ ] Release build made with the define
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
