// The joining side takes the computer's key only after it asked and this side's user said the digits are the same (RemotePairing.kt
// JoinGate; Swift: RemoteJoinGate). The vectors (VectorsTest.joinGate) check the order of events; this checks the key that comes out.
package dev.blurt.remote.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class JoinGateTest {
    private val k = ByteArray(32) { it.toByte() }

    @Test fun aKeyBeforeTheQuestionIsDroppedNotHeld() {
        val g = JoinGate()
        assertNull(g.newKey(k))
        assertFalse(g.keyWaiting)
        g.pairingWaits()
        assertNull(g.confirm(), "the dropped key doesn't come back on the yes")
    }

    @Test fun aYesBeforeTheQuestionCountsForNothing() {
        val g = JoinGate()
        assertNull(g.confirm())
        assertFalse(g.confirmed)
        g.pairingWaits()
        assertTrue(g.canConfirm)
        assertNull(g.newKey(k), "held: this side hasn't said yes to these digits")
        assertTrue(g.keyWaiting)
    }

    @Test fun theYesThenTheKey() {
        val g = JoinGate()
        g.pairingWaits()
        assertNull(g.confirm())
        assertFalse(g.canConfirm)
        assertContentEquals(k, g.newKey(k))
    }

    @Test fun theKeyThenTheYes() {
        val g = JoinGate()
        g.pairingWaits()
        assertNull(g.newKey(k))
        assertContentEquals(k, g.confirm())
        assertFalse(g.keyWaiting)
    }

    @Test fun aNewConnectionStartsOver() {
        val g = JoinGate()
        g.pairingWaits()
        g.newKey(k)
        g.reset()
        assertFalse(g.keyWaiting)
        assertFalse(g.canConfirm)
        g.pairingWaits()
        assertNull(g.confirm(), "the key held on the last connection is gone")
    }
}
