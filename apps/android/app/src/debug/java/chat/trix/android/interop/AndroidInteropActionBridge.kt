package chat.trix.android.interop

import android.content.Context
import chat.trix.android.core.auth.AuthBootstrapCoordinator
import chat.trix.android.core.auth.BootstrapInput
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking

object AndroidInteropActionBridge {
    /**
     * @return true if a terminal interop result JSON payload was written under [resultFileName]; false if both
     *   the primary and fallback failure writes failed (caller may retry or use a host-side stub write).
     */
    @JvmStatic
    fun perform(
        context: Context,
        actionJson: String,
        resultFileName: String,
        baseUrl: String,
    ): Boolean {
        val appContext = context.applicationContext
        val wireResult: AndroidInteropActionResult = runCatching {
            execute(
                context = appContext,
                action = AndroidInteropAction.decode(actionJson),
                baseUrl = baseUrl,
            )
        }.getOrElse { error ->
            AndroidInteropActionResult.failure(
                error.message ?: "Android interop bridge failed.",
            )
        }

        return runCatching {
            writeResult(
                context = appContext,
                resultFileName = resultFileName,
                result = wireResult,
            )
            true
        }.getOrElse { writeError ->
            runCatching {
                writeResult(
                    context = appContext,
                    resultFileName = resultFileName,
                    result = AndroidInteropActionResult.failure(
                        "Failed to write interop result: ${writeError.message}",
                    ),
                )
                true
            }.getOrElse {
                false
            }
        }
    }

    private fun execute(
        context: Context,
        action: AndroidInteropAction,
        baseUrl: String,
    ): AndroidInteropActionResult {
        return when (action.name) {
            AndroidInteropActionName.BOOTSTRAP_APPROVED_ACCOUNT -> {
                val accountId = runBlocking {
                    ensureApprovedAccount(
                        context = context,
                        baseUrl = baseUrl,
                    )
                }
                AndroidInteropActionResult.success(accountId = accountId)
            }

            AndroidInteropActionName.SEND_TEXT -> {
                AndroidInteropActionResult.failure(
                    "sendText is not supported by the Android interop bridge yet.",
                )
            }
        }
    }

    private suspend fun ensureApprovedAccount(
        context: Context,
        baseUrl: String,
    ): String {
        val coordinator = AuthBootstrapCoordinator(
            context = context,
            baseUrl = baseUrl,
        )
        val storedDevice = coordinator.peekStoredDevice()
        if (storedDevice?.deviceStatus == "active" && storedDevice.accountId.isNotBlank()) {
            return runCatching {
                coordinator.restoreSession().localState.accountId
            }.getOrElse {
                coordinator.clearStoredDevice()
                createInteropAccount(coordinator)
            }
        }

        if (storedDevice != null) {
            coordinator.clearStoredDevice()
        }

        return createInteropAccount(coordinator)
    }

    private suspend fun createInteropAccount(
        coordinator: AuthBootstrapCoordinator,
    ): String {
        val suffix = UUID.randomUUID().toString().take(8)
        val session = coordinator.createAccount(
            BootstrapInput(
                profileName = "Android Interop $suffix",
                handle = null,
                profileBio = "Debug interop smoke account",
                deviceDisplayName = "Genymotion $suffix",
            ),
        )
        return session.localState.accountId
    }

    private fun writeResult(
        context: Context,
        resultFileName: String,
        result: AndroidInteropActionResult,
    ) {
        val outputFile = File(
            File(context.filesDir, "interop").apply { mkdirs() },
            File(resultFileName).name,
        )
        outputFile.writeBytes(result.encodedJSON())
    }
}
