package chat.trix.android.core.chat

import org.junit.Assert.assertEquals
import org.junit.Test

class ConversationProjectionRecoveryTest {
    @Test
    fun refreshFailureAfterProjectionErrorIsBestEffort() {
        var projectionAttempts = 0
        var refreshAttempts = 0

        recoverConversationProjectionBestEffort(
            projectLocally = {
                projectionAttempts += 1
                throw IllegalStateException("missing local projection")
            },
            repairHistoryLocally = {
                throw AssertionError("local repair should not run after the first projection failure")
            },
            refreshFromServer = {
                refreshAttempts += 1
                throw IllegalStateException("network offline")
            },
        )

        assertEquals(1, projectionAttempts)
        assertEquals(1, refreshAttempts)
    }
}
