// A fake computer: the host's side of the wire (remote-protocol.md), as RemoteServer.swift runs it, minus pressing anything. It prints what
// arrives, one line each, so a test can read what the phone sent.
//
//   --platform mac|windows|linux   what it says it is (the phone's keys follow)
//   --name <name>                  its name on the phone
//   --picture <png>                stream this still (ffmpeg) when the phone asks for the screen, at the phone's rate up to --fps
//   --scroll                       the picture scrolls 2 px a frame, wrapping, as a terminal scrolling smoothly does
//   --fps <n>                      the most frames a second it sends (default 60)
//   --codec hevc|h264              this codec whatever the phone prefers
//   --no-repairs                   use none of the repairs the phone offers (an older host)
//   --fec <G>                      a parity piece for every G pieces, whatever the reports say
//   --address <ip>                 the address in the pairing link (default 10.0.2.2, the Mac as the emulator sees it)
//   --state <file>                 paired phones, kept across runs (default build/fakehost.json)
//   --ask                          a new phone waits for "y" on stdin; without it the answer is yes after 2 s
//   --port <n>                     TCP on n, UDP on n + 1 (default 47811)
//   --two-displays                 say it has a second display, above and to the right of the first (the picture is the same)
//
// Repairs (docs/design/remote-realtime.md §Host): of what the phone offers it uses nack and fec, not ltr (ffmpeg's encoders can't refer
// back to an acknowledged frame), so a frame given up costs a keyframe, as on a Linux host. Pieces are kept for a second and sent again when
// the phone names them; a keyframe is answered by starting the encoder over (at most every 0.7 s, as the Mac answers), with the picture
// and the frame numbers carrying on.
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
import dev.blurt.remote.core.RemoteScreenReport
import dev.blurt.remote.core.RemoteVideoCodec
import dev.blurt.remote.core.RemoteVideoFEC
import dev.blurt.remote.core.RemoteVideoFeature
import dev.blurt.remote.core.RemoteVideoFeedback
import dev.blurt.remote.core.RemoteVideoHistory
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
private var scroll = false
private var maxFps = 60
private var forceCodec: String? = null
private var repairsOn = true
private var forcedFec = 0
private val DISPLAYS = listOf(
    dev.blurt.remote.core.RemoteDisplay("1", "Built-in Retina Display", 0.0, 0.0, 1512.0, 944.0, true),
    dev.blurt.remote.core.RemoteDisplay("2", "Studio Display", 1512.0, -458.0, 2560.0, 1440.0, false),
)
private var tcpPort = 47811
private val udpPort get() = tcpPort + 1

private val start = System.nanoTime()
private fun now() = (System.nanoTime() - start) / 1e9
private fun log(s: String) = synchronized(System.out) { println(String.format("%8.3f %s", now(), s)); System.out.flush() }

