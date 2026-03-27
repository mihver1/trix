package chat.trix.android.ui.interop

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrixInteropLaunchCoordinatorTest {

    @Test
    fun stableKey_emptyWhenEitherInteropExtraMissing() {
        assertEquals("", TrixInteropLaunchCoordinator.stableInteropRequestKey(null, "out.json"))
        assertEquals("", TrixInteropLaunchCoordinator.stableInteropRequestKey("{}", null))
        assertEquals("", TrixInteropLaunchCoordinator.stableInteropRequestKey("   ", "out.json"))
        assertEquals("", TrixInteropLaunchCoordinator.stableInteropRequestKey("{}", "  "))
    }

    @Test
    fun stableKey_nonEmptyWhenBothExtrasPresent() {
        val key = TrixInteropLaunchCoordinator.stableInteropRequestKey(
            """{"name":"sendText","actor":"a"}""",
            "result.json",
        )
        assertTrue(key.isNotEmpty())
        assertEquals(
            key,
            TrixInteropLaunchCoordinator.stableInteropRequestKey(
                """{"name":"sendText","actor":"a"}""",
                "result.json",
            ),
        )
    }

    @Test
    fun initialBridgeFinished_trueWhenNoInteropRequest() {
        assertTrue(
            TrixInteropLaunchCoordinator.initialBridgeFinished(
                hasInteropRequest = false,
            ),
        )
    }

    @Test
    fun initialBridgeFinished_falseWhenInteropRequestPresent() {
        assertFalse(
            TrixInteropLaunchCoordinator.initialBridgeFinished(
                hasInteropRequest = true,
            ),
        )
    }

    @Test
    fun authBootstrapDeferredWhenInteropPending() {
        assertTrue(
            TrixInteropLaunchCoordinator.shouldDeferAuthBootstrap(
                hasInteropRequest = true,
                bridgeFinished = false,
            ),
        )
    }

    @Test
    fun authBootstrapNotDeferredWhenNoInterop() {
        assertFalse(
            TrixInteropLaunchCoordinator.shouldDeferAuthBootstrap(
                hasInteropRequest = false,
                bridgeFinished = false,
            ),
        )
    }

    @Test
    fun authBootstrapNotDeferredAfterBridgeFinished() {
        assertFalse(
            TrixInteropLaunchCoordinator.shouldDeferAuthBootstrap(
                hasInteropRequest = true,
                bridgeFinished = true,
            ),
        )
    }

    @Test
    fun loadingMessageInteropWhileDeferred() {
        assertEquals(
            "Running interoperability handshake…",
            TrixInteropLaunchCoordinator.loadingMessageWhileDeferred(
                hasInteropRequest = true,
                bridgeFinished = false,
            ),
        )
    }

    @Test
    fun loadingMessageDefaultWhenNotInteropDeferred() {
        assertEquals(
            "Restoring local device",
            TrixInteropLaunchCoordinator.loadingMessageWhileDeferred(
                hasInteropRequest = false,
                bridgeFinished = false,
            ),
        )
    }
}
