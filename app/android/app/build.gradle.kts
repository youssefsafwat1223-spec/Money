import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: reads either android/key.properties (see
// android/key.properties.example for the exact format and
// docs/ANDROID_RELEASE_SIGNING.md for how to generate/store/back up the
// keystore) or the four ANDROID_KEYSTORE_* environment variables a CI runner
// can inject instead of committing the file. Never both silently fall back
// to the debug key for a release build — see the `release` build type below.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun releaseSigningValue(envName: String, propertyName: String): String? {
    val fromEnv = System.getenv(envName)
    if (!fromEnv.isNullOrBlank()) return fromEnv
    return keystoreProperties.getProperty(propertyName)
}

// AdMob application id (R7 I3/A3). Build/deployment configuration, never a
// committed literal and never a DB row. Release takes it from the environment
// (or a Gradle property); debug always uses Google's public TEST id.
//
// If a release build supplies nothing, the placeholder keeps the TEST id so the
// manifest stays valid and the app still runs — but the Dart layer
// (ReportAdsBuildConfig) then reports "not configured", so NO ad is ever
// requested. That is the fail-closed-for-ads contract: no ads, no crash, and
// never a production build quietly serving on Google's sample identifiers.
val admobTestAppIdAndroid = "ca-app-pub-3940256099942544~3347511713"

fun admobAppIdFor(isRelease: Boolean): String {
    if (!isRelease) return admobTestAppIdAndroid
    val fromEnv = System.getenv("ADMOB_APP_ID_ANDROID")
    if (!fromEnv.isNullOrBlank()) return fromEnv
    val fromProperty = project.findProperty("ADMOB_APP_ID_ANDROID") as String?
    if (!fromProperty.isNullOrBlank()) return fromProperty
    return admobTestAppIdAndroid
}

val releaseStoreFilePath = releaseSigningValue("ANDROID_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = releaseSigningValue("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = releaseSigningValue("ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = releaseSigningValue("ANDROID_KEY_PASSWORD", "keyPassword")
val hasReleaseSigningConfig = !releaseStoreFilePath.isNullOrBlank() &&
    !releaseStorePassword.isNullOrBlank() &&
    !releaseKeyAlias.isNullOrBlank() &&
    !releaseKeyPassword.isNullOrBlank()

android {
    namespace = "com.youssefsafwat.mali"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.youssefsafwat.mali"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Default (debug and any non-release variant): Google's TEST app id.
        manifestPlaceholders["admobAppId"] = admobAppIdFor(isRelease = false)
    }

    signingConfigs {
        if (hasReleaseSigningConfig) {
            create("release") {
                storeFile = file(releaseStoreFilePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Deliberately NEVER falls back to the debug key here: a release
            // build silently signed with the debug key is exactly what got a
            // real Play Store upload rejected. If no real signing config is
            // present, `signingConfig` stays null and the task-failure hook
            // below fails clearly instead.
            if (hasReleaseSigningConfig) {
                signingConfig = signingConfigs.getByName("release")
            }
            // Release resolves ADMOB_APP_ID_ANDROID from env/property; falling
            // back to the TEST id keeps the manifest valid while Dart holds ads
            // closed (see admobAppIdFor above).
            manifestPlaceholders["admobAppId"] = admobAppIdFor(isRelease = true)
        }
    }
}

if (!hasReleaseSigningConfig) {
    // Fail clearly for every task that touches the release build type
    // (assembleRelease, bundleRelease — what `flutter build apk|appbundle
    // --release` invoke) instead of letting AGP either sign with nothing or
    // fall through to some other implicit config. Debug-mode `flutter run`
    // (no --release) is unaffected — it never touches these tasks.
    tasks.configureEach {
        val releaseTask = (name.startsWith("assemble") ||
            name.startsWith("bundle") ||
            name.startsWith("package")) && name.contains("Release")
        if (releaseTask) {
            doFirst {
                throw GradleException(
                    "No release signing configuration found for task '$name'. Set " +
                        "android/key.properties (see key.properties.example) or the " +
                        "ANDROID_KEYSTORE_PATH / ANDROID_KEYSTORE_PASSWORD / " +
                        "ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD environment variables " +
                        "before building a release artifact. See " +
                        "docs/ANDROID_RELEASE_SIGNING.md for owner steps to generate, " +
                        "store, and back up the keystore."
                )
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
