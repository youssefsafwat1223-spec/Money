# V1 Android Build — 2026-09-17

**Status: BUILDS.** `✓ Built build/app/outputs/flutter-apk/app-debug.apk` (207 MB
debug APK, 2026-09-17 05:08).

This is the first time the Android target has been built in this project. It had
never been attempted, so "Android compatibility" was unknown rather than
working — the distinction matters, because two real environment defects were in
the way and neither would have been visible without trying.

## What was actually broken

**1. `sdkmanager` could not find a Java runtime.**

`android/build.gradle.kts:19` shells out to `sdkmanager` during project
configuration. The failure it produced was opaque:

```
> org.gradle.process.ProcessExecutionException: Process
  '.../cmdline-tools/latest/bin/sdkmanager' finished with non-zero exit value 1
```

Running the same binary by hand gave the real reason:

```
The operation couldn't be completed. Unable to locate a Java Runtime.
```

`JAVA_HOME` was unset and no `java` was on `PATH`. Gradle itself was fine — it
uses the JDK Flutter hands it — but the `sdkmanager` subprocess inherits the
shell environment, and that had no JDK. Android Studio's bundled JDK 25 was
present the whole time at
`/Applications/Android Studio.app/Contents/jbr/Contents/Home`.

**Fix (environment, not code):** export `JAVA_HOME` to that path before
building. Nothing in the repository needed changing.

**2. The NDK download kept failing, leaving a stub that forced a refetch.**

After the JDK fix, configuration got as far as downloading NDK
`28.2.13676358` (~600 MB) and died at ~21% with `Connection reset`. It then
left `~/Library/Android/sdk/ndk/28.2.13676358/` containing nothing but a
`.installer/.installData` marker — enough for the directory to exist, not
enough to be usable — so every subsequent build started the download again.

Three `sdkmanager` attempts failed the same way. Gradle's own downloader, given
a long enough window, completed it: 2.8 GB on disk, after which it also
installed CMake 3.22.1 and the build finished.

**If this recurs:** delete the stub directory first
(`rm -rf ~/Library/Android/sdk/ndk/28.2.13676358`), then let `flutter build apk`
do the fetch rather than `sdkmanager`.

## One real code error, caught by the Android compiler

The first build that got past configuration failed at
`:app:compileFlutterBuildDebug`:

```
lib/features/planning_sync/planning_conflicts_sheet.dart:58:25:
Error: The getter 'l10n' isn't defined for the type 'BuildContext'.
```

That was a missing import in localization work in flight at the time, not an
Android-specific defect — the iOS analyzer would have caught the same thing.
Recorded because it is the only compile error the Android target has produced.

## What this does and does not establish

| Claim | Status |
|---|---|
| The project configures and compiles for Android | **PROVEN** — debug APK produced |
| The Dart/Flutter code is Android-compatible at compile time | **PROVEN** |
| Native plugin deps resolve for Android (NDK + CMake) | **PROVEN** |
| The app RUNS correctly on an Android device or emulator | **NOT PROVEN** — no emulator started, no smoke test run |
| Release build / signing | **NOT ATTEMPTED** — `key.properties` is the owner's |
| SMS capture on Android | **NOT APPLICABLE TO THIS BUILD** — the capture path is the iOS Shortcuts automation; the Android equivalent is a separate feature |
| Google Play submission | **DEFERRED** by standing instruction |

A build is not a smoke test. Nothing here says the app behaves correctly on
Android; it says the code compiles and packages for it, which was previously
unknown.

## Reproducing

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"
cd app && flutter build apk --debug
```

First run needs ~2.8 GB of NDK and a tolerant network; later runs are cached.
