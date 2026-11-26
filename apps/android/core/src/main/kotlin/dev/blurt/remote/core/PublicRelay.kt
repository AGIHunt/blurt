// Blurt's public relay (docs/design/remote-go-between.md §The public relay; Swift: RemoteRelay.swift `RemotePublicRelay`): where a session
// goes on when the go-between finds no direct path. Shared and free, with limits: a ticket from the go-between to get in, the picture on a
// lease from the relay, budgets. Only the pure parts live here: the addresses, the limits, the text messages, and what the phone decides
// on this path (which voice, whether a file may go). The sockets are the app's.
package dev.blurt.remote.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

object RemotePublicRelay {
    /** the only addresses a host or a phone goes to (wss:// only); the go-between's answer and `ToPhone.PublicRelay` must name one */
    val ADDRESSES = listOf("wss://relay.blurt.work")

    /** One of ADDRESSES, or the test build's own copy (`testing`: debug builds only; a release passes null). */
    fun allowed(address: String, testing: String? = null): Boolean = address in ADDRESSES || (testing != null && address == testing)

    /** how long either end waits for the relay to answer before it gives up and says there's no direct path */
    const val GIVE_UP_MS = 5_000L
    /** the computer's wait for the go-between's tickets */
    const val TICKET_WAIT_MS = 3_000L
    /** a `publicRelay` heard longer ago than this doesn't answer a `noDirect` */
    const val FRESH_MS = 10_000L

    /** the picture on this path: Data Saver's */
    const val MAX_WIDTH = 1280
    const val MAX_BITRATE = 1_000_000
    const val MAX_FPS = 15
    /** a lease is renewed this often while frames flow; the relay takes it back after 75 s without */
    const val RENEW_SECONDS = 30
    /** refused: asked again this often while the picture is wanted */
    const val ASK_AGAIN_SECONDS = 30
    /** no touch, key or voice from the device for this long: the picture stops and its lease goes */
    const val UNTOUCHED_SECONDS = 300
    /** files over this path, per device per UTC day, counted by the sender */
    const val FILES_PER_DAY = 50_000_000L
    /** a file or batch over this is asked about first */
    const val ASK_OVER = 20_000_000L
    /** the relay's close code for a computer nobody came to within 60 s */
    const val NOBODY_CAME = 4011
    /** `ToPhone.ScreenFailed` when the relay has no picture lease free */
    const val BUSY = "busy"

    /** `<relay>/v1/<room>/<role>?t=<ticket>`; null for a room or ticket that can't be one (it goes into a URL as it is) */
    fun url(address: String, room: String, role: String, ticket: String): String? {
        if (!ROOM.matches(room) || !TICKET.matches(ticket)) return null
        return RemoteRelay.url(address, room, role)?.let { "$it?t=$ticket" }
    }

    private val ROOM = Regex("[A-Za-z0-9_-]{43}")
    private val TICKET = Regex("[0-9]{10}\\.[A-Za-z0-9_-]{12}\\.[A-Za-z0-9_-]{22}")

    /** The text messages between a host and the go-between or the relay (never passed on). */
    fun lease(on: Boolean): String = if (on) """{"lease":true}""" else """{"lease":false}"""
    fun ticketAsk(room: String): String = """{"ticket":{"room":"$room"}}"""

    /** The go-between's answer to `ticketAsk`: the tickets, or why not ("off", "alone", "limit", "bad"). */
    sealed class TicketAnswer {
        data class Tickets(val relay: String, val room: String, val mac: String, val phone: String) : TicketAnswer()
        data class Refused(val why: String) : TicketAnswer()
    }

