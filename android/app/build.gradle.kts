import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// CI: set OXPLAYER_RELEASE_STORE_FILE (+ passwords/alias) to sign release with a distinct key.
// Local release without these falls back to debug keystore (same as before).
val oxplayerReleaseStorePath = System.getenv("OXPLAYER_RELEASE_STORE_FILE")
val oxplayerUseCiReleaseSigning =
    !oxplayerReleaseStorePath.isNullOrBlank() && file(oxplayerReleaseStorePath).isFile

val keyProperties = Properties()
val keyPropertiesFile = rootProject.file("key.properties")
if (keyPropertiesFile.exists()) {
    keyPropertiesFile.inputStream().use { keyProperties.load(it) }
}

val localReleaseKeystoreConfigured =
    keyPropertiesFile.exists() &&
        keyProperties.getProperty("storeFile") != null &&
        rootProject.file(keyProperties.getProperty("storeFile")).isFile

android {
    namespace = "de.aryanmo.oxplayer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "de.aryanmo.oxplayer"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

    }

    signingConfigs {
        if (oxplayerUseCiReleaseSigning) {
            val storePath = requireNotNull(oxplayerReleaseStorePath)
            create("ciRelease") {
                storeFile = file(storePath)
                storeType = "PKCS12"
                storePassword = System.getenv("OXPLAYER_RELEASE_STORE_PASSWORD").orEmpty()
                keyAlias = System.getenv("OXPLAYER_RELEASE_KEY_ALIAS").orEmpty()
                keyPassword = System.getenv("OXPLAYER_RELEASE_KEY_PASSWORD").orEmpty()
            }
        }
        if (localReleaseKeystoreConfigured) {
            create("localRelease") {
                storeFile = rootProject.file(keyProperties.getProperty("storeFile")!!)
                storePassword = keyProperties.getProperty("storePassword")!!
                keyAlias = keyProperties.getProperty("keyAlias")!!
                keyPassword = keyProperties.getProperty("keyPassword")!!
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            signingConfig = when {
                oxplayerUseCiReleaseSigning -> signingConfigs.getByName("ciRelease")
                localReleaseKeystoreConfigured -> signingConfigs.getByName("localRelease")
                else -> signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-ui:1.4.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
}

flutter {
    source = "../.."
}
