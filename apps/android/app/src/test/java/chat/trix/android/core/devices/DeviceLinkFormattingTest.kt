package chat.trix.android.core.devices

import java.time.ZoneId
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceLinkFormattingTest {
    @Test
    fun `short device identifier keeps prefix and suffix`() {
        assertEquals("abcdef…7890", shortDeviceIdentifier("abcdef1234567890"))
        assertEquals("short-id", shortDeviceIdentifier("short-id"))
    }

    @Test
    fun `pretty print json formats payload`() {
        val formatted = prettyPrintJsonOrRaw("""{"link_intent_id":"intent-1","link_token":"secret"}""")

        assertTrue(formatted.contains("\n  \"link_intent_id\": \"intent-1\""))
        assertTrue(formatted.contains("\n  \"link_token\": \"secret\""))
    }

    @Test
    fun `format link expiry uses supplied zone`() {
        val previousLocale = Locale.getDefault()
        try {
            Locale.setDefault(Locale.US)

            val formatted = formatLinkExpiry(
                epochSeconds = 1_700_000_000L,
                zoneId = ZoneId.of("UTC"),
            )

            assertEquals("Nov 14, 22:13", formatted)
        } finally {
            Locale.setDefault(previousLocale)
        }
    }
}
