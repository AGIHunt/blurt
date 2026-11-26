// The phone's Opus voice for Blurt's public relay (talk/OpusVoice.kt): on a device with the system encoder, a second of speech-like sound in
// 100 ms pieces (as the microphone gives them) comes out as about fifty raw Opus packets of 20 ms each, one frame a packet, near 32 kbps.
package dev.blurt.remote.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.blurt.remote.app.talk.OpusVoice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.PI
import kotlin.math.sin

@RunWith(AndroidJUnit4::class)
class OpusVoiceTest {
    @Test fun twentyMillisecondPacketsNearThirtyTwoKbps() {
        assumeTrue("Android 10 and later carry the encoder", android.os.Build.VERSION.SDK_INT >= 29)
        assertTrue(OpusVoice.available)
        val made = OpusVoice.make()
        assertNotNull(made)
        val e = made!!
        val packets = ArrayList<ByteArray>()
        var t = 0
        // 3 s of a voice-like mix (a 180 Hz fundamental with formants), in 100 ms pieces
        repeat(30) {
            val pcm = ByteArray(3200)
            for (i in 0 until 1600) {
                val x = t++ / 16000.0
                val v = 0.3 * sin(2 * PI * 180 * x) + 0.2 * sin(2 * PI * 720 * x) + 0.1 * sin(2 * PI * 2400 * x) * (1 + sin(2 * PI * 3 * x))
                val s = (v * 20000).toInt().coerceIn(-32768, 32767)
                pcm[2 * i] = s.toByte()
                pcm[2 * i + 1] = (s shr 8).toByte()
            }
            packets += e.encode(pcm)
        }
        repeat(10) { packets += e.encode(ByteArray(0)); Thread.sleep(20) }
        e.close()
        // the encoder may hold back a packet or two at the end
        assertTrue("${packets.size} packets for 150 frames", packets.size in 145..150)
        for (p in packets) {
            val toc = p[0].toInt() and 0xFF
            assertEquals("one frame a packet", 0, toc and 3)
            val config = toc shr 3
            val ms = when { config < 12 -> listOf(10, 20, 40, 60)[config % 4]; config < 16 -> listOf(10, 20)[config % 2]; else -> listOf(2, 5, 10, 20)[config % 4] }
            assertEquals("20 ms a packet", 20, ms)
        }
        val kbps = packets.sumOf { it.size } * 8.0 / (packets.size * 0.02) / 1000
        android.util.Log.i("OpusVoiceTest", "${packets.size} packets, ${"%.1f".format(kbps)} kbps, sizes ${packets.map { it.size }.sorted().let { "${it.first()}–${it.last()}" }}")
        assertTrue("about 32 kbps, was $kbps", kbps in 20.0..40.0)
    }
}
