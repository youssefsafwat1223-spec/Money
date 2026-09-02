# Qirsh — reviewer log

Claude is the primary integrator and executor. Fable and Codex act as delegated
independent reviewers. This file records what was reviewed, where they
disagreed, and how each disagreement was resolved — including the times a
reviewer corrected Claude, and the times repository evidence overruled a
reviewer.

Evidence hierarchy used throughout, highest first:
executable source behaviour → tests → project contracts/guards →
schema/migrations → **established owner decisions** → reviewer reasoning.

---

## 2026-09-01 — AdMob banner architecture and placements

**Reviewed by:** Fable ✅ · Codex ✅ · both returned APPROVE WITH CHANGES.

**Agreed, adopted without further debate:** ship Transactions only; cut Coupons
entirely rather than labelling a banner there; one config file with six AdMob
inputs (not a sibling file); typed boolean flags rather than a comma-separated
kill-list; no client refresh-on-resume; fix the session consent gate; add
`app-ads.txt`.

**Disagreed — resolved by source:**

| Question | Fable | Codex | Resolution |
|---|---|---|---|
| Ship the Reports banner? | ship | cut | **Cut.** Reports is `NestedScrollView` + `TabBarView`; `Visibility.of` catches the outer shell tab but not an inactive inner page. It also already carries the interstitial. |
| Banner size | anchored adaptive | fixed 320×50 | **Anchored adaptive, pre-resolved.** The SDK guarantees a stable height per device; inline adaptive sizes itself *after* load, which is the jank being avoided. |
| Signed-out users ad-eligible? | change the policy | keep it | **Keep it.** `app_router.dart:70-82` redirects unauthenticated users to `/onboarding/auth`; nothing ever sets the vestigial `authMethod='guest'`. Fable re-checked and accepted. |

**Reviewers corrected Claude:** the bottom nav is no longer a native platform
view (`MaliGlass` is pure Flutter; those comments are stale), and
`ReportAdsBuildConfig.resolve` was `@visibleForTesting`, which by itself killed
the two-config-file proposal.

**Both independently found a latent bug Claude had not:** the session consent
gate returned early in release when `enable_report_ads` was off, so a
banners-on/report-ads-off release would never have gathered UMP consent.

---

## 2026-09-02 — finalization: three unwired subsystems

**Reviewed by:** Fable ✅ · Codex ⚠️ then ✅ (see below).

**Codex availability:** the first dispatch **FAILED** — `stream disconnected
before completion` after five reconnect attempts against the Codex backend.
Recorded, retried once, and the retry completed. No review was fabricated during
the outage.

**Disagreed on the central question, then converged:**

- **Fable: A** — build the missing Android SMS enable UI.
- **Codex: B** — remove `RECEIVE_SMS` from the shipping artifact.

**Resolution: A.** Fable found a controlling document Claude had missed and
Codex had not read: `Qirsh Production/18_Android_SMS_Capture/README.md`, an
**explicit owner decision dated 2026-08-31** making automatic financial-SMS
capture a required core feature of Android V1 and **revoking** the "Play-safe,
share-only" position. Codex's option B was, textually, the revoked position.
Owner decisions outrank reviewer reasoning in the hierarchy above.

Codex was sent the document it had not read and **switched to A**, adding that
the build-readiness / publication distinction invalidated its own earlier
argument: publishing is gated on Play approval, building and device-testing is
not.

**Agreed by both:** the Proof-Carrying engine ships dormant and recorded
(activation is an integration change, not a flag flip); the affiliate click
gateway stays unwired until a network is contracted; readiness is **NOT READY**
pending device QA and the migration ledger.

**Codex corrections verified and acted on:**
1. `SmsCaptureReceiver` KDoc claimed a build-level manifest placeholder gating
   `RECEIVE_SMS`; none exists. **Fixed.**
2. `MainActivity.pendingSmsPermissionResult` is an activity-instance field, so
   an activity recreation during the dialog drops the result. Narrower than
   "rotation breaks it" — the manifest declares `configChanges`. **Bounded on
   the Dart side.**
3. `PHASE11_ACTIVATION_PACK.md` describes activating the proof client at 1% via
   a flag, which cannot work with no call site. **Correction banner added.**
4. The Settings sentence was true for a fresh install through the reachable UI
   but false as a description of implemented capability. **Copy replaced.**
5. `play_declaration_draft.md`, `data_safety_draft.md` and the live privacy
   policy disagree about whether SMS text reaches an AI provider. **Recorded as
   a pre-submission blocker.**

**Fable corrections verified and acted on:**
1. `_ensureMobileAds` was an instance method, not a private static (conclusion
   unchanged).
2. The `data_safety_draft.md` "0 open findings" claim. **Corrected — there are
   three.**

---

## Tooling availability

| Reviewer / capability | Status |
|---|---|
| Fable | **AVAILABLE** — used for both reviews |
| Codex CLI (`codex exec`, read-only) | **AVAILABLE** — one transport failure, recovered on retry |
| Codex Computer Use / Work | **UNAVAILABLE** — not accessible in this environment; no visual/interaction review was performed |
| iOS Simulator | **NOT USED** — no run performed |
| Android emulator | **NOT USED** — no run performed |
| Physical Android device | **UNAVAILABLE** — never attached to this machine |
| Physical iPhone | **UNAVAILABLE** — Apple portal needs an unavailable 2FA code |
| Supabase Management API | **UNAVAILABLE** — 403, insufficient privileges |
