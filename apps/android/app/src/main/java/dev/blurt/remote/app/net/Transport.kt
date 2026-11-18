// The byte streams a session runs over: a TCP socket on the local network, or a WebSocket to the owner's relay (docs/design/remote-protocol.md
// §Layers). Both carry the same length-prefixed frames; over the relay each binary message is whole frames.
package dev.blurt.remote.app.net

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

interface Transport {
    interface Sink {
        fun ready()
        fun bytes(b: ByteArray)
        /** `code`: the relay's close code, when that ended it */
        fun closed(code: Int?)
    }

    fun start(sink: Sink)
    /** `done` when it's on its way */
    fun send(b: ByteArray, done: (() -> Unit)? = null)
    fun close()
    /** where the computer is, once connected (local only): UDP goes to the same address */
    val remote: InetAddress?
    /** what it's to, for logs */
    val label: String
}

/** A TCP connection: no Nagle, low-delay traffic class, three seconds to connect. */
class TcpTransport(private val host: String, private val port: Int, private val resolved: InetAddress? = null) : Transport {
    private var socket: Socket? = null
    private var out: OutputStream? = null
    private val writer = Executors.newSingleThreadExecutor { r -> Thread(r, "blurt-tcp-out").apply { isDaemon = true; priority = Thread.MAX_PRIORITY } }
    private val closed = AtomicBoolean(false)
    @Volatile override var remote: InetAddress? = null
        private set
    override val label get() = "$host:$port"

    override fun start(sink: Transport.Sink) {
        Thread({
            try {
                val s = Socket()
                socket = s
                s.tcpNoDelay = true
                runCatching { s.trafficClass = 0x10 }      // IPTOS_LOWDELAY
                s.connect(if (resolved != null) InetSocketAddress(resolved, port) else InetSocketAddress(host, port), 3000)
                if (closed.get()) { s.close(); return@Thread }
                remote = s.inetAddress
                out = s.getOutputStream()
                sink.ready()
                val input = s.getInputStream()
                val buf = ByteArray(64 * 1024)
                while (!closed.get()) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (n > 0) sink.bytes(buf.copyOf(n))
                }
            } catch (_: IOException) {
            } catch (_: IllegalArgumentException) {
            }
            if (closed.compareAndSet(false, true)) runCatching { socket?.close() }
            writer.shutdown()
            sink.closed(null)
        }, "blurt-tcp-in").apply { isDaemon = true; priority = Thread.MAX_PRIORITY }.start()
    }

    override fun send(b: ByteArray, done: (() -> Unit)?) {
        if (closed.get()) return
        runCatching {
            writer.execute {
                try { out?.write(b); out?.flush() } catch (_: IOException) { close() }
                done?.invoke()
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { socket?.close() }
        writer.shutdown()
    }
}

/** The owner's relay: wss:// or ws://, what passes is sealed either way. */
class RelayTransport(private val url: String) : Transport {
    private var ws: WebSocket? = null
    private val closed = AtomicBoolean(false)
    override val remote: InetAddress? = null
    override val label get() = url.substringBefore("/v1/")

    override fun start(sink: Transport.Sink) {
        val req = runCatching { Request.Builder().url(url).build() }.getOrElse { sink.closed(null); return }
        ws = client.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { if (!closed.get()) sink.ready() }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { if (!closed.get()) sink.bytes(bytes.toByteArray()) }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
                if (closed.compareAndSet(false, true)) sink.closed(code)
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { if (closed.compareAndSet(false, true)) sink.closed(code) }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { if (closed.compareAndSet(false, true)) sink.closed(null) }
        })
    }

    override fun send(b: ByteArray, done: (() -> Unit)?) {
        if (closed.get()) return
        ws?.send(b.toByteString())
        done?.invoke()
    }

    /** bytes waiting to go out: over a slow link the next video-sized thing waits */
    val queued: Long get() = ws?.queueSize() ?: 0

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        ws?.close(1000, null)
    }

    companion object {
        val client: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(8, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.SECONDS)
                .pingInterval(20, TimeUnit.SECONDS)
                .build()
        }
    }
}
