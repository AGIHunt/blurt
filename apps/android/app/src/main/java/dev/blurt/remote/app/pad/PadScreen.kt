// The one screen (port of Pad/PadViewController.swift). Plain Views laid out by hand from PadLayout, for exact geometry and touches that never
// wait for anything; the sheets around it are Compose. Nothing here is a fragment or a second activity: opening a sheet mustn't end the session.
package dev.blurt.remote.app.pad

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.lifecycle.LifecycleCoroutineScope
import dev.blurt.remote.app.Fonts
import dev.blurt.remote.app.HardwareKeys
import dev.blurt.remote.app.Haptics
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.Theme
import dev.blurt.remote.app.dp
import dev.blurt.remote.app.keys.DeckText
import dev.blurt.remote.app.keys.KeyCell
import dev.blurt.remote.app.keys.KeyList
import dev.blurt.remote.app.keys.PageStrip
import dev.blurt.remote.app.keys.TypeField
import dev.blurt.remote.app.net.Link
import dev.blurt.remote.app.px2dp
import dev.blurt.remote.app.talk.TalkBar
import dev.blurt.remote.core.Deck
import dev.blurt.remote.core.KeyAction
import dev.blurt.remote.core.KeySlot
import dev.blurt.remote.core.LinkPhase
import dev.blurt.remote.core.LinkPath
import dev.blurt.remote.core.LinkStatus
import dev.blurt.remote.core.PadHaptic
import dev.blurt.remote.core.RemoteBlurtCommand
import dev.blurt.remote.core.RemoteChord
import dev.blurt.remote.core.RemoteDictationPhase
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.core.RemoteModifiers
import dev.blurt.remote.core.RemotePointerCurve
import dev.blurt.remote.core.RemoteSystemMove
import dev.blurt.remote.core.StatusAction
import dev.blurt.remote.core.StatusBanner
import dev.blurt.remote.core.StatusCue
import dev.blurt.remote.core.StatusFollower
import dev.blurt.remote.core.StatusLine
import dev.blurt.remote.core.ToMac
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

@SuppressLint("ViewConstructor")
class PadScreen(c: Context, private val sheets: Sheets) : ViewGroup(c) {
    /** what the screen asks of the activity */
    interface Sheets {
        fun settings()
        fun pairing()
        fun editor()
        fun switchMac()
        fun askMic()
        fun keepAwake(on: Boolean)
        fun displays()
    }

    private val main = Handler(Looper.getMainLooper())
    val pad = TrackpadView(c)
    /** a big screen's second trackpad, beside the keys */
    private val pad2 = TrackpadView(c).apply { isStage = false }
    val stage = StageView(c)
    private val cursor = CursorView(c)
    val talk = TalkBar(c)
    private val list = KeyList(c)
    private val dockCells = List(Deck.DOCK_COUNT) { KeyCell(c) }
    private val arrowCell = KeyCell(c)
    /** landscape: with the keys away there's still a picture to leave */
    private val appsCell = KeyCell(c)
    private val allCells get() = dockCells + listOf(arrowCell, appsCell) + list.cells
    private val strip = PageStrip(c)
    private val chips = listOf(
        Chip(c, c.getString(R.string.chip_cancel)) { Remote.link.send(ToMac.Blurt(RemoteBlurtCommand.DICTATION_CANCEL)) },
        Chip(c, c.getString(R.string.chip_structured)) { Remote.link.send(ToMac.Blurt(RemoteBlurtCommand.DICTATION_STRUCTURED)) },
        Chip(c, c.getString(R.string.chip_translate)) { Remote.link.send(ToMac.Blurt(RemoteBlurtCommand.DICTATION_TRANSLATE)) },
    )
    private val keyboardButton = IconButton(c, "keyboard", c.getString(R.string.keyboard))
    private val settingsButton = IconButton(c, "tune", c.getString(R.string.settings))
    private val screenButton = IconButton(c, "desktop_windows", c.getString(R.string.show_screen))
    private val findButton = IconButton(c, "my_location", c.getString(R.string.find_pointer))
    private val drawerButton = IconButton(c, "apps", c.getString(R.string.keys))
    private val displayButton = DisplayButton(c)
    private val header = TextView(c)
    private val liveText = TextView(c)
    /** what the pad says when the connection isn't simply there (StatusCard.kt) */
    private val card = StatusCard(c, onAction = { cardAction(second = false) }, onSecond = { cardAction(second = true) })
    private var shownBanner: StatusBanner? = null
    private var follower = StatusFollower()
    /** the app is in front (MainActivity says): left and come back to, the connection starts again, and that's not a drop to tell the thumb */
    var inFront = false
        set(v) { field = v; if (!v) follower = StatusFollower() }
    private val edgeMark = View(c)
    private val edgeLook = android.graphics.drawable.GradientDrawable().apply { cornerRadius = 1.5f.dp }
    /** one finger is scrolling along the edge: its mark stays lit over the picture */
    private var edgeScrolling = false
    /** the first time the picture showed: a line on what two fingers do there, then gone */
    private val tip = TextView(c)
    /** full screen: the one way back to the keys, in the top corner away from the talk key */
    private val exitFull = Chip(c, c.getString(R.string.exit_full_screen), Theme.mark) { Remote.prefs.fullScreen = false }
    /** the picture fills the screen, last time it was laid out */
    private var full = false
    private val dim = View(c)
    val field = TypeField(c)
    private val modRow = ModifierRow(c) { field.hide() }

