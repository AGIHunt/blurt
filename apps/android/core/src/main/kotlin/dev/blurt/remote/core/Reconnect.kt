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
        times < 10 -> 5000
        // a computer that's off, and an app left open beside it: the public service's day is everyone's
        else -> 10_000
    }

    /** back in front with a session kept meanwhile: no answer from the computer within this and it's taken as gone */
    fun proofMs(relay: Boolean): Long = if (relay) 2500 else 1200

    /** no pong for this long and the session is gone: over a relay a lost ping waits for its resend, on the same network not */
    fun silenceMs(relay: Boolean): Long = if (relay) 8000 else 2500

    /** The last pong as a check leaves it (back in front, another network): an answer is wanted within `proofMs`, and a session already that
     *  quiet is never given longer. Before 2026-11-27 each check set it, so a network that changed every second or two (a weak mobile link
     *  under a stalled connection) put the end off for ever. */
    fun proving(lastPong: Long, now: Long, relay: Boolean): Long = minOf(lastPong, now + proofMs(relay) - silenceMs(relay))

    /** a handshake done and the computer answering pings, but its `session` never came: start over after this */
    fun sessionDueMs(relay: Boolean): Long = if (relay) 10_000 else 5_000

    /** met on the go-between, its `session` here, and the stream hasn't moved onto a direct path: the host says noDirect after 8 s, and a word
     *  lost on the way isn't waited for longer */
    const val MEETING_DUE_MS = 12_000L

    /** The same, when both ends listed `publicRelay`: after its 8 s the host may wait 3 s for tickets and 5 s for the public relay before
     *  it says `publicRelay` and `noDirect` (remote-go-between.md §Getting in) */
    fun meetingDueMs(publicRelay: Boolean): Long =
        if (publicRelay) 8_000 + RemotePublicRelay.TICKET_WAIT_MS + RemotePublicRelay.GIVE_UP_MS + 1_000 else MEETING_DUE_MS

    /** nothing has answered for this long: said so on the pad */
    fun unreachableAfterMs(relay: Boolean): Long = if (relay) 12_000 else 8_000

    /** After the go-between turned this phone away: Retry or another network asks it once its rate limit (10 s) has surely passed; coming
     *  back to the app, which people do hundreds of times a day, once a minute at most. */
    fun busyFloorMs(asked: Boolean): Long = if (asked) 12_000 else 60_000

    /** How long a session is kept out of sight. With a foreground service (KeepService) Android leaves the process running: three minutes, a
     *  message answered. Without one the freezer stops it about 6 s after it leaves the screen and Android 15 closes its sockets, so this is
     *  only how long it may hang on where a maker lets it. */
    fun keepInBackgroundMs(service: Boolean): Long = if (service) 180_000 else 30_000

    /** the go-between's door: out of today's quota, or its rate limit. Anything else that isn't a WebSocket (a captive portal, a proxy) is a
     *  failure like any other, and tried again soon */
    fun isRefusal(http: Int): Boolean = http == 429 || http == 403 || http == 503 || http in 520..530 || http == 1015 || http == 1027
}
