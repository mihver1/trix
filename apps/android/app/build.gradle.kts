import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val workspaceRoot = rootProject.projectDir.parentFile.parentFile
val trixCoreCrateDir = File(workspaceRoot, "crates/trix-core")
val trixCoreUniffiConfig = File(trixCoreCrateDir, "uniffi.toml")
val trixAndroidNdkVersion = "29.0.14206865"
val generatedUniffiDir = layout.buildDirectory.dir("generated/source/uniffi/main")
val generatedJniLibsDir = layout.buildDirectory.dir("generated/jniLibs/main")
val androidStringsEn = layout.projectDirectory.file("src/main/res/values/strings.xml")
val androidStringsRu = layout.projectDirectory.file("src/main/res/values-ru/strings.xml")

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

val androidSdkRootValue = providers.environmentVariable("ANDROID_SDK_ROOT")
    .orElse(providers.environmentVariable("ANDROID_HOME"))
    .orElse(loadLocalProperty("sdk.dir") ?: "")
    .get()
val androidNdkRootDir = File(androidSdkRootValue, "ndk/$trixAndroidNdkVersion")
val skipAndroidNdkBuild = providers.gradleProperty("trixSkipAndroidNdkBuild")
    .orElse("false")
    .map { it.equals("true", ignoreCase = true) }
    .get()
val hostRustLibrary = File(workspaceRoot, "target/debug/${hostRustLibraryName()}")

val trixBaseUrlProvider = providers.gradleProperty("trixBaseUrl")
    .orElse(providers.environmentVariable("TRIX_BASE_URL"))
    .orElse("https://trix.artelproject.tech")
val trixBaseUrl = trixBaseUrlProvider
    .get()
    .trimEnd('/')
val trixInteropBaseUrl = providers.gradleProperty("trixInteropBaseUrl")
    .orElse(providers.environmentVariable("TRIX_INTEROP_BASE_URL"))
    .orElse(trixBaseUrlProvider)
    .get()
    .trimEnd('/')
val releaseStoreFileValue = providers.gradleProperty("trixReleaseStoreFile")
    .orElse(providers.environmentVariable("TRIX_RELEASE_STORE_FILE"))
    .orNull
val releaseStorePasswordValue = providers.gradleProperty("trixReleaseStorePassword")
    .orElse(providers.environmentVariable("TRIX_RELEASE_STORE_PASSWORD"))
    .orNull
val releaseKeyAliasValue = providers.gradleProperty("trixReleaseKeyAlias")
    .orElse(providers.environmentVariable("TRIX_RELEASE_KEY_ALIAS"))
    .orNull
val releaseKeyPasswordValue = providers.gradleProperty("trixReleaseKeyPassword")
    .orElse(providers.environmentVariable("TRIX_RELEASE_KEY_PASSWORD"))
    .orNull
val hasReleaseSigning = !releaseStoreFileValue.isNullOrBlank()

android {
    namespace = "chat.trix.android"
    compileSdk = 36
    ndkVersion = trixAndroidNdkVersion

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = file(releaseStoreFileValue!!)
                storePassword = releaseStorePasswordValue
                keyAlias = releaseKeyAliasValue
                keyPassword = releaseKeyPasswordValue
            }
        }
    }

    defaultConfig {
        applicationId = "chat.trix.android"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        testInstrumentationRunnerArguments["trixBaseUrl"] = trixInteropBaseUrl
        buildConfigField("String", "TRIX_BASE_URL", "\"$trixBaseUrl\"")
        buildConfigField("String", "TRIX_INTEROP_BASE_URL", "\"$trixInteropBaseUrl\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    buildTypes {
        debug {
            versionNameSuffix = "-debug"
            ndk {
                abiFilters += setOf("arm64-v8a", "x86_64")
            }
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            ndk {
                abiFilters += setOf("arm64-v8a")
                debugSymbolLevel = "FULL"
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
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
    workingDir = workspaceRoot
    commandLine("cargo", "build", "-p", "trix-core", "--lib")
    outputs.file(hostRustLibrary)
}

val generateTrixStrings by tasks.registering(Exec::class) {
    workingDir = workspaceRoot
    inputs.file(File(workspaceRoot, "strings.yaml"))
    inputs.file(File(workspaceRoot, "scripts/generate_strings.rb"))
    outputs.files(androidStringsEn, androidStringsRu)
    commandLine("ruby", "scripts/generate_strings.rb")
}

val generateTrixCoreKotlinBindings by tasks.registering(Exec::class) {
    dependsOn(buildTrixCoreHostLib)
    workingDir = workspaceRoot
    val outDir = generatedUniffiDir.get().asFile
    inputs.file(hostRustLibrary)
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

val syncCheckedInTrixCoreKotlinBindings by tasks.registering(Copy::class) {
    dependsOn(generateTrixCoreKotlinBindings)
    from(generatedUniffiDir.map { it.file("chat/trix/android/core/ffi/trix_core.kt") })
    into(layout.projectDirectory.dir("src/main/java/chat/trix/android/core/ffi"))
}

val buildTrixCoreAndroidLibs by tasks.registering(CargoNdkBuildTask::class) {
    dependsOn(buildTrixCoreHostLib)
    dependsOn(generateTrixCoreKotlinBindings)
    dependsOn(syncCheckedInTrixCoreKotlinBindings)
    workspaceDir.set(layout.dir(provider { workspaceRoot }))
    androidSdkRoot.set(androidSdkRootValue)
    androidNdkRoot.set(androidNdkRootDir.absolutePath)
    crateName.set("trix-core")
    platformLevel.set(28)
    targets.set(listOf("arm64-v8a", "x86_64"))
    outputDir.set(generatedJniLibsDir)
}

tasks.named("preBuild") {
    dependsOn(generateTrixStrings)
    dependsOn(syncCheckedInTrixCoreKotlinBindings)
    if (!skipAndroidNdkBuild) {
        dependsOn(buildTrixCoreAndroidLibs)
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.03.00")

    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-process:2.9.4")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    implementation("com.google.zxing:core:3.5.3")
    implementation("androidx.work:work-runtime-ktx:2.11.0")
    implementation("net.java.dev.jna:jna:5.18.1@aar")
    implementation("androidx.window:window:1.5.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
}
