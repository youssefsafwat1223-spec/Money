# AdMob Build Configuration

The four values, where each one has to arrive, and why some travel two paths.

## The four inputs

| Variable | Shape | Example (Google TEST value) |
|---|---|---|
| `ADMOB_APP_ID_IOS` | `ca-app-pub-{16}~{10}` | `ca-app-pub-3940256099942544~1458002511` |
| `ADMOB_APP_ID_ANDROID` | `ca-app-pub-{16}~{10}` | `ca-app-pub-3940256099942544~3347511713` |
| `ADMOB_INTERSTITIAL_IOS` | `ca-app-pub-{16}/{10}` | `ca-app-pub-3940256099942544/4411468910` |
| `ADMOB_INTERSTITIAL_ANDROID` | `ca-app-pub-{16}/{10}` | `ca-app-pub-3940256099942544/1033173712` |

**App IDs use `~`. Ad unit IDs use `/`.** The values above are Google's public
samples — safe to read, never billable, and explicitly rejected in a release build.

Set all four in the Codemagic **`supabase`** variable group (the group every
build workflow already loads). They are not secret, but they are deployment
configuration and do not belong in source.

## Why App IDs travel two paths

The **ad unit** IDs are only needed by Dart. The **App IDs** are needed by both
Dart *and* the native SDK, so each App ID must reach two places in a release
build.

### iOS

`Info.plist` holds no literal — it references a build setting:

```xml
<key>GADApplicationIdentifier</key>
<string>$(ADMOB_APP_ID)</string>
```

`ADMOB_APP_ID` resolves in `Runner.xcodeproj/project.pbxproj`:

| Configuration | Value |
|---|---|
| Debug / Profile | `ca-app-pub-3940256099942544~1458002511` (Google TEST) |
| Release | `$(ADMOB_APP_ID_IOS)` |

CI supplies it by writing an xcconfig before the build — `codemagic.yaml`
`ios-signed-release`:

```bash
if [ -n "${ADMOB_APP_ID_IOS:-}" ]; then
  printf 'ADMOB_APP_ID_IOS=%s\n' "$ADMOB_APP_ID_IOS" > ios/Flutter/AdMob.xcconfig
else
  echo "No ADMOB_APP_ID_IOS provided — building with ads unconfigured (fail closed)."
fi
```

…and the same value again as a dart-define, alongside the interstitial:

```
--dart-define=ADMOB_APP_ID_IOS="${ADMOB_APP_ID_IOS:-}"
--dart-define=ADMOB_INTERSTITIAL_IOS="${ADMOB_INTERSTITIAL_IOS:-}"
```

### Android

The manifest references a placeholder:

```xml
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="${admobAppId}" />
```

`build.gradle.kts` resolves it via `admobAppIdFor(isRelease)`:

- **Debug** — always the Google TEST id.
- **Release** — `System.getenv("ADMOB_APP_ID_ANDROID")`, falling back to the
  Gradle property of the same name.
- **Absent in release** — keeps the *valid* sample id so the manifest stays
  valid and the app still launches; Dart then reports "not configured" and no ad
  is requested.
- **Malformed in release** — **the build fails.** See
  [`safety_model.md`](safety_model.md).

Plus the dart-defines in `codemagic.yaml` `android-release`:

```
--dart-define=ADMOB_APP_ID_ANDROID="${ADMOB_APP_ID_ANDROID:-}"
--dart-define=ADMOB_INTERSTITIAL_ANDROID="${ADMOB_INTERSTITIAL_ANDROID:-}"
```

## Local release build

```bash
cd app
flutter build apk --release \
  --dart-define=ADMOB_APP_ID_ANDROID=ca-app-pub-XXXXXXXXXXXXXXXX~XXXXXXXXXX \
  --dart-define=ADMOB_INTERSTITIAL_ANDROID=ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX
```

For Android the App ID must also be visible to Gradle, so export it first:

```bash
export ADMOB_APP_ID_ANDROID=ca-app-pub-XXXXXXXXXXXXXXXX~XXXXXXXXXX
```

Otherwise the manifest keeps the sample id and Dart reports not-configured —
a silent no-ads build rather than an error.

## Source of truth

| Concern | File |
|---|---|
| Resolution + validation | `app/lib/features/report_ads/report_ads_build_config.dart` |
| iOS plist reference | `app/ios/Runner/Info.plist` |
| iOS build setting | `app/ios/Runner.xcodeproj/project.pbxproj` |
| Android resolution | `app/android/app/build.gradle.kts` |
| Android manifest | `app/android/app/src/main/AndroidManifest.xml` |
| CI | `codemagic.yaml` |
