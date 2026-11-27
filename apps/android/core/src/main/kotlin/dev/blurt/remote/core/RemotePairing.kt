// The pairing link the host's QR code holds (Swift: RemotePairing.swift):
//   blurtremote://pair?v=1&mac=<host id>&id=<device id>&k=<base64url key>&n=<name>&p=<tcp port>&a=<addr,addr>&r=<relay>
// Query values are percent-encoded as Foundation's URLComponents writes them; `+` is a plus, not a space.
package dev.blurt.remote.core

class RemotePairing(
    /** the host's id, whatever the host is */
    val macID: String,
    val deviceID: String,
    val key: ByteArray,
    val macName: String,
    /** u16 */
    val port: Int,
    val addresses: List<String>,
    val relay: String? = null,
) {
    val url: String
        get() {
            val items = mutableListOf("v" to "${RemoteCrypto.VERSION}", "mac" to macID, "id" to deviceID, "k" to RemoteCrypto.base64url(key),
                "n" to macName, "p" to "$port", "a" to addresses.joinToString(","))
            relay?.let { items += "r" to it }
            return "$SCHEME://pair?" + items.joinToString("&") { "${encode(it.first)}=${encode(it.second)}" }
        }

    override fun equals(other: Any?): Boolean = other is RemotePairing && other.macID == macID && other.deviceID == deviceID &&
        other.key.contentEquals(key) && other.macName == macName && other.port == port && other.addresses == addresses && other.relay == relay

    override fun hashCode(): Int = macID.hashCode() * 31 + deviceID.hashCode()
    override fun toString(): String = "RemotePairing(macID=$macID, deviceID=$deviceID, macName=$macName, port=$port, addresses=$addresses, relay=$relay)"

    companion object {
        const val SERVICE_TYPE = "_blurt-remote._tcp"
        const val SCHEME = "blurtremote"

        /** null for anything that isn't a whole, current pairing link. */
        fun parse(url: String): RemotePairing? {
            val head = "$SCHEME://pair"
            if (!url.startsWith(head)) return null
            var rest = url.substring(head.length)
            val hash = rest.indexOf('#')
            if (hash >= 0) rest = rest.substring(0, hash)
            if (rest.startsWith("/")) rest = rest.substring(1)
            if (!rest.startsWith("?")) return null
            val items = rest.substring(1).split("&").filter { it.isNotEmpty() }.map {
                val i = it.indexOf('=')
                if (i < 0) decode(it) to null else decode(it.substring(0, i)) to decode(it.substring(i + 1))
            }
            fun q(n: String): String? = items.firstOrNull { it.first == n }?.second
            if (q("v") != "${RemoteCrypto.VERSION}") return null
            val mac = q("mac")?.takeIf { it.isNotEmpty() } ?: return null
            val id = q("id")?.takeIf { it.isNotEmpty() } ?: return null
            val k = q("k")?.let { RemoteCrypto.base64url(it) }?.takeIf { it.size == 32 } ?: return null
            val p = q("p")?.takeIf { s -> s.isNotEmpty() && s.all { it in '0'..'9' } }?.toIntOrNull()?.takeIf { it in 0..65535 } ?: return null
            return RemotePairing(mac, id, k, q("n") ?: "Mac", p, (q("a") ?: "").split(",").filter { it.isNotEmpty() },
                q("r")?.let { RemoteRelay.address(it) })
        }

        /**
         * The link in pasted text: the copied link alone, or inside a message from a chat app or a note, with words, brackets or a full
         * stop around it and the scheme maybe capitalised. null when there's no whole link in it (Swift: RemotePairing(text:);
         * `vectors.json` → `pairingText`).
         */
        fun find(text: String): RemotePairing? = link(text)?.let(::parse)

        // The characters the hosts write a link with (percent-encoded ASCII): anything else ends it.
        private const val LINK_CHARS = "-._~!$'()*,;:@/?%&=+"
        // what ends a sentence or closes a bracket after a link, never the end of one (its last value is an address)
        private const val TRAILING = ".,;:!?)'"

        /** `blurtremote://…` from the first place it starts in `text` (in any case) to the first character a link can't hold, less a
         *  closing bracket or full stop after it, with the scheme in lower case. */
        fun link(text: String): String? {
            val head = "$SCHEME://"
            fun lower(c: Char) = if (c in 'A'..'Z') c + 32 else c      // ASCII only, as the other clients fold it
            val start = (0..text.length - head.length).firstOrNull { i -> head.indices.all { lower(text[i + it]) == head[it] } } ?: return null
            val body = start + head.length
            var end = body
            fun isLink(c: Char) = c < '\u0080' && (c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c in LINK_CHARS)
            while (end < text.length && isLink(text[end])) end++
            while (end > body && text[end - 1] in TRAILING) end--
            return head + text.substring(body, end)
        }

        // What URLComponents leaves alone in a query item: RFC 3986 unreserved, and the sub-delims and gen-delims allowed in a query, less & = + #.
        private const val ALLOWED = "-._~!$'()*,;:@/?"

        internal fun encode(s: String): String {
            val b = StringBuilder()
            for (byte in s.toByteArray(Charsets.UTF_8)) {
                val c = byte.toInt() and 0xFF
                val ch = c.toChar()
                if (c < 0x80 && (ch.isLetterOrDigit() || ch in ALLOWED)) b.append(ch) else b.append('%').append("%02X".format(c))
            }
            return b.toString()
        }

        internal fun decode(s: String): String? {
            val out = java.io.ByteArrayOutputStream()
            var i = 0
            while (i < s.length) {
                val c = s[i]
                if (c == '%') {
                    if (i + 3 > s.length) return null
                    val h = s.substring(i + 1, i + 3).toIntOrNull(16) ?: return null
                    out.write(h)
                    i += 3
                } else {
                    out.write(c.toString().toByteArray(Charsets.UTF_8))
                    i += 1
                }
            }
            return out.toByteArray().toString(Charsets.UTF_8)
        }
    }
}