    /** landscape: the keys are out. Out for the trackpad, put away when there's a picture to see */
    private var drawerOpen = true
    /** the computer's screen shows on the stage */
    private var showing = false
    private var host = Remote.link.host.value
    private var deck = loadDeck(host)
    private var cycleKey: KeyCell? = null
    private var layout: PadLayout? = null
    var fold: PadLayout.Fold? = null
        set(v) { if (field != v) { field = v; requestLayout() } }
    var imeHeight = 0
        set(v) { if (field != v) { field = v; requestLayout() } }
    var safe = Rect()
        set(v) { if (field != v) { field = v; requestLayout() } }

    init {
        setBackgroundColor(Color.BLACK)
        isMotionEventSplittingEnabled = true
        clipChildren = false
        pad.addView(stage, 0)
        for (v in listOf(header, liveText, tip, edgeMark, cursor, card)) pad.addView(v)
        Remote.screen.attach(stage, cursor)
        addView(pad)
        addView(pad2)
        header.apply { textSize = 12f; setTextColor(Theme.faint); typeface = Fonts.medium; isSingleLine = true }
        liveText.apply {
            textSize = 15f
            setTextColor(Theme.mark)
            maxLines = 3
            background = android.graphics.drawable.GradientDrawable().apply { setColor(Color.argb(184, 0, 0, 0)); cornerRadius = 12.dp }
            setPadding(10.dp.toInt(), 6.dp.toInt(), 10.dp.toInt(), 6.dp.toInt())
            visibility = GONE
        }
        tip.apply {
            textSize = 14f
            setTextColor(Theme.mark)
            gravity = android.view.Gravity.CENTER
            background = android.graphics.drawable.GradientDrawable().apply { setColor(Color.argb(184, 0, 0, 0)); cornerRadius = 12.dp }
            setPadding(12.dp.toInt(), 7.dp.toInt(), 12.dp.toInt(), 7.dp.toInt())
            visibility = GONE
        }
        edgeLook()
        edgeMark.background = edgeLook
        for (p in listOf(pad, pad2)) {
            p.onHaptic = { h -> when (h) { PadHaptic.TAP -> Haptics.tick(); PadHaptic.GRAB -> Haptics.grab(); PadHaptic.RELEASE -> Haptics.release(); PadHaptic.STEP -> Haptics.step() } }
            p.onClick = { Remote.sticky.used() }
            p.onViewEnd = { applyPrefs() }
        }
        pad.onEdgeScroll = { on -> edgeScroll(on) }
        // ⌘ held (Ctrl on a PC), on the dock or a keyboard: a pinch over the picture zooms the computer, as it does with the picture off
        pad.engine.computerZoomHeld = { ((Remote.sticky.held or HardwareKeys.held) and zoomModifier(host)) != 0 }

        addView(list)
        list.onCycle = { on, k -> cycling(on, k) }
        list.onEdit = { sheets.editor() }
        list.onSection = { strip.select(it) }
        for (k in dockCells) { addView(k); k.onCycle = { on -> cycling(on, k) } }
        arrowCell.slot = KeySlot(KeyAction.Arrows, hint = "Arrows")
        addView(arrowCell)
        appsCell.onCycle = { on -> cycling(on, appsCell) }
        addView(appsCell)
        addView(talk)
        talk.onAsk = { sheets.askMic() }
        addView(exitFull)
        exitFull.visibility = GONE
        for (b in listOf(drawerButton, screenButton, keyboardButton, settingsButton, findButton)) addView(b)
        addView(displayButton)
        displayButton.onTap = { Remote.link.nextDisplay() }
        displayButton.onHold = { sheets.displays() }
        drawerButton.onTap = { toggleDrawer() }
        screenButton.onTap = { toggleScreen() }
        // the map with one display too: it holds Full Screen
        screenButton.onHold = { sheets.displays() }
        keyboardButton.onTap = { toggleKeyboard() }
        settingsButton.onTap = { sheets.settings() }
        settingsButton.onHold = { if (Remote.link.macs.value.size > 1) sheets.switchMac() }
        findButton.onTap = { Haptics.tick(); Remote.link.send(ToMac.System(RemoteSystemMove.FIND_CURSOR)) }
        strip.onSelect = { go(it) }
        addView(strip)
        chips.forEach { it.visibility = GONE; addView(it) }
        addView(field)
        field.onSent = { touched() }
        addView(modRow)
        modRow.visibility = GONE
        dim.setBackgroundColor(Color.BLACK)
        dim.alpha = 0f
        dim.isClickable = false
        addView(dim)
        Remote.sticky.listeners += { allCells.forEach { it.invalidate() }; modRow.refresh() }
        applyPrefs()
        showDeck()
        touched()
    }

