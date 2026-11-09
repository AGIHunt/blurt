// A session over the wire, the phone's end (port of BlurtRemoteKit/RemoteChannel.swift). The stream (TCP, or the relay's WebSocket) carries
// the handshake, control messages and audio; UDP carries the pointer once a packet has made it across, and the picture. Everything runs on
// one thread of its own (`Net`), which is the only one that touches the sealer; callbacks arrive there too, and Link moves them to the main
// thread.
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
import dev.blurt.remote.core.ToMac
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

class Channel(private val transport: Transport, private val handshake: PhoneHandshake, val isRelay: Boolean) : Transport.Sink {
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

    /** the relay's close code, when that ended it */
    @Volatile var relayClose: Int? = null
        private set

    /** to reveal in the first message (ToMac.Hello) */
    val nonce: ByteArray get() = handshake.nonce
    /** the session's six digits, once the handshake is done */
    val check: String? get() = sealer?.check(handshake.nonce)
    val label get() = transport.label

    fun start() {
        transport.start(this)
        h.postDelayed(timeout, 6000)
    }

    // MARK: Transport.Sink (any thread)

    override fun ready() {
        h.post { if (!closed) transport.send(RemoteFrameReader.framed(handshake.hello())) }
    }

    override fun bytes(b: ByteArray) {
        h.post {
            if (closed) return@post
            reader.feed(b)
            try {
                while (true) {
                    val f = reader.next() ?: break
                    frame(f)
                    if (closed) return@post
                }
            } catch (_: Exception) {
                shut(null)
            }
        }
    }

    override fun closed(code: Int?) {
        h.post {
            if (code != null) relayClose = code
            shut(null)
        }
    }

    private fun frame(f: ByteArray) {
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
        deliver(plain)
    }

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
        transport.send(RemoteFrameReader.framed(f))
    }

    fun send(m: ToMac) {
        val d = m.encode()
        h.post { sendSealed(RemoteFrameKind.CONTROL, d) }
    }

    fun sendAudio(pcm: ByteArray) = h.post { sendSealed(RemoteFrameKind.AUDIO, pcm) }

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
        if (kind != RemoteFrameKind.PROBE) sendSealed(kind, body)
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

    fun udpConfirmed() = h.post { if (!isRelay && local != null) udpOK = true }

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
        deliver(plain)
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
        // the STUN server's name resolved off this thread
        Thread {
            val to = runCatching { InetSocketAddress(InetAddress.getByName("stun.cloudflare.com"), 3478) }.getOrNull()
            h.post { if (to != null && direct === s) sendUDP(s, RemoteSTUN.request(txn), to) }
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
        onClose?.invoke(failure)
    }
}

/** This phone's public IPv6 addresses: reachable as they are, where a firewall lets a reply through. */
object Addresses {
    fun publicIPv6(): List<String> = runCatching {
        java.net.NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }.flatMap { i ->
            i.inetAddresses.toList().filterIsInstance<java.net.Inet6Address>()
                .filter { !it.isLinkLocalAddress && !it.isSiteLocalAddress && !it.isLoopbackAddress }
                .map { it.hostAddress?.substringBefore('%') ?: "" }
                .filter { it.startsWith("2") || it.startsWith("3") }
        }.distinct()
    }.getOrDefault(emptyList())
}
