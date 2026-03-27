package chat.trix.android.interop

import android.content.Intent
import android.graphics.Bitmap
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import chat.trix.android.BuildConfig
import chat.trix.android.MainActivity
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidInteropDriverInstrumentedTest {
    @Test
    fun seededBootstrapActionReturnsDriverArtifacts() {
        val result = AndroidInteropInstrumentedDriver.run(
            action = AndroidInteropDriverPresetAction.BOOTSTRAP_APPROVED_ACCOUNT,
            baseUrl = BuildConfig.TRIX_INTEROP_BASE_URL,
        )

        assertEquals(AndroidInteropActionResult.Status.OK, result.status)
        assertNotNull(result.accountId)
        assertFalse(requireNotNull(result.accountId).isEmpty())

        val transcriptPath = requireNotNull(result.transcriptPath)
        assertTrue(File(transcriptPath).exists())
        assertNull(result.screenshotPaths)
    }

    @Test
    fun unsupportedSendTextIncludesFailureArtifacts() {
        val result = AndroidInteropInstrumentedDriver.run(
            action = AndroidInteropDriverPresetAction.SEND_TEXT_UNSUPPORTED,
            baseUrl = BuildConfig.TRIX_INTEROP_BASE_URL,
        )

        assertEquals(AndroidInteropActionResult.Status.FAILED, result.status)

        val transcriptPath = requireNotNull(result.transcriptPath)
        assertTrue(File(transcriptPath).exists())

        val shots = requireNotNull(result.screenshotPaths)
        assertEquals(1, shots.size)
        assertTrue(shots[0].endsWith(".png"))
        assertTrue(File(shots[0]).exists())
    }
}

private object AndroidInteropInstrumentedDriver {
    fun run(
        action: AndroidInteropDriverPresetAction,
        baseUrl: String,
    ): AndroidInteropActionResult {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val targetContext = instrumentation.targetContext
        val actionJson = String(action.encodedJSON())
        val resultFile = File(
            File(targetContext.filesDir, "interop"),
            "result-${UUID.randomUUID()}.json",
        )
        val transcript = AndroidInteropDriverTranscript(targetContext.cacheDir)

        transcript.append("action_preset=$action")
        transcript.append("action_json=$actionJson")
        transcript.append("base_url=$baseUrl")

        clearLocalState(targetContext, transcript)

        val launchIntent = Intent(targetContext, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(AndroidInteropLaunchEnvironment.ACTION_JSON, actionJson)
            putExtra(AndroidInteropLaunchEnvironment.RESULT_PATH, resultFile.name)
        }

        transcript.append("result_path=${resultFile.absolutePath}")

        ActivityScenario.launch<MainActivity>(launchIntent).use {
            val result = waitForResult(
                resultFile = resultFile,
                transcript = transcript,
                cacheDir = targetContext.cacheDir,
            )
            if (result.status == AndroidInteropActionResult.Status.FAILED) {
                val shots = captureFailureScreenshot(targetContext.cacheDir, transcript)
                transcript.append("final_outcome=app_failed")
                transcript.persist()
                return result.withDriverArtifacts(
                    transcriptPath = transcript.path,
                    screenshotPaths = shots,
                )
            }

            transcript.append("final_outcome=ok")
            transcript.persist()
            return result.withDriverArtifacts(
                transcriptPath = transcript.path,
                screenshotPaths = emptyList(),
            )
        }
    }

    private fun clearLocalState(
        targetContext: android.content.Context,
        transcript: AndroidInteropDriverTranscript,
    ) {
        targetContext.getSharedPreferences("trix_backend_config", android.content.Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        File(targetContext.filesDir, "secure").deleteRecursively()
        File(targetContext.filesDir, "trix").deleteRecursively()
        File(targetContext.filesDir, "interop").deleteRecursively()
        transcript.append("state_reset=done")
    }

    private fun waitForResult(
        resultFile: File,
        transcript: AndroidInteropDriverTranscript,
        cacheDir: File,
    ): AndroidInteropActionResult {
        val deadlineNanos = System.nanoTime() + 90_000_000_000L
        var lastError: Exception? = null
        while (System.nanoTime() < deadlineNanos) {
            if (resultFile.exists()) {
                return try {
                    val result = AndroidInteropActionResult.decode(resultFile.readText())
                    transcript.append("result_received=${result.status}")
                    result
                } catch (error: Exception) {
                    lastError = error
                    transcript.append("result_decode_error=${error.message}")
                    transcript.append("final_outcome=result_decode_failed")
                    val shots = captureFailureScreenshot(cacheDir, transcript)
                    transcript.persist()
                    return AndroidInteropActionResult.failure(
                        "Invalid interop result JSON: ${error.message}",
                    ).withDriverArtifacts(
                        transcriptPath = transcript.path,
                        screenshotPaths = shots,
                    )
                }
            }

            try {
                Thread.sleep(250)
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
                throw IOException("Interrupted while waiting for interop result", error)
            }
        }

        val detail = lastError?.message ?: "Timed out waiting for Android interop result."
        transcript.append("result_timeout=$detail")
        return AndroidInteropActionResult.failure(detail)
    }

    private fun captureFailureScreenshot(
        cacheDir: File,
        transcript: AndroidInteropDriverTranscript,
    ): List<String> {
        val screenshot = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            ?: return emptyList()
        return screenshot.useBitmap { bitmap ->
            val dir = File(cacheDir, "trix-interop-screenshots").apply { mkdirs() }
            val path = File(dir, "interop-${UUID.randomUUID()}.png")
            return@useBitmap try {
                FileOutputStream(path).use { output ->
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                }
                transcript.append("screenshot_path=${path.absolutePath}")
                listOf(path.absolutePath)
            } catch (_: IOException) {
                emptyList()
            }
        }
    }
}

private class AndroidInteropDriverTranscript(
    cacheDir: File,
) {
    private val lines = mutableListOf<String>()
    private val file = File(File(cacheDir, "trix-interop-transcripts").apply { mkdirs() }, "interop-${UUID.randomUUID()}.transcript.txt")

    val path: String
        get() = file.absolutePath

    init {
        append("begin transcript_path=$path")
    }

    fun append(line: String) {
        lines += line
    }

    fun persist() {
        file.writeText(lines.joinToString(separator = "\n", postfix = "\n"))
    }
}

private inline fun <T> Bitmap.useBitmap(block: (Bitmap) -> T): T {
    return try {
        block(this)
    } finally {
        recycle()
    }
}
