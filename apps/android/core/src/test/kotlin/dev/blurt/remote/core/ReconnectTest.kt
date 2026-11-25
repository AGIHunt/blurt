// How soon each way back is tried, and how long a session is kept out of sight (Reconnect.kt; docs/design/remote.md §Coming back).
package dev.blurt.remote.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ReconnectTest {
    @Test fun theRelayComesAMomentAfterTheLocalWaysUnlessTheLastSessionWasAway() {
        assertEquals(1200, Reconnect.relayDelayMs(lastAway = false))
        assertEquals(0, Reconnect.relayDelayMs(lastAway = true))
    }

    @Test fun aRelayThatEndedIsTriedAgainSoonThenLessOften() {
        assertEquals(listOf<Long>(400, 400, 800, 1500, 3000, 5000, 5000), (0..6).map { Reconnect.relayAgainMs(it) })
    }

    @Test fun whatIsWaitedFor() {
        assertEquals(1200, Reconnect.proofMs(relay = false))
        assertEquals(2500, Reconnect.proofMs(relay = true))
        assertEquals(5_000, Reconnect.sessionDueMs(relay = false))
        assertEquals(10_000, Reconnect.sessionDueMs(relay = true))
        assertEquals(12_000, Reconnect.MEETING_DUE_MS)
        assertEquals(8_000, Reconnect.unreachableAfterMs(relay = false))
        assertEquals(12_000, Reconnect.unreachableAfterMs(relay = true))
        assertEquals(12_000, Reconnect.busyFloorMs(asked = true))
        assertEquals(60_000, Reconnect.busyFloorMs(asked = false))
    }

    @Test fun howLongASessionIsKept() {
        assertEquals(180_000, Reconnect.keepInBackgroundMs(service = true))
        assertEquals(30_000, Reconnect.keepInBackgroundMs(service = false))
    }

    @Test fun whatIsARefusal() {
        for (c in listOf(429, 403, 503, 520, 525, 530, 1015, 1027)) assertTrue(Reconnect.isRefusal(c), "$c")
        for (c in listOf(200, 301, 404, 500, 502, 531)) assertFalse(Reconnect.isRefusal(c), "$c")
    }
}