/** paired phones: device id → key; and the one code waiting to be used */
private val keys = ConcurrentHashMap<String, ByteArray>()
private var codeID: String? = null
private var codeKey: ByteArray? = null
private val udp by lazy { DatagramSocket(udpPort) }
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
            "--scroll" -> scroll = true
            "--port" -> tcpPort = args[++i].toInt()
            "--fps" -> maxFps = args[++i].toInt()
            "--codec" -> forceCodec = args[++i]
            "--no-repairs" -> repairsOn = false
            "--fec" -> forcedFec = args[++i].toInt()
        }
        i++
    }
    load()
    newCode()
    thread(name = "udp") { udpLoop() }
    if (ask) thread(name = "stdin") { stdin() }
    val server = ServerSocket(tcpPort)
    log("listening tcp $tcpPort udp $udpPort as $platform \"$name\"")
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
    val p = RemotePairing(MAC_ID, codeID!!, codeKey!!, name, tcpPort, listOf(address))
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
    /** the newest of the phone's pointer instructions made (u32); null until it sends a number, and the cursor's place is 8 bytes */
    var phoneSeq: Long? = null
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
            RemoteFrameKind.VIDEO_FEEDBACK -> RemoteVideoFeedback.decode(body)?.let { feedback(it) }
            else -> {}
        }
    }

    fun pointer(p: RemotePointerPacket) {
        when (p) {
            is RemotePointerPacket.Move -> {
                px = (px + p.dx).coerceIn(0.0, 1512.0)
                py = (py + p.dy).coerceIn(0.0, 944.0)
                log("← pointer move ${"%.1f".format(p.dx)} ${"%.1f".format(p.dy)} → ${px.toInt()},${py.toInt()}${p.seq?.let { " #$it" } ?: ""}")
                made(p.seq)
                cursor()
            }
            is RemotePointerPacket.Scroll -> log("← scroll ${"%.1f".format(p.dx)} ${"%.1f".format(p.dy)} ${p.phase}")
            is RemotePointerPacket.ScrollFling -> log("← fling ${p.vx.toInt()} ${p.vy.toInt()}")
            RemotePointerPacket.ScrollStop -> if (greeted && udpSeen) log("← scroll stop")
        }
    }

    /** The phone's pointer instruction with this number is made. Later ones count, and one far behind is a phone that started over. */
    fun made(seq: Long?) {
        seq ?: return
        val l = phoneSeq
        if (l == null || !RemoteCursor.covers(l, seq) || ((l - seq) and 0xFFFF_FFFFL) >= (1L shl 16)) phoneSeq = seq
    }

    fun cursor() = datagram(RemoteFrameKind.CURSOR, RemoteCursor((px / 1512).toFloat(), (py / 944).toFloat(), phoneSeq).encoded())

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
        if (m !is ToMac.ScreenReport) log("← ${m.toJson()}")
        when (m) {
            is ToMac.Screen -> {
                stopStream()
                val r = m.request ?: return
                crop = r.crop
                repairs = if (repairsOn) r.features.orEmpty().filter { it == RemoteVideoFeature.NACK || it == RemoteVideoFeature.FEC }.toSet() else emptySet()
                stream(r.codecs ?: listOf(RemoteVideoCodec.HEVC), r.fps)
            }
            ToMac.RequestKeyframe -> keyframe()
            is ToMac.ScreenReport -> report(m.report)
            is ToMac.ScreenCrop -> crop = m.crop
            is ToMac.ShowDisplay -> {
                display = m.display ?: "1"
                if (streaming != null) send(ToPhone.ScreenView(1512.0, 944.0, lastCodec, if (twoDisplays) display else null, features()))
            }
            is ToMac.PointerTo -> { px = m.x * 1512.0; py = m.y * 944.0; made(m.seq); cursor() }
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
        send(ToPhone.Session(RemoteSessionInfo(name, udpPort, number, true, "1.0.15-fake", displayAspect = 1512.0 / 944.0, platform = platform)))
        send(ToPhone.Front(RemoteFront(if (platform == "mac") "com.apple.Terminal" else "WindowsTerminal.exe", "Terminal")))
        send(ToPhone.Dictation(RemoteDictationPhase.IDLE))
        if (twoDisplays) send(ToPhone.Displays(DISPLAYS))
    }

    // MARK: the picture

    var lastCodec = RemoteVideoCodec.HEVC
    /** the repairs used for this stream: what the phone offered, of nack and fec */
    @Volatile var repairs: Set<String> = emptySet()
    private val history = RemoteVideoHistory()
    /** frame numbers carry on across encoder restarts: the phone holds what's behind a gap */
    private var frameId = 0L
    /** frames encoded since the stream began: where the scrolling picture is */
    @Volatile private var encoded = 0L
    private var streamCodecs = listOf(RemoteVideoCodec.HEVC)
    private var streamFps = 30
    private var keyAt = -1.0
    private var keyWaiting = false
    /** the encoder has sent nothing yet */
    @Volatile private var fresh = false
    // parity: a piece for every `group` pieces, from what the phone's reports say (rtt and pieces asked for again)
    @Volatile private var group = 0
    private var sentPieces = 0
    private var askedPieces = 0
    private val recent = ArrayDeque<Pair<Int, Int>>()
    // sending again: at most max(300 KB, bitrate / 16) a second
    private var budgetAt = 0.0
    private var budgetUsed = 0
    private var resent = 0

    fun features(): List<String>? = repairs.sorted().takeIf { it.isNotEmpty() }

    fun stopStream() {
        val old = streaming
        streaming = null
        old?.destroy()
    }

    fun stream(codecs: List<String>, fps: Int) {
        if (picture == null) return log("no --picture: nothing to show")
        streamCodecs = codecs
        streamFps = minOf(fps, maxFps)
        val hevc = (forceCodec ?: codecs.firstOrNull()) == RemoteVideoCodec.HEVC
        lastCodec = if (hevc) RemoteVideoCodec.HEVC else RemoteVideoCodec.H264
        synchronized(history) { history.clear() }
        send(ToPhone.ScreenView(1512.0, 944.0, lastCodec, if (twoDisplays) display else null, features()))
        encoder()
    }

    /** The phone lost a frame for good, or its decoder did: the encoder starts over with a keyframe. At most every 0.7 s, as the Mac. */
    @Synchronized fun keyframe() {
        // a new encoder's first picture is a keyframe already: starting it over again would only put that off
        if (streaming == null || keyWaiting || fresh) return
        val wait = 0.7 - (now() - keyAt)
        if (wait > 0) {
            keyWaiting = true
            thread { Thread.sleep((wait * 1000).toLong()); synchronized(this) { keyWaiting = false }; keyframe() }
            return
        }
        keyAt = now()
        log("keyframe: encoder restarted")
        encoder()
    }

    private fun encoder() {
        val png = picture ?: return
        // retired first: the old one's last picture, cut off as it dies, must not go out
        val old = streaming
        streaming = null
        old?.destroy()
        fresh = true
        val hevc = lastCodec == RemoteVideoCodec.HEVC
        val rate = streamFps
        // no periodic keyframes with repairs, as the Mac (and 600 frames without, as the Mac too)
        val keyint = if (repairs.isEmpty()) 600 else 100_000
        val enc = if (hevc) listOf("-c:v", "libx265", "-x265-params", "keyint=$keyint:min-keyint=$keyint:scenecut=0:bframes=0:repeat-headers=1:aud=1:log-level=error", "-tune", "zerolatency", "-preset", "ultrafast")
            else listOf("-c:v", "libx264", "-x264-params", "keyint=$keyint:min-keyint=$keyint:scenecut=0:bframes=0:repeat-headers=1:aud=1", "-tune", "zerolatency", "-preset", "ultrafast")
        // scrolling: 2 px of 944 a frame, from where the last encoder left off
        val moving = if (scroll) ",scroll=vertical=${"%.6f".format(2.0 / 944)}:vpos=${"%.6f".format((encoded * 2.0 / 944) % 1.0)}" else ""
        val cmd = listOf("ffmpeg", "-hide_banner", "-loglevel", "error", "-re", "-loop", "1", "-framerate", "$rate", "-i", png,
            "-vf", "scale=1512:944$moving,format=yuv420p", "-r", "$rate", "-b:v", "8M", "-maxrate", "12M", "-bufsize", "400k") + enc +
            listOf("-f", if (hevc) "hevc" else "h264", "-")
        val p = ProcessBuilder(cmd).redirectError(ProcessBuilder.Redirect.INHERIT).start()
        streaming = p
        log("streaming $lastCodec at $rate fps${if (scroll) ", scrolling" else ""}, repairs ${features() ?: "none"}")
        thread(name = "video") {
            val nals = NalReader(p.inputStream)
            var au = mutableListOf<ByteArray>()
            fun flush() {
                if (au.isEmpty()) return
                val sets = au.filter { isParam(it, hevc) }
                val pic = au.filter { !isParam(it, hevc) && !isAud(it, hevc) }
                val key = au.any { isKey(it, hevc) }
                au = mutableListOf()
                if (pic.isEmpty() || streaming !== p) return
                encoded += 1
                fresh = false
                val picture = pic.fold(ByteArray(0)) { a, n -> a + len(n.size) + n }
                // one encoder, one picture: it can't send the part asked for, so it says it's the whole screen, which is true
                val payload = RemoteVideoPayload.pack(RemoteCrop.WHOLE, if (key) sets else emptyList(), picture)
                sendFrame(payload, key)
            }
            while (streaming === p) {
                val n = try { nals.next() } catch (_: java.io.IOException) { null } ?: break     // an encoder started over: this one is closed
                if (isAud(n, hevc)) flush()
                au += n
            }
            flush()
        }
    }

    /** One frame: its pieces, kept for sending again, then its parity pieces. */
    @Synchronized private fun sendFrame(payload: ByteArray, key: Boolean) {
        frameId += 1
        val pieces = RemoteVideoPacket.split(payload, frameId, key, now())
        val wire = pieces.map { it.encoded() }
        if (RemoteVideoFeature.NACK in repairs) synchronized(history) { history.add(frameId, wire, now()) }
        for (w in wire) datagram(RemoteFrameKind.VIDEO, w)
        sentPieces += wire.size
        val g = if (forcedFec > 0) forcedFec else group
        if (RemoteVideoFeature.FEC in repairs && g >= 2) for (par in RemoteVideoFEC.parity(pieces, g)) datagram(RemoteFrameKind.VIDEO, par.encoded())
    }

    /** What the phone says about the picture. */
    fun feedback(f: RemoteVideoFeedback) {
        when (f) {
            is RemoteVideoFeedback.Nack -> {
                if (RemoteVideoFeature.NACK !in repairs) return
                val t = now()
                synchronized(this) {
                    if (t - budgetAt >= 1) { budgetAt = t; budgetUsed = 0 }
                    for (m in f.missing) {
                        askedPieces += maxOf(1, m.pieces.size)
                        for (w in synchronized(history) { history.pieces(m.frame, m.pieces) }) {
                            // past the budget the network is the trouble: the rate would come down instead
                            if (budgetUsed + w.size > maxOf(300_000, 12_000_000 / 8 / 16)) return
                            budgetUsed += w.size
                            resent += 1
                            datagram(RemoteFrameKind.VIDEO, w)
                        }
                    }
                }
            }
            is RemoteVideoFeedback.Lost -> keyframe()       // no ltr here: a keyframe
            is RemoteVideoFeedback.Ack -> {}
        }
    }

    /** Every report: parity as remote-realtime.md §Host 5 says, from the round trip and the pieces asked for again over the last five. */
    @Synchronized fun report(r: RemoteScreenReport) {
        recent.addLast(askedPieces to sentPieces)
        askedPieces = 0
        sentPieces = 0
        while (recent.size > 5) recent.removeFirst()
        val asked = recent.sumOf { it.first }.toDouble()
        val sent = maxOf(1, recent.sumOf { it.second }).toDouble()
        val loss = asked / sent
        val rtt = r.rtt ?: 0.0
        val g = if (rtt >= 0.03) when { loss > 0.05 -> 4; loss > 0.01 -> 8; loss > 0.002 -> 16; else -> 0 } else if (loss > 0.10) 8 else 0
        if (g != group) log("parity: G = $g (rtt ${"%.1f".format(rtt * 1000)} ms, ${"%.2f".format(loss * 100)} % asked again)")
        group = g
        if (resent > 0) { log("sent again: $resent pieces since the last report"); resent = 0 }
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
