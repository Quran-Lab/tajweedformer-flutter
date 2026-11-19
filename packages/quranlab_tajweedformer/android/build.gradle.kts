group = "ai.quranlab.tajweedformer.flutter"
version = "4.0.0"

// The Android SDK this plugin wraps, from Maven Central, through its public API only. EXACTLY this version: the
// plugin is built and tested against it. Change it only together with a build and the plugin's tests against the new
// version.
val tajweedformerVersion = "4.0.0"

// A local Maven folder that holds ai.quranlab:tajweedformer before Maven Central does (a release candidate built with
// the Core's production release, or CI's build with the Core's test release): QURANLAB_MAVEN=<folder> or
// -Pquranlab.maven=<folder>. Only Quran Lab's group is taken from it. Unset: Maven Central.
val quranlabMaven: String? = (findProperty("quranlab.maven") as String?) ?: System.getenv("QURANLAB_MAVEN")?.takeIf { it.isNotBlank() }

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

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

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
    implementation("ai.quranlab:tajweedformer:$tajweedformerVersion")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.7.3")
}