    /** Brought up to date if it was stored as an older version shipped, and kept that way. */
    private fun loadDeck(h: RemoteHost): Deck {
        val stored = Remote.prefs.string(Deck.storeKey(h))
        val d = Deck.restore(stored, h)
        if (stored != null && Deck.fromJson(stored) != d) Remote.prefs.putString(Deck.storeKey(h), d.toJson())
        return d
    }

    fun setDeck(d: Deck) {
        deck = d
        Remote.prefs.putString(Deck.storeKey(host), d.toJson())
        showDeck()
        requestLayout()
    }

    val currentDeck: Deck get() = deck

    // MARK: watching

    fun bind(scope: LifecycleCoroutineScope) {
        val l = Remote.link
        scope.launch { combine(l.state, l.current, l.canControl) { _, _, _ -> }.collect { status() } }
        scope.launch { combine(l.waitingForMac, l.pairFailed, l.route, l.screenError) { _, _, _, e -> e }.collect { e -> if (e != null) setShowing(false); status() } }
        scope.launch { combine(l.path, l.away) { _, _ -> }.collect { status() } }
        // the picture was of the computer just left
        var last: String? = l.current.value?.deviceID
        scope.launch { l.current.collect { m -> if (m?.deviceID != last) { last = m?.deviceID; setShowing(false) } } }
        scope.launch {
            l.host.collect { h ->
                if (h != host) {
                    // another kind of computer: its own keys and modifiers' names
                    host = h
                    Remote.sticky.clear()
                    deck = loadDeck(h)
                    showDeck()
                    modRow.rebuild()
                    requestLayout()
                }
            }
        }
        scope.launch {
            l.dictation.collect { p ->
                talk.show(p)
                chips.forEach { it.visibility = if (p == RemoteDictationPhase.LISTENING) VISIBLE else GONE }
                status()
                requestLayout()
            }
        }
        // a measured run (debug builds, TestWeather): once connected, the picture on, measured, and a report in the log
        if (dev.blurt.remote.app.BuildConfig.DEBUG) scope.launch {
            l.state.collect { st ->
                val seconds = TestWeather.screenTest
                if (st != Link.State.CONNECTED || seconds <= 0) return@collect
                TestWeather.screenTest = 0
                setShowing(true)
                Remote.screen.measure(seconds, "run")
            }
        }
        scope.launch { l.live.collect { (f, p) -> words(f, p) } }
        scope.launch { l.level.collect { talk.level(it) } }
        scope.launch { Remote.prefs.changed.collect { applyPrefs() } }
        scope.launch { l.displayAspect.collect { requestLayout() } }
        scope.launch {
            combine(l.displays, l.shownDisplay) { _, shown -> shown }.collect { shown ->
                displayButton.number = l.displaysInOrder.indexOfFirst { it.id == shown } + 1
                requestLayout()
            }
        }
    }

