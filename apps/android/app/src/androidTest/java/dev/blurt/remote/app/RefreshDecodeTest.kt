// Does this phone's decoder take a refresh (docs/design/remote-realtime.md §Phone 3)? A refresh is a P-frame made from a picture the phone
// acknowledged, after frames that never came: the decoder sees a gap, then a frame whose references it still has. Some decoders hang or
// smear on it (Moonlight's experience), so `ltr` is offered only on decoders that pass this.
//
// The streams are what a Mac host sends (tools/refresh_stream.swift): synthetic terminal text scrolling 2 px a frame, frames 30…33 lost,
// frame 34 the refresh. Every decoder on the device for H.264 and HEVC decodes them; each picture is compared with what it should show (the
// test draws the same text). "ltr" must come back sharp from the refresh on; "skip" (no refresh, the frames after the loss refer to
// pictures that never came) shows the comparison can tell a broken picture. Run: ./gradlew :app:connectedDebugAndroidTest.
package dev.blurt.remote.app

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import kotlin.math.log10

@RunWith(AndroidJUnit4::class)
class RefreshDecodeTest {
    private class Frame(val n: Int, val key: Boolean, val refresh: Boolean, val data: ByteArray)

    private fun frames(asset: String): List<Frame> {
        val b = ByteBuffer.wrap(InstrumentationRegistry.getInstrumentation().context.assets.open(asset).readBytes())
        val out = ArrayList<Frame>()
        while (b.remaining() >= 9) {
            val len = b.int
            val flags = b.get().toInt()
            val n = b.int
            val d = ByteArray(len).also { b.get(it) }
            out += Frame(n, flags and 1 != 0, flags and 2 != 0, d)
        }
        return out
    }

    private fun luma(x: Int, r: Int): Int {
        val line = r / 18
        val inLine = r % 18
        val glyph = (x / 9 + line * 7) % 13
        return if (inLine in 4..14 && glyph < 8 && (x * 31 + r * 17 + line) % 5 != 0) 220 else 24
    }

    class Result(val decoder: String, val error: String?, val decoded: Int, val psnrBefore: Double, val psnrAfter: Double, val minAfter: Double) {
        override fun toString() = "$decoder: ${error ?: "ok"}, $decoded decoded, PSNR before the loss ${"%.1f".format(psnrBefore)} dB, " +
            "after it mean ${"%.1f".format(psnrAfter)} min ${"%.1f".format(minAfter)} dB"
    }

    /** Decodes a stream with one decoder, to buffers, and compares each picture's luma with what it should be. */
    private fun decode(name: String, mime: String, stream: List<Frame>): Result {
        val w = W
        val h = H
        val psnr = HashMap<Int, Double>()
        var error: String? = null
        val c = MediaCodec.createByCodecName(name)
        try {
            val f = MediaFormat.createVideoFormat(mime, w, h)
            f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            c.configure(f, null, null, 0)
            c.start()
            val info = MediaCodec.BufferInfo()
            var fed = 0
            var idle = 0
            while (idle < 200) {
                if (fed < stream.size) {
                    val i = c.dequeueInputBuffer(5_000)
                    if (i >= 0) {
                        val s = stream[fed]
                        c.getInputBuffer(i)!!.apply { clear(); put(s.data) }
                        c.queueInputBuffer(i, 0, s.data.size, s.n.toLong(), 0)
                        fed += 1
                    }
                } else if (fed == stream.size) {
                    val i = c.dequeueInputBuffer(5_000)
                    if (i >= 0) { c.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); fed += 1 }
                }
                val o = c.dequeueOutputBuffer(info, 5_000)
                if (o >= 0) {
                    idle = 0
                    if (info.size > 0) c.getOutputImage(o)?.use { img ->
                        val y = img.planes[0]
                        val buf = y.buffer
                        val n = info.presentationTimeUs.toInt()
                        val off = (n * 2) % (h * 2)
                        val crop = img.cropRect
                        var se = 0.0
                        var count = 0
                        for (r in 0 until h step 2) for (x in 0 until w step 2) {
                            val v = buf.get((r + crop.top) * y.rowStride + (x + crop.left) * y.pixelStride).toInt() and 0xFF
                            val d = (v - luma(x, r + off)).toDouble()
                            se += d * d
                            count++
                        }
                        val mse = se / count
                        psnr[n] = if (mse == 0.0) 99.0 else 10 * log10(255.0 * 255.0 / mse)
                    }
                    c.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                } else if (fed > stream.size) {
                    idle++
                }
            }
        } catch (e: Exception) {
            error = "${e.javaClass.simpleName}: ${e.message}"
        } finally {
            runCatching { c.stop() }
            c.release()
        }
        val refreshAt = stream.firstOrNull { it.refresh }?.n ?: stream.first { it.n > 33 }.n
        val before = psnr.filterKeys { it < 30 }.values
        val after = psnr.filterKeys { it >= refreshAt }.values
        return Result(name, error ?: if (after.size < stream.count { it.n >= refreshAt }) "only ${after.size} decoded after the loss" else null,
            psnr.size, before.average(), after.average(), after.minOrNull() ?: 0.0)
    }

    private fun decoders(mime: String) = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
        .filter { !it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, ignoreCase = true) } }
        .map { it.name }

    @Test
    fun everyDecoderTakesARefresh() {
        val lines = ArrayList<String>()
        var failed = false
        for ((codec, mime) in listOf("hevc" to MediaFormat.MIMETYPE_VIDEO_HEVC, "h264" to MediaFormat.MIMETYPE_VIDEO_AVC)) {
            val ltr = frames("refresh-$codec-ltr.bin")
            val skip = frames("refresh-$codec-skip.bin")
            for (name in decoders(mime)) {
                val good = decode(name, mime, ltr)
                val bad = decode(name, mime, skip)
                // sharp again from the refresh on, and the comparison can tell: without one the picture after the loss is worse
                val pass = good.error == null && good.minAfter > 30 && good.minAfter > bad.minAfter + 3
                if (!pass) failed = true
                lines += "${if (pass) "TAKES" else "FAILS"} refresh $codec: $good | without a refresh: $bad"
            }
        }
        lines.forEach { Log.i("RefreshDecodeTest", it) }
        assertTrue(lines.joinToString("\n"), lines.isNotEmpty() && !failed)
    }

    private companion object {
        const val W = 640
        const val H = 400
    }
}
