// The screen as a stream of small datagrams (Swift: RemoteVideo.swift; docs/design/remote.md §Screen). A frame is cut into pieces that each
// fit a Wi-Fi packet. Without repairs a frame missing a piece is dropped, and since the frames after it can't be decoded either, the phone asks
// for a keyframe; with them (RemoteVideoRepair.kt, docs/design/remote-realtime.md) the missing piece is asked for again or rebuilt.
package dev.blurt.remote.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** A part of the source, 0…1. The phone decides what's in view; the host sends that part and says with each frame which part it is. */
data class RemoteCrop(val x: Float, val y: Float, val w: Float, val h: Float) {
    /** Inside the source and not absurdly small, whatever arrived. */
    val valid: RemoteCrop
        get() {
            if (!(x.isFinite() && y.isFinite() && w.isFinite() && h.isFinite())) return WHOLE
            val w = minOf(1f, maxOf(0.1f, w))
            val h = minOf(1f, maxOf(0.1f, h))
            return RemoteCrop(minOf(1 - w, maxOf(0f, x)), minOf(1 - h, maxOf(0f, y)), w, h)
        }

    fun toJson(): JsonObject = J.obj("x" to J.float(x), "y" to J.float(y), "w" to J.float(w), "h" to J.float(h))

    companion object {
        val WHOLE = RemoteCrop(0f, 0f, 1f, 1f)

        fun centered(zoom: Float): RemoteCrop {
            val s = 1 / maxOf(1f, zoom)
            return RemoteCrop((1 - s) / 2, (1 - s) / 2, s, s)
        }

        fun fromJson(e: JsonElement?): RemoteCrop? {
            val o = e as? JsonObject ?: return null
            return RemoteCrop(J.float(o, "x") ?: return null, J.float(o, "y") ?: return null, J.float(o, "w") ?: return null, J.float(o, "h") ?: return null)
        }
    }
}

object RemoteVideoCodec {
    const val HEVC = "hevc"
    const val H264 = "h264"
    /** what an Apple phone asks for; an Android phone sends what MediaCodec decodes, best first */
    val DECODABLE = listOf(HEVC, H264)
}

