// The computer's screen on the phone (docs/design/remote.md §Screen; port of Pad/ScreenStream.swift): pieces to frames, frames through the
// hardware decoder, onto the stage behind the pad. Off unless asked for: while off nothing is sent, received or decoded.
//
// The phone owns the view (ViewPort): fingers move it here at once, over the picture already here, and the computer is asked for that part
// about 7 times a second. Every frame says which part it shows, and StageView draws it there in the same pass it shows it. The pointer
// isn't in the video: the phone draws it, ahead of the stream on its own strokes, and the computer has the last word after a stroke.
//
// Loss is repaired rather than started over (docs/design/remote-realtime.md): the phone offers nack and fec, and ltr on decoders known to
// take a refresh; core's RemoteVideoReceiver holds frames behind a missing piece, asks for it again, rebuilds it from parity, and waits out
// a stall. Each decoded frame goes up at once, the newest only, at the panel's top rate.
//
// Geometry here is in dp, as the pad engine's is.
package dev.blurt.remote.app.pad

import android.content.Context
import android.graphics.BitmapFactory
import android.hardware.display.DisplayManager
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.util.Log
import android.view.Display
import android.view.Surface
import dev.blurt.remote.app.BuildConfig
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.net.Net
import dev.blurt.remote.core.LinkRoute
import dev.blurt.remote.core.PadPoint
import dev.blurt.remote.core.PadSize
import dev.blurt.remote.core.RemoteCrop
import dev.blurt.remote.core.RemoteCursor
import dev.blurt.remote.core.RemoteFrameKind
import dev.blurt.remote.core.RemoteScreenReport
import dev.blurt.remote.core.RemoteScreenRequest
import dev.blurt.remote.core.RemoteVideoAssembler
import dev.blurt.remote.core.RemoteVideoCodec
import dev.blurt.remote.core.RemoteVideoFeature
import dev.blurt.remote.core.RemoteVideoPacket
import dev.blurt.remote.core.RemoteVideoPayload
import dev.blurt.remote.core.RemoteVideoReceiver
import dev.blurt.remote.core.ScreenPlan
import dev.blurt.remote.core.ToMac
import dev.blurt.remote.core.ViewPort
import kotlinx.coroutines.flow.MutableStateFlow
import java.nio.ByteBuffer
import kotlin.math.roundToInt

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
    /** the stream's codec: on `dec` */
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
    private var receiver = RemoteVideoReceiver(nack = false, ltr = false, now = Net.now())
    /** what the computer said it does for this stream (screenView.features) */
    private var repairs: Set<String> = emptySet()
    private var decoder: MediaCodec? = null
    private var decoderName: String? = null
    private var decoderSets: List<ByteArray>? = null
    private var surface: Surface? = null
    private val waiting = ArrayDeque<Pair<ByteArray, Long>>()
    private val freeInputs = ArrayDeque<Int>()
    /** the frame each timestamp carries, until it's decoded: acknowledgements, and its age */
    private val inFlight = HashMap<Long, RemoteVideoAssembler.Frame>()
    /** a decoded picture not yet released: only the newest of several ready goes up */
    private var outReady = -1
    private var reportFrames = 0
    private var reportBytes = 0
    private var reportDropped = 0
    private var pictureBytes = 0
    private var reportAt = Net.now()
    private var totalBytes = 0L
    private var nextPts = 1L
    @Volatile private var timersOn = false
    /** when the last frame went up, for letting the panel's rate go */
    @Volatile private var lastShown = 0.0

    fun attach(s: StageView, cursor: CursorView) {
        stage = s
        cursorView = cursor
        s.onSurface = { out -> dec.post { surface = out; resetDecoder() } }
        s.surface?.let { out -> dec.post { surface = out } }
        s.onShown = { crop -> main.post { if (crop != shown) { shown = crop; place() } } }
        s.onPresented = { t -> presented(t) }
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
            PadSize(maxOf(dm.widthPixels, dm.heightPixels).toDouble(), minOf(dm.widthPixels, dm.heightPixels).toDouble()), panel)
    }

    /** The display's top refresh rate: 120 on a 120 Hz panel. Asked for at home (ScreenPlan) and while frames come (StageView.wantRate). */
    private val panel: Int by lazy {
        runCatching {
            c.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY).supportedModes.maxOf { it.refreshRate }.roundToInt()
        }.getOrDefault(60)
    }

    /** What this phone offers to have repaired: nack and fec always, ltr only where the decoder is known to take a refresh. */
    private val features: List<String>? get() {
        if (BuildConfig.DEBUG && !TestWeather.repairs) return null
        val mime = if (decodable.first() == RemoteVideoCodec.H264) MediaFormat.MIMETYPE_VIDEO_AVC else MediaFormat.MIMETYPE_VIDEO_HEVC
        val ltr = decoderName(mime)?.let(::takesRefresh) == true
        return listOfNotNull(RemoteVideoFeature.NACK, RemoteVideoFeature.LTR.takeIf { ltr }, RemoteVideoFeature.FEC)
    }

    private fun same(a: ScreenPlan?, b: ScreenPlan) = a != null && a.width == b.width && a.height == b.height && a.bitrate == b.bitrate && a.fps == b.fps

    /** The most the computer may send, for this path and what the user chose. Under that it follows what the network carries. */
    fun start() {
        val p = plan
        planned = p
        val crop = port.crop
        sentCrop = crop
        idle = false
        val r = RemoteScreenRequest(TARGET, crop, p.width, p.height, p.bitrate, p.fps, decodable, features = features)
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
        stage?.wantRate(0f)
        stage?.clear()
        resetView()
        cursorView?.hide()
    }

    // MARK: the view and the pointer

    /** What the computer is showing, in which codec, and which repairs it does. Another codec than the frames so far: start from a keyframe. */
    fun source(w: Double, h: Double, codec: String?, features: List<String>? = null) {
        dec.post {
            val c = codec ?: RemoteVideoCodec.HEVC
            if (c != this.codec) {
                this.codec = c
                resetDecoder()
            }
            repairs = features.orEmpty().toSet()
            receiver.nack = RemoteVideoFeature.NACK in repairs
            receiver.ltr = RemoteVideoFeature.LTR in repairs
        }
        main.post {
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
            if (BuildConfig.DEBUG && !TestWeather.current.calm) {
                val passed = TestWeather.current.passes(Net.now()) { wait -> dec.postDelayed({ arrived(p, d.size) }, (wait * 1000).toLong()) }
                if (!passed) return@post
            }
            arrived(p, d.size)
        }
    }

    private fun arrived(p: RemoteVideoPacket, size: Int) {
        if (!on) return
        reportBytes += size
        pictureBytes += p.payload.size
        test?.let { it.bytes += size }
        handle(receiver.add(p, Net.now()))
    }

    /** What the receiver wants done: frames decoded, the computer told what's missing or what was decoded, a keyframe asked for. */
    private fun handle(out: List<RemoteVideoReceiver.Output>) {
        for (o in out) when (o) {
            is RemoteVideoReceiver.Output.Frame -> decode(o.frame)
            // straight to the channel's thread: a resend asked for late is a frame shown late
            is RemoteVideoReceiver.Output.Feedback -> Remote.link.datagram(RemoteFrameKind.VIDEO_FEEDBACK, o.feedback.encoded())
            RemoteVideoReceiver.Output.Keyframe -> {
                test?.let { it.keyRequests += 1 }
                main.post { if (on) Remote.link.send(ToMac.RequestKeyframe) }
            }
        }
    }

    fun probeBack(d: ByteArray) {}

    private fun resetDecoder() {
        receiver = RemoteVideoReceiver(receiver.nack, receiver.ltr, Net.now()).also { it.rtt = Remote.link.rtt ?: 0.01 }
        reportDropped = 0
        waiting.clear()
        freeInputs.clear()
        inFlight.clear()
        outReady = -1
        decoder?.let { d -> runCatching { d.stop() }; runCatching { d.release() } }
        decoder = null
        decoderSets = null
    }

    /** The decoder can't go on: its references are gone, and only a keyframe helps. */
    private fun failed() {
        decoder?.let { d -> runCatching { d.stop() }; runCatching { d.release() } }
        decoder = null
        decoderSets = null
        waiting.clear()
        freeInputs.clear()
        inFlight.clear()
        outReady = -1
        receiver.decoderFailed(Net.now())
    }

    private fun decode(f: RemoteVideoAssembler.Frame) {
        val u = RemoteVideoPayload.unpack(f.data) ?: return
        if (u.parameterSets.isNotEmpty()) prepare(u.parameterSets)
        val d = decoder ?: return
        val pts = nextPts++
        stage?.crops?.put(pts, u.crop)
        inFlight[pts] = f
        if (inFlight.size > 64) inFlight.keys.min().let { inFlight.remove(it) }
        // the picture's 4-byte lengths become start codes, which is what Android's decoders want
        val annexB = startCodes(u.picture)
        if (waiting.size > 60) {
            // the decoder has fallen a second behind: what's queued is worth nothing, and what follows needs a keyframe. Not sooner: frames
            // held behind a piece sent again are let go together, and each is a reference for the next
            failed()
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
                failed()
                return
            }
        }
    }

    /** Decoded: up it goes, unless a newer one is already waiting behind it in the queue (then only that one does). */
    private fun output(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
        if (outReady >= 0) runCatching { codec.releaseOutputBuffer(outReady, false) }
        outReady = index
        val now = Net.now()
        inFlight.remove(info.presentationTimeUs)?.let { f ->
            handle(receiver.decoded(f, now))
            test?.decoded(f, now, offset)
        }
        reportFrames += 1
        // after every callback already queued has run: the newest of them is released, the rest were dropped above
        dec.post {
            if (outReady == index && decoder === codec) {
                outReady = -1
                runCatching { codec.releaseOutputBuffer(index, true) }
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
        outReady = -1
        val mime = if (codec == RemoteVideoCodec.H264) MediaFormat.MIMETYPE_VIDEO_AVC else MediaFormat.MIMETYPE_VIDEO_HEVC
        val name = decoderName(mime) ?: return
        val f = MediaFormat.createVideoFormat(mime, maxOf(64, srcW.toInt()), maxOf(64, srcH.toInt()))
        if (mime == MediaFormat.MIMETYPE_VIDEO_AVC) {
            sets.getOrNull(0)?.let { f.setByteBuffer("csd-0", ByteBuffer.wrap(START + it)) }
            sets.getOrNull(1)?.let { f.setByteBuffer("csd-1", ByteBuffer.wrap(START + it)) }
        } else {
            f.setByteBuffer("csd-0", ByteBuffer.wrap(sets.fold(ByteArray(0)) { a, s -> a + START + s }))
        }
        lowLatency(f, name, mime)
        val d = try { MediaCodec.createByCodecName(name) } catch (_: Exception) { return }
        d.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                if (decoder !== codec) return
                freeInputs.addLast(index)
                feed(codec)
            }
            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                if (decoder !== codec) return
                output(codec, index, info)
            }
            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                if (decoder !== codec) return
                // nothing after this can be decoded: start again from a keyframe
                failed()
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
        decoderName = name
        decoderSets = sets
    }

    /** A frame went up on the stage (GL thread). The panel is asked for its top rate while they come. */
    private fun presented(nanos: Long) {
        val first = Net.now() - lastShown > 1
        lastShown = Net.now()
        if (first) main.post { stage?.wantRate(panel.toFloat()) }
        test?.let { t -> dec.post { t.shown(nanos) } }
    }

    // MARK: reports

    private val report = object : Runnable {
        override fun run() {
            if (!timersOn) return
            dec.post { reportRate() }
            main.postDelayed(this, 1000)
        }
    }
    /** Every 4 ms: pieces asked for again, frames given up, a keyframe asked for when nothing arrives (a still screen, the first one lost). */
    private val tick = object : Runnable {
        override fun run() {
            if (!timersOn) return
            if (on) handle(receiver.tick(Net.now()))
            dec.postDelayed(this, 4)
        }
    }
    /** A second without a frame: the panel goes back to whatever the system likes. */
    private val rateWatch = object : Runnable {
        override fun run() {
            if (!timersOn) return
            if (lastShown > 0 && Net.now() - lastShown > 1) stage?.wantRate(0f)
            main.postDelayed(this, 500)
        }
    }

    private fun startTimers() {
        stopTimers()
        timersOn = true
        dec.post { reportDropped = receiver.dropped; reportAt = Net.now() }
        main.postDelayed(report, 1000)
        main.postDelayed(rateWatch, 500)
        dec.post(tick)
    }

    private fun stopTimers() {
        timersOn = false
        main.removeCallbacks(report)
        main.removeCallbacks(rateWatch)
        dec.removeCallbacks(tick)
    }

    /** Every second the computer hears what arrived, and Settings what it's costing. */
    private fun reportRate() {
        val now = Net.now()
        val s = maxOf(now - reportAt, 0.1)
        val lost = maxOf(0, receiver.dropped - reportDropped)
        val frames = reportFrames
        val sent = reportBytes
        val received = pictureBytes
        reportDropped = receiver.dropped
        Remote.link.rtt?.let { receiver.rtt = it }
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

    // MARK: measured runs (debug builds; TestWeather says how to start one)

    /** the run being measured, on `dec` */
    @Volatile private var test: Measure? = null

    /** What a stage of a measured run saw: frames decoded and shown, the gaps between pictures, what was repaired. */
    private inner class Measure {
        val start = Net.now()
        val startNanos = System.nanoTime()
        var bytes = 0L
        var keyRequests = 0
        var decoded = 0
        val shownAt = ArrayList<Long>()
        val ages = ArrayList<Double>()
        val nacked0 = receiver.nacked
        val repaired0 = receiver.repaired
        val refreshes0 = receiver.refreshes
        val dropped0 = receiver.dropped
        val weather0 = TestWeather.current.dropped

        fun decoded(f: RemoteVideoAssembler.Frame, now: Double, offset: Double?) {
            decoded += 1
            if (offset != null && ages.size < 20_000) ages += (now + offset - f.captured) * 1000
        }

        fun shown(nanos: Long) { if (nanos >= startNanos && shownAt.size < 20_000) shownAt += nanos }

        fun report(stage: String): String {
            val t = Net.now() - start
            val gaps = shownAt.zipWithNext { a, b -> (b - a) / 1e6 }.sorted()
            fun pct(a: List<Double>, p: Double) = if (a.isEmpty()) -1.0 else Math.round(a[minOf(a.size - 1, (a.size * p).toInt())] * 10) / 10.0
            val sortedAges = ages.sorted()
            val frozen = gaps.filter { it > 40 }.sumOf { it - 1000.0 / panel }
            val r = receiver
            return "{\"stage\":\"$stage\",\"seconds\":${Math.round(t * 10) / 10.0},\"shown_fps\":${Math.round(shownAt.size / t * 10) / 10.0}," +
                "\"decoded_fps\":${Math.round(decoded / t * 10) / 10.0},\"gap_p50\":${pct(gaps, 0.5)},\"gap_p99\":${pct(gaps, 0.99)}," +
                "\"gap_max\":${pct(gaps, 1.0)},\"frozen_ms_per_s\":${Math.round(frozen / maxOf(t, 1.0) * 10) / 10.0}," +
                "\"age_p50\":${pct(sortedAges, 0.5)},\"age_p95\":${pct(sortedAges, 0.95)},\"age_max\":${pct(sortedAges, 1.0)}," +
                "\"dropped\":${r.dropped - dropped0},\"key_requests\":$keyRequests,\"nacked\":${r.nacked - nacked0}," +
                "\"fec_repaired\":${r.repaired - repaired0},\"refreshes\":${r.refreshes - refreshes0}," +
                "\"weather_dropped\":${TestWeather.current.dropped - weather0},\"mbps\":${Math.round(bytes * 8 / t / 1e5) / 10.0}," +
                "\"repairs\":\"${repairs.sorted().joinToString(",")}\",\"decoder\":\"$decoderName\",\"panel\":$panel," +
                "\"rtt_ms\":${Remote.link.rtt?.let { Math.round(it * 10000) / 10.0 }}}"
        }
    }

    /** A measured run: wait for the picture to settle, then measure `seconds` and say what was seen. */
    fun measure(seconds: Int, stage: String) {
        dec.postDelayed({
            if (!on) return@postDelayed
            val m = Measure()
            test = m
            dec.postDelayed({
                if (test !== m) return@postDelayed
                test = null
                val r = m.report(stage)
                Log.i("BlurtScreenTest", r)
                main.post { Remote.link.send(ToMac.ScreenStats(r)) }
            }, seconds * 1000L)
        }, 3000)
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

        private fun hasLowLatency(name: String, mime: String): Boolean = runCatching {
            list.first { it.name == name }.getCapabilitiesForType(mime).isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
        }.getOrDefault(false)

        /** Each picture out as soon as it's decoded, not held for reordering or pacing: KEY_LOW_LATENCY where the decoder lists the
         *  feature, and the vendors' own keys as Moonlight sets them (a decoder ignores keys it doesn't know). */
        fun lowLatency(f: MediaFormat, name: String, mime: String) {
            if (Build.VERSION.SDK_INT >= 30 && hasLowLatency(name, mime)) f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            f.setInteger(MediaFormat.KEY_PRIORITY, 0)
            f.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            f.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
            f.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1)
            f.setInteger("vendor.low-latency.enable", 1)
            f.setInteger("vdec-lowlatency", 1)
        }

        /**
         * Decoders known to take a refresh: a P-frame from an acknowledged picture after frames that never came (remote-realtime.md §Phone 3).
         * Moonlight's experience: reference invalidation hangs Amlogic HEVC and misbehaves on some low-end Snapdragons, so this is an
         * allow-list. Snapdragon 8 Gen 1 and later (SM8450+), Google Tensor, MediaTek Dimensity 9000 and later (MT6983+), by Moonlight's
         * and the spec's judgement, not tested here. Android's own software decoders and the emulator's: RefreshDecodeTest on Android 16
         * (2026-11-09, all six, HEVC and H.264: 54 dB after the refresh against 6–8 dB without one), so from that version on.
         * Everything else gets nack and fec, and keyframes after a loss.
         */
        fun takesRefresh(name: String): Boolean {
            val n = name.lowercase()
            if (REFRESH_TESTED.any { n.startsWith(it) }) return Build.VERSION.SDK_INT >= 36
            if (Build.VERSION.SDK_INT < 31) return false
            val soc = Build.SOC_MODEL.uppercase()
            val maker = Build.SOC_MANUFACTURER.lowercase()
            fun model(prefix: String, from: Int) = soc.startsWith(prefix) && (soc.drop(prefix.length).takeWhile { it.isDigit() }.toIntOrNull() ?: 0) >= from
            return when {
                n.startsWith("c2.qti.") || n.startsWith("omx.qcom.") -> model("SM", 8450) && soc.startsWith("SM8")
                n.startsWith("c2.exynos.") || n.startsWith("c2.google.") -> maker == "google"
                n.startsWith("c2.mtk.") || n.startsWith("omx.mtk.") -> model("MT", 6983) && soc.startsWith("MT69")
                else -> false
            }
        }

        /** the platform's own decoders that RefreshDecodeTest showed decode a refresh cleanly (prefixes) */
        private val REFRESH_TESTED = listOf("c2.android.", "c2.goldfish.", "omx.google.")

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

