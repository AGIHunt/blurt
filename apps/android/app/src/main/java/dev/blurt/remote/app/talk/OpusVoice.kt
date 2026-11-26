// Voice as Opus on Blurt's public relay (frame kind 9, docs/design/remote-go-between.md §What the devices do on this path; Swift:
// BlurtRemoteKit/RemoteOpus.swift): 20 ms packets of 16 kHz mono at about 32 kbps, instead of 256 kbps of PCM. Android's own encoder
// (MediaCodec "audio/opus", in the system from Android 10), nothing downloaded. The rest of the app keeps speaking PCM16: the encoder takes the
// same bytes the phone would send as kind 1, and gives back whole raw Opus packets, one per 20 ms, without Ogg or any other wrapping.
package dev.blurt.remote.app.talk

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build

class OpusVoice private constructor(private val codec: MediaCodec) {
    private val info = MediaCodec.BufferInfo()
    private var pending = ByteArray(0)
    /** microseconds of audio queued so far: the encoder wants time to go on */
    private var pts = 0L
    private var dead = false

    /** `pcm`: 16 kHz mono PCM16 little-endian, any length. Returns the packets it completes; what's left over waits for the next call. */
    fun encode(pcm: ByteArray): List<ByteArray> {
        if (dead) return emptyList()
        val out = ArrayList<ByteArray>()
        pending += pcm
        var at = 0
        var full = 0
        try {
            while (pending.size - at >= FRAME_BYTES) {
                val i = codec.dequeueInputBuffer(10_000)
                if (i < 0) {
                    drain(out, 0)
                    // an encoder that takes nothing for 200 ms: what's left waits for the next piece
                    if (++full >= 20) break
                    continue
                }
                val buf = codec.getInputBuffer(i) ?: break
                buf.clear()
                buf.put(pending, at, FRAME_BYTES)
                codec.queueInputBuffer(i, 0, FRAME_BYTES, pts, 0)
                pts += FRAME_US
                at += FRAME_BYTES
                drain(out, 0)
            }
            // the encoder works on its own thread: what it has finished by now goes with this piece, the rest with the next
            drain(out, 2_000)
        } catch (_: IllegalStateException) {
            dead = true
        }
        pending = pending.copyOfRange(at, pending.size)
        return out
    }

    private fun drain(out: MutableList<ByteArray>, waitUs: Long) {
        var wait = waitUs
        while (true) {
            val o = codec.dequeueOutputBuffer(info, wait)
            if (o < 0) {
                if (o == MediaCodec.INFO_TRY_AGAIN_LATER) return
                continue        // the output format, said once
            }
            wait = 0
            // the first is OpusHead and the codec's delays: the host's decoder is set up from what kind 9 means, not from these
            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                val b = codec.getOutputBuffer(o)
                if (b != null) {
                    b.position(info.offset)
                    b.limit(info.offset + info.size)
                    out += ByteArray(info.size).also { b.get(it) }
                }
            }
            codec.releaseOutputBuffer(o, false)
        }
    }

    fun close() {
        if (dead) return
        dead = true
        runCatching { codec.stop() }
        runCatching { codec.release() }
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        const val BIT_RATE = 32_000
        /** 20 ms of 16 kHz PCM16 */
        const val FRAME_BYTES = 640
        private const val FRAME_US = 20_000L

        private fun format(): MediaFormat = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, SAMPLE_RATE, 1).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, FRAME_BYTES * 2)
        }

        /** This phone can encode it: Android 10 and later carry an Opus encoder (c2.android.opus.encoder). Asked once. */
        val available: Boolean by lazy {
            Build.VERSION.SDK_INT >= 29 && runCatching { MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format()) != null }.getOrDefault(false)
        }

        /** null where there's no encoder, or it won't start */
        fun make(): OpusVoice? {
            if (!available) return null
            val name = runCatching { MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format()) }.getOrNull() ?: return null
            val c = runCatching { MediaCodec.createByCodecName(name) }.getOrNull() ?: return null
            return try {
                c.configure(format(), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                c.start()
                OpusVoice(c)
            } catch (_: Exception) {
                runCatching { c.release() }
                null
            }
        }
    }
}
