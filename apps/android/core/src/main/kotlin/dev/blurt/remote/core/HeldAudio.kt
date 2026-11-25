// What the microphone heard while the session was away with the talk key held (docs/design/remote.md §Dictation): the last ten seconds, sent
// in order once the computer listens again, then live. iOS: Link.swift `HeldAudio`. Any thread.
package dev.blurt.remote.core

class HeldAudio(private val most: Int = MOST) {
    private val pieces = ArrayDeque<ByteArray>()
    private var bytes = 0
    /** pieces are kept, not sent */
    @get:Synchronized
    var holding = false
        private set

    /** From here pieces are kept (true) or go straight on (false); whatever was kept is dropped either way. */
    @Synchronized fun hold(on: Boolean) {
        holding = on
        clear()
    }

    /** A piece from the microphone: on its way at once, or kept, the oldest making room. */
    @Synchronized fun add(d: ByteArray, send: (ByteArray) -> Unit) {
        if (!holding) return send(d)
        pieces.addLast(d)
        bytes += d.size
        while (bytes > most && pieces.isNotEmpty()) bytes -= pieces.removeFirst().size
    }

    /** The computer listens: what was kept goes first, in order, and what comes next straight after it. */
    @Synchronized fun release(send: (ByteArray) -> Unit) {
        if (!holding) return
        holding = false
        pieces.forEach(send)
        clear()
    }

    private fun clear() {
        pieces.clear()
        bytes = 0
    }

    companion object {
        /** ten seconds of 16 kHz PCM16 */
        const val MOST = 10 * 32_000
    }
}
