package chat.trix.android.ui.interop

/**
 * Pure helpers for ordering debug interop bridge work before normal auth bootstrap,
 * and for consistent loading copy. Covered by unit tests; keep logic here—not in Composable lambdas.
 */
object TrixInteropLaunchCoordinator {

    fun stableInteropRequestKey(actionJson: String?, resultFileName: String?): String {
        val json = actionJson?.trim().orEmpty()
        val result = resultFileName?.trim().orEmpty()
        if (json.isEmpty() || result.isEmpty()) {
            return ""
        }
        return "${json.hashCode()}|$result"
    }

    fun hasInteropRequest(stableKey: String): Boolean = stableKey.isNotEmpty()

    fun initialBridgeFinished(hasInteropRequest: Boolean): Boolean = !hasInteropRequest

    fun shouldDeferAuthBootstrap(hasInteropRequest: Boolean, bridgeFinished: Boolean): Boolean {
        return hasInteropRequest && !bridgeFinished
    }

    fun loadingMessageWhileDeferred(hasInteropRequest: Boolean, bridgeFinished: Boolean): String {
        return if (hasInteropRequest && !bridgeFinished) {
            "Running interoperability handshake…"
        } else {
            "Restoring local device"
        }
    }
}
