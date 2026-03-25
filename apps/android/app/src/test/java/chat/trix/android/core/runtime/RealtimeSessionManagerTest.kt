package chat.trix.android.core.runtime

import chat.trix.android.core.ffi.FfiRealtimeEventKind
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RealtimeSessionManagerTest {
    @Test
    fun `local websocket handoff is treated as recoverable`() {
        assertTrue(isRecoverableSessionReplacement("replaced by a newer websocket session"))
    }

    @Test
    fun `server shutdown websocket replacement is retried`() {
        assertTrue(isRecoverableSessionReplacement("server shutting down"))
    }

    @Test
    fun `custom session replacement reason stays fatal`() {
        assertFalse(isRecoverableSessionReplacement("manual disconnect"))
    }

    @Test
    fun `acked event without changed chats does not refresh ui`() {
        assertFalse(
            shouldDispatchChatRefresh(
                eventKind = FfiRealtimeEventKind.ACKED,
                changedChatIds = emptySet(),
            ),
        )
    }

    @Test
    fun `inbox event with changed chats refreshes ui`() {
        assertTrue(
            shouldDispatchChatRefresh(
                eventKind = FfiRealtimeEventKind.INBOX_ITEMS,
                changedChatIds = setOf("chat-1"),
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
