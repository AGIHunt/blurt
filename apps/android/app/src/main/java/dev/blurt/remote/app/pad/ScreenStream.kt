// The computer's screen on the phone (docs/design/remote.md §Screen; port of Pad/ScreenStream.swift): pieces to frames, frames through the
// hardware decoder, onto the stage behind the pad. Off unless asked for: while off nothing is sent, received or decoded.
//
// The phone owns the view (ViewPort): fingers move it here at once, over the picture already here, and the computer is asked for that part
// about 7 times a second. Every frame says which part it shows, and StageView draws it there in the same pass it shows it. The pointer
// isn't in the video: the phone draws it, ahead of the stream on its own strokes, and the computer has the last word after a stroke.
//
// Geometry here is in dp, as the pad engine's is.
package dev.blurt.remote.app.pad

import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.view.Surface
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.net.Net
import dev.blurt.remote.core.LinkRoute
import dev.blurt.remote.core.PadPoint
import dev.blurt.remote.core.PadSize
import dev.blurt.remote.core.RemoteCrop
import dev.blurt.remote.core.RemoteCursor
import dev.blurt.remote.core.RemoteScreenReport
import dev.blurt.remote.core.RemoteScreenRequest
import dev.blurt.remote.core.RemoteVideoAssembler
import dev.blurt.remote.core.RemoteVideoCodec
import dev.blurt.remote.core.RemoteVideoPacket
import dev.blurt.remote.core.RemoteVideoPayload
import dev.blurt.remote.core.ScreenPlan
import dev.blurt.remote.core.ToMac
import dev.blurt.remote.core.ViewPort
import kotlinx.coroutines.flow.MutableStateFlow
import java.nio.ByteBuffer

