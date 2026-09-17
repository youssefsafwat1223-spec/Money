# Android runtime — what was repaired, and what actually ran

Audit item 39. Previously **NOT DONE**: "no AVD and no system image
installed", with a note that `sdkmanager --list_installed` reported the image
present while `~/Library/Android/sdk/system-images` did not exist, so
`--install` was a no-op exiting 0.

That note described the symptom correctly and the cause wrongly. Both are
below, because the wrong diagnosis is the more useful record.

## The environment defects, in the order they appeared

### 1. Two SDK roots

`sdkmanager` was reporting a system image as installed that was not in the SDK
Flutter uses. Running it with an explicit `--sdk_root` made the phantom
disappear:

```
$ sdkmanager --list_installed                      # system image present
$ sdkmanager --list_installed --sdk_root=~/Library/Android/sdk   # absent
```

There are **two Android SDK roots on this machine**:

| Root | What it is |
|---|---|
| `~/Library/Android/sdk` | Android Studio's, and the one Flutter uses |
| `/opt/homebrew/share/android-commandlinetools` | a Homebrew cask |

The tools resolved to the Homebrew root by default. It was not a stale record;
it was a truthful record *of a different SDK*. (`$PATH` also still carried
`/usr/local/share/android-commandlinetools/platform-tools`, which does not
exist at all — a third, dead root.)

### 2. `sdkmanager` has no Java of its own

`sdkmanager` failed with "Unable to locate a Java Runtime". `JAVA_HOME` was
unset and there is no system JDK. Android Studio ships one:

```
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
```

### 3. The download keeps being reset, and leaves a stub

`sdkmanager` reached 25% and died with `Connection reset` — the same failure
class that had already cost the NDK download earlier in this programme. It
left a half-created directory that made the next attempt believe the package
was installed.

Fixed by not using `sdkmanager` for the transfer. `curl -C -` with retries
resumed across **twelve** rounds (several of which hit a 15-minute ceiling
mid-stream) and completed all 1.78 GB intact, verified with `unzip -t`. The
image was then unpacked into the SDK layout and given a hand-written
`package.xml` matching its `source.properties`, after which `sdkmanager`
reports it correctly.

### 4. `PUB_CACHE` points at an unmounted volume

`flutter build` failed with
`Creation failed, path = '/Volumes/shared' (OS Error: Permission denied)`.
`~/.zshrc` exports `PUB_CACHE=/Volumes/shared/flutter-cache/pub-cache`, which
is not mounted. The packages are actually in `~/.pub-cache`, which is what
`.dart_tool/package_config.json` resolves to — so `--no-pub` worked and a real
build did not. Every Android build here sets `PUB_CACHE=$HOME/.pub-cache`.

This is a **machine setting, not a repo problem**, and it is the third such
one found (see `~/.qirsh-qa/env.sh`, which already documents `PUB_CACHE` and
`TMPDIR` pointing at a previous account's home).

## The black screen that was not a defect

With the emulator on `-gpu swiftshader_indirect`, `adb exec-out screencap`
returned a **pure black frame** for the running app — verified by decoding the
PNG and sampling it, not by eye. The native splash captured fine.

That is not the app. Flutter renders into a `SurfaceView`, which `screencap`
cannot read. It is the same constraint that makes
`IntegrationTestWidgetsFlutterBinding.convertFlutterSurfaceToImage()` exist,
and it is why `bilingual_walk_test` now calls it on Android before taking a
screenshot.

The runtime evidence contradicts the screenshot, and the runtime evidence is
the one that reads the widget tree:

```
[QA] J1 first frame OK
[QA] J2 no ErrorWidget
[QA] J3 screen text (9): متحمّسين
[QA] J4 tappables: 5
[QA] J5 nav bars: 0
[QA] J6 scrollables: 2
[QA] J7 layout exception: none
[QA] J8 tapped primary control; surface changed: true
```

Switching the emulator to `-gpu host` (Apple M1) also made the capture work,
which confirms the diagnosis from the other direction.

## A second false alarm worth recording

After `flutter test -d emulator-5554` ran, the app appeared to hang at launch:
engine loaded, VM service listening, and no bootstrap line ever printed.

`flutter test` installs a bundle whose Dart entrypoint is the **test file**,
under the same package id. Launching that by hand starts a test host waiting
for a driver that is not coming. Reinstalling the real debug APK resolved it.
Nothing was wrong with the app.

## What actually ran on Android

Emulator: Pixel 6, **Android 15 (API 35)**, `google_apis`, `arm64-v8a`, host
GPU.

| Evidence | Result |
|---|---|
| Debug APK built | ✓ (`app-debug.apk`) |
| Installed and launched | ✓ `topResumedActivity=com.youssefsafwat.mali/.MainActivity` |
| Full bootstrap | ✓ all 16 steps, `done — session=needsOnboarding` |
| **SQLCipher database opened on Android** | ✓ `database_open ok (12647ms)` |
| Catalog seeding | ✓ currencies, countries seeded; banks/parsers/categories already present |
| `runtime_smoke_test` | ✓ PASS — 9 Text widgets, 5 tappables, no `ErrorWidget`, no layout exception, tap changed the surface |
| Real Supabase sign-in + demo seed | ✓ PASS |
| **`bilingual_walk_test` — 19 routes × 2 languages** | ✓ PASS, direction asserted on every route |
| Localization parity with iOS | ✓ identical: 8/19 routes, 13 on `/`, every survivor user data |

The bilingual walk passing on Android is the substantive result. It is not a
smoke test: it drives every V1 route in both languages, asserts text direction
on each, and reads back the strings on screen.

## What Android runtime does NOT prove

* **SMS capture.** `android_sms_capture_service.dart` needs the `RECEIVE_SMS`
  permission and a real message from a real sender. Not exercised.
* **Notification delivery and the channel names as the OS renders them.** See
  `V1_ANDROID_NOTIFICATION_CHANNELS.md` — the id/name wiring is asserted, the
  Settings list has not been read off a screen.
* **Release signing.** Owner's `key.properties`. Blocked, and unchanged.
* **Play Store.** Deferred by standing instruction.
* **Anything about a physical Android device.** An emulator on host GPU is not
  a phone.

## Reproducing

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PUB_CACHE="$HOME/.pub-cache"          # ~/.zshrc points at /Volumes/shared

$ANDROID_SDK_ROOT/emulator/emulator -avd qirsh_qa_a35 \
    -no-snapshot -no-audio -no-boot-anim -gpu host -memory 4096 -cores 4 &

flutter test -d emulator-5554 \
    --dart-define-from-file=$HOME/.qirsh-qa/qa_run_defines.json \
    integration_test/bilingual_walk_test.dart
```

The AVD `qirsh_qa_a35` exists on this machine. `-gpu host` matters: under
software rendering the emulator hit `detected a hanging thread 'QEMU2 CPU0'`
and the integration test died with `VmServiceDisappearedException`.
