// Repairing the picture instead of starting it over (Swift: BlurtRemoteKit/RemoteVideoRepair.swift; docs/design/remote-realtime.md). Before
// this, one piece lost on the way cost the whole frame, every frame after it, and a keyframe of 50–100 KB that took a round trip to ask for.
// Three repairs, each offered by the phone in its screen request and answered by the host in screenView, so an older phone or host goes on
// as before:
//
//  • nack: the phone says which pieces are missing, the host sends them again from what it kept. On a home network that's back in a few ms,
//    well before the frame is due; the phone holds the frames behind it meanwhile, since they can't be decoded without it.
//  • ltr: the phone acknowledges the frames the host marks; a frame that's gone for good costs one small frame made from an acknowledged
//    one (a refresh), not a keyframe.
//  • fec: one parity piece per group of pieces, so a single loss in a group is mended without asking. Only where a round trip is long.
package dev.blurt.remote.core

import java.io.ByteArrayOutputStream

object RemoteVideoFeature {
    const val NACK = "nack"
    const val LTR = "ltr"
    const val FEC = "fec"
    /** everything this library implements; the app offers `ltr` only on decoders known to take a refresh */
    val ALL = listOf(NACK, LTR, FEC)
}

/** What the phone tells the host about the picture: datagrams of kind VIDEO_FEEDBACK, first byte the type, numbers big-endian. */
sealed class RemoteVideoFeedback {
    /** `pieces` by index; empty: the whole frame (nothing of it arrived, so its size isn't known). frame u32, pieces u16. */
    data class Missing(val frame: Long, val pieces: List<Int>)

    /** 1: send these again. Repeated: u32 frame, u16 n (0xFFFF = the whole frame), n × u16 index */
    data class Nack(val missing: List<Missing>) : RemoteVideoFeedback()
    /** 2: decoded, of the frames that asked for it: u32 the newest, u32 a bit for each of the 32 before it (bit 0 = newest − 1) */
    data class Ack(val newest: Long, val earlier: Long) : RemoteVideoFeedback()
    /** 3: the frame after this one is gone for good: a refresh (or a keyframe if nothing is acknowledged). u32 the last frame decoded */
    data class Lost(val after: Long) : RemoteVideoFeedback()

    fun encoded(): ByteArray {
        val d = ByteArrayOutputStream()
        fun u32(v: Long) { for (s in intArrayOf(24, 16, 8, 0)) d.write((v ushr s).toInt() and 0xFF) }
        fun u16(v: Int) { d.write((v ushr 8) and 0xFF); d.write(v and 0xFF) }
        when (this) {
            is Nack -> {
                d.write(1)
                for (f in missing) {
                    u32(f.frame)
                    u16(if (f.pieces.isEmpty()) 0xFFFF else f.pieces.size)
                    f.pieces.forEach(::u16)
                }
            }
            is Ack -> { d.write(2); u32(newest); u32(earlier) }
            is Lost -> { d.write(3); u32(after) }
        }
        return d.toByteArray()
    }

    companion object {
        const val MAX_SIZE = 1100

        /** null for anything that isn't one. */
        fun decode(b: ByteArray): RemoteVideoFeedback? {
            var at = 1
            fun u32(): Long? {
                if (at + 4 > b.size) return null
                var v = 0L
                repeat(4) { v = (v shl 8) or (b[at + it].toLong() and 0xFF) }
                at += 4
                return v
            }
            fun u16(): Int? {
                if (at + 2 > b.size) return null
                val v = (b[at].toInt() and 0xFF) shl 8 or (b[at + 1].toInt() and 0xFF)
                at += 2
                return v
            }
            if (b.isEmpty()) return null
            return when (b[0].toInt()) {
                1 -> {
                    val m = ArrayList<Missing>()
                    while (at < b.size) {
                        val f = u32() ?: return null
                        val n = u16() ?: return null
                        if (n == 0xFFFF) { m += Missing(f, emptyList()); continue }
                        val p = ArrayList<Int>(n)
                        repeat(n) { p += u16() ?: return null }
                        m += Missing(f, p)
                    }
                    if (m.isEmpty()) null else Nack(m)
                }
                2 -> Ack(u32() ?: return null, u32() ?: return null)
                3 -> Lost(u32() ?: return null)
                else -> null
            }
        }

        /** Several frames' worth, in datagrams that fit. */
        fun nacks(m: List<Missing>): List<RemoteVideoFeedback> {
            val out = ArrayList<RemoteVideoFeedback>()
            var cur = ArrayList<Missing>()
            var size = 1
            for (f0 in m) {
                val f = if (f0.pieces.size > 400) f0.copy(pieces = f0.pieces.take(400)) else f0
                val n = 6 + 2 * f.pieces.size
                if (size + n > MAX_SIZE && cur.isNotEmpty()) { out += Nack(cur); cur = ArrayList(); size = 1 }
                cur += f
                size += n
            }
            if (cur.isNotEmpty()) out += Nack(cur)
            return out
        }
    }
}