/**
 * While a code is being used to join, the other end is only known to hold that code, and anyone with a photo of it or the copied link can
 * answer as the computer. So the joining side takes `newKey` only after the computer asked (`pairingWaits`, which shows the digits) and this
 * side's user said the digits are the same as the computer's: the yes and the key may come in either order. A key before the question is
 * dropped, not held. A new connection starts over, since its digits are new. Every client runs the same rule, checked against
 * `vectors.json` → `joinGate` (Swift: RemoteJoinGate; docs/design/remote-protocol.md, security review F1, 2026-11-26).
 */
class JoinGate {
    enum class Event(val wire: String) {
        PAIRING_WAITS("pairingWaits"), SAME("same"), NEW_KEY("newKey"), RECONNECT("reconnect");

        companion object {
            fun of(wire: String): Event? = entries.firstOrNull { it.wire == wire }
        }
    }

    /** the computer asked: the digits are on screen */
    var asked = false
        private set
    /** this side's user said they're the same */
    var confirmed = false
        private set
    private var held: ByteArray? = null

    /** the digits can be confirmed now (shown, and not yet confirmed) */
    val canConfirm: Boolean get() = asked && !confirmed
    /** the computer said yes; this side's user hasn't yet */
    val keyWaiting: Boolean get() = held != null

    fun pairingWaits() { asked = true }

    /** The user says the digits are the same. The key to store now, when the computer's yes came first. */
    fun confirm(): ByteArray? {
        if (!asked) return null
        confirmed = true
        val k = held
        held = null
        return k
    }

    /** The computer's `newKey`. The key to store now, or null: held until the user's yes, or dropped when the computer never asked. */
    fun newKey(k: ByteArray): ByteArray? {
        if (!asked) return null
        if (confirmed) return k
        held = k
        return null
    }

    /** a new connection: new digits, asked again */
    fun reset() {
        asked = false
        confirmed = false
        held = null
    }

    companion object {
        /** Runs `events` in order (the vectors' form); the index of the event at which the key is stored, or null. */
        fun run(events: List<Event>, key: ByteArray = ByteArray(32) { 7 }): Int? {
            val g = JoinGate()
            for ((i, e) in events.withIndex()) {
                val got = when (e) {
                    Event.PAIRING_WAITS -> { g.pairingWaits(); null }
                    Event.SAME -> g.confirm()
                    Event.NEW_KEY -> g.newKey(key)
                    Event.RECONNECT -> { g.reset(); null }
                }
                if (got != null) return i
            }
            return null
        }
    }
}
