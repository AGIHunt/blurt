// A fake computer: the host's side of the wire (remote-protocol.md), as RemoteServer.swift runs it, minus pressing anything. It prints what
// arrives, one line each, so a test can read what the phone sent.
//
//   --platform mac|windows|linux   what it says it is (the phone's keys follow)
//   --name <name>                  its name on the phone
//   --picture <png>                stream this still (ffmpeg, re-encoded at 30 fps) when the phone asks for the screen
//   --address <ip>                 the address in the pairing link (default 10.0.2.2, the Mac as the emulator sees it)
//   --state <file>                 paired phones, kept across runs (default build/fakehost.json)
//   --ask                          a new phone waits for "y" on stdin; without it the answer is yes after 2 s
//   --two-displays                 say it has a second display, above and to the right of the first (the picture is the same)
package dev.blurt.remote.fakehost

import dev.blurt.remote.core.MacHandshake
import dev.blurt.remote.core.RemoteCrop
import dev.blurt.remote.core.RemoteCrypto
import dev.blurt.remote.core.RemoteCursor
import dev.blurt.remote.core.RemoteDictationPhase
import dev.blurt.remote.core.RemoteFrameKind
import dev.blurt.remote.core.RemoteFrameReader
import dev.blurt.remote.core.RemoteFront
import dev.blurt.remote.core.RemotePairing
import dev.blurt.remote.core.RemotePointerPacket
import dev.blurt.remote.core.RemoteSealer
import dev.blurt.remote.core.RemoteSessionInfo
import dev.blurt.remote.core.RemoteVideoCodec
import dev.blurt.remote.core.RemoteVideoPacket
import dev.blurt.remote.core.RemoteVideoPayload
import dev.blurt.remote.core.ToMac
import dev.blurt.remote.core.ToPhone
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

private var platform = "mac"
private var name = "Studio Mac"
private var picture: String? = null
private var address = "10.0.2.2"
private var stateFile = File("build/fakehost.json")
private var ask = false
private var twoDisplays = false
private val DISPLAYS = listOf(
    dev.blurt.remote.core.RemoteDisplay("1", "Built-in Retina Display", 0.0, 0.0, 1512.0, 944.0, true),
    dev.blurt.remote.core.RemoteDisplay("2", "Studio Display", 1512.0, -458.0, 2560.0, 1440.0, false),
)
private const val TCP_PORT = 47811
private const val UDP_PORT = 47812

private val start = System.nanoTime()
private fun now() = (System.nanoTime() - start) / 1e9
private fun log(s: String) = synchronized(System.out) { println(String.format("%8.3f %s", now(), s)); System.out.flush() }

/** paired phones: device id → key; and the one code waiting to be used */
private val keys = ConcurrentHashMap<String, ByteArray>()
private var codeID: String? = null
private var codeKey: ByteArray? = null
private val udp = DatagramSocket(UDP_PORT)
private val sessionNumbers = AtomicLong(1000)
@Volatile private var current: Session? = null

fun main(args: Array<String>) {
    var i = 0
    while (i < args.size) {
        when (args[i]) {
            "--platform" -> platform = args[++i]
            "--name" -> name = args[++i]
            "--picture" -> picture = args[++i]
            "--address" -> address = args[++i]
            "--state" -> stateFile = File(args[++i])
            "--ask" -> ask = true
            "--two-displays" -> twoDisplays = true
        }
        i++
    }
    load()
    newCode()
    thread(name = "udp") { udpLoop() }
    if (ask) thread(name = "stdin") { stdin() }
    val server = ServerSocket(TCP_PORT)
    log("listening tcp $TCP_PORT udp $UDP_PORT as $platform \"$name\"")
    while (true) {
        val s = server.accept()
        s.tcpNoDelay = true
        thread(name = "session") { Session(s).run() }
    }
}

private fun load() {
    if (!stateFile.exists()) return
    for (line in stateFile.readLines()) {
        val (id, k) = line.split(" ").takeIf { it.size == 2 } ?: continue
        RemoteCrypto.base64url(k)?.let { keys[id] = it }
    }
    log("paired phones: ${keys.size}")
}

private fun save() {
    stateFile.parentFile?.mkdirs()
    stateFile.writeText(keys.entries.joinToString("\n") { "${it.key} ${RemoteCrypto.base64url(it.value)}" })
}

private fun newCode() {
    codeID = RemoteCrypto.newID()
    codeKey = RemoteCrypto.newKey()
    val p = RemotePairing(MAC_ID, codeID!!, codeKey!!, name, TCP_PORT, listOf(address))
    log("PAIRING ${p.url}")
    File("build/fakehost-pairing.txt").apply { parentFile.mkdirs(); writeText(p.url) }
}

