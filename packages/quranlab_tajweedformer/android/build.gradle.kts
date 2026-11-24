group = "ai.quranlab.tajweedformer.flutter"
version = "4.0.4"

// The Android SDK this plugin wraps, from Maven Central, through its public API only. EXACTLY this version: the
// plugin is built and tested against it. Change it only together with a build and the plugin's tests against the new
// version.
val tajweedformerVersion = "4.0.2"

// A local Maven folder that holds ai.quranlab:tajweedformer before Maven Central does (a release candidate built with
// the Core's production release, or CI's build with the Core's test release): QURANLAB_MAVEN=<folder> or
// -Pquranlab.maven=<folder>. Only Quran Lab's group is taken from it. Unset: Maven Central.
val quranlabMaven: String? = (findProperty("quranlab.maven") as String?) ?: System.getenv("QURANLAB_MAVEN")?.takeIf { it.isNotBlank() }

// A release candidate's AAR file, built from tajweedformer-sdk-android before it has a version of its own on Maven
// Central (CI's unpublished build, or a local one): QURANLAB_AAR=<file> or -Pquranlab.aar=<file>. It replaces
// ai.quranlab:tajweedformer under its file name only, never under Maven coordinates, so no cache ever holds it as a
// released version; the SDK's own dependencies (those its POM names) are listed below. Unset: the version above.
val quranlabAar: File? = ((findProperty("quranlab.aar") as String?) ?: System.getenv("QURANLAB_AAR")?.takeIf { it.isNotBlank() })
    ?.let { File(it).absoluteFile }

buildscript {
    val kotlinVersion = "2.4.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.3.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        quranlabAar?.let { aar -> flatDir { dirs(aar.parentFile) } }
        quranlabMaven?.let { folder ->
            maven {
                url = uri(file(folder))
                content { includeGroup("ai.quranlab") }
            }
        }
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "ai.quranlab.tajweedformer.flutter"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // No sourceSets block: src/main/kotlin and src/test/kotlin are the default source folders (AGP's built-in Kotlin
    // and the Kotlin plugin both use them). Flutter's plugin template had one, written against the AGP on the
    // buildscript classpath above (9.3.1); in an app on AGP older than 9.2 it threw a ClassCastException
    // (DefaultAndroidSourceSet_Decorated to AndroidLibrarySourceSet, a 9.2 type) while configuring (4.0.0 to 4.0.3).
    // tool/agp_matrix.py says how CI checks it.

    defaultConfig {
        // the SDK's own minimum (Android 8.0)
        minSdk = 26
    }

    testOptions {
        unitTests {
            isReturnDefaultValues = true
            all {
                it.useJUnitPlatform()
                it.outputs.upToDateWhen { false }
                it.testLogging {
                    events("passed", "skipped", "failed", "standardError")
                }
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
    if (quranlabAar != null) {
        check(quranlabAar.isFile) { "QURANLAB_AAR: no file at $quranlabAar" }
        implementation(":${quranlabAar.nameWithoutExtension}@aar")
        // the SDK's dependencies as its POM names them (tajweedformer-sdk-android, tajweedformer/build.gradle.kts)
        implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3")
        implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
        implementation("androidx.work:work-runtime:2.9.1")
        implementation("com.google.android.play:integrity:1.4.0")
    } else {
        implementation("ai.quranlab:tajweedformer:$tajweedformerVersion")
    }
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.7.3")
}
