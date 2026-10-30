import java.util.Properties
import java.io.FileInputStream
plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
android {
    namespace = "com.zenocta.duomusicplayer"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zenocta.duomusicplayer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ffmpeg_kit_flutter_new_audio (4D/8D audio conversion) requires API 24+.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // Only set real signing values when key.properties exists (it's
            // gitignored, so a fresh clone/CI checkout won't have it) — this
            // is a config-time block Gradle evaluates for every build type,
            // debug included, so casting a missing property straight to
            // String crashed `flutter build apk --debug` too, not just
            // release. Falls back to Gradle's default (unsigned) release
            // config when absent; identical behavior to before whenever
            // key.properties is present.
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            // Lets a debug build install beside the Play Store release (which
            // is signed with a different key) instead of replacing its data.
            applicationIdSuffix = ".dev"
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            signingConfig = signingConfigs.getByName("release")

            // R8 code/resource shrinking for release builds — reduces method count,
            // APK size and steady-state memory use. Debug builds are left untouched.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Duo Mode (DuoEngine.kt) runs its own pair of ExoPlayers with a custom
    // per-ear audio processor. Pinned to the same Media3 version just_audio
    // 0.10.5 already bundles, so this adds no new code to the APK.
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    // Chromecast (CastHelper.kt): Cast SDK + MediaRouter for device discovery.
    implementation("com.google.android.gms:play-services-cast-framework:22.1.0")
    implementation("androidx.mediarouter:mediarouter:1.7.0")
    testImplementation("junit:junit:4.13.2")
}
