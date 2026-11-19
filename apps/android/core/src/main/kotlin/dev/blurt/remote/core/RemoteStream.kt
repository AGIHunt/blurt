// The session's stream once it has moved onto the direct UDP path (docs/design/remote-go-between.md §Moving the stream). On the go-between
// the WebSocket only introduces the two ends: after `udpOK` each side writes `streamMoved` as its last frame there, and from then on its
// stream bytes (the same length-prefixed, channel-0-sealed frames, the same implicit counters) travel in kind-7 datagrams, acknowledged by
// kind-8 ones. This is the reliable, ordered part of that: a sender and a receiver, with time passed in (seconds) so tests run on a fake clock.
// Neither is thread-safe; the app drives both from its network thread.
package dev.blurt.remote.core

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.TreeMap

/** The bodies of frame kinds 7 (`stream`) and 8 (`streamAck`), after the kind byte. Numbers are big-endian. */
object RemoteStreamPacket {
    /** stream bytes after the offset field, at most */
    const val MAX_CHUNK = 1100
    /** unacknowledged bytes a sender keeps in flight, and how far past `next` a receiver keeps bytes that came early */
    const val WINDOW = 256 * 1024

    /** u64 BE offset ∥ bytes */
    fun chunk(offset: Long, bytes: ByteArray, from: Int = 0, count: Int = bytes.size - from): ByteArray {
        require(offset >= 0 && count in 0..MAX_CHUNK)
        return ByteBuffer.allocate(8 + count).putLong(offset).put(bytes, from, count).array()
    }

    /** null: shorter than the offset, more than MAX_CHUNK bytes after it, or an offset past what a Long holds */
    fun parseChunk(body: ByteArray): Pair<Long, ByteArray>? {
        if (body.size < 8 || body.size > 8 + MAX_CHUNK) return null
        val offset = ByteBuffer.wrap(body, 0, 8).getLong()
        if (offset < 0) return null
        return offset to body.copyOfRange(8, body.size)
    }

    /** u64 BE next */
    fun ack(next: Long): ByteArray = ByteBuffer.allocate(8).putLong(next).array()

    /** null: not exactly 8 bytes, or past what a Long holds */
    fun parseAck(body: ByteArray): Long? {
        if (body.size != 8) return null
        return ByteBuffer.wrap(body).getLong().takeIf { it >= 0 }
    }
}

/**
 * The sending half. Keeps every byte until it is acknowledged; sends new bytes in chunks of up to 1,100 while fewer than 256 KiB are in
 * flight, and queues the rest. With no progress for RTO = max(200 ms, 2 × smoothed RTT) it sends again from the acknowledged offset, up to
 * 8 chunks, and doubles the RTO, up to 2 s; three acks in a row with the same `next` send one chunk again at once.
 *
 * Every call returns the kind-7 bodies to send now ([RemoteStreamPacket.chunk]), in order.
 */
class RemoteStreamSender(
    /** a round trip already measured (the session's pings), before this stream has one of its own; seconds */
    rtt: Double? = null,
) {
    /** everything before this has been acknowledged */
    var acked = 0L
        private set
    /** everything before this has been sent at least once */
    var sent = 0L
        private set
    /** everything before this has been written */
    var written = 0L
        private set
    val inFlight: Long get() = sent - acked
    /** written, not yet sent: the window is full, or there is no path yet */
    val queued: Long get() = written - sent

    /** smoothed round trip, seconds; null until measured or given */
    var srtt: Double? = rtt
        private set
    private var backoff = 0
    /** the retransmission timeout now, backoff included */
    val rto: Double get() {
        val base = maxOf(MIN_RTO, 2 * (srtt ?: 0.0))
        var r = base
        repeat(backoff) { r *= 2 }
        return minOf(r, maxOf(MAX_RTO, base))
    }

    /** when the retransmission timer fires, while bytes are in flight */
    var deadline: Double? = null
        private set
    /** the same `next` in a row, counting the ack that first said it */
    private var sameAcks = 0
    /** the bytes from `acked` to `written`: buf[start until end] */
    private var buf = ByteArray(64 * 1024)
    private var start = 0
    private var end = 0
    /** first sends, for round trips: chunk end → when; Karn's rule: a chunk sent again isn't timed */
    private val timing = ArrayDeque<Pair<Long, Double>>()
    /** chunks sent so far, first sends and repeats alike */
    var chunksSent = 0
        private set
    var resent = 0
        private set

    fun write(bytes: ByteArray, now: Double): List<ByteArray> {
        if (bytes.isEmpty()) return emptyList()
        if (end + bytes.size > buf.size) {
            val need = end - start + bytes.size
            val nb = if (need * 2 <= buf.size) buf else ByteArray(maxOf(buf.size * 2, need * 2))
            System.arraycopy(buf, start, nb, 0, end - start)
            buf = nb
            end -= start
            start = 0
        }
        System.arraycopy(bytes, 0, buf, end, bytes.size)
        end += bytes.size
        written += bytes.size
        return pump(now)
    }

    /** A kind-8 body's `next`. */
    fun ack(next: Long, now: Double): List<ByteArray> {
        if (next < acked || next > sent) return emptyList()     // an old ack, or one for bytes never sent
        if (next == acked) {
            if (inFlight == 0L) return emptyList()
            sameAcks += 1
            if (sameAcks < 3) return emptyList()
            sameAcks = 0
            timing.clear()
            resent += 1
            chunksSent += 1
            return listOf(chunkAt(acked))
        }
        var sample: Double? = null
        while (timing.isNotEmpty() && timing.first().first <= next) sample = now - timing.removeFirst().second
        sample?.let { s -> srtt = srtt?.let { it * 7 / 8 + s / 8 } ?: s }
        start += (next - acked).toInt()
        acked = next
        backoff = 0
        sameAcks = 1
        deadline = if (inFlight > 0) now + rto else null
        return pump(now)
    }

    /** The retransmission timer: call it often (every 10 ms or so), or at [deadline]. */
    fun tick(now: Double): List<ByteArray> {
        val d = deadline ?: return emptyList()
        if (now < d || inFlight == 0L) return emptyList()
        backoff += 1
        sameAcks = 0
        timing.clear()
        val out = ArrayList<ByteArray>()
        var at = acked
        while (at < sent && out.size < RESEND_CHUNKS) {
            val c = chunkAt(at)
            out += c
            at += c.size - 8
        }
        resent += out.size
        chunksSent += out.size
        deadline = now + rto
        return out
    }

    private fun pump(now: Double): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        while (sent < written && inFlight < RemoteStreamPacket.WINDOW) {
            val n = minOf(RemoteStreamPacket.MAX_CHUNK.toLong(), written - sent, RemoteStreamPacket.WINDOW - inFlight).toInt()
            if (inFlight == 0L) deadline = now + rto
            out += RemoteStreamPacket.chunk(sent, buf, start + (sent - acked).toInt(), n)
            sent += n
            timing.addLast(sent to now)
        }
        chunksSent += out.size
        return out
    }

    /** the chunk that starts at `at`, of what has been sent */
    private fun chunkAt(at: Long): ByteArray {
        val n = minOf(RemoteStreamPacket.MAX_CHUNK.toLong(), sent - at).toInt()
        return RemoteStreamPacket.chunk(at, buf, start + (at - acked).toInt(), n)
    }

    companion object {
        const val MIN_RTO = 0.2
        const val MAX_RTO = 2.0
        const val RESEND_CHUNKS = 8
    }
}

