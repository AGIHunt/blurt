// Getting back to a computer: how long a session is kept while the app is out of sight, and how soon each way in is tried again
// (docs/design/remote.md §Coming back). The same numbers as BlurtRemoteKit/RemoteReconnect.swift, but for what Android allows.
package dev.blurt.remote.core

object Reconnect {
    /** away from home last time (a relay, the go-between or an overlay network): the relay starts with the local ways; at home it waits, so
     *  it's never the one that wins there */
    const val RELAY_AFTER_MS = 1200L
    fun relayDelayMs(lastAway: Boolean): Long = if (lastAway) 0 else RELAY_AFTER_MS

    /** A relay connection ended before a session: the next one this long after, by how many have ended like that in a row. A computer that
     *  has just let the last session go is back in its room within a second, so the first ones come soon. */
    fun relayAgainMs(times: Int): Long = when {
        times < 2 -> 400
        times == 2 -> 800
        times == 3 -> 1500
        times == 4 -> 3000
        else -> 5000
    }

    /** back in front with a session kept meanwhile: no answer from the computer within this and it's taken as gone */
    fun proofMs(relay: Boolean): Long = if (relay) 2500 else 1200

    /** a handshake done and the computer answering pings, but its `session` never came: start over after this */
    fun sessionDueMs(relay: Boolean): Long = if (relay) 10_000 else 5_000

    /** nothing has answered for this long: said so on the pad */
    fun unreachableAfterMs(relay: Boolean): Long = if (relay) 12_000 else 8_000

    /** After the go-between turned this phone away: Retry or another network asks it once its rate limit (10 s) has surely passed; coming
     *  back to the app, which people do hundreds of times a day, once a minute at most. */
    fun busyFloorMs(asked: Boolean): Long = if (asked) 12_000 else 60_000

    /** Android lets the app just left run on for a while (the freezer takes it later): a session is kept a minute */
    const val KEEP_IN_BACKGROUND_MS = 60_000L

    /** the go-between's door: out of today's quota, or its rate limit. Anything else that isn't a WebSocket (a captive portal, a proxy) is a
     *  failure like any other, and tried again soon */
    fun isRefusal(http: Int): Boolean = http == 429 || http == 403 || http == 503 || http in 520..530 || http == 1015 || http == 1027
}