/**
 * Parity pieces, about one for every `group` pieces: the frame's n groups are interleaved (piece i is in group i mod n), so a burst of up to n
 * pieces lost in a row, as Wi-Fi loses them, costs each group at most one. Parity piece k (index count + k) is one byte n, then the XOR of
 * each member's length (2 bytes) and payload, zero-padded to the longest. Any one piece missing from a group is rebuilt from the rest.
 */
object RemoteVideoFEC {
    /** parity pieces a frame may carry: an index at count + MAX_PARITY or beyond is not a piece */
    const val MAX_PARITY = 64

    fun parity(pieces: List<RemoteVideoPacket>, group: Int): List<RemoteVideoPacket> {
        val first = pieces.firstOrNull() ?: return emptyList()
        if (group < 2 || pieces.size < 2) return emptyList()
        val n = minOf(MAX_PARITY, (pieces.size + group - 1) / group)
        return (0 until n).mapNotNull { k ->
            val members = (k until pieces.size step n).map { pieces[it] }
            if (members.size < 2) return@mapNotNull null    // a group of one gains nothing over sending it twice
            val len = members.maxOf { it.payload.size }
            val x = ByteArray(2 + len)
            for (m in members) xor(x, m.payload)
            first.with(first.count + k, byteArrayOf(n.toByte()) + x)
        }
    }

    private fun xor(x: ByteArray, payload: ByteArray) {
        val n = payload.size
        x[0] = (x[0].toInt() xor (n ushr 8)).toByte()
        x[1] = (x[1].toInt() xor (n and 255)).toByte()
        for (i in payload.indices) x[i + 2] = (x[i + 2].toInt() xor payload[i].toInt()).toByte()
    }

    /** The one piece missing from a parity piece's group, if exactly one is: (index, payload). */
    fun recover(parity: ByteArray, slot: Int, count: Int, have: Map<Int, ByteArray>): Pair<Int, ByteArray>? {
        if (parity.size < 3) return null
        val n = parity[0].toInt() and 0xFF
        if (n < 1 || slot >= n) return null
        val members = (slot until count step n).toList()
        val missing = members.filter { have[it] == null }
        if (missing.size != 1) return null
        val x = parity.copyOfRange(1, parity.size)
        for (i in members) {
            if (i == missing[0]) continue
            val p = have[i] ?: return null
            if (p.size + 2 > x.size) return null
            xor(x, p)
        }
        val len = (x[0].toInt() and 0xFF) shl 8 or (x[1].toInt() and 0xFF)
        if (len + 2 > x.size) return null
        return missing[0] to x.copyOfRange(2, 2 + len)
    }
}

/** The host's recent pieces, to send again when the phone says they're missing. A second at most, and only what fits. Not thread-safe. */
class RemoteVideoHistory(val maxAge: Double = 1.0, val maxBytes: Int = 6_000_000) {
    private class Kept(val id: Long, val at: Double, val packets: List<ByteArray>) { val bytes = packets.sumOf { it.size } }
    private val frames = ArrayDeque<Kept>()
    private var bytes = 0

    /** One frame's pieces, encoded (RemoteVideoPacket.encoded), parity pieces left out. */
    fun add(id: Long, packets: List<ByteArray>, now: Double) {
        val k = Kept(id, now, packets)
        frames.addLast(k)
        bytes += k.bytes
        while (frames.size > 1) {
            val f = frames.first()
            if (!(now - f.at > maxAge || bytes > maxBytes)) break
            bytes -= f.bytes
            frames.removeFirst()
        }
    }

