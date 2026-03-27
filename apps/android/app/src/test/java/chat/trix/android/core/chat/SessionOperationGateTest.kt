package chat.trix.android.core.chat

import java.util.Collections
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test

class SessionOperationGateTest {
    @Test
    fun nestedWithLockDoesNotDeadlock() = runBlocking {
        val gate = SessionOperationGate()
        val order = mutableListOf("start")

        val result = withTimeout(1_000) {
            gate.withLock {
                order += "outer"
                gate.withLock {
                    order += "inner"
                    "ok"
                }
            }
        }

        assertEquals("ok", result)
        assertEquals(listOf("start", "outer", "inner"), order)
    }

    @Test
    fun concurrentWithLockCallsRemainSerialized() = runBlocking {
        val gate = SessionOperationGate()
        val order = Collections.synchronizedList(mutableListOf<String>())

        val first = async {
            gate.withLock {
                order += "first-start"
                delay(100)
                order += "first-end"
            }
        }
        val second = async {
            delay(10)
            gate.withLock {
                order += "second"
            }
        }

        withTimeout(1_000) {
            first.await()
            second.await()
        }

        assertEquals(listOf("first-start", "first-end", "second"), order)
    }
}
