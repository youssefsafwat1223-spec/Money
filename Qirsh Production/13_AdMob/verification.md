# AdMob Verification

A build with absent or incomplete AdMob configuration **succeeds and ships with
ads off**. So "the build passed" proves nothing. Verify explicitly.

## Before the build — local checks

Confirm the values are well-formed without a build:

```bash
cd app
flutter test test/features/report_ads/ test/architecture/report_ads_guards_test.dart
```

Covers shape validation, debug/QA always resolving TEST identifiers, release
resolution of a supplied value, missing ⇒ null, malformed ⇒ null, the
completeness gate, that platform values never cross, and that no production ID
is baked into source.

Confirm CI carries all four defines:

```bash
grep -c 'dart-define=ADMOB' codemagic.yaml     # expect 4
```

## After the build — artifact checks

These prove the value reached the **native** layer, which the dart-define alone
does not.

**Android** — read the App ID back out of the built manifest:

```bash
# from an AAB/APK, via bundletool or aapt2
aapt2 dump xmltree app-release.apk --file AndroidManifest.xml \
  | grep -A2 'ads.APPLICATION_ID'
```

Expect **your production App ID**. If you see
`ca-app-pub-3940256099942544~3347511713`, the environment variable did not reach
Gradle — the build fell back to the sample id and Dart will report
not-configured.

**iOS** — read `GADApplicationIdentifier` from the packaged app:

```bash
/usr/libexec/PlistBuddy -c 'Print :GADApplicationIdentifier' \
  Payload/Runner.app/Info.plist
```

Expect your production App ID, not `$(ADMOB_APP_ID)` and not the sample.

## On a physical device — the real test

Debug and profile builds always use Google's TEST identifiers, so **QA on a debug
build proves the flow works, not that production configuration is correct.**
Both matter; they are different tests.

### Flow test (debug build, TEST ads — safe)

- [ ] Export a report
- [ ] A test interstitial appears
- [ ] Dismiss it → **the report still generates**
- [ ] Force the ad to fail (airplane mode) → **the report still generates**

That last one is the contract: ads are **fail-open**. No ad must never mean no
report.

### Production test (release build, real IDs)

- [ ] Install the signed release build
- [ ] Export a report
- [ ] A real ad appears, or none does — both are acceptable outcomes
- [ ] **The app does not crash on launch** — this is the check that matters most,
      because a malformed Android App ID crashes at process start, before Dart

⚠️ **Do not click your own live ads.** Self-clicking is an AdMob policy violation
and can suspend the account. To test with real units, register the device as a
[test device](https://developers.google.com/admob/android/test-ads) in AdMob so
it serves test ads through your production unit IDs.

## Expected outcomes

| Observation | Meaning |
|---|---|
| App launches, no ad on export | Not configured, or no fill. Check the manifest/plist first. |
| App crashes on **every** launch | Malformed Android App ID reached the manifest. Should have failed the build — investigate the gate. |
| Test ad in a release build | A test identifier was supplied. Treated as unconfigured by Dart, so this should be impossible — investigate. |
| Report fails when the ad fails | **Bug.** Ads are fail-open; the coordinator must generate the report regardless. |

## No ads after everything looks right

Almost always one of these, in order of likelihood:

1. **Payments/tax setup incomplete** in AdMob — no serving, silently.
2. **New ad unit** — units can take hours to begin serving.
3. **No fill** for the region or at that moment. Normal; not a defect.
