// The phone's microphone, to the computer: 16 kHz mono PCM16 in 100 ms pieces, the format Blurt's dictation takes (port of Talk/MicStream.swift).
// It starts on the talk key's key-down, so nothing said in the first moments is lost; the computer keeps what arrives before its take has
// started. It ends when the computer says the take isn't listening any more, or when the press came to nothing. The VOICE_RECOGNITION source:
// tuned for a recogniser (no noise suppression that eats consonants, no automatic gain pumping), what every Android dictation app uses.
package dev.blurt.remote.app.talk

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.Process
import androidx.core.content.ContextCompat
import dev.blurt.remote.app.Remote
import dev.blurt.remote.core.RemoteDictationPhase

class MicStream(private val c: Context) {
    /** who has the microphone: the talk key, and a voice note the computer started from here. It stops when neither does */
    enum class Holder { TALK, NOTE }

    private val main = Handler(Looper.getMainLooper())
    private val holders = mutableSetOf<Holder>()
    @Volatile private var running = false
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private var sawListening = false
    private var giveUp: Runnable? = null

    val granted: Boolean get() = ContextCompat.checkSelfPermission(c, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** The phone's microphone is the one to use: chosen in Settings, and allowed. Otherwise the computer listens with its own. */
    val usable: Boolean get() = Remote.prefs.micOnPhone && granted

    /** false: the microphone can't be had right now (a call has it) */
    @SuppressLint("MissingPermission")
    fun start(h: Holder = Holder.TALK): Boolean {
        if (h == Holder.TALK) giveUp?.let { main.removeCallbacks(it) }
        holders += h
        if (running) return true
        if (!granted) { holders -= h; return false }
        val rate = 16000
        val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val r = runCatching {
            AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, PIECE * 4))
        }.getOrNull()
        if (r == null || r.state != AudioRecord.STATE_INITIALIZED) {
            r?.release()
            holders -= h
            return false
        }
        runCatching { r.startRecording() }
        if (r.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            r.release()
            holders -= h
            return false
        }
        record = r
        running = true
        sawListening = false
        thread = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val buf = ByteArray(PIECE)
            while (running) {
                var got = 0
                while (got < PIECE && running) {
                    val n = r.read(buf, got, PIECE - got)
                    if (n <= 0) break
                    got += n
                }
                if (got > 0) Remote.link.audio(buf.copyOf(got))
            }
        }, "blurt-mic").apply { start() }
        return true
    }

    /** The key was let go of. A hands-free take goes on: the computer's next phase decides. */
    fun released() {
        val w = Runnable { if (!sawListening) stop(Holder.TALK) }
        giveUp = w
        main.postDelayed(w, 800)
    }

    fun macPhase(p: RemoteDictationPhase) {
        if (p == RemoteDictationPhase.LISTENING) sawListening = true
        else if (running && sawListening) { sawListening = false; stop(Holder.TALK) }
    }

    /** `h` is done with it; null: everyone is (the session ended) */
    fun stop(h: Holder? = null) {
        if (h != null) holders -= h else holders.clear()
        if (h == null || h == Holder.TALK) giveUp?.let { main.removeCallbacks(it) }
        if (!running || holders.isNotEmpty()) return
        running = false
        val r = record
        record = null
        thread?.join(300)
        thread = null
        runCatching { r?.stop() }
        r?.release()
    }

    private companion object {
        /** 100 ms of 16 kHz PCM16 */
        const val PIECE = 3200
    }
}
