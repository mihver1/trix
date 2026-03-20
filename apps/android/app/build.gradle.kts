import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val workspaceDir = rootProject.projectDir.parentFile.parentFile
val trixCoreCrateDir = File(workspaceDir, "crates/trix-core")
val trixCoreUniffiConfig = File(trixCoreCrateDir, "uniffi.toml")
val trixAndroidNdkVersion = "29.0.14206865"
val generatedUniffiDir = layout.buildDirectory.dir("generated/source/uniffi/main")
val generatedJniLibsDir = layout.buildDirectory.dir("generated/jniLibs/main")

fun loadLocalProperty(name: String): String? {
    val localPropertiesFile = rootProject.file("local.properties")
    if (!localPropertiesFile.exists()) {
        return null
    }

    val properties = Properties()
    localPropertiesFile.inputStream().use(properties::load)
    return properties.getProperty(name)
}

fun hostRustLibraryName(): String {
    val osName = System.getProperty("os.name").lowercase()
    return when {
        osName.contains("mac") -> "libtrix_core.dylib"
        osName.contains("win") -> "trix_core.dll"
        else -> "libtrix_core.so"
    }
}

val androidSdkRoot = providers.environmentVariable("ANDROID_SDK_ROOT")
    .orElse(providers.environmentVariable("ANDROID_HOME"))
    .orElse(loadLocalProperty("sdk.dir") ?: "")
    .get()
val androidNdkRoot = File(androidSdkRoot, "ndk/$trixAndroidNdkVersion")
val hostRustLibrary = File(workspaceDir, "target/debug/${hostRustLibraryName()}")

val trixBaseUrl = providers.gradleProperty("trixBaseUrl")
    .orElse(providers.environmentVariable("TRIX_BASE_URL"))
    .orElse("http://10.0.2.2:8080")
    .get()
    .trimEnd('/')

android {
    namespace = "chat.trix.android"
    compileSdk = 36
    ndkVersion = trixAndroidNdkVersion

    defaultConfig {
        applicationId = "chat.trix.android"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("String", "TRIX_BASE_URL", "\"$trixBaseUrl\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.setSrcDirs(listOf(generatedJniLibsDir.get().asFile))
        }
    }
}

val buildTrixCoreHostLib by tasks.registering(Exec::class) {
    workingDir = workspaceDir
    commandLine("cargo", "build", "-p", "trix-core", "--lib")
    outputs.file(hostRustLibrary)
}

val generateTrixCoreKotlinBindings by tasks.registering(Exec::class) {
    dependsOn(buildTrixCoreHostLib)
    workingDir = workspaceDir
    val outDir = generatedUniffiDir.get().asFile
    inputs.file(trixCoreUniffiConfig)
    outputs.dir(outDir)
    doFirst {
        outDir.deleteRecursively()
        outDir.mkdirs()
    }
    commandLine(
        "cargo",
        "run",
        "-p",
        "trix-core",
        "--bin",
        "uniffi-bindgen",
        "--",
        "generate",
        hostRustLibrary.absolutePath,
        "--language",
        "kotlin",
        "--no-format",
        "--out-dir",
        outDir.absolutePath,
        "--config",
        trixCoreUniffiConfig.absolutePath,
    )
}

val buildTrixCoreAndroidLibs by tasks.registering(Exec::class) {
    notCompatibleWithConfigurationCache("Uses local cargo-ndk/NDK toolchain state")
    workingDir = workspaceDir
    val outDir = generatedJniLibsDir.get().asFile
    outputs.dir(outDir)
    doFirst {
        if (!androidNdkRoot.exists()) {
            error("Android NDK $trixAndroidNdkVersion is not installed under $androidNdkRoot")
        }
        outDir.deleteRecursively()
        outDir.mkdirs()
    }
    environment("ANDROID_HOME", androidSdkRoot)
    environment("ANDROID_SDK_ROOT", androidSdkRoot)
    environment("ANDROID_NDK_HOME", androidNdkRoot.absolutePath)
    environment("ANDROID_NDK_ROOT", androidNdkRoot.absolutePath)
    commandLine(
        "cargo",
        "ndk",
        "--platform",
        "28",
        "-t",
        "arm64-v8a",
        "-t",
        "x86_64",
        "-o",
        outDir.absolutePath,
        "build",
        "-p",
        "trix-core",
        "--lib",
    )
}

tasks.named("preBuild") {
    dependsOn(buildTrixCoreAndroidLibs)
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.03.00")

    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("com.google.android.material:material:1.12.0")
    implementation("net.java.dev.jna:jna:5.18.1")
    implementation("androidx.window:window:1.5.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
