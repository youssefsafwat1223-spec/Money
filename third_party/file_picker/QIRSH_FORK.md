# Vendored fork — `file_picker`

**This is NOT an official upstream release.** It is a Qirsh-maintained fork of a
published version, carrying one backported fix. Treat it as temporary.

## Provenance

| | |
|---|---|
| Upstream package | `file_picker` (pub.dev) |
| Upstream base | **11.0.3** — the latest 11.x line |
| Base source | verbatim copy of the published `file_picker-11.0.3` pub archive |
| Vendored on | 2026-08-23 (R8B) |
| Upstream fix reference | the AGP-9 registration fix shipped in the file_picker **12** line — `android_file_picker 1.0.1`, `android/build.gradle.kts` |

### Why 11.0.3 and not 12.0.0

`file_picker` 12 fixes the same defect, but its dependency graph forces
`win32 ^6`, which cascades into two further major upgrades:

* `share_plus` 10.1.4 → **13.x** (first release on `win32 ^6`), which **removes**
  the `Share.*` static API used in three Qirsh call sites — including the
  report-sharing path that was physically verified on device.
* `flutter_secure_storage` 9.2.4 → **10.x** (needs `flutter_secure_storage_windows`
  ≥ 4.2.0 for `win32 ^6`) — the layer that stores the **SQLCipher database key**
  and the device secret.

A `dependency_overrides: win32: ^6.3.0` shortcut was tested and **proved
non-viable**: `flutter_secure_storage_windows 3.1.2` fails to compile against
win32 6.4.0 with 10+ errors, and because Dart's `kernel_snapshot` compiles the
whole package graph, that breaks the **Android** build too — "Windows isn't
shipped" does not save it.

So the smallest safe change is to fix the one package that is actually broken.

### Not vendored (subtractive only, no shipped code altered)

`example/` (17 MB), `test/` (3.9 MB) and `tool/` are upstream development assets
that pub does not need to consume the package. Everything pub resolves — `lib/`,
`android/`, `ios/`, `macos/`, `pubspec.yaml`, `LICENSE` — is present verbatim
apart from the patch below.

## The Qirsh backport

**One file changed beyond upstream: `android/build.gradle`** (plus this document).

Upstream 11.0.3 asked only whether AGP is ≥ 9 and, if so, skipped applying the
Kotlin plugin — assuming AGP 9's *built-in Kotlin* would compile the sources:

```groovy
def isAgp9OrAbove = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION
        .tokenize('.')[0].toInteger() >= 9
apply plugin: 'com.android.library'
if (!isAgp9OrAbove) { apply plugin: 'org.jetbrains.kotlin.android' }
```

Built-in Kotlin is gated on the `android.builtInKotlin` Gradle property, and the
Flutter template sets **`android.builtInKotlin=false`** (see
`app/android/gradle.properties`). With the property false *and* the Kotlin plugin
skipped, nothing compiles `FilePickerPlugin.kt`, so every Android build fails at
`:app:compileDebugJavaWithJavac`:

```
GeneratedPluginRegistrant.java:24: error: cannot find symbol
  flutterEngine.getPlugins().add(new com.mr.flutter.plugin.filepicker.FilePickerPlugin());
  symbol: class FilePickerPlugin
```

The backport adopts upstream's corrected condition — consult the property, and
apply the Kotlin plugin whenever built-in Kotlin is not actually in effect:

```groovy
def agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.tokenize('.')[0].toInteger()
def builtInKotlinProperty = providers.gradleProperty("android.builtInKotlin").orNull
def isBuiltInKotlinEnabled = agpMajor >= 9 &&
        (builtInKotlinProperty == null || builtInKotlinProperty.toBoolean())
def shouldApplyKotlinAndroidPlugin = agpMajor < 9 || !isBuiltInKotlinEnabled
```

Used at two sites: applying `org.jetbrains.kotlin.android`, and setting
`kotlinOptions.jvmTarget`. **Nothing else was taken from the 12 line** — no win32
migration, no federated restructuring, no new APIs, no iOS 14 work, no SAF
changes, no `saveFile` changes, no dependency bumps.

## Security

The base is **11.0.3**, which is *newer* than the 11.0.2 the app previously used,
so the 11.0.2 path-traversal fix is retained — the backport is an upgrade, never a
downgrade. The patch touches only Gradle plugin-application logic; no Android
path-resolution or file-handling code was modified.

## Removal condition

Remove this fork only when **either**:

* upstream publishes an **11.x** release containing the AGP-9 registration fix, **or**
* Qirsh deliberately performs the larger migration (file_picker 12 + share_plus 13
  + flutter_secure_storage 10), including re-verification of report sharing on a
  physical device and of the backup/restore crypto path.

In both cases the Android **and** iOS regression gates must pass before the fork
is dropped.

## Keeping the fork honest

`app/test/architecture/vendored_file_picker_test.dart` re-diffs this tree against
the pristine 11.0.3 pub archive when it is available locally, and fails if
anything beyond `android/build.gradle` and this document has drifted.
