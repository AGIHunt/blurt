// Ported one for one from skills/blurt/recorder/macos/Tests/BlurtRemoteKitTests/RemoteVideoRepairTests.swift.
package dev.blurt.remote.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

class RemoteVideoRepairTest {
    private fun frame(id: Long, size: Int = 3000, key: Boolean = false, refresh: Boolean = false, ack: Boolean = false): List<RemoteVideoPacket> {
        val data = ByteArray(size) { (it * 7 + id.toInt()).toByte() }
        return RemoteVideoPacket.split(data, id, key, id.toDouble(), 1000, refresh, ack)
    }

    private fun frames(out: List<RemoteVideoReceiver.Output>) = out.filterIsInstance<RemoteVideoReceiver.Output.Frame>().map { it.frame.id }
    private fun feedback(out: List<RemoteVideoReceiver.Output>) = out.filterIsInstance<RemoteVideoReceiver.Output.Feedback>().map { it.feedback }
    private fun RemoteVideoReceiver.feed(ps: List<RemoteVideoPacket>, now: Double) = ps.flatMap { add(it, now) }
    private fun nack(vararg m: RemoteVideoFeedback.Missing) = RemoteVideoFeedback.Nack(m.toList())
    private fun miss(frame: Long, vararg pieces: Int) = RemoteVideoFeedback.Missing(frame, pieces.toList())

    @Test fun feedbackRoundTrips() {
        val all = listOf(
            nack(miss(7, 0, 3, 9), miss(8)),
            RemoteVideoFeedback.Ack(1234, 0b1011),
            RemoteVideoFeedback.Lost(99),
        )
        for (f in all) assertEquals(f, RemoteVideoFeedback.decode(f.encoded()))
        assertNull(RemoteVideoFeedback.decode(byteArrayOf(9, 1, 2)))
        assertNull(RemoteVideoFeedback.decode(byteArrayOf(1, 0, 0)))
        // many frames: split so every datagram fits
        val big = RemoteVideoFeedback.nacks((0L until 300L).map { miss(it, 1, 2, 3) })
        assertTrue(big.size > 1)
        assertTrue(big.all { it.encoded().size <= RemoteVideoFeedback.MAX_SIZE })
        // u32 frame numbers past 2^31 survive
        assertEquals(RemoteVideoFeedback.Lost(0xFFFF_FFF0L), RemoteVideoFeedback.decode(RemoteVideoFeedback.Lost(0xFFFF_FFF0L).encoded()))
    }

    @Test fun flagsByteKeepsTheOldMeaning() {
        val p = RemoteVideoPacket(1, 0, 1, true, 0.0, byteArrayOf(1))
        assertEquals(1, p.encoded()[8].toInt(), "what an old phone reads as a keyframe")
        val r = RemoteVideoPacket(1, 0, 1, false, 0.0, byteArrayOf(1), refresh = true, ackRequested = true)
        val back = RemoteVideoPacket.decode(r.encoded())!!
        assertTrue(back.refresh)
        assertTrue(back.ackRequested)
        assertFalse(back.keyframe)
    }

    @Test fun parityRebuildsAnyOnePiece() {
        val pieces = frame(3, size = 9_500, key = true)      // ten pieces, the last short
        val parity = RemoteVideoFEC.parity(pieces, group = 5)
        assertEquals(2, parity.size)
        assertTrue(parity.all { it.isParity })
        // an old assembler never takes a parity piece for a piece
        val old = RemoteVideoAssembler()
        for (p in parity) assertNull(old.add(RemoteVideoPacket.decode(p.encoded())!!))
        val whole = pieces.fold(ByteArray(0)) { a, p -> a + p.payload }
        for (lost in listOf(listOf(0), listOf(4), listOf(9), listOf(3, 4))) {
            val r = RemoteVideoReceiver(nack = false, ltr = false)
            val out = (pieces + parity).filter { it.index !in lost }.flatMap { r.add(RemoteVideoPacket.decode(it.encoded())!!, 0.0) }
            val f = (out.firstOrNull() as? RemoteVideoReceiver.Output.Frame)?.frame ?: fail("piece $lost not rebuilt")
            assertContentEquals(whole, f.data)
            assertEquals(lost.size, r.repaired, "a burst of two lands in two groups")
        }
    }

