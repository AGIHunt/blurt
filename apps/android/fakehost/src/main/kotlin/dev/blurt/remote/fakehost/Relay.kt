// The fake host through relays (docs/design/remote-go-between.md): it waits for each paired phone at the go-between, as a host with the
// Public connection service on does; 8 s after `session` with no datagram it asks the go-between for tickets, opens the public relay, and
// sends the phone `publicRelay` and `noDirect`; there it asks the relay for a picture lease before the picture, says `screenFailed("busy")`
// while it's refused, and logs the phone's Opus voice. For end-to-end runs against local copies of tools/remote-relay, never Blurt's own.
package dev.blurt.remote.fakehost

import dev.blurt.remote.core.RemoteCrypto
import dev.blurt.remote.core.RemoteFeature
import dev.blurt.remote.core.RemotePublicRelay
import dev.blurt.remote.core.RemoteRelay
import dev.blurt.remote.core.RemoteScreenRequest
import dev.blurt.remote.core.ToPhone
import java.io.ByteArrayOutputStream
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.time.Duration
import java.util.concurrent.CompletionStage
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** A WebSocket to a relay (the JDK's client): binary is the session's stream, text is said to the relay itself. */
internal class WsPipe(private val url: String) : Pipe {
    @Volatile var onBinary: ((ByteArray) -> Unit)? = null
    @Volatile var onText: ((String) -> Unit)? = null
    @Volatile var onClose: ((Int?) -> Unit)? = null
    @Volatile private var ws: WebSocket? = null
    private val done = CountDownLatch(1)
    @Volatile var closeCode: Int? = null
        private set

    /** false: it didn't open within `timeoutMs` (refused, nothing there, a bad ticket) */
    fun open(timeoutMs: Long): Boolean {
        val bin = ByteArrayOutputStream()
        val txt = StringBuilder()
        val listener = object : WebSocket.Listener {
            override fun onBinary(w: WebSocket, data: ByteBuffer, last: Boolean): CompletionStage<*>? {
                val b = ByteArray(data.remaining()).also { data.get(it) }
                bin.write(b)
                if (last) {
                    val all = bin.toByteArray()
                    bin.reset()
                    onBinary?.invoke(all)
                }
                w.request(1)
                return null
            }
            override fun onText(w: WebSocket, data: CharSequence, last: Boolean): CompletionStage<*>? {
                txt.append(data)
                if (last) {
                    val t = txt.toString()
                    txt.setLength(0)
                    onText?.invoke(t)
                }
                w.request(1)
                return null
            }
            override fun onClose(w: WebSocket, code: Int, reason: String): CompletionStage<*>? {
                ended(code)
                return null
            }
            override fun onError(w: WebSocket, error: Throwable) = ended(null)
        }
        return try {
            ws = HttpClient.newHttpClient().newWebSocketBuilder().connectTimeout(Duration.ofMillis(timeoutMs))
                .buildAsync(URI(url), listener).get(timeoutMs, TimeUnit.MILLISECONDS)
            true
        } catch (e: Exception) {
            log("couldn't open ${url.substringBefore('?')}: ${e.cause?.message ?: e.message ?: e.javaClass.simpleName}")
            false
        }
    }

    private fun ended(code: Int?) {
        if (done.count == 0L) return
        closeCode = code
        done.countDown()
        onClose?.invoke(code)
    }

    fun awaitClosed() = done.await()

    override fun write(b: ByteArray) {
        val w = ws ?: return
        synchronized(this) { runCatching { w.sendBinary(ByteBuffer.wrap(b), true).join() } }
    }

    fun text(t: String) {
        val w = ws ?: return
        synchronized(this) { runCatching { w.sendText(t, true).join() } }
    }

    override fun close() {
        val w = ws ?: return ended(null)
        runCatching { w.sendClose(WebSocket.NORMAL_CLOSURE, "").get(1, TimeUnit.SECONDS) }
        w.abort()
        ended(null)
    }
}

/** Waiting for one paired phone at the go-between: one connection at a time, another as soon as one ends. */
internal object GoBetween {
    fun wait(address: String, device: String, key: ByteArray) = thread(name = "go-between", isDaemon = true) {
        val url = RemoteRelay.url(address, RemoteRelay.room(key), "mac") ?: return@thread
        while (true) {
            val pipe = WsPipe(url)
            val s = Session(pipe, Way.GO_BETWEEN, only = device)
            pipe.onBinary = { b -> s.feed(b) }
            pipe.onText = { t -> s.relay?.text(t) }
            pipe.onClose = { code -> if (s.id != null) log("go-between closed${code?.let { " ($it)" } ?: ""}"); s.ended() }
            if (!pipe.open(5000)) { Thread.sleep(2000); continue }
            log("waiting at the go-between for $device")
            pipe.awaitClosed()
            Thread.sleep(500)
        }
    }
}

/** A session's dealings with the relay it runs through. */
internal class RelaySide(private val s: Session) {
    private val pipe get() = s.pipe as? WsPipe

    // MARK: the go-between: no direct path, so on to the public relay

    private val answers = LinkedBlockingQueue<String>()

    fun began() {
        if (s.way != Way.GO_BETWEEN) return
        thread(name = "meet", isDaemon = true) {
            Thread.sleep((meetWait * 1000).toLong())
            if (!s.over && !s.udpSeen) noDirect()
        }
    }

    /** No datagram came: the public relay, if the phone can go there and the go-between gives tickets; else `noDirect` alone. */
    private fun noDirect() {
        val p = pipe ?: return
        val room = RemoteCrypto.base64url(RemoteCrypto.random(32))
        val to = if (RemoteFeature.PUBLIC_RELAY in s.phoneFeatures) open(p, room) else null
        if (to != null) {
            val (address, ticket) = to
            log("no direct path: on to the public relay")
            s.send(ToPhone.PublicRelay(address, room, ticket))
        } else log("no direct path")
        s.send(ToPhone.NoDirect)
        Thread.sleep(200)
        p.close()
    }

    /** Tickets in 3 s, the relay open in 5: the address and the phone's ticket, with the computer's connection waiting there. */
    private fun open(p: WsPipe, room: String): Pair<String, String>? {
        answers.clear()
        p.text(RemotePublicRelay.ticketAsk(room))
        val said = answers.poll(RemotePublicRelay.TICKET_WAIT_MS, TimeUnit.MILLISECONDS) ?: return null.also { log("no tickets in 3 s") }
        val t = when (val a = RemotePublicRelay.ticketAnswer(said)) {
            is RemotePublicRelay.TicketAnswer.Tickets -> a
            is RemotePublicRelay.TicketAnswer.Refused -> return null.also { log("tickets refused: ${a.why}") }
            null -> return null
        }
        if (!RemotePublicRelay.allowed(t.relay, publicRelayTest) || t.room != room) return null.also { log("not a relay this host goes to: ${t.relay}") }
        val url = RemotePublicRelay.url(t.relay, room, "mac", t.mac) ?: return null
        val pr = WsPipe(url)
        val device = s.id ?: return null
        val next = Session(pr, Way.PUBLIC, only = device)
        pr.onBinary = { b -> next.feed(b) }
        pr.onText = { x -> next.relay?.text(x) }
        pr.onClose = { code ->
            if (code == RemotePublicRelay.NOBODY_CAME) log("public relay: nobody came (4011)") else log("public relay closed${code?.let { " ($it)" } ?: ""}")
            next.ended()
        }
        if (!pr.open(RemotePublicRelay.GIVE_UP_MS)) return null
        log("waiting at the public relay for $device")
        return t.relay to t.phone
    }

    // MARK: the public relay: the picture on a lease

    /** what the phone asked for, while it wants the picture */
    @Volatile private var wanted: RemoteScreenRequest? = null
    @Volatile private var held = false
    @Volatile private var askedAt = -1e9
    @Volatile private var renewedAt = 0.0
    @Volatile private var touchedAt = now()
    @Volatile private var ticking = false

    fun screen(r: RemoteScreenRequest?) {
        if (s.way == Way.GO_BETWEEN) return log("no picture on the go-between")
        wanted = r
        if (r == null) {
            if (held) give()
            return
        }
        tick()
        if (held) s.startPicture(r) else ask()
    }

    private fun ask() {
        askedAt = now()
        log("→ relay ${RemotePublicRelay.lease(true)}")
        pipe?.text(RemotePublicRelay.lease(true))
    }

    private fun give() {
        held = false
        log("→ relay ${RemotePublicRelay.lease(false)}")
        pipe?.text(RemotePublicRelay.lease(false))
    }

    fun text(t: String) {
        if (s.way == Way.GO_BETWEEN) { answers.offer(t); return }
        val a = RemotePublicRelay.leaseAnswer(t) ?: return log("relay said $t")
        log("← relay $t")
        if (a.ok) {
            renewedAt = now()
            if (!held) {
                held = true
                wanted?.let { s.startPicture(it) }
            }
            return
        }
        // refused, or taken back: the picture waits, the phone hears why, and it's asked again in 30 s while wanted
        held = false
        s.stopStream()
        if (wanted != null) s.send(ToPhone.ScreenFailed(RemotePublicRelay.BUSY))
    }

    /** a touch, key or voice from the device */
    fun touched() { touchedAt = now() }

    private val seenOpus = java.util.concurrent.atomic.AtomicLong()
    private val opusBytes = java.util.concurrent.atomic.AtomicLong()
    @Volatile private var opusLogAt = 0.0

    /** One Opus packet (kind 9): counted, and its first byte read as RFC 6716's TOC says (config → frame length, one frame or more). */
    fun opus(p: ByteArray) {
        touched()
        val n = seenOpus.incrementAndGet()
        opusBytes.addAndGet(p.size.toLong())
        if (now() - opusLogAt < 1 && n > 1) return
        opusLogAt = now()
        val toc = p.firstOrNull()?.toInt()?.and(0xFF) ?: return
        val config = toc shr 3
        val ms = when {
            config < 12 -> listOf(10, 20, 40, 60)[config % 4]
            config < 16 -> listOf(10, 20)[config % 2]
            else -> listOf(2.5, 5, 10, 20)[config % 4]
        }
        val mode = if (config < 12) "SILK" else if (config < 16) "hybrid" else "CELT"
        log("← opus $n packets so far, ${opusBytes.get() / n} bytes each on average (${opusBytes.get() * 8 / maxOf(1, n * 20)} kbps): $mode, $ms ms, " +
            "${if (toc and 3 == 0) "one frame" else "code ${toc and 3}"} a packet")
    }

    /** every second: renew a lease in use, ask again for one refused, stop a picture nobody has touched for 5 min */
    private fun tick() {
        if (ticking) return
        ticking = true
        thread(name = "lease", isDaemon = true) {
            while (!s.over) {
                Thread.sleep(1000)
                val t = now()
                if (wanted == null) continue
                if (!held && t - askedAt >= askAgain) ask()
                if (held && t - renewedAt >= RemotePublicRelay.RENEW_SECONDS) ask()
                if (held && t - touchedAt >= RemotePublicRelay.UNTOUCHED_SECONDS) {
                    log("untouched for 5 min: the picture stops")
                    wanted = null
                    s.stopStream()
                    give()
                    s.send(ToPhone.ScreenFailed("stopped"))
                }
            }
        }
    }

    fun ended() {
        if (held) give()
        wanted = null
    }
}
