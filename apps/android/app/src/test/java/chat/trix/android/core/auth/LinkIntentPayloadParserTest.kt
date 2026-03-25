package chat.trix.android.core.auth

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkIntentPayloadParserTest {
    @Test
    fun `parses payload and prefers embedded base url`() {
        val parsed = parseLinkIntentPayload(
            rawPayload = """
                {
                  "link_intent_id": "intent-123",
                  "link_token": "token-abc",
                  "base_url": "https://relay.example.com/"
                }
            """.trimIndent(),
            fallbackBaseUrl = "http://10.0.2.2:8080",
        )

        assertEquals("intent-123", parsed.linkIntentId)
        assertEquals("token-abc", parsed.linkToken)
        assertEquals("https://relay.example.com", parsed.baseUrl)
    }

    @Test
    fun `falls back to configured backend when payload omits base url`() {
        val parsed = parseLinkIntentPayload(
            rawPayload = """
                {
                  "link_intent_id": "intent-123",
                  "link_token": "token-abc"
                }
            """.trimIndent(),
            fallbackBaseUrl = "http://10.0.2.2:8080/",
        )

        assertEquals("http://10.0.2.2:8080", parsed.baseUrl)
    }

    @Test
    fun `rejects payload without link token`() {
        val error = runCatching {
            parseLinkIntentPayload(
                rawPayload = """{"link_intent_id":"intent-123"}""",
                fallbackBaseUrl = "http://10.0.2.2:8080",
            )
        }.exceptionOrNull()

        assertTrue(error is IOException)
        assertEquals("Link payload is missing link_token", error?.message)
    }
}