    @Test fun framesWaitForAPieceSentAgain() {
        val r = RemoteVideoReceiver(nack = true, ltr = false)
        r.rtt = 0.004
        assertEquals(listOf(1L), frames(r.feed(frame(1, key = true), 0.0)))
        val f2 = frame(2)
        val f3 = frame(3)
        var out = r.feed(f2.filter { it.index != 1 }, 0.016)
        out = out + r.feed(f3, 0.032)
        assertEquals(emptyList(), frames(out), "3 waits for 2")
        assertEquals(listOf<RemoteVideoFeedback>(nack(miss(2, 1))), feedback(r.tick(0.033)))
        assertEquals(emptyList(), feedback(r.tick(0.034)), "not again within a round trip")
        assertEquals(listOf(2L, 3L), frames(r.add(f2[1], 0.037)))
        assertEquals(0, r.dropped)
    }

    @Test fun aWholeFrameMissingIsAskedFor() {
        val r = RemoteVideoReceiver(nack = true, ltr = false)
        r.feed(frame(1, key = true), 0.0)
        r.feed(frame(3), 0.03)
        assertEquals(listOf<RemoteVideoFeedback>(nack(miss(2))), feedback(r.tick(0.031)))
        assertEquals(listOf(2L, 3L), frames(r.feed(frame(2), 0.035)))
    }

    @Test fun theEndOfAFrameIsAskedForOnceQuiet() {
        val r = RemoteVideoReceiver(nack = true, ltr = false)
        r.feed(frame(1, key = true), 0.0)
        val f2 = frame(2)
        r.feed(f2.dropLast(1), 0.016)
        assertEquals(emptyList(), feedback(r.tick(0.02)), "its last piece may still be coming")
        assertEquals(listOf<RemoteVideoFeedback>(nack(miss(2, 2))), feedback(r.tick(0.05)))
    }

    @Test fun givenUpThenARefreshEndsTheWait() {
        val r = RemoteVideoReceiver(nack = true, ltr = true)
        r.rtt = 0.004
        var out = r.feed(frame(1, key = true, ack = true), 0.0)
        val f1 = (out[0] as RemoteVideoReceiver.Output.Frame).frame
        // decoded and acknowledged
        assertEquals(listOf<RemoteVideoFeedback>(RemoteVideoFeedback.Ack(1, 0)), feedback(r.decoded(f1, 0.01)))
        out = r.feed(frame(2).filter { it.index != 0 }, 0.016)
        out = out + r.feed(frame(3), 0.032)
        assertEquals(emptyList(), frames(out))
        // frames keep coming (the path works), the piece doesn't
        var t = 0.033
        var n = 4L
        var lost = false
        while (t < 0.3 && !lost) {
            if ((t * 1000).toInt() % 16 == 0) { r.feed(frame(n), t); n += 1 }
            lost = feedback(r.tick(t)).contains(RemoteVideoFeedback.Lost(1))
            t += 0.001
        }
        assertTrue(lost, "gave up within its patience")
        assertTrue(t < 0.09)
        assertTrue(r.broken)
        // ordinary frames don't help now; the refresh does
        assertEquals(emptyList(), frames(r.feed(frame(n), t + 0.01)))
        assertEquals(listOf(n + 1), frames(r.feed(frame(n + 1, refresh = true), t + 0.02)))
        assertFalse(r.broken)
        assertEquals(listOf(n + 2), frames(r.feed(frame(n + 2), t + 0.03)))
    }

    @Test fun aStallIsWaitedOutNotGivenUp() {
        val r = RemoteVideoReceiver(nack = true, ltr = true)
        r.rtt = 0.004
        r.feed(frame(1, key = true), 0.0)
        val f2 = frame(2)
        r.feed(f2.take(1), 0.016)
        // nothing at all for 120 ms: the rest of frame 2 was held up, not lost
        var asked = 0
        var t = 0.02
        while (t < 0.136) {
            val out = r.tick(t)
            assertFalse(out.contains(RemoteVideoReceiver.Output.Keyframe))
            assertFalse(feedback(out).contains(RemoteVideoFeedback.Lost(1)), "gave up during a stall at $t")
            asked += feedback(out).size
            t += 0.004
        }
        assertTrue(asked <= 1, "the end of the frame asked for once, not again into the stall")
        assertEquals(listOf(2L), frames(r.feed(f2.drop(1), 0.137)))
        assertFalse(r.broken)
    }