data class RemoteScreenRequest(
    /** "display": the screen with the pointer. "window": the window titled "Blurt Screen Test". */
    val target: String,
    val crop: RemoteCrop = RemoteCrop.WHOLE,
    val width: Int,
    val height: Int,
    val bitrate: Int,
    val fps: Int = 60,
    /** what the phone decodes, best first; null = HEVC only (phones before 1.0.15) */
    val codecs: List<String>? = RemoteVideoCodec.DECODABLE,
    /** a RemoteDisplay id to show; null = the display the pointer is on, following it from display to display (the default) */
    val display: String? = null,
    /** the repairs this phone does (RemoteVideoFeature); null = none, as from phones before 1.0.15 */
    val features: List<String>? = null,
) {
    fun toJson(): JsonObject = J.obj(
        "target" to J.str(target), "crop" to crop.toJson(), "width" to J.int(width), "height" to J.int(height), "bitrate" to J.int(bitrate),
        "fps" to J.int(fps), "codecs" to J.list(codecs) { JsonPrimitive(it) }, "display" to J.str(display),
        "features" to J.list(features) { JsonPrimitive(it) },
    )

    companion object {
        fun fromJson(e: JsonElement?): RemoteScreenRequest? {
            val o = e as? JsonObject ?: return null
            fun strings(k: String): List<String>? = J.list(o, k) { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            val codecs = if (J.has(o, "codecs")) strings("codecs") ?: return null else null
            val features = if (J.has(o, "features")) strings("features") ?: return null else null
            return RemoteScreenRequest(
                J.str(o, "target") ?: return null, RemoteCrop.fromJson(o["crop"]) ?: return null, J.int(o, "width") ?: return null,
                J.int(o, "height") ?: return null, J.int(o, "bitrate") ?: return null, J.int(o, "fps") ?: return null, codecs,
                J.str(o, "display"), features,
            )
        }
    }
}

/** What the phone got since its last report. */
data class RemoteScreenReport(
    val frames: Int,
    /** frames that never arrived whole */
    val lost: Int,
    /** seconds, the last ping's round trip */
    val rtt: Double?,
    /** bytes of picture since this stream began */
    val received: Int,
) {
    fun toJson(): JsonObject = J.obj("frames" to J.int(frames), "lost" to J.int(lost), "rtt" to J.double(rtt), "received" to J.int(received))

    companion object {
        fun fromJson(e: JsonElement?): RemoteScreenReport? {
            val o = e as? JsonObject ?: return null
            return RemoteScreenReport(J.int(o, "frames") ?: return null, J.int(o, "lost") ?: return null, J.double(o, "rtt"), J.int(o, "received") ?: return null)
        }
    }
}

/**
 * One piece of a frame: 17-byte header (frame u32 BE, index u16 BE, count u16 BE, flags u8, captured f64 BE) ∥ payload.
 * Flags: bit 0 keyframe, bit 1 refresh, bit 2 acknowledge (the last two only to a phone that offered "ltr"). An index from `count` up is a
 * parity piece (RemoteVideoFEC), only to a phone that offered "fec".
 */
class RemoteVideoPacket(
    /** u32 */
    val frame: Long,
    /** u16: below count, a piece of the frame; count and up, a parity piece */
    val index: Int,
    /** u16 */
    val count: Int,
    val keyframe: Boolean,
    /** when the host composed it, on the host's clock */
    val captured: Double,
    val payload: ByteArray,
    /** decodable from references the phone has acknowledged, after a loss */
    val refresh: Boolean = false,
    /** the phone acknowledges this frame once it's decoded: the host may refer back to it after a loss */
    val ackRequested: Boolean = false,
) {
    val isParity: Boolean get() = index >= count

    /** The ninth byte. A phone before 1.0.15 reads keyframe as "== 1" and is never sent the others. */
    val flags: Int get() = (if (keyframe) 1 else 0) or (if (refresh) 2 else 0) or (if (ackRequested) 4 else 0)

    fun encoded(): ByteArray {
        val b = ByteBuffer.allocate(HEADER_SIZE + payload.size).order(ByteOrder.BIG_ENDIAN)
        b.putInt(frame.toInt()).putShort(index.toShort()).putShort(count.toShort()).put(flags.toByte()).putLong(captured.toRawBits()).put(payload)
        return b.array()
    }

    /** The same header with another index and payload: a parity piece carries its frame's. */
    fun with(index: Int, payload: ByteArray) = RemoteVideoPacket(frame, index, count, keyframe, captured, payload, refresh, ackRequested)

    override fun equals(other: Any?): Boolean = other is RemoteVideoPacket && other.frame == frame && other.index == index && other.count == count &&
        other.flags == flags && other.captured.toRawBits() == captured.toRawBits() && other.payload.contentEquals(payload)

    override fun hashCode(): Int = (frame * 31 + index).toInt() * 31 + payload.contentHashCode()
    override fun toString(): String =
        "RemoteVideoPacket(frame=$frame, index=$index, count=$count, flags=$flags, captured=$captured, ${payload.size} bytes)"

    companion object {
        const val HEADER_SIZE = 17
        const val PAYLOAD_SIZE = 1180

        fun decode(d: ByteArray): RemoteVideoPacket? {
            if (d.size < HEADER_SIZE) return null
            val b = ByteBuffer.wrap(d).order(ByteOrder.BIG_ENDIAN)
            val frame = b.getInt().toLong() and 0xFFFF_FFFFL
            val index = b.getShort().toInt() and 0xFFFF
            val count = b.getShort().toInt() and 0xFFFF
            val flags = b.get().toInt()
            val captured = Double.fromBits(b.getLong())
            if (count <= 0 || index >= count + RemoteVideoFEC.MAX_PARITY) return null
            return RemoteVideoPacket(frame, index, count, flags and 1 != 0, captured, d.copyOfRange(HEADER_SIZE, d.size), flags and 2 != 0, flags and 4 != 0)
        }

        /** One encoded frame, in pieces. */
        fun split(
            data: ByteArray, frame: Long, keyframe: Boolean, captured: Double, size: Int = PAYLOAD_SIZE,
            refresh: Boolean = false, ackRequested: Boolean = false,
        ): List<RemoteVideoPacket> {
            val count = maxOf(1, (data.size + size - 1) / size)
            return (0 until count).map { i ->
                val start = i * size
                val end = minOf(start + size, data.size)
                RemoteVideoPacket(frame, i, count, keyframe, captured, data.copyOfRange(start, end), refresh, ackRequested)
            }
        }
    }
}

/** Pieces in, whole frames out, in order, and never a frame the decoder couldn't use. Not thread-safe. */
class RemoteVideoAssembler {
    class Frame(
        val data: ByteArray, val keyframe: Boolean, val captured: Double, val id: Long,
        val refresh: Boolean = false, val ackRequested: Boolean = false,
    ) {
        /** when its first and last pieces arrived, on the phone's clock (0 when not measured) */
        var firstAt = 0.0
        var lastAt = 0.0

        override fun equals(other: Any?): Boolean = other is Frame && other.data.contentEquals(data) && other.keyframe == keyframe &&
            other.captured == captured && other.id == id && other.refresh == refresh && other.ackRequested == ackRequested

        override fun hashCode(): Int = data.contentHashCode() * 31 + id.hashCode()
        override fun toString(): String = "Frame(id=$id, keyframe=$keyframe, refresh=$refresh, ${data.size} bytes)"
    }

    private var current: Long? = null
    private var pieces = HashMap<Int, ByteArray>()
    private var total = 0
    private var key = false
    private var captured = 0.0
    private var lastDone: Long? = null
    private var lastComplete: Long? = null
    /** the gap ahead of this frame has been counted */
    private var noted = false

    /** a frame was lost: nothing can be decoded until the next keyframe */
    var waitingForKey = true
        private set
    var dropped = 0
        private set

    /** A frame, if this piece finished one. */
    fun add(p: RemoteVideoPacket): Frame? {
        if (p.isParity) return null                              // only RemoteVideoReceiver uses them
        lastDone?.let { if (p.frame <= it) return null }        // late
        if (current != p.frame) {
            current?.let { if (p.frame < it) return null }      // late, and a newer one has begun
            if (current != null) { dropped += 1; waitingForKey = true; noted = true }   // the frame before never finished
            current = p.frame
            pieces = HashMap()
            total = p.count
            key = p.keyframe
            captured = p.captured
        }
        pieces[p.index] = p.payload
        if (pieces.size != total) return null
        val out = java.io.ByteArrayOutputStream()
        for (i in 0 until total) out.write(pieces[i] ?: ByteArray(0))
        lastDone = p.frame
        current = null
        pieces = HashMap()
        val previous = lastComplete
        if (previous != null && p.frame != ((previous + 1) and 0xFFFF_FFFFL)) {
            waitingForKey = true
            if (!noted) dropped += 1
        }
        noted = false
        lastComplete = p.frame
        if (key) waitingForKey = false
        return if (waitingForKey) null else Frame(out.toByteArray(), key, captured, p.frame)
    }
}

/** The part of the source this frame shows (four f32 LE), then the keyframe's parameter sets (a count, then each with a 2-byte BE length), then its picture. */
object RemoteVideoPayload {
    class Unpacked(val crop: RemoteCrop, val parameterSets: List<ByteArray>, val picture: ByteArray) {
        override fun equals(other: Any?): Boolean = other is Unpacked && other.crop == crop && other.parameterSets.size == parameterSets.size &&
            other.parameterSets.zip(parameterSets).all { it.first.contentEquals(it.second) } && other.picture.contentEquals(picture)

        override fun hashCode(): Int = crop.hashCode() * 31 + picture.contentHashCode()
    }

    fun pack(crop: RemoteCrop, parameterSets: List<ByteArray>, picture: ByteArray): ByteArray {
        val size = 17 + parameterSets.sumOf { 2 + it.size } + picture.size
        val b = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
        for (v in listOf(crop.x, crop.y, crop.w, crop.h)) b.putFloat(v)
        b.put(parameterSets.size.toByte())
        for (p in parameterSets) {
            b.put((p.size shr 8).toByte()).put((p.size and 255).toByte())
            b.put(p)
        }
        b.put(picture)
        return b.array()
    }

    fun unpack(d: ByteArray): Unpacked? {
        if (d.size < 17) return null
        val b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN)
        val crop = RemoteCrop(b.getFloat(0), b.getFloat(4), b.getFloat(8), b.getFloat(12)).valid
        val n = d[16].toInt() and 0xFF
        var at = 17
        val sets = ArrayList<ByteArray>(n)
        repeat(n) {
            if (at + 2 > d.size) return null
            val len = (d[at].toInt() and 0xFF) shl 8 or (d[at + 1].toInt() and 0xFF)
            at += 2
            if (at + len > d.size) return null
            sets += d.copyOfRange(at, at + len)
            at += len
        }
        return Unpacked(crop, sets, d.copyOfRange(at, d.size))
    }
}