private val MAC_ID = "fakehost-" + name.hashCode().toUInt().toString(16)

private fun stdin() {
    val r = System.`in`.bufferedReader()
    while (true) {
        val l = r.readLine() ?: return
        current?.answer(l.trim().lowercase().startsWith("y"))
    }
}

private class Session(val socket: Socket) {
    val input: InputStream = socket.getInputStream()
    val out: OutputStream = socket.getOutputStream()
    val reader = RemoteFrameReader()
    var sealer: RemoteSealer? = null
    var id: String? = null
    var commitment: ByteArray? = null
    var pairingKey: ByteArray? = null
    var greeted = false
    var asking = false
    val number = sessionNumbers.incrementAndGet()
    @Volatile var flow: SocketAddress? = null
    var udpSeen = false
    var audio = 0
    var lastAudioLog = 0.0
    @Volatile var streaming: Process? = null
    // the pointer on a 1512 × 944 screen
    var px = 756.0
    var py = 472.0
    @Volatile var crop = RemoteCrop.WHOLE
    @Volatile var listening = false
    @Volatile var display = "1"

    fun run() {
        log("connection from ${socket.remoteSocketAddress}")
        try {
            val buf = ByteArray(65536)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                reader.feed(buf.copyOf(n))
                while (true) {
                    val f = reader.next() ?: break
                    frame(f)
                }
            }
        } catch (e: Exception) {
            log("connection ended: ${e.javaClass.simpleName} ${e.message ?: ""}")
        }
        stopStream()
        if (current === this) current = null
        log("closed")
        runCatching { socket.close() }
    }

    @Synchronized fun sendRaw(b: ByteArray) {
        out.write(RemoteFrameReader.framed(b))
        out.flush()
    }

    fun send(m: ToPhone) {
        val s = sealer ?: return
        synchronized(this) { sendRaw(s.seal(byteArrayOf(RemoteFrameKind.CONTROL.raw.toByte()) + m.encode())) }
        if (m !is ToPhone.Pong && m !is ToPhone.Clock && m !is ToPhone.Live && m !is ToPhone.Level) log("→ ${m.toJson()}")
    }

    fun datagram(kind: RemoteFrameKind, body: ByteArray) {
        val to = flow ?: return
        val s = sealer ?: return
        val p = synchronized(this) { s.sealPacket(byteArrayOf(kind.raw.toByte()) + body, number) }
        runCatching { udp.send(DatagramPacket(p, p.size, to)) }
    }

    fun frame(f: ByteArray) {
        val s = sealer
        if (s == null) {
            val a = MacHandshake.answer(f) { who -> keys[who] ?: if (who == codeID) codeKey else null }
            sendRaw(a.reply)
            if (a.sealer == null) { log("handshake refused: ${String(a.reply)}"); throw IllegalStateException("refused") }
            sealer = a.sealer
            id = a.id
            commitment = a.commitment
            reader.limit = RemoteFrameReader.MAX_FRAME
            log("handshake ok, device ${a.id}${if (a.id == codeID) " (pairing code)" else ""}")
            return
        }
        val plain = s.open(f)
        deliver(plain)
    }

    fun deliver(plain: ByteArray) {
        val body = plain.copyOfRange(1, plain.size)
        when (RemoteFrameKind.from(plain[0].toInt() and 0xFF)) {
            RemoteFrameKind.CONTROL -> ToMac.decode(body)?.let { control(it) } ?: log("← unknown control ${String(body)}")
            RemoteFrameKind.AUDIO -> {
                audio += body.size
                if (now() - lastAudioLog > 1) { lastAudioLog = now(); log("← audio ${audio} bytes so far (${audio / 32} ms)") }
            }
            RemoteFrameKind.POINTER -> RemotePointerPacket.decode(body)?.let { pointer(it) }
            RemoteFrameKind.PROBE -> datagram(RemoteFrameKind.PROBE, body)
            else -> {}
        }
    }

    fun pointer(p: RemotePointerPacket) {
        when (p) {
            is RemotePointerPacket.Move -> {
                px = (px + p.dx).coerceIn(0.0, 1512.0)
                py = (py + p.dy).coerceIn(0.0, 944.0)
                log("← pointer move ${"%.1f".format(p.dx)} ${"%.1f".format(p.dy)} → ${px.toInt()},${py.toInt()}")
                cursor()
            }
            is RemotePointerPacket.Scroll -> log("← scroll ${"%.1f".format(p.dx)} ${"%.1f".format(p.dy)} ${p.phase}")
            is RemotePointerPacket.ScrollFling -> log("← fling ${p.vx.toInt()} ${p.vy.toInt()}")
            RemotePointerPacket.ScrollStop -> if (greeted && udpSeen) log("← scroll stop")
        }
    }

    fun cursor() = datagram(RemoteFrameKind.CURSOR, RemoteCursor.encode((px / 1512).toFloat(), (py / 944).toFloat()))

    fun control(m: ToMac) {
        when (m) {
            is ToMac.Ping -> {
                send(ToPhone.Pong(m.t))
                send(ToPhone.Clock(m.t, now()))
                return
            }
            is ToMac.Hello -> {
                log("← hello from \"${m.device}\" micOnPhone=${m.micOnPhone}")
                if (id == codeID) {
                    val n = m.nonce
                    val c = commitment
                    if (n == null || c == null || !RemoteCrypto.same(RemoteCrypto.commitment(n), c)) { log("nonce doesn't match: refused"); socket.close(); return }
                    asking = true
                    current = this
                    log("ASKING: allow \"${m.device}\"? digits ${sealer!!.check(n)}")
                    send(ToPhone.PairingWaits)
                    if (!ask) thread { Thread.sleep(2000); answer(true) }
                    return
                }
                begin()
                return
            }
            ToMac.KeyStored -> {
                val k = pairingKey ?: return
                keys[id!!] = k
                save()
                pairingKey = null
                log("paired: ${id}")
                newCode()
                begin()
                return
            }
            else -> {}
        }
        log("← ${m.toJson()}")
        when (m) {
            is ToMac.Screen -> {
                stopStream()
                val r = m.request ?: return
                crop = r.crop
                stream(r.codecs ?: listOf(RemoteVideoCodec.HEVC), r.fps)
            }
            is ToMac.ScreenCrop -> crop = m.crop
            is ToMac.ShowDisplay -> {
                display = m.display ?: "1"
                if (streaming != null) send(ToPhone.ScreenView(1512.0, 944.0, lastCodec, if (twoDisplays) display else null))
            }
            is ToMac.PointerTo -> { px = m.x * 1512.0; py = m.y * 944.0; cursor() }
            is ToMac.DictationKey -> {
                send(ToPhone.Dictation(if (m.down) RemoteDictationPhase.LISTENING else RemoteDictationPhase.IDLE))
                listening = m.down
                // what Blurt would show while someone talks: the words so far, and the level
                if (m.down) thread {
                    val words = "把会话列表和旁边的对话分开滚动，手指在哪边就滚哪边，别让整页一起动。"
                    var n = 0
                    while (listening && n < words.length) {
                        n = minOf(words.length, n + 3)
                        val cut = maxOf(0, n - 6)
                        send(ToPhone.Live(words.take(cut), words.substring(cut, n)))
                        send(ToPhone.Level((0.25 + Math.random() * 0.6).toFloat()))
                        Thread.sleep(250)
                    }
                }
            }
            ToMac.Unpair -> { keys.remove(id); save() }
            else -> {}
        }
    }

    fun answer(yes: Boolean) {
        if (!asking) return
        asking = false
        if (!yes) { log("said no"); socket.close(); return }
        pairingKey = RemoteCrypto.newKey()
        send(ToPhone.NewKey(pairingKey!!))
    }

    fun begin() {
        greeted = true
        current = this
        send(ToPhone.Session(RemoteSessionInfo(name, UDP_PORT, number, true, "1.0.15-fake", displayAspect = 1512.0 / 944.0, platform = platform)))
        send(ToPhone.Front(RemoteFront(if (platform == "mac") "com.apple.Terminal" else "WindowsTerminal.exe", "Terminal")))
        send(ToPhone.Dictation(RemoteDictationPhase.IDLE))
        if (twoDisplays) send(ToPhone.Displays(DISPLAYS))
    }

    // MARK: the picture

    var lastCodec = RemoteVideoCodec.HEVC

    fun stopStream() {
        streaming?.destroy()
        streaming = null
    }

    fun stream(codecs: List<String>, fps: Int) {
        val png = picture ?: return log("no --picture: nothing to show")
        val hevc = codecs.firstOrNull() == RemoteVideoCodec.HEVC
        val codec = if (hevc) RemoteVideoCodec.HEVC else RemoteVideoCodec.H264
        lastCodec = codec
        send(ToPhone.ScreenView(1512.0, 944.0, codec, if (twoDisplays) display else null))
        val rate = minOf(fps, 30)
        val enc = if (hevc) listOf("-c:v", "libx265", "-x265-params", "keyint=30:bframes=0:repeat-headers=1:aud=1:log-level=error", "-tune", "zerolatency", "-preset", "ultrafast")
            else listOf("-c:v", "libx264", "-x264-params", "keyint=30:bframes=0:repeat-headers=1:aud=1", "-tune", "zerolatency", "-preset", "ultrafast")
        val cmd = listOf("ffmpeg", "-hide_banner", "-loglevel", "error", "-re", "-loop", "1", "-framerate", "$rate", "-i", png,
            "-vf", "scale=1512:944,format=yuv420p", "-r", "$rate", "-b:v", "6M") + enc + listOf("-f", if (hevc) "hevc" else "h264", "-")
        val p = ProcessBuilder(cmd).redirectError(ProcessBuilder.Redirect.INHERIT).start()
        streaming = p
        log("streaming $codec at $rate fps")
        thread(name = "video") {
            var frame = 0L
            val nals = NalReader(p.inputStream)
            var au = mutableListOf<ByteArray>()
            fun flush() {
                if (au.isEmpty()) return
                val sets = au.filter { isParam(it, hevc) }
                val pic = au.filter { !isParam(it, hevc) && !isAud(it, hevc) }
                val key = au.any { isKey(it, hevc) }
                au = mutableListOf()
                if (pic.isEmpty()) return
                val picture = pic.fold(ByteArray(0)) { a, n -> a + len(n.size) + n }
                // one encoder, one picture: it can't send the part asked for, so it says it's the whole screen, which is true
                val payload = RemoteVideoPayload.pack(RemoteCrop.WHOLE, if (key) sets else emptyList(), picture)
                frame += 1
                for (piece in RemoteVideoPacket.split(payload, frame, key, now())) datagram(RemoteFrameKind.VIDEO, piece.encoded())
            }
            while (streaming === p) {
                val n = nals.next() ?: break
                if (isAud(n, hevc)) flush()
                au += n
            }
            flush()
        }
    }
}