    @Test fun aHitchOnThePhoneGivesNothingUp() {
        // the phone stops for 60 ms (a busy CPU, the app descheduled) while the piece asked for is on its way: the tick that comes after
        // reads nothing yet, so it mustn't give the frame up; the piece, read next, completes it
        val r = RemoteVideoReceiver(nack = true, ltr = true)
        r.rtt = 0.002
        r.feed(frame(1, key = true), 0.0)
        val f2 = frame(2)
        r.feed(f2.filter { it.index != 1 }, 0.016)
        r.feed(frame(3), 0.032)
        assertEquals(listOf<RemoteVideoFeedback>(nack(miss(2, 1))), feedback(r.tick(0.033)))
        // back after 60 ms: the first piece read (heard just now, so it doesn't look like a stall), then the timers, then the rest
        r.feed(frame(4), 0.094)
        val out = r.tick(0.094)
        assertFalse(feedback(out).any { it is RemoteVideoFeedback.Lost }, "gave up after a hitch: $out")
        assertFalse(r.broken)
        assertEquals(listOf(2L, 3L, 4L), frames(r.add(f2[1], 0.095)))
        assertEquals(0, r.dropped)
        // a piece that really is gone is still given up on, the hitch not counted
        r.feed(frame(5).filter { it.index != 0 }, 0.096)
        var t = 0.098
        var n = 6L
        var lost: Double? = null
        while (t < 0.4 && lost == null) {
            if (t >= 0.096 + 0.016 * (n - 5)) { r.feed(frame(n), t); n++ }
            if (feedback(r.tick(t)).contains(RemoteVideoFeedback.Lost(4))) lost = t
            t += 0.002
        }
        val at = lost ?: fail("a lost piece is still given up")
        assertTrue(at < 0.097 + r.patience + 0.05, "$at")
    }

    @Test fun aPhoneThatStaysBusyStillGivesUp() {
        // every tick 20 ms after the last (a slow phone's busy decoder thread): each one looks like a hitch, but a piece that never
        // comes is still given up within a second of real time, so the picture doesn't freeze with nothing asked
        val r = RemoteVideoReceiver(nack = true, ltr = true)
        r.rtt = 0.002
        r.feed(frame(1, key = true), 0.0)
        r.feed(frame(2).filter { it.index != 1 }, 0.016)
        var t = 0.02
        var n = 3L
        var lost: Double? = null
        while (t < 2.0 && lost == null) {
            r.feed(frame(n), t); n++
            if (feedback(r.tick(t)).contains(RemoteVideoFeedback.Lost(1))) lost = t
            t += 0.02
        }
        val at = lost ?: fail("given up though every tick was late")
        assertTrue(at <= 0.02 + 1.0 + 0.02 + 1e-9, "$at")
    }

    @Test fun afterAStallThePieceAskedForGetsItsRetry() {
        // the end of frame 2 is lost, asked for, and then nothing comes for 80 ms (Wi-Fi's stall, or the sender stopped): when the next
        // frame's first piece arrives the frame has been late longer than the patience, but only in the stall
        val r = RemoteVideoReceiver(nack = true, ltr = true)
        r.rtt = 0.002
        r.feed(frame(1, key = true), 0.0)
        val f2 = frame(2)
        r.feed(f2.take(1), 0.016)
        var t = 0.02
        val asked = ArrayList<RemoteVideoFeedback>()
        while (t < 0.13) { asked += feedback(r.tick(t)); t += 0.004 }
        assertEquals(listOf<RemoteVideoFeedback>(nack(miss(2, 1, 2))), asked, "asked once, then the stall")
        r.feed(frame(3).take(1), 0.13)
        val out = r.tick(0.13)
        assertFalse(feedback(out).any { it is RemoteVideoFeedback.Lost }, "gave up as the stall ended: $out")
        assertEquals(listOf<RemoteVideoFeedback>(nack(miss(2, 1, 2))), feedback(out), "asked again at once")
        assertEquals(listOf(2L), frames(r.feed(f2.drop(1), 0.134)))
        assertEquals(0, r.dropped)
    }

