// What the microphone hears while the session is away (HeldAudio.kt).
package dev.blurt.remote.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class HeldAudioTest {
    private val sent = mutableListOf<Int>()
    private val send: (ByteArray) -> Unit = { sent += it[0].toInt() }
    private fun piece(n: Int, size: Int = 3200) = ByteArray(size).also { it[0] = n.toByte() }

    @Test fun liveGoesStraightOn() {
        val h = HeldAudio()
        h.add(piece(1), send)
        h.release(send)
        h.add(piece(2), send)
        assertEquals(listOf(1, 2), sent)
        assertFalse(h.holding)
    }

    @Test fun whatWasHeldGoesFirstAndInOrder() {
        val h = HeldAudio()
        h.add(piece(1), send)
        h.hold(true)
        for (i in 2..4) h.add(piece(i), send)
        assertEquals(listOf(1), sent)
        assertTrue(h.holding)
        h.release(send)
        h.add(piece(5), send)
        assertEquals(listOf(1, 2, 3, 4, 5), sent)
        h.release(send)
        assertEquals(5, sent.size, "once")
    }

    @Test fun tenSecondsAndTheOldestMakeRoom() {
        val h = HeldAudio()
        h.hold(true)
        for (i in 1..110) h.add(piece(i), send)      // 11 s in pieces of 100 ms
        h.release(send)
        assertEquals((11..110).toList(), sent)
        assertEquals(320_000, HeldAudio.MOST)
    }

    @Test fun letGoOfItIsDropped() {
        val h = HeldAudio()
        h.hold(true)
        h.add(piece(1), send)
        h.hold(false)
        h.add(piece(2), send)
        assertEquals(listOf(2), sent)
        // and held anew, nothing of the last one is left
        h.hold(true)
        h.add(piece(3), send)
        h.hold(true)
        h.add(piece(4), send)
        h.release(send)
        assertEquals(listOf(2, 4), sent)
    }
}
