import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties
import java.nio.file.Files
import java.nio.file.Path

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties: Properties = Properties()
val localPropertiesFile: Path = rootProject.file("local.properties").toPath()
if (Files.exists(localPropertiesFile)) {
    Files.newBufferedReader(localPropertiesFile).use { reader ->
        localProperties.load(reader)
    }
}

val flutterRoot: String = localProperties.getProperty("flutter.sdk")
    ?: throw GradleException("Flutter SDK not found. Define location with flutter.sdk in the local.properties file.")

val flutterVersionCode: String = localProperties.getProperty("flutter.versionCode") ?: "1"
val flutterVersionName: String = localProperties.getProperty("flutter.versionName") ?: "1.0"

android {
    namespace = "com.it_nomads.fluttersecurestorageexample"

    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget = JvmTarget.JVM_17
        }
    }

    sourceSets {
        named("main") {
            java.srcDir("src/main/kotlin")
        }
        named("androidTest") {
            // Run the plugin fixture in this modern-targeted test APK too.
            java.srcDir("../../../android/src/androidTest/java")
        }
    }

    defaultConfig {
        // Deliberately distinct from all Mornye/MUSA application IDs.
        applicationId = "org.mornye.experimental.securestorage"
        testApplicationId = "org.mornye.experimental.securestorage.test"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        minSdk = 23
        targetSdk = 36
        versionCode = flutterVersionCode.toInt()
        versionName = flutterVersionName
    }

    buildTypes {
        getByName("release") {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // integration_test contributes older AndroidX test artifacts to the debug
    // runtime. Align both configurations before AGP applies tested-app strict
    // version constraints to the instrumentation APK.
    debugImplementation("androidx.test:runner:1.7.0")
    debugImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}

flutter {
    source = "../.."
}