    @Test fun withoutLTRALossAsksForAKeyframe() {
        val r = RemoteVideoReceiver(nack = true, ltr = false)
        r.feed(frame(1, key = true), 0.0)
        r.feed(frame(3), 0.02)
        var t = 0.02
        var asked = false
        while (t < 0.4 && !asked) { asked = r.tick(t).contains(RemoteVideoReceiver.Output.Keyframe); t += 0.005 }
        assertTrue(asked)
        assertEquals(listOf(9L), frames(r.feed(frame(9, key = true), t)))
        assertEquals(7, r.dropped)
    }

    @Test fun afterTheDecoderFailsOnlyAKeyframeWill() {
        val r = RemoteVideoReceiver(nack = true, ltr = true)
        r.feed(frame(1, key = true), 0.0)
        r.decoderFailed(0.01)
        assertEquals(listOf<RemoteVideoReceiver.Output>(RemoteVideoReceiver.Output.Keyframe), r.tick(0.02))
        assertEquals(emptyList(), frames(r.feed(frame(2, refresh = true), 0.03)))
        assertEquals(listOf(3L), frames(r.feed(frame(3, key = true), 0.04)))
    }

    @Test fun noAskingAtTheStartWhileTheFirstKeyframeArrives() {
        val r = RemoteVideoReceiver(nack = true, ltr = true, now = 0.0)
        r.feed(frame(1, key = true).take(1), 0.001)
        assertFalse(r.tick(0.01).contains(RemoteVideoReceiver.Output.Keyframe))
        assertTrue(r.tick(0.5).contains(RemoteVideoReceiver.Output.Keyframe))
    }

    @Test fun historyKeepsASecond() {
        val h = RemoteVideoHistory(maxAge = 1.0, maxBytes = 10_000)
        h.add(1, listOf(byteArrayOf(1), byteArrayOf(2)), 0.0)
        h.add(2, listOf(byteArrayOf(3)), 0.5)
        assertContentEquals(byteArrayOf(2), h.pieces(1, listOf(1)).single())
        assertEquals(2, h.pieces(1, emptyList()).size)
        h.add(3, listOf(byteArrayOf(4)), 1.2)
        assertEquals(emptyList(), h.pieces(1, listOf(0)))
        assertContentEquals(byteArrayOf(3), h.pieces(2, listOf(0)).single())
    }

    // Beyond the Swift list: the whole path under made-up loss, as the app runs it (a tick every 4 ms, frames every 16 ms).

    @Test fun onePercentLossInBurstsCostsNoFrame() {
        val rng = java.util.Random(7)
        val r = RemoteVideoReceiver(nack = true, ltr = true)
        r.rtt = 0.004
        val sent = HashMap<Long, List<RemoteVideoPacket>>()
        val inFlight = ArrayList<Pair<Double, RemoteVideoPacket>>()
        var shown = 0
        var keyframes = 0
        var bad = false
        fun lose(): Boolean {                          // two states, bursts of 2 on average, 1 % of pieces
            val end = 0.5
            val start = 0.01 * end / 0.99
            bad = if (bad) rng.nextDouble() >= end else rng.nextDouble() < start
            return bad
        }
        var t = 0.0
        var id = 1L
        while (t < 10.0) {
            if (Math.round(t * 1000) % 16 == 0L) {
                val ps = frame(id, size = 25_000, key = id == 1L)
                sent[id] = ps
                for (p in ps) if (!lose()) inFlight += (t + 0.002) to p
                id += 1
            }
            val due = inFlight.filter { it.first <= t }
            inFlight.removeAll(due)
            for ((_, p) in due) shown += frames(r.add(p, t)).size
            for (o in r.tick(t)) when (o) {
                RemoteVideoReceiver.Output.Keyframe -> keyframes += 1
                is RemoteVideoReceiver.Output.Feedback -> (o.feedback as? RemoteVideoFeedback.Nack)?.missing?.forEach { m ->
                    val ps = sent[m.frame] ?: return@forEach
                    for (p in if (m.pieces.isEmpty()) ps else m.pieces.map { ps[it] }) if (!lose()) inFlight += (t + 0.004) to p
                }
                is RemoteVideoReceiver.Output.Frame -> shown += 1
            }
            t += 0.001
        }
        assertEquals(0, keyframes, "no keyframes asked at 1 % loss")
        assertEquals(0, r.dropped)
        assertTrue(shown >= id - 3, "frames shown $shown of ${id - 1}")
        assertTrue(r.nacked > 0)
    }
}
