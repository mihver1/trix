import javax.inject.Inject
import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.ListProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction
import org.gradle.api.tasks.UntrackedTask
import org.gradle.process.ExecOperations

@UntrackedTask(because = "Cargo manages native build outputs outside Gradle's incremental model")
abstract class CargoNdkBuildTask @Inject constructor(
    private val execOperations: ExecOperations,
) : DefaultTask() {
    @get:InputDirectory
    abstract val workspaceDir: DirectoryProperty

    @get:Input
    abstract val androidSdkRoot: Property<String>

    @get:Input
    abstract val androidNdkRoot: Property<String>

    @get:Input
    abstract val crateName: Property<String>

    @get:Input
    abstract val platformLevel: Property<Int>

    @get:Input
    abstract val targets: ListProperty<String>

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun buildNativeLibraries() {
        val ndkRoot = androidNdkRoot.get()
        val sdkRoot = androidSdkRoot.get()
        val outputRoot = outputDir.get().asFile

        if (!outputRoot.exists()) {
            outputRoot.mkdirs()
        }

        if (!outputRoot.isDirectory) {
            error("JNI output path is not a directory: $outputRoot")
        }

        if (!java.io.File(ndkRoot).exists()) {
            error("Android NDK is not installed under $ndkRoot")
        }

        outputRoot.deleteRecursively()
        outputRoot.mkdirs()

        val command = mutableListOf(
            "cargo",
            "ndk",
            "--platform",
            platformLevel.get().toString(),
        )
        targets.get().forEach { target ->
            command += listOf("-t", target)
        }
        command += listOf(
            "-o",
            outputRoot.absolutePath,
            "build",
            "-p",
            crateName.get(),
            "--lib",
        )

        execOperations.exec {
            workingDir = workspaceDir.get().asFile
            environment(
                mapOf(
                    "ANDROID_HOME" to sdkRoot,
                    "ANDROID_SDK_ROOT" to sdkRoot,
                    "ANDROID_NDK_HOME" to ndkRoot,
                    "ANDROID_NDK_ROOT" to ndkRoot,
                ),
            )
            commandLine(command)
        }
    }
}