    fun ticketAnswer(text: String): TicketAnswer? {
        val t = (J.parse(text.toByteArray()) as? JsonObject)?.get("ticket") as? JsonObject ?: return null
        fun s(k: String) = (t[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        s("error")?.let { return TicketAnswer.Refused(it) }
        return TicketAnswer.Tickets(s("relay") ?: return null, s("room") ?: return null, s("mac") ?: return null, s("phone") ?: return null)
    }

    /** The relay's answer to `lease(true)`: granted (`ttl` s), or refused / taken back ("full", "prefix", "alone", "expired"). */
    data class LeaseAnswer(val ok: Boolean, val ttl: Int? = null, val why: String? = null)

    fun leaseAnswer(text: String): LeaseAnswer? {
        val l = (J.parse(text.toByteArray()) as? JsonObject)?.get("lease") as? JsonObject ?: return null
        val ok = (l["ok"] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toBooleanStrictOrNull() ?: return null
        return LeaseAnswer(ok, (l["ttl"] as? JsonPrimitive)?.content?.toDoubleOrNull()?.toInt(), (l["why"] as? JsonPrimitive)?.takeIf { it.isString }?.content)
    }
}

/**
 * The `publicRelay` the host sent last, for the `noDirect` right behind it: taken only when its address is allowed and it came within
 * RemotePublicRelay.FRESH_MS, and taken once (a second `noDirect` starts at the go-between again).
 */
class PublicRelayOffer {
    private var offer: ToPhone.PublicRelay? = null
    private var at = 0L

    /** false: not an address this phone goes to; dropped */
    fun heard(m: ToPhone.PublicRelay, nowMs: Long, testing: String? = null): Boolean {
        if (!RemotePublicRelay.allowed(m.address, testing) || RemotePublicRelay.url(m.address, m.room, "phone", m.ticket) == null) {
            offer = null
            return false
        }
        offer = m
        at = nowMs
        return true
    }

    /** `noDirect` came: where to go now, if anywhere */
    fun take(nowMs: Long): ToPhone.PublicRelay? {
        val o = offer
        offer = null
        return o?.takeIf { nowMs - at in 0..RemotePublicRelay.FRESH_MS }
    }

    fun clear() { offer = null }
}

/** How this phone's voice goes, by the path and what both ends can do (remote-go-between.md §What the devices do on this path). */
enum class VoiceWay {
    /** 16 kHz PCM16, kind 1: everywhere but the public relay */
    PCM,
    /** Opus, kind 9: on the public relay, when this phone can encode it and the host listed `opus` */
    OPUS,
    /** on the public relay with a host that can't hear Opus: "To use this, update Blurt on …" */
    HOST_CANT,
    /** on the public relay, and this phone has no Opus encoder */
    PHONE_CANT;

    val carries: Boolean get() = this == PCM || this == OPUS

    companion object {
        fun of(publicRelay: Boolean, phoneOpus: Boolean, hostFeatures: List<String>?): VoiceWay = when {
            !publicRelay -> PCM
            !phoneOpus -> PHONE_CANT
            hostFeatures?.contains(RemoteFeature.OPUS) != true -> HOST_CANT
            else -> OPUS
        }
    }
}

/**
 * Files this phone sent over the public relay today (UTC), counted by the sender as they go: at most FILES_PER_DAY, and a send over
 * ASK_OVER is asked about first. `day`/`sent` are what the app keeps across runs.
 */
class PublicRelayFiles(day: Long = 0, sent: Long = 0) {
    enum class Gate { GO, ASK, OVER }

    var day = day
        private set
    var sent = sent
        private set

    private fun roll(nowMs: Long) {
        val d = dayOf(nowMs)
        if (d != day) { day = d; sent = 0 }
    }

    /** what's left today */
    fun left(nowMs: Long): Long {
        roll(nowMs)
        return maxOf(0, RemotePublicRelay.FILES_PER_DAY - sent)
    }

    /** A send of `bytes` (a file or a batch) on this path: past today's allowance it doesn't go; over ASK_OVER it's asked about. */
    fun gate(bytes: Long, nowMs: Long): Gate = when {
        bytes > left(nowMs) -> Gate.OVER
        bytes > RemotePublicRelay.ASK_OVER -> Gate.ASK
        else -> Gate.GO
    }

    /** bytes of files that went over this path just now */
    fun count(bytes: Long, nowMs: Long) {
        roll(nowMs)
        sent += maxOf(0, bytes)
    }

    /** nothing more goes today */
    fun spent(nowMs: Long): Boolean = left(nowMs) <= 0

    companion object {
        fun dayOf(ms: Long): Long = Math.floorDiv(ms, 86_400_000L)
    }
}
