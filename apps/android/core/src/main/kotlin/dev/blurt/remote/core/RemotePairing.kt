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
