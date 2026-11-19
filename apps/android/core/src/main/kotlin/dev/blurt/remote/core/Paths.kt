// Which way the session runs, as the phone names it (docs/design/remote-go-between.md §Who uses which path, §What each end shows), and the
// pieces that decide it apart from Android: which addresses are Tailscale's, and how long to leave Blurt's go-between alone once it said busy.
package dev.blurt.remote.core

/** In the order they win: the first that works is the one used. */
enum class LinkPath {
    /** the same network: an address on one of the phone's own networks, or found by DNS-SD */
    SAME_NETWORK,
    /** an address in Tailscale's ranges */
    TAILSCALE,
    /** another overlay (ZeroTier and the like): an address the phone reached that isn't on its own networks */
    OVERLAY,
    /** through a relay, with the direct UDP path open (the pointer and picture go direct), or moved off the go-between entirely */
    DIRECT,
    /** the owner's relay, nothing direct */
    OWN_RELAY,
    /** Blurt's go-between, before the stream has moved */
    GO_BETWEEN;

    /** What the picture's ceiling goes by: an overlay counts as away, since its path may run through someone's relay. */
    val route: LinkRoute get() = when (this) {
        SAME_NETWORK -> LinkRoute.LOCAL
        TAILSCALE, OVERLAY, DIRECT -> LinkRoute.DIRECT
        OWN_RELAY, GO_BETWEEN -> LinkRoute.RELAY
    }

    /** a TCP session to an address the phone was told: Tailscale's ranges by name, else the same network if it's on one of the phone's own */
    companion object {
        fun of(address: String, onMyNetwork: Boolean): LinkPath = when {
            RemoteOverlay.isTailscale(address) -> TAILSCALE
            onMyNetwork -> SAME_NETWORK
            else -> OVERLAY
        }
    }
}

/** Overlay networks' addresses, which a host lists among its candidates (remote-go-between.md §Overlay addresses). */
object RemoteOverlay {
    /** how long a TCP connection to an overlay address may take before it's given up */
    const val CONNECT_TIMEOUT_MS = 1500

    /** 100.64.0.0/10 (IPv4, Tailscale's CGNAT range) or fd7a:115c:a1e0::/48 (Tailscale's IPv6). Literals only: no name is looked up. */
    fun isTailscale(address: String): Boolean {
        val a = address.trim().removePrefix("[").substringBefore(']').substringBefore('%')
        ipv4(a)?.let { return it[0] == 100 && it[1] in 64..127 }
        val g = ipv6(a) ?: return false
        return g[0] == 0xfd7a && g[1] == 0x115c && g[2] == 0xa1e0
    }

    /**
     * An address worth a TCP try away from home: Tailscale's, or a private one (10/8, 172.16/12, 192.168/16, fc00::/7) that only an overlay
     * such as ZeroTier would make reachable from another network. Public addresses and link-local ones aren't.
     */
    fun mayBeOverlay(address: String): Boolean {
        if (isTailscale(address)) return true
        val a = address.trim().removePrefix("[").substringBefore(']').substringBefore('%')
        ipv4(a)?.let { return it[0] == 10 || it[0] == 172 && it[1] in 16..31 || it[0] == 192 && it[1] == 168 }
        val g = ipv6(a) ?: return false
        return g[0] and 0xfe00 == 0xfc00
    }

    private fun ipv4(a: String): IntArray? {
        val p = a.split('.')
        if (p.size != 4) return null
        return IntArray(4) { i -> p[i].takeIf { it.isNotEmpty() && it.length <= 3 && it.all(Char::isDigit) }?.toInt()?.takeIf { it <= 255 } ?: return null }
    }

    /** the eight groups, or null if it isn't an IPv6 literal (an embedded IPv4 tail is taken as two groups) */
    private fun ipv6(a: String): IntArray? {
        if (!a.contains(':')) return null
        fun groups(s: String): List<Int>? {
            if (s.isEmpty()) return emptyList()
            val out = ArrayList<Int>()
            val parts = s.split(':')
            for ((i, part) in parts.withIndex()) {
                if (i == parts.lastIndex && part.contains('.')) {
                    val v4 = ipv4(part) ?: return null
                    out += v4[0] shl 8 or v4[1]
                    out += v4[2] shl 8 or v4[3]
                } else {
                    if (part.isEmpty() || part.length > 4) return null
                    out += part.toIntOrNull(16) ?: return null
                }
            }
            return out
        }
        val halves = a.lowercase().split("::")
        return when (halves.size) {
            1 -> groups(halves[0])?.takeIf { it.size == 8 }?.toIntArray()
            2 -> {
                val head = groups(halves[0]) ?: return null
                val tail = groups(halves[1]) ?: return null
                if (head.size + tail.size > 7) return null
                (head + List(8 - head.size - tail.size) { 0 } + tail).toIntArray()
            }
            else -> null
        }
    }
}

/**
 * Blurt's go-between said it's busy (out of today's free quota, or rate-limited): it isn't asked again in a loop, but after 30 s, 2 min,
 * 10 min, then hourly. A session through it that works starts the count over. Times in seconds.
 */
class GoBetweenBackoff {
    private var refusals = 0
    /** not before this */
    var until = Double.NEGATIVE_INFINITY
        private set
    val busy: Boolean get() = refusals > 0

    fun refused(now: Double) {
        until = now + STEPS[minOf(refusals, STEPS.lastIndex)]
        refusals += 1
    }

    fun mayTry(now: Double): Boolean = now >= until

    fun worked() {
        refusals = 0
        until = Double.NEGATIVE_INFINITY
    }

    companion object {
        val STEPS = doubleArrayOf(30.0, 120.0, 600.0, 3600.0)
    }
}