private fun len(n: Int) = byteArrayOf((n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte())
private fun type(n: ByteArray, hevc: Boolean) = if (hevc) (n[0].toInt() shr 1) and 0x3F else n[0].toInt() and 0x1F
private fun isParam(n: ByteArray, hevc: Boolean) = type(n, hevc).let { if (hevc) it in 32..34 else it == 7 || it == 8 }
private fun isAud(n: ByteArray, hevc: Boolean) = type(n, hevc) == if (hevc) 35 else 9
private fun isKey(n: ByteArray, hevc: Boolean) = type(n, hevc).let { if (hevc) it in 16..21 else it == 5 }

/** Annex B in, NAL units out (without their start codes). */
private class NalReader(private val input: InputStream) {
    private val buf = java.io.ByteArrayOutputStream()
    private var pending = ByteArray(0)
    private var at = 0

    fun next(): ByteArray? {
        while (true) {
            // find the next start code after the first
            val s = startAt(0) ?: if (!fill()) return null else continue
            val e = startAt(s.first + s.second)
            if (e == null) { if (!fill()) { val n = pending.copyOfRange(s.first + s.second, pending.size); pending = ByteArray(0); return n.takeIf { it.isNotEmpty() } }; continue }
            val n = pending.copyOfRange(s.first + s.second, e.first)
            pending = pending.copyOfRange(e.first, pending.size)
            return n
        }
    }

    private fun startAt(from: Int): Pair<Int, Int>? {
        var i = from
        while (i + 3 <= pending.size) {
            if (pending[i] == 0.toByte() && pending[i + 1] == 0.toByte()) {
                if (pending[i + 2] == 1.toByte()) return i to 3
                if (i + 4 <= pending.size && pending[i + 2] == 0.toByte() && pending[i + 3] == 1.toByte()) return i to 4
            }
            i++
        }
        return null
    }

    private fun fill(): Boolean {
        val b = ByteArray(65536)
        val n = input.read(b)
        if (n <= 0) return false
        pending += b.copyOf(n)
        buf.reset()
        at = 0
        return true
    }
}

private fun udpLoop() {
    val buf = ByteArray(2048)
    while (true) {
        val p = DatagramPacket(buf, buf.size)
        udp.receive(p)
        val d = buf.copyOf(p.length)
        val s = current ?: continue
        if (RemoteSealer.sessionOfPacket(d) != s.number || !s.greeted) continue
        val plain = synchronized(s) { s.sealer?.openPacket(d) } ?: continue
        s.flow = p.socketAddress
        if (!s.udpSeen) {
            s.udpSeen = true
            log("udp ok from ${p.socketAddress}")
            s.send(ToPhone.UdpOK)
        }
        s.deliver(plain)
    }
}

@Suppress("unused") private fun unused(a: InetSocketAddress) = a
