import java.security.KeyStore
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.yingyu.player"
    compileSdk = 36
    buildToolsVersion = "36.0.0"
    ndkVersion = "30.0.16248370"
    ndkPath = System.getenv("YINGYU_NDK")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.yingyu.player.release"
        minSdk = 26
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    sourceSets.getByName("main").jniLibs.srcDir("../../dependencies/bluray/prebuilt")

    signingConfigs {
        create("release") {
            val path = System.getenv("YINGYU_KEYSTORE")
            val password = System.getenv("YINGYU_SIGN_PASSWORD")
            if (path != null && password != null) {
                val signingFile = file(path)
                val certificate = KeyStore.getInstance(signingFile, password.toCharArray())
                    .getCertificate("yingyu") ?: error("Missing Yingyu release certificate")
                val fingerprint = MessageDigest.getInstance("SHA-256")
                    .digest(certificate.encoded).joinToString("") { "%02x".format(it) }
                check(fingerprint == "13f64687afc61988916fb061ffa31ad88116fd62ab64404e8e1170ed2cc2fdb8") {
                    "The keystore does not match the Yingyu coexist release certificate"
                }
                storeFile = signingFile
            }
            storePassword = password
            keyAlias = "yingyu"
            keyPassword = password
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            proguardFiles("fence095-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    add("releaseImplementation", files("../../dependencies/flutter-fence/flutter-embedding-fence.jar"))
    // Exact compile dependencies from the pinned original embedding POM.
    add("releaseImplementation", "androidx.lifecycle:lifecycle-common:2.7.0")
    add("releaseImplementation", "androidx.lifecycle:lifecycle-common-java8:2.7.0")
    add("releaseImplementation", "androidx.lifecycle:lifecycle-process:2.7.0")
    add("releaseImplementation", "androidx.lifecycle:lifecycle-runtime:2.7.0")
    add("releaseImplementation", "androidx.fragment:fragment:1.7.1")
    add("releaseImplementation", "androidx.annotation:annotation:1.8.1")
    add("releaseImplementation", "androidx.tracing:tracing:1.2.0")
    add("releaseImplementation", "androidx.core:core:1.13.1")
    add("releaseImplementation", "androidx.window:window-java:1.2.0")
    add("releaseImplementation", "com.getkeepsafe.relinker:relinker:1.4.5")
    add("releaseImplementation", "androidx.exifinterface:exifinterface:1.4.1")

    implementation("com.google.mlkit:translate:17.0.3")
    // Bundled identification model: no second install-time/download dependency.
    implementation("com.google.mlkit:language-id:17.0.6")
}

// Two Java image-fence waits only; the SDK and native engine are unchanged.
configurations.configureEach {
    if (name.contains("release", ignoreCase = true)) {
        exclude(group = "io.flutter", module = "flutter_embedding_release")
    }
}
