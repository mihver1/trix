package chat.trix.android.core.system

import android.content.Context
import android.util.Log
import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

class AppTelemetry(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val logDir = File(appContext.filesDir, "logs")
    private val activeLogFile = File(logDir, "app.log")
    private val rotatedLogFile = File(logDir, "app.log.1")

    fun info(tag: String, message: String) {
        Log.i(tag, message)
        append("INFO", tag, message, null)
    }

    fun warn(
        tag: String,
        message: String,
        error: Throwable? = null,
    ) {
        Log.w(tag, message, error)
        append("WARN", tag, message, error)
    }

    fun error(
        tag: String,
        message: String,
        error: Throwable? = null,
    ) {
        Log.e(tag, message, error)
        append("ERROR", tag, message, error)
    }

    @Synchronized
    private fun append(
        level: String,
        tag: String,
        message: String,
        error: Throwable?,
    ) {
        runCatching {
            rotateIfNeeded()
            logDir.mkdirs()
            val suffix = error?.let { " | ${it.javaClass.simpleName}: ${it.message.orEmpty()}" }.orEmpty()
            val line = "${timestamp()} ${level.padEnd(5)} ${tag.take(32)} | $message$suffix\n"
            activeLogFile.appendText(line)
        }
    }

    private fun rotateIfNeeded() {
        if (activeLogFile.exists() && activeLogFile.length() < MAX_LOG_BYTES) {
            return
        }
        if (!activeLogFile.exists()) {
            return
        }
        if (rotatedLogFile.exists()) {
            rotatedLogFile.delete()
        }
        activeLogFile.renameTo(rotatedLogFile)
    }

    private fun timestamp(): String {
        return TIMESTAMP_FORMATTER.format(Instant.now())
    }

    companion object {
        private const val MAX_LOG_BYTES = 256 * 1024L
        private val TIMESTAMP_FORMATTER = DateTimeFormatter.ofPattern(
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            Locale.US,
        ).withZone(ZoneOffset.UTC)
    }
}
