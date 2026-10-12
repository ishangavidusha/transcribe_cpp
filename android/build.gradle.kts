group = "com.transcribecpp.transcribe_cpp"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// The engine is not in git. tool/build_android.sh builds it into jniLibs/, and
// the package on pub.dev carries it. Without it the app would build and then
// fail at the first transcription, so say so here instead.
val engine = file("src/main/jniLibs/arm64-v8a/libtranscribe.so")
if (!engine.exists()) {
    throw GradleException(
        "transcribe_cpp: the Android engine is missing (${engine.path}). " +
            "Run tool/build_android.sh in the plugin, or depend on the " +
            "package from pub.dev, which includes it.",
    )
}

android {
    namespace = "com.transcribecpp.transcribe_cpp"

    compileSdk = 36

    // The app's NDK. Only this package's own C is compiled here; the engine
    // ships prebuilt in src/main/jniLibs (see tool/build_android.sh).
    ndkVersion = android.ndkVersion

    externalNativeBuild {
        cmake {
            path = file("../src/CMakeLists.txt")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        // Matches ANDROID_PLATFORM in tool/build_android.sh.
        minSdk = 24

        // Merged into the app's shrinker configuration, whatever the app's
        // own rules are.
        consumerProguardFiles("consumer-rules.pro")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
