allprojects {
    repositories {
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

// Third-party plugins without `namespace` (required by AGP 8+): patch from AndroidManifest package.
subprojects {
    plugins.withId("com.android.library") {
        val androidExt = extensions.findByName("android") ?: return@withId
        val requiredNs =
            when (name) {
                "isar_flutter_libs" -> "dev.isar.isar_flutter_libs"
                "tdlib" -> "org.naji.td.tdlib"
                else -> null
            } ?: return@withId
        try {
            val getNs = androidExt.javaClass.getMethod("getNamespace")
            val current = getNs.invoke(androidExt) as? String
            if (current.isNullOrEmpty()) {
                val setNs = androidExt.javaClass.getMethod("setNamespace", String::class.java)
                setNs.invoke(androidExt, requiredNs)
            }
        } catch (_: Exception) {
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
