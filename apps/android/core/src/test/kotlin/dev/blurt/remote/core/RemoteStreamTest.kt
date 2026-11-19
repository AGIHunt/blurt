// The stream after the move (RemoteStream.kt; docs/design/remote-go-between.md §Moving the stream), on a fake clock: loss, reordering,
// duplicates, a full window, the retransmission timer and its backoff, three acks in a row; and a whole session's frames moved onto it,
// sealed on channel 0 with the counters carrying on from the old stream.
package dev.blurt.remote.core

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RemoteStreamTest {
    private fun bytes(n: Int, seed: Int = 1) = ByteArray(n) { (it * 31 + seed).toByte() }
    private fun offsetOf(c: ByteArray) = RemoteStreamPacket.parseChunk(c)!!.first
    private fun lengthOf(c: ByteArray) = c.size - 8

    @Test fun theBodiesOnTheWire() {
        val c = RemoteStreamPacket.chunk(0x0102030405060708, byteArrayOf(9, 10))
        assertEquals("0102030405060708090a", hex(c))
        val (o, b) = RemoteStreamPacket.parseChunk(c)!!
        assertEquals(0x0102030405060708, o)
        assertContentEquals(byteArrayOf(9, 10), b)
        assertEquals("0000000000000400", hex(RemoteStreamPacket.ack(1024)))
        assertEquals(1024L, RemoteStreamPacket.parseAck(RemoteStreamPacket.ack(1024)))
        // an empty chunk is only an offset
        assertEquals(0, RemoteStreamPacket.parseChunk(RemoteStreamPacket.ack(5))!!.second.size)
        assertNull(RemoteStreamPacket.parseChunk(ByteArray(7)), "shorter than the offset")
        assertNull(RemoteStreamPacket.parseChunk(ByteArray(8 + 1101)), "more than 1,100 bytes after it")
        assertNotNull(RemoteStreamPacket.parseChunk(ByteArray(8 + 1100)))
        assertNull(RemoteStreamPacket.parseChunk(unhex("ff00000000000000")), "past a Long")
        assertNull(RemoteStreamPacket.parseAck(ByteArray(9)))
        assertEquals(7, RemoteFrameKind.STREAM.raw)
        assertEquals(8, RemoteFrameKind.STREAM_ACK.raw)
        assertEquals(RemoteFrameKind.STREAM, RemoteFrameKind.from(7))
        assertEquals(RemoteFrameKind.STREAM_ACK, RemoteFrameKind.from(8))
    }

    @Test fun inOrderAndAcked() {
        val s = RemoteStreamSender()
        val r = RemoteStreamReceiver()
        val data = bytes(2500)
        val out = s.write(data, 0.0)
        assertEquals(listOf(0L, 1100L, 2200L), out.map(::offsetOf))
        assertEquals(listOf(1100, 1100, 300), out.map(::lengthOf))
        assertEquals(2500L, s.inFlight)
        val got = java.io.ByteArrayOutputStream()
        var lastAck: ByteArray? = null
        for ((i, c) in out.withIndex()) {
            val (o, b) = RemoteStreamPacket.parseChunk(c)!!
            val res = r.received(o, b, 0.05 + i * 0.001)
            got.write(res.data)
            res.ack?.let { lastAck = it }
        }
        assertContentEquals(data, got.toByteArray())
        // the first chunk is acked at once, the next two inside 20 ms wait for the tick
        assertEquals(1100L, RemoteStreamPacket.parseAck(lastAck!!))
        assertNull(r.tick(0.06))
        val owed = assertNotNull(r.tick(0.071))
        assertEquals(2500L, RemoteStreamPacket.parseAck(owed))
        assertNull(r.tick(0.2), "nothing more owed")
        assertTrue(s.ack(2500, 0.1).isEmpty())
        assertEquals(0L, s.inFlight)
        assertNull(s.deadline, "nothing in flight, no timer")
        assertEquals(0.1, s.srtt!!, 1e-9)
    }

    @Test fun reorderedAndDuplicateChunks() {
        val r = RemoteStreamReceiver()
        val data = bytes(3300)
        val c = (0 until 3).map { RemoteStreamPacket.chunk(it * 1100L, data, it * 1100, 1100) }
        fun feed(x: ByteArray, now: Double) = RemoteStreamPacket.parseChunk(x)!!.let { (o, b) -> r.received(o, b, now) }
        // the third first: kept, nothing handed out, acked with next = 0
        val a = feed(c[2], 0.0)
        assertEquals(0, a.data.size)
        assertEquals(0L, RemoteStreamPacket.parseAck(a.ack!!))
        // the second, 1 ms later: still a gap before it, so the ack waits
        val b = feed(c[1], 0.001)
        assertEquals(0, b.data.size)
        assertNull(b.ack)
        // the first fills the gap: everything at once, and acked at once despite the 20 ms
        val f = feed(c[0], 0.002)
        assertContentEquals(data, f.data)
        assertEquals(3300L, RemoteStreamPacket.parseAck(f.ack!!))
        // the same chunk again, and one that overlaps the end and goes further
        assertEquals(0, feed(c[1], 0.003).data.size)
        assertEquals(1, r.duplicates)
        val more = bytes(4000, 7)
        val overlap = RemoteStreamPacket.chunk(3000, ByteArray(300) { data[3000 + it] } + more.copyOf(500))
        assertContentEquals(more.copyOf(500), feed(overlap, 0.004).data, "only what's new")
        assertEquals(3800L, r.next)
    }

    @Test fun overlappingEarlyChunksJoinUp() {
        val r = RemoteStreamReceiver()
        val data = bytes(3000)
        fun feed(at: Int, n: Int) = r.received(at.toLong(), data.copyOfRange(at, at + n), 0.0).data
        assertEquals(0, feed(1000, 1000).size)
        assertEquals(0, feed(1500, 1000).size)
        assertEquals(0, feed(1200, 300).size, "inside what it has")
        assertContentEquals(data.copyOf(2500), feed(0, 1100))
        assertContentEquals(data.copyOfRange(2500, 3000), feed(2400, 600))
    }

    @Test fun theReceiverKeepsAWindow() {
        val r = RemoteStreamReceiver()
        val w = RemoteStreamPacket.WINDOW.toLong()
        // early bytes past the window are dropped; at its edge they're cut
        r.received(w + 10, bytes(100), 0.0)
        r.received(w - 50, bytes(100), 0.0)
        val first = r.received(0, bytes(1100), 0.0)
        assertEquals(1100, first.data.size)
        assertEquals(1100L, r.next, "what was kept doesn't join up yet")
        // holding: bytes in order are kept back, and count against the window
        val h = RemoteStreamReceiver(holding = true)
        val got = h.received(0, bytes(1000), 0.0)
        assertEquals(0, got.data.size)
        assertEquals(1000L, h.next, "acked all the same: they arrived")
        assertEquals(1000, h.heldBytes)
        h.received(w, bytes(100), 0.0)
        h.received(w - 1000 - 10, bytes(100), 0.0)
        assertContentEquals(bytes(1000), h.release())
        assertEquals(0, h.heldBytes)
        assertEquals(500, h.received(1000, bytes(500), 0.1).data.size, "handed out from now on")
    }

    @Test fun aFullWindowQueuesTheRest() {
        val s = RemoteStreamSender()
        val w = RemoteStreamPacket.WINDOW
        val out = s.write(ByteArray(w + 5000), 0.0)
        assertEquals(w.toLong(), out.sumOf { lengthOf(it) }.toLong())
        assertEquals(w.toLong(), s.inFlight)
        assertEquals(5000L, s.queued)
        assertTrue(s.write(ByteArray(10), 0.0).isEmpty(), "still full")
        // an ack opens room: exactly that much more goes
        val more = s.ack(2200, 0.05)
        assertEquals(2200, more.sumOf(::lengthOf))
        assertEquals(w.toLong() + 2200, more.last().let { offsetOf(it) + lengthOf(it) })
        assertEquals(w.toLong(), s.inFlight)
        assertEquals(2810L, s.queued)
    }

    @Test fun theTimerResendsAndBacksOff() {
        val s = RemoteStreamSender()
        val out = s.write(bytes(20 * 1100), 0.0)
        assertEquals(20, out.size)
        assertEquals(0.2, s.rto, 1e-9, "no round trip yet: the floor")
        assertEquals(0.2, s.deadline!!, 1e-9)
        assertTrue(s.tick(0.19).isEmpty())
        // no progress for the RTO: again from the acked offset, 8 chunks at most
        val again = s.tick(0.2)
        assertEquals((0 until 8).map { it * 1100L }, again.map(::offsetOf))
        assertEquals(0.4, s.rto, 1e-9, "doubled")
        assertEquals(0.6, s.deadline!!, 1e-9)
        s.tick(0.61)
        assertEquals(0.8, s.rto, 1e-9)
        s.tick(1.42)
        assertEquals(1.6, s.rto, 1e-9)
        s.tick(3.1)
        assertEquals(2.0, s.rto, 1e-9, "up to 2 s")
        s.tick(5.2)
        assertEquals(2.0, s.rto, 1e-9)
        // progress resets it; a round trip measured on a chunk sent once only (Karn), so nothing timed here after the resends
        s.ack(1100, 5.3)
        assertEquals(0.2, s.rto, 1e-9)
        assertEquals(5.5, s.deadline!!, 1e-9)
        assertNull(s.srtt)
        // chunks after the resends are timed
        val t = RemoteStreamSender()
        t.write(bytes(1100), 0.0)
        t.ack(1100, 0.3)
        assertEquals(0.3, t.srtt!!, 1e-9)
        assertEquals(0.6, t.rto, 1e-9, "2 × the smoothed round trip")
        t.write(bytes(1100), 1.0)
        t.ack(2200, 1.1)
        assertEquals(0.3 * 7 / 8 + 0.1 / 8, t.srtt!!, 1e-9)
        // a round trip from the pings before this stream has its own
        assertEquals(0.5, RemoteStreamSender(rtt = 0.25).rto, 1e-9)
    }

    @Test fun threeAcksInARowResendOneChunk() {
        val s = RemoteStreamSender()
        s.write(bytes(5 * 1100), 0.0)
        assertTrue(s.ack(1100, 0.05).isEmpty(), "progress: the first ack saying 1100")
        assertTrue(s.ack(1100, 0.06).isEmpty())
        val one = s.ack(1100, 0.07)
        assertEquals(1, one.size, "the third in a row")
        assertEquals(1100L, offsetOf(one[0]))
        assertEquals(1100, lengthOf(one[0]))
        assertTrue(s.ack(1100, 0.08).isEmpty(), "counting starts over")
        assertTrue(s.ack(1100, 0.09).isEmpty())
        assertEquals(1, s.ack(1100, 0.10).size)
        // old and impossible acks are ignored
        assertTrue(s.ack(0, 0.11).isEmpty())
        assertTrue(s.ack(99_999, 0.11).isEmpty())
        assertEquals(1100L, s.acked)
    }

    /** Two ends over a made-up network: each datagram is lost, delayed, reordered or doubled at random. Everything arrives, in order. */
    @Test fun aLossyNetworkCarriesEverything() {
        for (seed in 1..6) {
            val rnd = Random(seed)
            val loss = 0.05 * seed
            val s = RemoteStreamSender()
            val r = RemoteStreamReceiver()
            data class Pkt(val at: Double, val toReceiver: Boolean, val body: ByteArray)
            val wire = ArrayList<Pkt>()
            fun send(now: Double, toReceiver: Boolean, bodies: List<ByteArray>) {
                for (b in bodies) {
                    if (rnd.nextDouble() < loss) continue
                    val delay = 0.03 + rnd.nextDouble() * 0.04
                    wire += Pkt(now + delay, toReceiver, b)
                    if (rnd.nextDouble() < 0.05) wire += Pkt(now + delay + 0.01, toReceiver, b)
                }
            }
            val data = bytes(400_000, seed)
            val got = java.io.ByteArrayOutputStream()
            var now = 0.0
            var written = 0
            while (got.size() < data.size && now < 120.0) {
                // the app writes in pieces, as frames come
                if (written < data.size) {
                    val n = minOf(3000, data.size - written)
                    send(now, true, s.write(data.copyOfRange(written, written + n), now))
                    written += n
                }
                val due = wire.filter { it.at <= now }.sortedBy { it.at }
                wire.removeAll(due.toSet())
                for (p in due) {
                    if (p.toReceiver) {
                        val (o, b) = RemoteStreamPacket.parseChunk(p.body)!!
                        val res = r.received(o, b, now)
                        got.write(res.data)
                        res.ack?.let { send(now, false, listOf(it)) }
                    } else {
                        send(now, true, s.ack(RemoteStreamPacket.parseAck(p.body)!!, now))
                    }
                }
                r.tick(now)?.let { send(now, false, listOf(it)) }
                send(now, true, s.tick(now))
                now += 0.005
            }
            assertContentEquals(data, got.toByteArray(), "seed $seed, loss $loss")
            if (seed > 1) assertTrue(s.resent > 0, "lost chunks were sent again")
        }
    }

    /** The session's own frames, sealed on channel 0: the counters carry on across the move, so the receiver opens the UDP stream's frames
     *  with the same sealer it read the old stream with. */
    @Test fun framesCarryOnAcrossTheMove() {
        val paired = RemoteCrypto.newKey()
        val phone = PhoneHandshake("dev", paired)
        val answer = MacHandshake.answer(phone.hello()) { paired }
        val phoneSealer = phone.finish(answer.reply)
        val mac = answer.sealer!!
        fun frame(m: ToMac) = RemoteFrameReader.framed(phoneSealer.seal(byteArrayOf(0) + m.encode()))
        // on the old stream: two messages, then the last frame there
        val old = RemoteFrameReader().apply { limit = RemoteFrameReader.MAX_FRAME }
        old.feed(frame(ToMac.Ping(1.0)) + frame(ToMac.Hello("x", true, null, listOf(RemoteFeature.MOVE))) + frame(ToMac.StreamMoved))
        val heard = ArrayList<ToMac>()
        while (true) heard += ToMac.decode(mac.open(old.next() ?: break).let { it.copyOfRange(1, it.size) })!!
        assertEquals(ToMac.StreamMoved, heard.last())
        // then over UDP, out of order, and an audio frame bigger than a chunk
        val s = RemoteStreamSender()
        val audio = bytes(3200)
        val chunks = s.write(frame(ToMac.Ping(2.0)), 0.0) + s.write(RemoteFrameReader.framed(phoneSealer.seal(byteArrayOf(1) + audio)), 0.0) +
            s.write(frame(ToMac.DictationKey(false)), 0.0)
        val r = RemoteStreamReceiver()
        val reader = RemoteFrameReader().apply { limit = RemoteFrameReader.MAX_FRAME }
        for (c in chunks.reversed()) RemoteStreamPacket.parseChunk(c)!!.let { (o, b) -> reader.feed(r.received(o, b, 0.0).data) }
        val after = ArrayList<ByteArray>()
        while (true) after += mac.open(reader.next() ?: break)
        assertEquals(3, after.size)
        assertEquals(ToMac.Ping(2.0), ToMac.decode(after[0].copyOfRange(1, after[0].size)))
        assertContentEquals(byteArrayOf(1) + audio, after[1])
        assertEquals(ToMac.DictationKey(false), ToMac.decode(after[2].copyOfRange(1, after[2].size)))
    }
}
