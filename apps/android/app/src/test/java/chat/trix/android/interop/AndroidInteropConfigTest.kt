package chat.trix.android.interop

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidInteropConfigTest {
    @Test
    fun genymotionBaseUrlDefaultsToHostLoopback() {
        val config = AndroidInteropConfig.forGenymotion(
            hostBaseUrl = "http://127.0.0.1:8080",
        )

        assertEquals("http://10.0.3.2:8080", config.deviceReachableBaseUrl)
    }

    @Test
    fun actionDecoderParsesSendTextRequest() {
        val action = AndroidInteropAction.decode(
            """
            {"name":"sendText","actor":"android-a","chatAlias":"dm-a-b","text":"hello"}
            """.trimIndent(),
        )

        assertEquals(AndroidInteropActionName.SEND_TEXT, action.name)
        assertEquals("android-a", action.actor)
        assertEquals("dm-a-b", action.chatAlias)
        assertEquals("hello", action.text)
    }

    @Test
    fun driverArtifactsAttachToWireResult() {
        val result = AndroidInteropActionResult.success(accountId = "account-1")
            .withDriverArtifacts(
                transcriptPath = "/tmp/android-interop.transcript.txt",
                screenshotPaths = emptyList(),
            )

        assertEquals(AndroidInteropActionResult.Status.OK, result.status)
        assertEquals("/tmp/android-interop.transcript.txt", result.transcriptPath)
        assertNull(result.screenshotPaths)
    }
}
