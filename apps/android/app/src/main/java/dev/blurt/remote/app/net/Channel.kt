// A session over the wire, the phone's end (port of BlurtRemoteKit/RemoteChannel.swift). The stream (TCP, or the relay's WebSocket) carries
// the handshake, control messages and audio; UDP carries the pointer once a packet has made it across, and the picture. Everything runs on
// one thread of its own (`Net`), which is the only one that touches the sealer; callbacks arrive there too, and Link moves them to the main
// thread.
//
// On Blurt's go-between the WebSocket only introduces the two ends (docs/design/remote-go-between.md): once the host says `udpOK`, each
// side writes `streamMoved` as its last frame there, and the rest of its stream (the same sealed frames, the same counters) goes in kind-7
// datagrams on the direct path (core's RemoteStreamSender / RemoteStreamReceiver). Until then no audio goes over the WebSocket.
package dev.blurt.remote.app.net

import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import dev.blurt.remote.core.PhoneHandshake
import dev.blurt.remote.core.RemoteCandidate
import dev.blurt.remote.core.RemoteFrameKind
import dev.blurt.remote.core.RemoteFrameReader
import dev.blurt.remote.core.RemoteHandshakeError
import dev.blurt.remote.core.RemotePointerPacket
import dev.blurt.remote.core.RemoteSTUN
import dev.blurt.remote.core.RemoteSealer
import dev.blurt.remote.core.RemoteStreamPacket
import dev.blurt.remote.core.RemoteStreamReceiver
import dev.blurt.remote.core.RemoteStreamSender
import dev.blurt.remote.core.ToMac
import dev.blurt.remote.core.ToPhone
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketAddress

object Net {
    private val thread = HandlerThread("blurt-net", Process.THREAD_PRIORITY_URGENT_DISPLAY).apply { start() }
    val handler = Handler(thread.looper)
    fun now(): Double = SystemClock.elapsedRealtimeNanos() / 1e9
}

