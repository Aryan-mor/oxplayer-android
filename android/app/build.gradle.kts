import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// CI: set TELE_CIMA_RELEASE_STORE_FILE (+ passwords/alias) to sign release with a distinct key.
// Local release without these falls back to debug keystore (same as before).
val teleCimaReleaseStorePath = System.getenv("TELE_CIMA_RELEASE_STORE_FILE")
val teleCimaUseCiReleaseSigning =
    !teleCimaReleaseStorePath.isNullOrBlank() && file(teleCimaReleaseStorePath).isFile

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
    namespace = "com.example.tele_cima"
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
        applicationId = "com.example.tele_cima"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

    }

    signingConfigs {
        if (teleCimaUseCiReleaseSigning) {
            val storePath = requireNotNull(teleCimaReleaseStorePath)
            create("ciRelease") {
                storeFile = file(storePath)
                storePassword = System.getenv("TELE_CIMA_RELEASE_STORE_PASSWORD").orEmpty()
                keyAlias = System.getenv("TELE_CIMA_RELEASE_KEY_ALIAS").orEmpty()
                keyPassword = System.getenv("TELE_CIMA_RELEASE_KEY_PASSWORD").orEmpty()
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
                teleCimaUseCiReleaseSigning -> signingConfigs.getByName("ciRelease")
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
}

flutter {
    source = "../.."
}
