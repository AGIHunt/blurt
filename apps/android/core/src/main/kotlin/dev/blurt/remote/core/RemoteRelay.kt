// Reaching the host from anywhere (Swift: RemoteRelay.swift; docs/design/remote.md §Away from home). Blurt runs no relay: each owner runs
// their own (tools/remote-relay), and the phone hears its address inside the sealed session. Only the pure parts live here: the room, the
// address as typed, the close codes, and STUN's bytes. The sockets are the app's.
package dev.blurt.remote.core

object RemoteRelay {
    const val PHONE_LEFT = 4000
    const val MAC_GONE = 4001
    const val REPLACED = 4002

    /** base64url(HMAC-SHA256(paired, "blurt-relay-room")), no padding: unguessable, and it says nothing about the pair. */
    fun room(key: ByteArray): String = RemoteCrypto.base64url(RemoteCrypto.hmac(key, "blurt-relay-room".toByteArray()))

    /**
     * What someone typed, as the address to use: `relay.example.com` means wss://. null if it can't be one. `ws://` is allowed: what passes
     * is sealed either way. No query or fragment; trailing slashes go.
     */
    fun address(typed: String): String? {
        var t = typed.trim()
        if (t.isEmpty()) return null
        if (!t.contains("://")) t = "wss://$t"
        while (t.endsWith("/")) t = t.dropLast(1)
        if (t.any { it.isWhitespace() || it.code < 0x20 || it in "<>\"{}|\\^`" }) return null
        val i = t.indexOf("://")
        if (i < 0) return null
        val scheme = t.substring(0, i)
        if (scheme != "wss" && scheme != "ws") return null
        val rest = t.substring(i + 3)
        if (rest.contains('?') || rest.contains('#')) return null
        val authority = rest.substringBefore('/')
        val hostPort = authority.substringAfterLast('@')
        val host = if (hostPort.startsWith("[")) {
            val end = hostPort.indexOf(']')
            if (end < 0) return null
            val after = hostPort.substring(end + 1)
            if (after.isNotEmpty() && !(after.startsWith(":") && after.drop(1).all { it.isDigit() })) return null
            hostPort.substring(1, end)
        } else {
            val c = hostPort.indexOf(':')
            if (c >= 0 && !hostPort.substring(c + 1).all { it.isDigit() }) return null
            if (c >= 0) hostPort.substring(0, c) else hostPort
        }
        if (host.isEmpty()) return null
        return t
    }

    /** `<relay>/v1/<room>/<mac|phone>` */
    fun url(address: String, room: String, role: String): String? = address(address)?.let { "$it/v1/$room/$role" }
}

/** What the outside world sees of a local UDP port: a Binding request, and the IPv4 XOR-MAPPED-ADDRESS out of the answer. */
object RemoteSTUN {
    const val SERVER = "stun.cloudflare.com"
    const val PORT = 3478
    private val COOKIE = byteArrayOf(0x21, 0x12, 0xA4.toByte(), 0x42)

    fun newTransaction(): ByteArray = RemoteCrypto.random(12)

    /** 20 bytes: Binding request, no attributes. */
    fun request(txn: ByteArray): ByteArray = byteArrayOf(0, 1, 0, 0) + COOKIE + txn

    fun parse(d: ByteArray, txn: ByteArray): RemoteCandidate? {
        val b = IntArray(d.size) { d[it].toInt() and 0xFF }
        if (b.size < 20 || b[0] != 1 || b[1] != 1) return null
        for (i in 0 until 4) if (b[4 + i] != (COOKIE[i].toInt() and 0xFF)) return null
        if (txn.size != 12) return null
        for (i in 0 until 12) if (b[8 + i] != (txn[i].toInt() and 0xFF)) return null
        var at = 20
        while (at + 4 <= b.size) {
            val type = b[at] shl 8 or b[at + 1]
            val len = b[at + 2] shl 8 or b[at + 3]
            if (at + 4 + len > b.size) return null
            if (type == 0x0020 && len >= 8 && b[at + 5] == 1) {      // XOR-MAPPED-ADDRESS, IPv4
                val port = (b[at + 6] xor 0x21) shl 8 or (b[at + 7] xor 0x12)
                val ip = (0 until 4).joinToString(".") { "${b[at + 8 + it] xor (COOKIE[it].toInt() and 0xFF)}" }
                return RemoteCandidate(ip, port)
            }
            at += 4 + (len + 3) / 4 * 4
        }
        return null
    }
}