class Channel(
    private val transport: Transport,
    private val handshake: PhoneHandshake,
    val isRelay: Boolean,
    /** the relay is Blurt's go-between: the stream moves onto the direct path once it opens */
    val goBetween: Boolean = false,
    /** a TCP address DNS-SD found: the same network */
    val discovered: Boolean = false,
) : Transport.Sink {
    private val h = Net.handler
    private val reader = RemoteFrameReader()
    private var sealer: RemoteSealer? = null
    @Volatile private var closed = false
    private var opened = false
    private val timeout = Runnable { if (!opened) shut(null) }

    /** the session is up: the computer proved itself */
    var onOpen: (() -> Unit)? = null
    var onControl: ((ByteArray) -> Unit)? = null
    var onVideo: ((ByteArray) -> Unit)? = null
    var onProbe: ((ByteArray) -> Unit)? = null
    var onCursor: ((ByteArray) -> Unit)? = null
    /** a direct path answered, or stopped answering */
    var onDirect: ((Boolean) -> Unit)? = null
    /** `failure`: the handshake's reason, when that is what ended it */
    var onClose: ((RemoteHandshakeError?) -> Unit)? = null

    /** the stream moved onto the direct path: the WebSocket is idle from here on */
    var onMoved: (() -> Unit)? = null

    /** the relay's close code, when that ended it */
    @Volatile var relayClose: Int? = null
        private set
    /** the HTTP status of a refused upgrade (the go-between's 429), when that ended it */
    @Volatile var relayRefused: Int? = null
        private set

    /** to reveal in the first message (ToMac.Hello) */
    val nonce: ByteArray get() = handshake.nonce
    /** the session's six digits, once the handshake is done */
    val check: String? get() = sealer?.check(handshake.nonce)
    val label get() = transport.label
    /** where a TCP session went, once connected */
    val remoteAddress: InetAddress? get() = transport.remote

    fun start() {
        transport.start(this)
        h.postDelayed(timeout, 6000)
    }

    // MARK: Transport.Sink (any thread)

    /** the transport opened (for a relay: the WebSocket), whether or not anyone answered in it */
    @Volatile var wasReady = false

    override fun ready() {
        wasReady = true
        h.post { if (!closed) transport.send(RemoteFrameReader.framed(handshake.hello())) }
    }

    override fun bytes(b: ByteArray) {
        h.post {
            // past the peer's streamMoved nothing more is read from the old stream: the counters went on in the datagrams
            if (closed || peerMoved) return@post
            reader.feed(b)
            try {
                while (true) {
                    val f = reader.next() ?: break
                    frame(f, old = true)
                    if (closed || peerMoved) return@post
                }
            } catch (_: Exception) {
                shut(null)
            }
        }
    }

    override fun closed(code: Int?, http: Int?) {
        h.post {
            if (code != null) relayClose = code
            if (http != null) relayRefused = http
            // both ends have moved: the WebSocket's going changes nothing
            if (moved && peerMoved) return@post
            shut(null)
        }
    }

    /** `old`: read from the old stream (TCP or the WebSocket), not the datagrams' */
    private fun frame(f: ByteArray, old: Boolean = false) {
        val s = sealer
        if (s == null) {
            try {
                sealer = handshake.finish(f)
                reader.limit = RemoteFrameReader.MAX_FRAME
                opened = true
                h.removeCallbacks(timeout)
                onOpen?.invoke()
            } catch (e: RemoteHandshakeError) {
                shut(e)
            } catch (_: Exception) {
                shut(null)
            }
            return
        }
        val plain = try { s.open(f) } catch (_: Exception) { return shut(null) }
        if (old && moveAllowed && isStreamMoved(plain)) return peerMovedNow()
        deliver(plain)
    }

    private fun isStreamMoved(plain: ByteArray): Boolean =
        plain.size in 2..40 && plain[0].toInt() == RemoteFrameKind.CONTROL.raw && ToPhone.decode(plain.copyOfRange(1, plain.size)) == ToPhone.StreamMoved

    /** A frame or packet, opened: the first byte says what it is. */
    private fun deliver(plain: ByteArray) {
        if (plain.isEmpty()) return
        val body = plain.copyOfRange(1, plain.size)
        when (RemoteFrameKind.from(plain[0].toInt() and 0xFF)) {
            RemoteFrameKind.CONTROL -> onControl?.invoke(body)
            RemoteFrameKind.VIDEO -> onVideo?.invoke(body)
            RemoteFrameKind.PROBE -> onProbe?.invoke(body)
            RemoteFrameKind.CURSOR -> onCursor?.invoke(body)
            else -> {}
        }
    }

    // MARK: sending (any thread)

    private fun sendSealed(kind: RemoteFrameKind, body: ByteArray) {
        val s = sealer ?: return
        if (closed) return
        val f = try { s.seal(byteArrayOf(kind.raw.toByte()) + body) } catch (_: Exception) { return }
        // sealed and written in one go on this thread: the stream's order is the counters' order, wherever the stream runs
        val framed = RemoteFrameReader.framed(f)
        val out = streamOut
        if (out != null) streamDatagrams(out.write(framed, Net.now())) else transport.send(framed)
    }

    fun send(m: ToMac) {
        val d = m.encode()
        h.post { sendSealed(RemoteFrameKind.CONTROL, d) }
    }

    fun sendAudio(pcm: ByteArray) = h.post {
        // on the go-between nothing heavy crosses the WebSocket: the talk key's first words wait for the move, the last few seconds of them
        if (goBetween && !moved) {
            if (closed) return@post
            heldAudio.addLast(pcm)
            heldAudioBytes += pcm.size
            while (heldAudioBytes > HELD_AUDIO && heldAudio.isNotEmpty()) heldAudioBytes -= heldAudio.removeFirst().size
            return@post
        }
        sendSealed(RemoteFrameKind.AUDIO, pcm)
    }

    /** Over UDP once it works, else in the stream. `inOrder`: in the stream regardless, behind the messages sent before it, as a scroll must be
     *  when the pointer was just placed where it's to happen. */
    fun sendPointer(p: RemotePointerPacket, inOrder: Boolean = false) {
        val body = p.encoded()
        h.post {
            val s = sealer ?: return@post
            if (closed) return@post
            if (!inOrder && datagram(RemoteFrameKind.POINTER, body)) return@post
            sendSealed(RemoteFrameKind.POINTER, body)
        }
    }

    /** For what's worthless late (probes, reports of what arrived). Without a datagram path it goes in the stream, probes excepted. */
    fun sendDatagram(kind: RemoteFrameKind, body: ByteArray) = h.post {
        if (datagram(kind, body)) return@post
        if (kind != RemoteFrameKind.PROBE && !(goBetween && !moved)) sendSealed(kind, body)
    }

    /** True if it went as a datagram. */
    private fun datagram(kind: RemoteFrameKind, body: ByteArray): Boolean {
        val s = sealer ?: return false
        val (sock, to) = when {
            udpOK && local != null -> local!! to null
            direct != null && chosen != null -> direct!! to chosen
            else -> return false
        }
        val d = try { s.sealPacket(byteArrayOf(kind.raw.toByte()) + body, udpSession) } catch (_: Exception) { return false }
        sendUDP(sock, d, to)
        return true
    }

    private fun sendUDP(sock: DatagramSocket, d: ByteArray, to: SocketAddress?) {
        try {
            if (to == null) sock.send(DatagramPacket(d, d.size)) else sock.send(DatagramPacket(d, d.size, to))
        } catch (_: IOException) {
        } catch (_: IllegalArgumentException) {
        }
    }

    // MARK: the local network's UDP path

    private var local: DatagramSocket? = null
    private var udpSession = 0L
    @Volatile var udpOK = false
        private set

    /** The computer said where: send it packets until `udpConfirmed`. */
    fun openUDP(port: Int, session: Long) = h.post {
        val to = transport.remote ?: return@post
        if (local != null || closed) return@post
        udpSession = session
        try {
            val s = DatagramSocket()
            runCatching { s.trafficClass = 0xB8 }      // DSCP EF: voice-like, the pointer can't wait
            runCatching { s.receiveBufferSize = 4 shl 20 }     // a keyframe comes as a burst of a hundred pieces or more
            s.connect(InetSocketAddress(to, port))
            local = s
            receive(s)
            probe(6)
        } catch (_: IOException) {
        }
    }

    private fun probe(left: Int) {
        val s = local ?: return
        val sealer = sealer ?: return
        if (left <= 0 || udpOK || closed) return
        runCatching { sendUDP(s, sealer.sealPacket(byteArrayOf(RemoteFrameKind.POINTER.raw.toByte()) + RemotePointerPacket.ScrollStop.encoded(), udpSession), null) }
        h.postDelayed({ probe(left - 1) }, 400)
    }

    fun udpConfirmed() = h.post {
        if (!isRelay && local != null) udpOK = true
        // the host saw a datagram from here: on the go-between, everything moves to the direct path
        if (goBetween && moveAllowed && !moved) move()
    }

    private fun receive(s: DatagramSocket) {
        Thread({
            val buf = ByteArray(2048)
            while (!closed && !s.isClosed) {
                val p = DatagramPacket(buf, buf.size)
                try { s.receive(p) } catch (_: IOException) { break }
                val d = buf.copyOf(p.length)
                val from = p.socketAddress
                h.post { packet(s, d, from) }
            }
        }, "blurt-udp").apply { isDaemon = true; priority = Thread.MAX_PRIORITY }.start()
    }

    private fun packet(s: DatagramSocket, d: ByteArray, from: SocketAddress) {
        if (closed) return
        if (s === direct) {
            stunTxn?.let { txn ->
                RemoteSTUN.parse(d, txn)?.let { found -> stunTxn = null; stunDone?.invoke(found); stunDone = null; return }
            }
        }
        val plain = sealer?.openPacket(d) ?: return
        if (s === direct) {
            if (chosen == null && trying.any { it == from }) choose(from)
            if (from == chosen) directHeard = Net.now()
        }
        if (plain.isEmpty()) return
        when (plain[0].toInt() and 0xFF) {
            RemoteFrameKind.STREAM.raw -> streamChunk(plain)
            RemoteFrameKind.STREAM_ACK.raw -> {
                val next = RemoteStreamPacket.parseAck(plain.copyOfRange(1, plain.size)) ?: return
                streamOut?.let { streamDatagrams(it.ack(next, Net.now())) }
            }
            else -> deliver(plain)
        }
    }

    // MARK: the stream moved onto the direct path (the go-between)

    /** both ends listed RemoteFeature.MOVE: set from the host's `session` */
    private var moveAllowed = false
    /** this phone writes its stream in kind-7 datagrams now */
    @Volatile var moved = false
        private set
    /** the host's `streamMoved` has been read: its stream comes in kind-7 datagrams now */
    private var peerMoved = false
    private var streamOut: RemoteStreamSender? = null
    private var streamIn: RemoteStreamReceiver? = null
    private val streamReader = RemoteFrameReader().apply { limit = RemoteFrameReader.MAX_FRAME }
    private val heldAudio = ArrayDeque<ByteArray>()
    private var heldAudioBytes = 0
    /** the session's round trip from its pings, for the stream's first retransmission timer */
    @Volatile var rttHint: Double? = null
    private val streamTicker = object : Runnable {
        override fun run() {
            if (closed || !(moved || peerMoved)) return
            val now = Net.now()
            streamOut?.let { streamDatagrams(it.tick(now)) }
            streamIn?.tick(now)?.let { datagram(RemoteFrameKind.STREAM_ACK, it) }
            h.postDelayed(this, 10)
        }
    }

    /** The host's session said it moves too. Bytes it sends early wait for its `streamMoved`. */
    fun allowMove(on: Boolean) = h.post {
        if (closed || moveAllowed == on || moved) return@post
        moveAllowed = on
        if (on && streamIn == null) streamIn = RemoteStreamReceiver(holding = true)
    }

    private fun move() {
        if (moved || closed || !moveAllowed) return
        // the last frame on the old stream
        sendSealed(RemoteFrameKind.CONTROL, ToMac.StreamMoved.encode())
        moved = true
        streamOut = RemoteStreamSender(rttHint)
        directHeard = Net.now()       // the 6 s count from here
        if (!peerMoved) h.postDelayed(streamTicker, 10)
        watchMoved()
        // what the talk key said before the move, in order, ahead of anything new
        while (heldAudio.isNotEmpty()) sendSealed(RemoteFrameKind.AUDIO, heldAudio.removeFirst())
        heldAudioBytes = 0
        onMoved?.invoke()
    }

    private fun peerMovedNow() {
        if (peerMoved) return
        peerMoved = true
        val inn = streamIn ?: RemoteStreamReceiver().also { streamIn = it }
        if (!moved) h.postDelayed(streamTicker, 10)
        // the host moved first (it got here before udpOK did): follow it
        if (!moved) move()
        feedStream(inn.release())
    }

    private fun streamChunk(plain: ByteArray) {
        val inn = streamIn ?: return
        val (offset, bytes) = RemoteStreamPacket.parseChunk(plain.copyOfRange(1, plain.size)) ?: return
        val r = inn.received(offset, bytes, Net.now())
        r.ack?.let { datagram(RemoteFrameKind.STREAM_ACK, it) }
        if (r.data.isNotEmpty()) feedStream(r.data)
        // a host that never says streamMoved can't fill the window and wait forever
        if (inn.heldBytes >= RemoteStreamPacket.WINDOW) shut(null)
    }

    private fun feedStream(b: ByteArray) {
        if (b.isEmpty() || closed) return
        streamReader.feed(b)
        try {
            while (true) {
                val f = streamReader.next() ?: break
                frame(f)
                if (closed) return
            }
        } catch (_: Exception) {
            shut(null)
        }
    }

    /** kind-7 bodies out; with no direct path yet they're lost, and the retransmission timer sends them again */
    private fun streamDatagrams(bodies: List<ByteArray>) {
        for (b in bodies) datagram(RemoteFrameKind.STREAM, b)
    }

    /** After the move, 6 s without a datagram ends the session: the phone starts over. */
    private fun watchMoved() {
        if (closed) return
        if (Net.now() - directHeard > 6) return shut(null)
        h.postDelayed({ watchMoved() }, 1000)
    }

    // MARK: a direct path, from over the relay

    private var direct: DatagramSocket? = null
    private var trying: List<SocketAddress> = emptyList()
    @Volatile private var chosen: SocketAddress? = null
    private var directHeard = 0.0
    private var stunTxn: ByteArray? = null
    private var stunDone: ((RemoteCandidate?) -> Unit)? = null

    /** One local port for everything: what STUN sees of it is what the computer's packets will meet. `mine` gets this phone's candidates. */
    fun lookForDirect(theirs: List<RemoteCandidate>, session: Long, mine: (List<RemoteCandidate>) -> Unit) = h.post {
        if (closed || !isRelay) return@post
        udpSession = session
        val port = (50000..60000).random()
        val s = try { DatagramSocket(port) } catch (_: IOException) { runCatching { DatagramSocket() }.getOrNull() } ?: return@post
        runCatching { s.trafficClass = 0xB8 }
        runCatching { s.receiveBufferSize = 4 shl 20 }
        direct?.close()
        direct = s
        chosen = null
        receive(s)
        val txn = RemoteSTUN.newTransaction()
        stunTxn = txn
        var answered = false
        stunDone = { found ->
            if (!answered) {
                answered = true
                val list = Addresses.publicIPv6().map { RemoteCandidate(it, s.localPort) }.toMutableList()
                if (found != null) list += found
                mine(list)
                knockAll(theirs)
            }
        }
        // the STUN servers' names resolved off this thread; asked together, the first answer taken (RemoteSTUN.SERVERS)
        Thread {
            val to = RemoteSTUN.SERVERS.mapNotNull { (host, port) -> runCatching { InetSocketAddress(InetAddress.getByName(host), port) }.getOrNull() }
            h.post { if (direct === s) to.forEach { sendUDP(s, RemoteSTUN.request(txn), it) } }
        }.start()
        h.postDelayed({ if (direct === s) { stunTxn = null; stunDone?.invoke(null); stunDone = null } }, 2000)
    }

    private fun knockAll(theirs: List<RemoteCandidate>) {
        Thread {
            val list = theirs.mapNotNull { k -> runCatching { InetSocketAddress(InetAddress.getByName(k.host), k.port) as SocketAddress }.getOrNull() }
            h.post {
                trying = list
                knock(30)
            }
        }.start()
    }

    private fun knock(left: Int) {
        val s = direct ?: return
        val sealer = sealer ?: return
        if (left <= 0 || closed || chosen != null) return
        for (a in trying) runCatching {
            sendUDP(s, sealer.sealPacket(byteArrayOf(RemoteFrameKind.POINTER.raw.toByte()) + RemotePointerPacket.ScrollStop.encoded(), udpSession), a)
        }
        h.postDelayed({ knock(left - 1) }, 300)
    }

    private fun choose(a: SocketAddress) {
        chosen = a
        trying = emptyList()
        directHeard = Net.now()
        onDirect?.invoke(true)
        holdDirect()
    }

    /** A small packet now and every 2 s, echoed by the computer: firewalls forget a quiet path, and no echo for 6 s means it's gone. */
    private fun holdDirect() {
        if (closed || chosen == null) return
        if (Net.now() - directHeard > 6) {
            // after the move there is nothing to fall back on
            if (moved) return shut(null)
            chosen = null
            onDirect?.invoke(false)
            return
        }
        datagram(RemoteFrameKind.PROBE, ByteArray(8))
        h.postDelayed({ holdDirect() }, 2000)
    }

    val hasDirect: Boolean get() = chosen != null

    // MARK: ending

    fun close(failure: RemoteHandshakeError? = null) = h.post { shut(failure) }

    private fun shut(failure: RemoteHandshakeError?) {
        if (closed) return
        closed = true
        h.removeCallbacks(timeout)
        transport.close()
        local?.close()
        local = null
        direct?.close()
        direct = null
        chosen = null
        heldAudio.clear()
        h.removeCallbacks(streamTicker)
        onClose?.invoke(failure)
    }
}