class ScreenStream(private val c: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val dec = Handler(HandlerThread("blurt-decode", Process.THREAD_PRIORITY_URGENT_DISPLAY).apply { start() }.looper)

    /** what Settings shows: kbps, fps, bytes since opening, running */
    data class Use(val kbps: Int = 0, val fps: Int = 0, val total: Long = 0, val running: Boolean = false)
    val use = MutableStateFlow(Use())

    @Volatile var on = false
        private set
    private var stage: StageView? = null
    private var cursorView: CursorView? = null
    /** the pad, in dp */
    private var bw = 0.0
    private var bh = 0.0
    private var alignY = 0.5
    private var srcW = 0.0
    private var srcH = 0.0
    private var codec: String = RemoteVideoCodec.HEVC
    /** what's in view: fingers move it here, at once */
    var port = ViewPort()
        private set
    /** what the frame on screen shows */
    @Volatile private var shown = RemoteCrop.WHOLE
    private var sentCrop = RemoteCrop.WHOLE
    private var lastCropSent = 0.0
    private var cropQueued = false
    private var planned: ScreenPlan? = null
    private var planWait: Runnable? = null
    private var idle = false
    private var quietReports = 0

    // the pointer, drawn here: 0…1 of the screen, -1 = not known yet
    private var px = -1.0
    private var py = -1.0
    private var macPointer: Pair<Double, Double>? = null
    private var settling = false
    private var dragWaiting: Pair<Double, Double>? = null
    private var lastDragSent = 0.0
    private var lastPredicted = 0.0

    // the computer's clock, from the fastest exchange seen
    @Volatile private var offset: Double? = null
    private var bestRTT = Double.MAX_VALUE

    // decoding: on `dec`
    private var assembler = RemoteVideoAssembler()
    private var decoder: MediaCodec? = null
    private var decoderSets: List<ByteArray>? = null
    private var surface: Surface? = null
    private val waiting = ArrayDeque<Pair<ByteArray, Long>>()
    private val freeInputs = ArrayDeque<Int>()
    private var lastKeyRequest = 0.0
    private var reportFrames = 0
    private var reportBytes = 0
    private var reportDropped = 0
    private var pictureBytes = 0
    private var reportAt = Net.now()
    private var totalBytes = 0L
    private var nextPts = 1L
    private var timersOn = false

    fun attach(s: StageView, cursor: CursorView) {
        stage = s
        cursorView = cursor
        s.onSurface = { out -> dec.post { surface = out; resetDecoder() } }
        s.surface?.let { out -> dec.post { surface = out } }
        s.onShown = { crop -> main.post { if (crop != shown) { shown = crop; place() } } }
    }

    /** The stage is the whole pad; the picture sits in it. `alignY`: where a picture smaller than the stage sits, near the thumb in portrait. */
    fun layout(widthDp: Double, heightDp: Double, alignY: Double) {
        bw = widthDp
        bh = heightDp
        this.alignY = alignY
        reshape()
    }

    private fun reshape() {
        val a = if (srcW > 0 && srcH > 0) srcW / srcH else Remote.link.displayAspect.value
        if (bh > 0 && a > 0) port.reshape(bw / bh / a, alignY)
        place()
    }

    private val plan: ScreenPlan get() {
        val l = Remote.link
        val dm = c.resources.displayMetrics
        return ScreenPlan(Remote.prefs.quality, l.route.value, Remote.net.cellular, Remote.net.lowData,
            PadSize(maxOf(dm.widthPixels, dm.heightPixels).toDouble(), minOf(dm.widthPixels, dm.heightPixels).toDouble()))
    }

    private fun same(a: ScreenPlan?, b: ScreenPlan) = a != null && a.width == b.width && a.height == b.height && a.bitrate == b.bitrate && a.fps == b.fps

    /** The most the computer may send, for this path and what the user chose. Under that it follows what the network carries. */
    fun start() {
        val p = plan
        planned = p
        val crop = port.crop
        sentCrop = crop
        idle = false
        val r = RemoteScreenRequest(TARGET, crop, p.width, p.height, p.bitrate, p.fps, decodable)
        on = true
        stage?.scene?.on = true
        dec.post {
            resetDecoder()
            pictureBytes = 0
        }
        Remote.link.send(ToMac.Screen(r))
        startTimers()
    }

    /** The route, the phone's network, or the user's choice changed. A network that flickers restarts nothing. */
    fun planChanged() {
        planWait?.let { main.removeCallbacks(it) }
        val w = Runnable { if (on && !same(planned, plan)) start() }
        planWait = w
        main.postDelayed(w, 1500)
    }

    /** Nobody touching the phone, away from home: the computer slows down. Home has nothing to save. */
    fun setIdle(want0: Boolean) {
        val want = want0 && Remote.link.route.value != LinkRoute.LOCAL
        if (!on || want == idle) return
        idle = want
        Remote.link.send(ToMac.ScreenPace(want))
    }

    /** A new session: the computer stopped the stream with the old one. */
    fun resume() { if (on) start() }

    fun connectionLost() { dec.post { resetDecoder() } }

    fun stop() {
        if (!on) return
        on = false
        stage?.scene?.on = false
        stopTimers()
        use.value = use.value.copy(running = false)
        Remote.link.send(ToMac.Screen(null))
        dec.post { resetDecoder() }
        stage?.clear()
        resetView()
        cursorView?.hide()
    }

    // MARK: the view and the pointer

    fun source(w: Double, h: Double, codec: String?) {
        main.post {
            this.codec = codec ?: RemoteVideoCodec.HEVC
            srcW = w
            srcH = h
            if (h > 0) Remote.link.setAspect(w / h)     // the display in view, which may not be the main one
            reshape()
        }
    }

    /** Fingers on the view. The picture moves now; the computer catches up. */
    fun change(scale: Double, dx: Double, dy: Double, at: PadPoint) {
        if (bw <= 0) return
        if (port.isWhole) stage?.wantBackdrop = true
        port.change(scale, PadPoint(dx / bw, dy / bh), PadPoint(at.x / bw, at.y / bh))
        place()
        askForView()
    }

    fun gestureEnded() {
        port.settle()
        place()
        askForView(now = true)
    }

    /** The view back to the whole screen and nothing left of the last one. */
    fun resetView() {
        port = ViewPort()
        reshape()
        shown = RemoteCrop.WHOLE
        sentCrop = RemoteCrop.WHOLE
        place()
    }

    /** At most a few times a second while it moves: each change costs the encoder a little, and there's a picture to look at meanwhile. */
    private fun askForView(now: Boolean = false) {
        val crop = port.crop
        if (!on || crop == sentCrop) return
        val gap = if (Remote.link.route.value == LinkRoute.RELAY) 0.33 else 0.15
        val wait = gap - (Net.now() - lastCropSent)
        if (now || wait <= 0) {
            sentCrop = crop
            lastCropSent = Net.now()
            Remote.link.send(ToMac.ScreenCrop(crop))
        } else if (!cropQueued) {
            cropQueued = true
            main.postDelayed({ cropQueued = false; askForView() }, (wait * 1000).toLong())
        }
    }

    /** Both pictures where they belong for what's in view. */
    private fun place() {
        val s = stage ?: return
        val r = port.rect
        s.scene.view = doubleArrayOf(r.x, r.y, r.width, r.height)
        s.scene.showBackdrop = !(port.isWhole && shown == RemoteCrop.WHOLE)
        s.requestRender()
        placeCursor()
    }

    /** The view has moved off the pointer and the finger is about to use it: it comes into view, where the eyes are. */
    fun bringPointerIntoView() {
        val v = port.visible
        if (!on || port.isWhole || px < 0) return
        if (px < v.minX || px > v.maxX || py < v.minY || py > v.maxY) move(v.midX, v.midY)
    }

    fun cursor(d: ByteArray) {
        val p = RemoteCursor.decode(d) ?: return
        main.post {
            macPointer = p.first.toDouble() to p.second.toDouble()
            settle()
        }
    }

    /** The phone's own guess leads while the finger moves, and the computer has the last word when it stops. A word that came while the
     *  finger was still moving is kept, not dropped, or the two drift apart stroke by stroke. */
    private fun settle() {
        val wait = maxOf(0.12, (Remote.link.rtt ?: 0.0) * 1.5) - (Net.now() - lastPredicted)
        if (wait <= 0) {
            val m = macPointer ?: return
            px = m.first
            py = m.second
            placeCursor()
        } else if (!settling) {
            settling = true
            main.postDelayed({ settling = false; settle() }, ((wait + 0.01) * 1000).toLong())
        }
    }

    /** Where a point on the pad is on the computer's screen; null off the picture. */
    private fun onScreen(p: PadPoint): Pair<Double, Double>? {
        if (bw <= 0) return null
        val v = port.rect
        val x = v.minX + p.x / bw * v.width
        val y = v.minY + p.y / bh * v.height
        return if (x in 0.0..1.0 && y in 0.0..1.0) x to y else null
    }

    /** The pointer under the finger, now, ahead of whatever comes next. False off the picture. */
    fun placePointer(p: PadPoint): Boolean {
        if (!on) return false
        val at = onScreen(p) ?: return false
        move(at.first, at.second)
        return true
    }

    /** With the button down it follows the finger, and stops at the picture's edge. Over the relay no more often than the pointer goes. */
    fun dragPointer(p: PadPoint) {
        if (!on || bw <= 0) return
        val v = port.visible
        val r = port.rect
        val x = (r.minX + p.x / bw * r.width).coerceIn(v.minX, v.maxX)
        val y = (r.minY + p.y / bh * r.height).coerceIn(v.minY, v.maxY)
        px = x
        py = y
        lastPredicted = Net.now()
        placeCursor()
        if (Remote.link.route.value != LinkRoute.RELAY) return Remote.link.send(ToMac.PointerTo(x.toFloat(), y.toFloat()))
        dragWaiting = x to y
        if (Net.now() - lastDragSent >= 1.0 / 30) finishDrag()
    }

    /** What's left of a drag goes before the button comes up. */
    fun finishDrag() {
        val at = dragWaiting ?: return
        dragWaiting = null
        lastDragSent = Net.now()
        Remote.link.send(ToMac.PointerTo(at.first.toFloat(), at.second.toFloat()))
    }

    private fun move(x: Double, y: Double) {
        px = x
        py = y
        lastPredicted = Net.now()
        Remote.link.send(ToMac.PointerTo(x.toFloat(), y.toFloat()))     // on this thread: a click sent next must land after it
        placeCursor()
    }

    fun predict(dx: Float, dy: Float) {
        if (!on || srcW <= 0 || px < 0) return
        lastPredicted = Net.now()
        px = (px + dx / srcW).coerceIn(0.0, 1.0)
        py = (py + dy / srcH).coerceIn(0.0, 1.0)
        if (port.follow(PadPoint(px, py))) {
            place()
            askForView()
        } else {
            placeCursor()
        }
    }

    fun shape(png: ByteArray, hotX: Double, hotY: Double, w: Double, h: Double) {
        val b = BitmapFactory.decodeByteArray(png, 0, png.size) ?: return
        main.post {
            cursorView?.shape(b, hotX, hotY, w, h)
            placeCursor()
        }
    }

    private fun placeCursor() {
        val cv = cursorView ?: return
        if (!on || srcW <= 0 || px < 0 || bw <= 0) return cv.hide()
        val v = port.rect
        val x = (px - v.minX) / v.width
        val y = (py - v.minY) / v.height
        if (x < 0 || x > 1 || y < 0 || y > 1) return cv.hide()
        // its true scale, but never too small to find
        val k = maxOf(0.75, bw / (srcW * v.width))
        cv.place(x * bw, y * bh, k)
    }

    fun clock(phone: Double, mac: Double) {
        val rtt = Net.now() - phone
        // the fastest exchange says the most; older ones count for less as the clocks drift
        bestRTT *= 1.002
        if (rtt < bestRTT) {
            bestRTT = rtt
            offset = mac - (phone + rtt / 2)
        }
    }

    // MARK: arriving (the net thread), decoding (`dec`)

    fun packet(d: ByteArray) {
        if (!on) return
        val p = RemoteVideoPacket.decode(d) ?: return
        dec.post {
            reportBytes += d.size
            pictureBytes += p.payload.size
            assembler.add(p)?.let { decode(it) }
            askForKey()
        }
    }

    fun probeBack(d: ByteArray) {}

    private fun askForKey() {
        if (!assembler.waitingForKey) return
        val now = Net.now()
        if (now - lastKeyRequest <= 0.25) return
        lastKeyRequest = now
        main.post { if (on) Remote.link.send(ToMac.RequestKeyframe) }
    }

    private fun resetDecoder() {
        assembler = RemoteVideoAssembler()
        reportDropped = 0
        waiting.clear()
        freeInputs.clear()
        decoder?.let { d -> runCatching { d.stop() }; runCatching { d.release() } }
        decoder = null
        decoderSets = null
    }

    private fun decode(f: RemoteVideoAssembler.Frame) {
        val u = RemoteVideoPayload.unpack(f.data) ?: return
        if (u.parameterSets.isNotEmpty()) prepare(u.parameterSets)
        val d = decoder ?: return
        val pts = nextPts++
        stage?.crops?.put(pts, u.crop)
        // the picture's 4-byte lengths become start codes, which is what Android's decoders want
        val annexB = startCodes(u.picture)
        if (waiting.size > 6) {
            // the decoder has fallen behind: what's queued is worth nothing, and what follows needs a keyframe
            waiting.clear()
            assembler = RemoteVideoAssembler()
            askForKey()
            return
        }
        waiting.addLast(annexB to pts)
        feed(d)
    }

    private fun feed(d: MediaCodec) {
        while (waiting.isNotEmpty() && freeInputs.isNotEmpty()) {
            val i = freeInputs.removeFirst()
            val (data, pts) = waiting.removeFirst()
            try {
                val b = d.getInputBuffer(i) ?: continue
                b.clear()
                b.put(data)
                d.queueInputBuffer(i, 0, data.size, pts, 0)
            } catch (_: Exception) {
                resetDecoder()
                askForKey()
                return
            }
        }
    }

    private fun prepare(sets: List<ByteArray>) {
        val old = decoderSets
        if (decoder != null && old != null && old.size == sets.size && old.indices.all { old[it].contentEquals(sets[it]) }) return
        val out = surface ?: return
        decoder?.let { runCatching { it.stop() }; runCatching { it.release() } }
        decoder = null
        waiting.clear()
        freeInputs.clear()
        val mime = if (codec == RemoteVideoCodec.H264) MediaFormat.MIMETYPE_VIDEO_AVC else MediaFormat.MIMETYPE_VIDEO_HEVC
        val name = decoderName(mime) ?: return
        val f = MediaFormat.createVideoFormat(mime, maxOf(64, srcW.toInt()), maxOf(64, srcH.toInt()))
        if (mime == MediaFormat.MIMETYPE_VIDEO_AVC) {
            sets.getOrNull(0)?.let { f.setByteBuffer("csd-0", ByteBuffer.wrap(START + it)) }
            sets.getOrNull(1)?.let { f.setByteBuffer("csd-1", ByteBuffer.wrap(START + it)) }
        } else {
            f.setByteBuffer("csd-0", ByteBuffer.wrap(sets.fold(ByteArray(0)) { a, s -> a + START + s }))
        }
        if (Build.VERSION.SDK_INT >= 30 && lowLatency(name, mime)) f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        f.setInteger(MediaFormat.KEY_PRIORITY, 0)
        // what some vendors' decoders want instead: they ignore keys they don't know
        f.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
        f.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1)
        f.setInteger("vendor.low-latency.enable", 1)
        f.setInteger("vdec-lowlatency", 1)
        val d = try { MediaCodec.createByCodecName(name) } catch (_: Exception) { return }
        d.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                if (decoder !== codec) return
                freeInputs.addLast(index)
                feed(codec)
            }
            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                if (decoder !== codec) return
                runCatching { codec.releaseOutputBuffer(index, true) }
                reportFrames += 1
            }
            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                if (decoder !== codec) return
                // nothing after this can be decoded: start again from a keyframe
                resetDecoder()
                askForKey()
            }
            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {}
        }, dec)
        try {
            d.configure(f, out, null, 0)
            d.start()
        } catch (_: Exception) {
            runCatching { d.release() }
            return
        }
        decoder = d
        decoderSets = sets
    }

    // MARK: reports

    private val report = object : Runnable {
        override fun run() {
            if (!timersOn) return
            dec.post { reportRate() }
            main.postDelayed(this, 1000)
        }
    }
    private val keyWatch = object : Runnable {
        override fun run() {
            if (!timersOn) return
            // with no packets arriving (a still screen, the first keyframe lost) nothing else would ask
            dec.post { askForKey() }
            main.postDelayed(this, 1000)
        }
    }

    private fun startTimers() {
        stopTimers()
        timersOn = true
        dec.post { reportDropped = assembler.dropped; reportAt = Net.now() }
        main.postDelayed(report, 1000)
        main.postDelayed(keyWatch, 1500)
    }

    private fun stopTimers() {
        timersOn = false
        main.removeCallbacks(report)
        main.removeCallbacks(keyWatch)
    }

    /** Every second the computer hears what arrived, and Settings what it's costing. */
    private fun reportRate() {
        val now = Net.now()
        val s = maxOf(now - reportAt, 0.1)
        val lost = maxOf(0, assembler.dropped - reportDropped)
        val frames = reportFrames
        val sent = reportBytes
        val received = pictureBytes
        reportDropped = assembler.dropped
        reportFrames = 0
        reportBytes = 0
        reportAt = now
        totalBytes += sent
        val u = Use((sent * 8 / s / 1000).toInt(), Math.round(frames / s).toInt(), totalBytes, true)
        // nothing arriving, nothing to say; now and then regardless, so the computer knows the phone's still looking
        quietReports = if (sent == 0) quietReports + 1 else 0
        main.post {
            if (!on) return@post
            use.value = u
            if (quietReports == 0 || quietReports % 5 == 0) Remote.link.send(ToMac.ScreenReport(RemoteScreenReport(frames, lost, Remote.link.rtt, received)))
        }
    }

    companion object {
        private const val TARGET = "display"
        private val START = byteArrayOf(0, 0, 0, 1)

        /** NAL units with 4-byte big-endian lengths → the same units after start codes. */
        fun startCodes(d: ByteArray): ByteArray {
            val out = d.copyOf()
            var at = 0
            while (at + 4 <= out.size) {
                val n = ((out[at].toInt() and 0xFF) shl 24) or ((out[at + 1].toInt() and 0xFF) shl 16) or
                    ((out[at + 2].toInt() and 0xFF) shl 8) or (out[at + 3].toInt() and 0xFF)
                out[at] = 0; out[at + 1] = 0; out[at + 2] = 0; out[at + 3] = 1
                if (n <= 0) break
                at += 4 + n
            }
            return out
        }

        private val list by lazy { MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder } }

        private fun hardware(i: MediaCodecInfo): Boolean =
            if (Build.VERSION.SDK_INT >= 29) i.isHardwareAccelerated
            else !i.name.startsWith("OMX.google.") && !i.name.startsWith("c2.android.")

        private fun decoders(mime: String) = list.filter { i -> i.supportedTypes.any { it.equals(mime, ignoreCase = true) } }

        /** The hardware one where there is one. */
        fun decoderName(mime: String): String? = decoders(mime).sortedBy { if (hardware(it)) 0 else 1 }.firstOrNull()?.name

        private fun lowLatency(name: String, mime: String): Boolean = runCatching {
            list.first { it.name == name }.getCapabilitiesForType(mime).isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
        }.getOrDefault(false)

        /** What this phone decodes, best first: in hardware first, HEVC before H.264; in software H.264 first, which is far lighter. */
        val decodable: List<String> by lazy {
            val hevc = decoders(MediaFormat.MIMETYPE_VIDEO_HEVC)
            val avc = decoders(MediaFormat.MIMETYPE_VIDEO_AVC)
            buildList {
                if (hevc.any(::hardware)) add(RemoteVideoCodec.HEVC)
                if (avc.any(::hardware)) add(RemoteVideoCodec.H264)
                if (avc.isNotEmpty() && RemoteVideoCodec.H264 !in this) add(RemoteVideoCodec.H264)
                if (hevc.isNotEmpty() && RemoteVideoCodec.HEVC !in this) add(RemoteVideoCodec.HEVC)
            }.ifEmpty { listOf(RemoteVideoCodec.H264) }
        }
    }
}

