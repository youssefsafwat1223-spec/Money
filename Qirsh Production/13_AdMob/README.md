# 13 — AdMob

Everything needed to ship the report-export interstitial (R4/R7). Source and CI
are complete; what remains is an AdMob account and four identifiers.

| Question | Answer |
|---|---|
| Required for release? | **No.** Absent ⇒ the app ships with ads off and works normally. |
| Can a wrong value break the app? | **Yes — and it is the sharpest edge here.** See [`safety_model.md`](safety_model.md). |
| What do I actually have to do? | [`setup_checklist.md`](setup_checklist.md) |
| What are the four values and where do they go? | [`build_configuration.md`](build_configuration.md) |
| How do I confirm it works? | [`verification.md`](verification.md) |

## Status

- [x] Client implementation — `app/lib/features/report_ads/` (4 files)
- [x] Build-time configuration + shape validation — `report_ads_build_config.dart`
- [x] Native wiring — iOS `Info.plist` / xcconfig, Android manifest / `build.gradle.kts`
- [x] CI wiring — all four defines in `codemagic.yaml`
- [x] Guard tests — 8 test files, including architecture guards
- [ ] **AdMob account created** — Youssef
- [ ] **Four production identifiers obtained** — Youssef
- [ ] **Set in Codemagic** — Youssef
- [ ] **Verified on a physical device** — after a release build

## The one thing to get right

AdMob identifiers are **build/deployment configuration**. They are never Admin-editable
rows, never business data, never a remote feature-config value. Four inputs, supplied
at build time, and nothing else:

```
ADMOB_APP_ID_IOS          ADMOB_INTERSTITIAL_IOS
ADMOB_APP_ID_ANDROID      ADMOB_INTERSTITIAL_ANDROID
```

App IDs use `~`. Ad unit IDs use `/`. Mixing them up is the classic AdMob
misconfiguration and the code rejects it explicitly.