/**
 * The receiving half. Hands out the stream's bytes in order; keeps bytes that came early, up to 256 KiB past `next`; a chunk that overlaps
 * what it has is fine. Acks every chunk, at most once every 20 ms unless the chunk filled a gap; an ack held back goes at [tick].
 *
 * While [holding] (the peer's `streamMoved` hasn't been read from the old stream yet) bytes in order are kept rather than handed out, and
 * they count against the window.
 */
class RemoteStreamReceiver(var holding: Boolean = false) {
    class Result(
        /** the stream's next bytes, in order; empty while holding */
        val data: ByteArray,
        /** a kind-8 body to send now */
        val ack: ByteArray?,
    )

    /** every byte before this has arrived */
    var next = 0L
        private set
    private val early = TreeMap<Long, ByteArray>()
    private val held = ByteArrayOutputStream()
    private var lastAck = Double.NEGATIVE_INFINITY
    private var owed = false
    /** chunks that brought nothing new */
    var duplicates = 0
        private set

    /** bytes arrived in order but not yet handed out */
    val heldBytes: Int get() = held.size()

    fun received(offset: Long, bytes: ByteArray, now: Double): Result {
        val limit = next - held.size() + RemoteStreamPacket.WINDOW
        val end = minOf(offset + bytes.size, limit)
        var out = ByteArray(0)
        var filledGap = false
        when {
            end <= next || offset >= end -> duplicates += 1
            offset <= next -> {
                val gap = early.isNotEmpty()
                val o = ByteArrayOutputStream()
                o.write(bytes, (next - offset).toInt(), (end - next).toInt())
                next = end
                // what came early and now follows on
                while (early.isNotEmpty() && early.firstKey() <= next) {
                    val (at, b) = early.pollFirstEntry().let { it.key to it.value }
                    val bEnd = at + b.size
                    if (bEnd > next) {
                        o.write(b, (next - at).toInt(), (bEnd - next).toInt())
                        next = bEnd
                    }
                }
                filledGap = gap
                out = o.toByteArray()
            }
            else -> {
                val keep = if (end < offset + bytes.size) bytes.copyOf((end - offset).toInt()) else bytes
                val floor = early.floorEntry(offset)
                val covered = floor != null && floor.key + floor.value.size >= end
                if (!covered) early[offset] = keep else duplicates += 1
            }
        }
        if (holding && out.isNotEmpty()) {
            held.write(out)
            out = ByteArray(0)
        }
        val ack = if (filledGap || now - lastAck >= ACK_GAP) ackNow(now) else { owed = true; null }
        return Result(out, ack)
    }

    /** An ack held back, once 20 ms have passed since the last. */
    fun tick(now: Double): ByteArray? = if (owed && now - lastAck >= ACK_GAP) ackNow(now) else null

    /** The peer's `streamMoved` was read: what was held, and from now on everything is handed out as it comes. */
    fun release(): ByteArray {
        holding = false
        val b = held.toByteArray()
        held.reset()
        return b
    }

    private fun ackNow(now: Double): ByteArray {
        lastAck = now
        owed = false
        return RemoteStreamPacket.ack(next)
    }

    companion object {
        const val ACK_GAP = 0.02
    }
}
