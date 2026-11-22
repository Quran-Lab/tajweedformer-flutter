// The plugin's Android SDK from a local Maven folder before Maven Central has it (the plugin's build file says when):
// the app resolves it too, so the folder is named here as well.
val quranlabMaven: String? = (findProperty("quranlab.maven") as String?) ?: System.getenv("QURANLAB_MAVEN")?.takeIf { it.isNotBlank() }
// The same for a release candidate's AAR file (QURANLAB_AAR, the plugin's build file says when): its folder.
val quranlabAar: String? = (findProperty("quranlab.aar") as String?) ?: System.getenv("QURANLAB_AAR")?.takeIf { it.isNotBlank() }

allprojects {
    repositories {
        quranlabAar?.let { aar -> flatDir { dirs(File(aar).absoluteFile.parentFile) } }
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

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