private const val HELD_AUDIO = 5 * 32_000      // five seconds of 16 kHz PCM16

/** This phone's public IPv6 addresses: reachable as they are, where a firewall lets a reply through. */
object Addresses {
    /** `a` is on one of the networks this phone is on itself, not through a VPN: the same network, rather than an overlay's address. */
    fun onMyNetwork(c: android.content.Context, a: InetAddress): Boolean = runCatching {
        if (a.isLoopbackAddress || a.isLinkLocalAddress) return true
        val cm = c.getSystemService(android.net.ConnectivityManager::class.java) ?: return false
        @Suppress("DEPRECATION")
        for (n in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(n) ?: continue
            if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) continue
            val lp = cm.getLinkProperties(n) ?: continue
            for (la in lp.linkAddresses) if (sameSubnet(la.address, la.prefixLength, a)) return true
        }
        false
    }.getOrDefault(false)

    private fun sameSubnet(mine: InetAddress, prefix: Int, other: InetAddress): Boolean {
        val x = mine.address
        val y = other.address
        if (x.size != y.size) return false
        var bits = prefix.coerceIn(0, x.size * 8)
        var i = 0
        while (bits > 0) {
            val mask = if (bits >= 8) 0xFF else (0xFF shl (8 - bits)) and 0xFF
            if ((x[i].toInt() and mask) != (y[i].toInt() and mask)) return false
            bits -= 8
            i += 1
        }
        return true
    }

    fun publicIPv6(): List<String> = runCatching {
        java.net.NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }.flatMap { i ->
            i.inetAddresses.toList().filterIsInstance<java.net.Inet6Address>()
                .filter { !it.isLinkLocalAddress && !it.isSiteLocalAddress && !it.isLoopbackAddress }
                .map { it.hostAddress?.substringBefore('%') ?: "" }
                .filter { it.startsWith("2") || it.startsWith("3") }
        }.distinct()
    }.getOrDefault(emptyList())
}