    private fun words(f: String, p: String) {
        // the newest words: three lines' worth from the end
        val room = max(40, (min(pad.width.toFloat().px2dp - 32, 420f) / 14.5f).toInt() * 3 - 2)
        val cut = max(0, f.length + p.length - room)
        val t = SpannableStringBuilder()
        if (cut > 0) t.append("…", ForegroundColorSpan(Theme.caption), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        t.append(f.drop(cut), ForegroundColorSpan(Theme.mark), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        t.append(p.drop(max(0, cut - f.length)), ForegroundColorSpan(Theme.caption), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        liveText.text = t
        liveText.visibility = if (t.isEmpty()) GONE else VISIBLE
        requestLayout()
        touched()
    }

    private fun applyPrefs() {
        val p = Remote.prefs
        Haptics.on = p.haptics
        // closer in, the same stroke crosses less of the computer's screen
        val zoom = Remote.screen.port.zoom
        pad.engine.curve = RemotePointerCurve().scaled(p.pointerSpeed / max(1f, sqrt(zoom.toFloat())))
        pad2.engine.curve = RemotePointerCurve().scaled(p.pointerSpeed)
        pad.engine.scrollGain = 2.4 * p.scrollSpeed
        pad2.engine.scrollGain = 2.4 * p.scrollSpeed
        pad.engine.touchMode = showing && p.tapWhereTouched
        requestLayout()
    }

    /**
     * What the pad says, in the few states where it should say anything: which words for which state is core's LinkStatus, the same on
     * the iPhone. Connected and working it's the computer's name, small, in the corner; anything else is the card in the middle.
     */
    private fun status() {
        val l = Remote.link
        val c = context
        val name = l.current.value?.title ?: ""
        val phase = when (l.state.value) {
            Link.State.UNPAIRED -> LinkPhase.UNPAIRED
            Link.State.CONNECTING -> LinkPhase.CONNECTING
            Link.State.UNREACHABLE -> LinkPhase.UNREACHABLE
            Link.State.CONNECTED -> LinkPhase.CONNECTED
            Link.State.FORGOTTEN -> LinkPhase.FORGOTTEN
            Link.State.REPLACED -> LinkPhase.REPLACED
            Link.State.ENDED -> LinkPhase.ENDED
        }
        val cue = follower.see(phase, l.current.value?.id, inFront)
        val banner = StatusBanner.of(LinkStatus(phase, dropped = follower.dropped, hasRelay = l.current.value?.relayAddress != null,
            otherComputers = l.macs.value.size > 1, canControl = l.canControl.value, screenError = l.screenError.value,
            waiting = l.waitingForMac.value, pairFailed = l.pairFailed.value != null,
            pairRetry = l.pairFailed.value?.why?.canRetry == true, away = l.away.value))
        shownBanner = banner
        fun say(line: StatusLine) = StatusCard.text(c, line, host, name, l.pairCheck, l.pairFailed.value)
        card.show(banner?.mark, banner?.let { b ->
            StatusCard.Words(say(b.title), b.detail?.let(::say), b.action?.let { StatusCard.text(c, it) }, b.second?.let { StatusCard.text(c, it) })
        })
        // the thumb and TalkBack hear of it too: the connection went, or it's back (the card is a live region: TalkBack reads what it says)
        when (cue) {
            StatusCue.DROPPED -> Haptics.release()
            StatusCue.BACK -> {
                Haptics.grab()
                @Suppress("DEPRECATION")
                announceForAccessibility(c.getString(R.string.connected_to, name.ifEmpty { c.getString(R.string.the_computer) }))
            }
            null -> {}
        }
        // away, the label names the way: Tailscale, an overlay, direct, the owner's relay or the go-between; at home just the name
        val via = if (l.path.value == LinkPath.SAME_NETWORK) name else c.getString(R.string.via_path, name, pathName(c, l.path.value))
        header.text = if (l.state.value == Link.State.CONNECTED && !showing) via else null
        val ready = l.state.value == Link.State.CONNECTED
        talk.alpha = if (ready) 1f else 0.35f
        if (cycleKey == null) allCells.forEach { it.alpha = if (ready) 1f else 0.35f }
        requestLayout()
    }

    private fun cardAction(second: Boolean) {
        val a = (if (second) shownBanner?.second else shownBanner?.action) ?: return
        Haptics.tick()
        when (a) {
            StatusAction.RETRY -> Remote.link.tryAgain()
            StatusAction.SCAN -> sheets.pairing()
            StatusAction.ANOTHER -> sheets.switchMac()
        }
    }

    // MARK: the computer's screen

    private fun toggleScreen() {
        Haptics.tick()
        Remote.link.screenError.value = null
        setShowing(!showing)
    }

    private fun setShowing(on: Boolean) {
        if (on == showing) return
        showing = on
        drawerOpen = !on
        keysPutAway()
        pad.engine.pinchZoomsView = on
        pad.showing = on
        sheets.keepAwake(true)
        Remote.screen.resetView()
        applyPrefs()
        if (on) Remote.screen.start() else Remote.screen.stop()
        edgeLook()
        // over the picture the edge's mark hides, after showing where it is each time the picture comes
        main.removeCallbacks(edgeFade)
        edgeMark.animate().cancel()
        edgeMark.alpha = 1f
        if (on) main.postDelayed(edgeFade, 1500)
        if (on && !Remote.prefs.pictureHintShown) showTip()
        if (!on) hideTip()
        status()
        requestLayout()
    }

    private val edgeFade = Runnable { if (showing && !edgeScrolling) edgeMark.animate().alpha(0f).setDuration(300).start() }

    private fun edgeScroll(on: Boolean) {
        edgeScrolling = on
        if (!showing) return
        main.removeCallbacks(edgeFade)
        if (on) {
            edgeMark.animate().cancel()
            edgeMark.alpha = 1f
        } else {
            edgeFade.run()
        }
    }

    /** the mark: a hairline on the glass; over the picture, white with a dark edge, so it reads on any picture */
    private fun edgeLook() {
        edgeLook.setColor(if (showing) Color.argb(204, 255, 255, 255) else Theme.hairline)
        edgeLook.setStroke(if (showing) max(1, 0.5f.dp.toInt()) else 0, Color.argb(110, 0, 0, 0))
    }

    private val tipFade = Runnable { tip.animate().alpha(0f).setDuration(300).withEndAction { tip.visibility = GONE }.start() }

    private fun showTip() {
        Remote.prefs.pictureHintShown = true
        val mod = RemoteModifiers.label(zoomModifier(host), host)
        tip.text = context.getString(if (host == RemoteHost.MAC) R.string.picture_hint_mac else R.string.picture_hint_pc, mod)
        tip.animate().cancel()
        tip.alpha = 1f
        tip.visibility = VISIBLE
        main.removeCallbacks(tipFade)
        main.postDelayed(tipFade, 4000)
        requestLayout()
    }

    private fun hideTip() {
        main.removeCallbacks(tipFade)
        tip.animate().cancel()
        tip.visibility = GONE
    }

    private fun toggleDrawer() {
        Haptics.tick()
        drawerOpen = !drawerOpen
        keysPutAway()
        requestLayout()
    }

    /** Landscape, the keys put away: the modifiers went with them, so none stays held on the computer out of sight. */
    private fun keysPutAway() {
        if (drawerOpen || layout?.landscape != true || Remote.sticky.held == 0) return
        Remote.sticky.release(Remote.sticky.held)
    }

    // MARK: keys

    private fun showDeck() {
        list.host = host
        list.show(deck.sections)
        strip.show(deck.sections.map { DeckText.tr(it.name) }, list.section)
        for ((i, k) in dockCells.withIndex()) { k.host = host; k.slot = deck.dock.getOrNull(i) }
        arrowCell.host = host
        appsCell.host = host
        // ⌘Tab on a Mac, Alt+Tab elsewhere: the first cycle key of the deck's switching row, else the platform's own
        val cyc = deck.sections.firstOrNull()?.slots?.firstOrNull { (it.action as? KeyAction.Chord)?.cycle == true }
        appsCell.slot = cyc?.copy(caption = "") ?: KeySlot(KeyAction.Chord(RemoteChord(if (host == RemoteHost.MAC) RemoteModifiers.COMMAND else RemoteModifiers.OPTION, "Tab"), true), glyph = "mark:apps", caption = "", hint = "Apps")
        status()
    }

    private fun go(n: Int) {
        list.scrollToSection(n)
        strip.select(n)
        Haptics.step()
    }

    /** A slide across the keys while a cycle key is held: the rest are out of play, and look it. */
    private fun cycling(on: Boolean, k: KeyCell) {
        cycleKey = if (on) k else null
        val rest = if (on) 0.3f else if (Remote.link.state.value == Link.State.CONNECTED) 1f else 0.35f
        for (x in allCells) if (x !== k) { x.isEnabled = !on; x.alpha = rest }
    }

    // MARK: touches, dimming

    override fun dispatchTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_DOWN) touched()
        return super.dispatchTouchEvent(e)
    }

    private val dimmer = Runnable {
        // never while typing or talking
        if (field.open || Remote.link.dictation.value != RemoteDictationPhase.IDLE) touched()
        else dim.animate().alpha(0.6f).setDuration(600).start()
    }
    private val pacer = Runnable {
        if (field.open || Remote.link.dictation.value != RemoteDictationPhase.IDLE) watchIdle() else Remote.screen.setIdle(true)
    }

    /** The screen dims when nothing happens and comes back with any touch, which still does its job. */
    fun touched() {
        Remote.link.touched()
        Remote.screen.setIdle(false)
        watchIdle()
        if (dim.alpha > 0) dim.animate().alpha(0f).setDuration(150).start()
        main.removeCallbacks(dimmer)
        main.postDelayed(dimmer, IDLE_DIM)
    }

    /** Nobody's touching it: away from home, the picture slows down until someone does. */
    private fun watchIdle() {
        main.removeCallbacks(pacer)
        main.postDelayed(pacer, IDLE_PACE)
    }

    /** The app is leaving the screen: nothing stays pressed. */
    fun letGo() {
        pad.letGo()
        pad2.letGo()
        talk.letGo()
        allCells.forEach { it.letGo() }
        Remote.sticky.clear()
        HardwareKeys.forget()
    }

    /** turned, folded or resized: whatever was mid-gesture ends, the session and the view stay */
    fun reshaped() {
        drawerOpen = !showing
        pad.letGo()
        pad2.letGo()
    }

    // MARK: keyboard

    private fun toggleKeyboard() {
        Haptics.tick()
        if (field.open) field.hide() else field.show()
    }

    // MARK: layout

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), MeasureSpec.getSize(heightMeasureSpec))
    }

    /** Where a view goes. Never whether it shows (`show` decides that): a view hidden here and shown there would ask for another layout
     *  on every pass. */
    private fun place(v: View, r: Frame?) {
        if (r == null || r.isEmpty) { v.layout(0, 0, 0, 0); return }
        val d = resources.displayMetrics.density
        val l = (r.left * d).toInt()
        val t = (r.top * d).toInt()
        val rr = (r.right * d).toInt()
        val b = (r.bottom * d).toInt()
        v.measure(MeasureSpec.makeMeasureSpec(rr - l, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(b - t, MeasureSpec.EXACTLY))
        v.layout(l, t, rr, b)
    }

    private fun show(v: View, on: Boolean) { v.visibility = if (on) VISIBLE else GONE }

    override fun onLayout(changed: Boolean, l0: Int, t0: Int, r0: Int, b0: Int) {
        val d = resources.displayMetrics.density
        val w = width / d
        val h = height / d
        val typing = imeHeight > 0
        val l = PadLayout(w, h, safe.left / d, safe.top / d, safe.right / d, safe.bottom / d, Remote.prefs.lefty, drawerOpen, fold,
            displays = showing && Remote.link.displays.value.size >= 2, thumbs = PadLayout.thumbs(deck.dock))
        layout = l
        // full screen: the picture takes it all, inside the cutouts; a fold half open keeps its halves
        val fullNow = showing && Remote.prefs.fullScreen && !typing && fold == null
        if (fullNow != full) {
            full = fullNow
            // the modifiers go out of sight with the keys: none stays held on the computer unseen
            if (fullNow && Remote.sticky.held != 0) main.post { Remote.sticky.release(Remote.sticky.held) }
        }
        val keys = !fullNow
        val sl = safe.left / d
        val st = safe.top / d
        val sr = safe.right / d
        val sb = safe.bottom / d
        var padFrame = l.pad
        var talkFrame = l.talk
        if (fullNow) {
            padFrame = Frame(sl, st, w - sr, h - sb)
            // the talk key in the thumb's bottom corner; the way out in the top corner across from it
            val m = 16f
            talkFrame = if (l.lefty) Frame(sl + m, h - sb - m - 56, sl + m + 64, h - sb - m) else Frame(w - sr - m - 64, h - sb - m - 56, w - sr - m, h - sb - m)
            val ew = exitFull.fitWidth()
            place(exitFull, if (l.lefty) Frame(w - sr - 12 - ew, st + 12, w - sr - 12, st + 12 + 34) else Frame(sl + 12, st + 12, sl + 12 + ew, st + 12 + 34))
        }
        show(exitFull, fullNow)
        talk.floating = fullNow
        if (typing) {
            // the keyboard has the keys' place: the pad takes everything above it, and the row of modifiers sits on the keyboard
            val top = if (l.landscape) max(safe.top / d, 8f) else l.pad.top
            val side = if (l.landscape) max(safe.left / d, 12f) else l.pad.left
            padFrame = Frame(side, top, w - side, h - imeHeight / d - 48 - 8)
        }
        place(pad, padFrame)
        show(pad2, keys && !typing && l.pad2 != null)
        if (!typing) place(pad2, l.pad2)
        show(talk, !typing && !talkFrame.isEmpty)
        place(talk, talkFrame)
        val railed = l.rail != null
        val keysOut = keys && !typing && (!railed || drawerOpen)
        show(list, keysOut)
        place(list, l.list)
        list.arrange(l.keyW * d, l.keyH * d, PadLayout.GAP * d, if (l.landscape) 1.4f else null)
        for ((i, k) in dockCells.withIndex()) {
            place(k, l.dock[i])
            show(k, keys && !typing && (keysOut || l.staysOut(i)))
        }
        show(arrowCell, keys && !typing)
        place(arrowCell, l.arrowKey)
        place(appsCell, l.appsKey)
        show(appsCell, keys && !typing && railed)
        pad.engine.scrollEdge = l.scrollEdge(padFrame.width)
        l.pad2?.let { pad2.engine.scrollEdge = l.scrollEdge(it.width) }
        place(drawerButton, l.drawerButton)
        show(drawerButton, keys && railed && !typing)
        drawerButton.slab = true
        drawerButton.lit = drawerOpen
        place(screenButton, l.screenButton)
        show(screenButton, keys && !typing)
        // lit while it's on, as a modifier is: a crossed-out eye over a live picture reads as off
        screenButton.slab = railed
        screenButton.lit = showing
        screenButton.tint = if (railed) Theme.mark else Theme.caption
        screenButton.contentDescription = context.getString(if (showing) R.string.hide_screen else R.string.show_screen)
        for ((b, r) in listOf(keyboardButton to l.keyboardButton, settingsButton to l.settingsButton, findButton to l.findButton)) {
            place(b, r)
            show(b, keys && !typing)
            b.slab = railed
        }
        show(displayButton, keys && !typing && !l.displayButton.isEmpty)
        if (!l.displayButton.isEmpty) place(displayButton, l.displayButton)
        displayButton.slab = railed
        place(strip, l.strip)
        show(strip, !typing && keysOut)
        // over the bottom of the pad, not over keys that are still in use while talking; in full screen, above the talk key
        val chipsW = min(padFrame.width - 16, 300f)
        val cw = (chipsW - 12) / 3
        val chipsBottom = if (fullNow) talkFrame.top - 8 else padFrame.bottom - 8
        for ((i, ch) in chips.withIndex()) {
            val x = padFrame.centerX - chipsW / 2 + i * (cw + 6)
            place(ch, Frame(x, chipsBottom - 32, x + cw, chipsBottom))
            if (Remote.link.dictation.value != RemoteDictationPhase.LISTENING) ch.visibility = GONE
        }
        field.layout(0, 0, 1, 1)
        show(modRow, typing)
        if (typing) {
            val y = height - imeHeight - (48 * d).toInt()
            modRow.measure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec((48 * d).toInt(), MeasureSpec.EXACTLY))
            modRow.layout(0, y, width, y + (48 * d).toInt())
        }
        dim.layout(0, 0, width, height)

        // inside the pad, in its own coordinates
        val pw = padFrame.width
        val ph = padFrame.height
        Remote.screen.layout(pw.toDouble(), ph.toDouble(), if (fullNow) 0.5 else l.alignY.toDouble())
        place(stage, Frame(0f, 0f, pw, ph))
        // a SurfaceView clears the glass under it: only there while the picture is
        show(stage, showing)
        cursor.measure(MeasureSpec.makeMeasureSpec((64 * d).toInt(), MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec((64 * d).toInt(), MeasureSpec.EXACTLY))
        cursor.layout(0, 0, (64 * d).toInt(), (64 * d).toInt())
        // over the picture it's there but see-through, lit as the picture comes and while the edge scrolls (setShowing, edgeScroll)
        place(edgeMark, if (Remote.prefs.lefty) Frame(7f, ph / 2 - 34, 10f, ph / 2 + 34) else Frame(pw - 10, ph / 2 - 34, pw - 7, ph / 2 + 34))
        place(header, Frame(16f, 12f, pw - 16, 30f))
        // the first time's line, at the top of the picture, under the way out of full screen
        val tipW = min(pw - 32, 420f)
        tip.measure(MeasureSpec.makeMeasureSpec((tipW * d).toInt(), MeasureSpec.AT_MOST), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
        val tw = tip.measuredWidth / d
        val tth = tip.measuredHeight / d
        val tipTop = if (fullNow) 12f + 34 + 10 else 12f
        place(tip, Frame(pw / 2 - tw / 2, tipTop, pw / 2 + tw / 2, tipTop + tth))
        show(header, !header.text.isNullOrEmpty())
        // above the chips, nearest the thumb; the newest words stay in view
        val wordsW = min(pw - 32, 420f)
        val chipsTop = chipsBottom - padFrame.top - 32 - 8
        liveText.measure(MeasureSpec.makeMeasureSpec((wordsW * d).toInt(), MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
        val lh = liveText.measuredHeight / d
        place(liveText, Frame(pw / 2 - wordsW / 2, chipsTop - 6 - lh, pw / 2 + wordsW / 2, chipsTop - 6))
        show(liveText, !liveText.text.isNullOrEmpty())
        // the card: in the middle of the pad, a little above it as the eye expects; a pad too short for it keeps its top
        if (card.words != null) {
            val inset = Frame(16f, 12f, pw - 16, ph - 12)
            val cw = min(inset.width, StatusCard.MAX_WIDTH)
            card.measure(MeasureSpec.makeMeasureSpec((cw * d).toInt(), MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec((inset.height * d).toInt(), MeasureSpec.AT_MOST))
            val chh = card.measuredHeight / d
            val cy = max(inset.top, ph / 2 - chh / 2 - min(20f, (inset.height - chh) / 2))
            place(card, Frame(pw / 2 - cw / 2, cy, pw / 2 + cw / 2, cy + chh))
        }

        exclusions = (if (fullNow) emptyList() else l.exclusions).map { r -> Rect((r.left * d).toInt(), (r.top * d).toInt(), (r.right * d).toInt(), (r.bottom * d).toInt()) }
        if (android.os.Build.VERSION.SDK_INT >= 29) systemGestureExclusionRects = exclusions
    }

    private var exclusions: List<Rect> = emptyList()

    companion object {
        /** long enough that it never happens in use: this only protects a phone left on the desk */
        const val IDLE_DIM = 300_000L
        const val IDLE_PACE = 45_000L
        /** the modifier the computer's own zoom keys use: ⌘ on a Mac (⌘= ⌘−), Ctrl elsewhere */
        fun zoomModifier(h: RemoteHost) = if (h == RemoteHost.MAC) RemoteModifiers.COMMAND else RemoteModifiers.CONTROL
        @Suppress("unused") private fun now() = SystemClock.uptimeMillis()
    }
}