    /** The pieces asked for (empty: all of them), if the frame is still here. */
    fun pieces(id: Long, indices: List<Int>): List<ByteArray> {
        val f = frames.lastOrNull { it.id == id } ?: return emptyList()
        if (indices.isEmpty()) return f.packets
        return indices.mapNotNull { f.packets.getOrNull(it) }
    }

    fun clear() { frames.clear(); bytes = 0 }
}

/**
 * The phone's side: pieces in, frames out in order, and what to tell the host. Frames behind a missing piece wait for it to be sent again,
 * up to a limit set by the round trip; then the frame is given up and the host asked for a refresh (or a keyframe). Time is passed in, so
 * this is a pure state machine and its tests run without a clock. Not thread-safe: one thread feeds it, ticks it and tells it what decoded.
 */
class RemoteVideoReceiver(
    /** what the host said it does (screenView.features): with neither, nothing waits and a loss asks for a keyframe, as before them */
    var nack: Boolean,
    var ltr: Boolean,
    now: Double = 0.0,
) {
    sealed class Output {
        data class Frame(val frame: RemoteVideoAssembler.Frame) : Output()
        data class Feedback(val feedback: RemoteVideoFeedback) : Output()
        /** ask for a keyframe the old way (ToMac.RequestKeyframe): nothing can be decoded until one comes */
        data object Keyframe : Output()
    }

    private class Asked(val at: Double, val times: Int)

    private class Partial(
        val count: Int, val key: Boolean, val refresh: Boolean, val ack: Boolean, val captured: Double, val firstAt: Double, var lastAt: Double,
    ) {
        val pieces = HashMap<Int, ByteArray>()
        val parity = HashMap<Int, ByteArray>()
        /** when each missing piece was last asked for, and how often */
        val asked = HashMap<Int, Asked>()
        var highest = 0
        val complete: Boolean get() = pieces.size == count
    }

    /** the last measured round trip, seconds */
    var rtt = 0.01
    private val partials = HashMap<Long, Partial>()
    /** frames known only from a gap in the numbers: when each was last asked for, and how often */
    private val whole = HashMap<Long, Asked>()
    /** the frame that decodes next; null until the first keyframe */
    private var next: Long? = null
    private var newest: Long? = null
    /** nothing can be decoded until a keyframe, or with ltr a refresh, arrives */
    var broken = true
        private set
    /** the decoder lost its references: only a keyframe will do */
    private var needsKey = true
    private var brokenAt = now
    private var askedAt = -1.0
    /** when frame `next` was first seen to be late */
    private var lateSince: Double? = null
    /** how long it has been late while pieces were arriving and the phone was running: what the patience is measured against */
    private var lateFor = 0.0
    /** when any piece last arrived. Nothing at all for a while is a stall (a radio dozing, a busy channel), not a loss: everything held up
     *  arrives together afterwards, so nothing is given up and nothing asked for twice meanwhile */
    private var heardAt = -1.0
    /** when `tick` last ran: one much later than the last means the phone itself wasn't running (a hitch), not that the network lost
     *  anything; what arrived meanwhile hasn't been read yet */
    private var tickedAt: Double? = null
    private val acks = ArrayList<Long>()
    private var ackedAt = -1.0
    var dropped = 0
        private set
    var repaired = 0
        private set
    var nacked = 0
        private set
    var refreshes = 0
        private set

    /** How long frames wait behind a missing one before it's given up: a few round trips, within reason. Without nack, not at all. */
    val patience: Double get() = if (nack) minOf(0.15, maxOf(0.04, rtt * 3 + 0.02)) else 0.0
    private val retry: Double get() = maxOf(0.012, rtt * 1.5)
    /** pieces of a frame still arriving: the end of a frame is asked for only after this quiet (keyframes on a direct path come in paced batches) */
    private val tailWait: Double get() = maxOf(0.03, rtt * 2)

    fun add(p: RemoteVideoPacket, now: Double): List<Output> {
        next?.let { if (p.frame < it) return emptyList() }       // decoded already, or given up: a second copy, or late
        // waiting to start over: only what can end the wait is worth keeping
        if (broken && !p.keyframe && !(p.refresh && ltr && !needsKey)) return emptyList()
        if (partials[p.frame] == null) {
            if (partials.size > 120) partials.keys.min().let { partials.remove(it) }
            partials[p.frame] = Partial(p.count, p.keyframe, p.refresh, p.ackRequested, p.captured, now, now)
            whole.remove(p.frame)
        }
        val f = partials[p.frame]!!
        if (f.count != p.count) return emptyList()
        f.lastAt = now
        heardAt = now
        if (p.isParity) {
            f.parity[p.index - p.count] = p.payload
        } else if (f.pieces[p.index] == null) {
            f.pieces[p.index] = p.payload
            f.asked.remove(p.index)
            f.highest = maxOf(f.highest, p.index)
        }
        if (!f.complete && f.parity.isNotEmpty()) {
            for ((slot, par) in f.parity) {
                val (i, d) = RemoteVideoFEC.recover(par, slot, f.count, f.pieces) ?: continue
                f.pieces[i] = d
                f.asked.remove(i)
                repaired += 1
            }
        }
        val n = newest
        if (n == null || p.frame > n) {
            // a gap in the numbers: whole frames to ask for (bounded: a jump past a second of frames is a new start, not a loss)
            if (nack && n != null && p.frame > n + 1) {
                val nx = next
                for (g in maxOf(n + 1, p.frame - 120) until p.frame) {
                    if (partials[g] == null && whole[g] == null && nx != null && g >= nx) whole[g] = Asked(0.0, 0)
                }
            }
            newest = p.frame
        }
        return drain()
    }

    /** Frames ready to decode, in order. */
    private fun drain(): List<Output> {
        val out = ArrayList<Output>()
        while (true) {
            // a whole keyframe jumps over anything before it
            val floor = next ?: 0
            val k = partials.entries.filter { it.value.complete && it.value.key && it.key >= floor }.minOfOrNull { it.key }
            if (k != null && (broken || k != next)) {
                out += Output.Frame(release(k))
                continue
            }
            if (broken) {
                // with references acknowledged, a refresh will do
                val n = next
                if (ltr && !needsKey && n != null) {
                    val r = partials.entries.filter { it.value.complete && it.value.refresh && it.key >= n }.minOfOrNull { it.key }
                    if (r != null) {
                        refreshes += 1
                        out += Output.Frame(release(r))
                        continue
                    }
                }
                break
            }
            val n = next ?: break
            if (partials[n]?.complete != true) break
            out += Output.Frame(release(n))
        }
        return out
    }

    private fun release(id: Long): RemoteVideoAssembler.Frame {
        val f = partials[id]!!
        val data = ByteArrayOutputStream()
        for (i in 0 until f.count) data.write(f.pieces[i] ?: ByteArray(0))
        next?.let { if (id > it) dropped += (id - it).toInt() }
        partials.keys.removeAll { it < id }
        whole.keys.removeAll { it <= id }
        partials.remove(id)
        next = id + 1
        if (f.key) needsKey = false
        broken = false
        lateSince = null
        return RemoteVideoAssembler.Frame(data.toByteArray(), f.key, f.captured, id, f.refresh, f.ack).also {
            it.firstAt = f.firstAt
            it.lastAt = f.lastAt
        }
    }

    /** Timers: missing pieces asked for, frames given up, the host asked to start over. Call every few ms while the picture is on.
     *  The patience counts only while pieces arrive and the phone is running. In a stall nothing can be asked again, and when it ends
     *  the piece asked for gets its retry before the frame is given up. A tick long after the last one gives nothing up: the phone was
     *  busy, and the pieces that came meanwhile (the one asked for among them) are still to be read. */
    fun tick(now: Double): List<Output> {
        val out = ArrayList<Output>()
        val sinceTick = tickedAt?.let { now - it } ?: 0.0
        val away = sinceTick > AWAY
        if (away) lateSince = lateSince?.plus(sinceTick)
        tickedAt = now
        // a frame that can't come: give up on it, and everything behind it waits for a refresh
        val n = next
        if (!broken && n != null) {
            val f = partials[n]
            val nw = newest
            val late = if (f != null) !f.complete && ((nw != null && nw > n) || now - f.lastAt > tailWait) else (nw != null && nw >= n)
            if (late) {
                val stalled = now - heardAt > QUIET
                val since = lateSince?.also { if (!away && !stalled) lateFor += sinceTick } ?: now.also {
                    lateFor = 0.0
                    lateSince = it
                }
                if (!away && ((lateFor >= patience && !stalled) || now - since >= LONGEST)) {
                    broken = true
                    brokenAt = now
                    askedAt = -1.0
                    lateSince = null
                    // what's behind it is no use now, except what could end the wait
                    partials.values.removeAll { !it.key && !it.refresh }
                    whole.clear()
                }
            } else {
                lateSince = null
            }
        }
        if (broken) {
            // at the start the first keyframe is on its way: ask only if it doesn't come
            val started = next == null && askedAt < 0
            if (now - askedAt >= 0.25 && (!started || now - brokenAt > 0.3)) {
                askedAt = now
                val nx = next
                out += if (ltr && !needsKey && nx != null) Output.Feedback(RemoteVideoFeedback.Lost(nx - 1)) else Output.Keyframe
            }
        }
        if (nack) out += missing(now)
        if (acks.isNotEmpty() && now - ackedAt >= 0.02) out += Output.Feedback(takeAck(now))
        return out
    }

    /** What to ask for again, now. */
    private fun missing(now: Double): List<Output> {
        val want = ArrayList<RemoteVideoFeedback.Missing>()
        val floor = next ?: 0
        for (id in partials.keys.sorted()) {
            val f = partials[id]!!
            if (f.complete || id < floor) continue
            // while broken only what could end it is worth having
            if (broken && !(f.key || (f.refresh && ltr && !needsKey))) continue
            val later = newest?.let { it > id } ?: false
            val ask = ArrayList<Int>()
            for (i in 0 until f.count) {
                if (f.pieces[i] != null) continue
                // a hole before the newest piece of the frame, or the end once it's been quiet (or a later frame has begun)
                if (!(i < f.highest || later || now - f.lastAt > tailWait)) continue
                // asked already: again after a round trip and a half, but not into a stall
                val a = f.asked[i]
                if (a != null && !(a.times < 4 && now - a.at >= retry && now - heardAt <= QUIET)) continue
                ask += i
                f.asked[i] = Asked(now, (a?.times ?: 0) + 1)
            }
            if (ask.isEmpty()) continue
            want += RemoteVideoFeedback.Missing(id, ask)
            nacked += ask.size
        }
        if (!broken) {
            for (id in whole.keys.sorted()) {
                val a = whole[id]!!
                if (id < floor || a.times >= 4 || now - a.at < retry) continue
                whole[id] = Asked(now, a.times + 1)
                want += RemoteVideoFeedback.Missing(id, emptyList())
                nacked += 1
            }
        }
        return RemoteVideoFeedback.nacks(want).map { Output.Feedback(it) }
    }

    /** The decoder took this frame: if the host asked, it hears so (in a batch, every 20 ms at most). */
    fun decoded(f: RemoteVideoAssembler.Frame, now: Double): List<Output> {
        if (!ltr || !f.ackRequested) return emptyList()
        acks += f.id
        if (now - ackedAt < 0.02) return emptyList()
        return listOf(Output.Feedback(takeAck(now)))
    }

    private fun takeAck(now: Double): RemoteVideoFeedback {
        val n = acks.max()
        var bits = 0L
        for (a in acks) if (a < n && n - a <= 32) bits = bits or (1L shl (n - a - 1).toInt())
        acks.clear()
        ackedAt = now
        return RemoteVideoFeedback.Ack(n, bits)
    }

    /** The decoder failed: its references are gone, only a keyframe helps. */
    fun decoderFailed(now: Double) {
        broken = true
        needsKey = true
        brokenAt = now
        askedAt = -1.0
        acks.clear()
    }

    private companion object {
        const val QUIET = 0.02
        /** a stall this long is given up on regardless */
        const val LONGEST = 0.35
        /** ticks further apart than this: the phone was busy (a frame at 60 Hz without one) */
        const val AWAY = 0.015
    }
}
