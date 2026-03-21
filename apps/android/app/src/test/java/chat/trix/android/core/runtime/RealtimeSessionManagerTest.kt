package chat.trix.android.core.runtime

import chat.trix.android.core.ffi.FfiRealtimeEventKind
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RealtimeSessionManagerTest {
    @Test
    fun `acked event refreshes ui even without changed chat ids`() {
        assertTrue(
            shouldDispatchChatRefresh(
                eventKind = FfiRealtimeEventKind.ACKED,
                changedChatIds = emptySet(),
            ),
        )
    }

    @Test
    fun `non chat realtime event does not force refresh`() {
        assertFalse(
            shouldDispatchChatRefresh(
                eventKind = FfiRealtimeEventKind.PONG,
                changedChatIds = emptySet(),
            ),
        )
    }
}
