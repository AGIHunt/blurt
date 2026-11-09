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
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.lifecycle.LifecycleCoroutineScope
import dev.blurt.remote.app.Fonts
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
import dev.blurt.remote.core.LinkRoute
import dev.blurt.remote.core.PadHaptic
import dev.blurt.remote.core.RemoteBlurtCommand
import dev.blurt.remote.core.RemoteChord
import dev.blurt.remote.core.RemoteDictationPhase
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.core.RemoteModifiers
import dev.blurt.remote.core.RemotePointerCurve
import dev.blurt.remote.core.RemoteSystemMove
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
    private val message = TextView(c)
    private val action = TextView(c)
    private val edgeMark = View(c)
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
        for (v in listOf(header, liveText, message, action, edgeMark, cursor)) pad.addView(v)
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
        message.apply { textSize = 15f; setTextColor(Theme.caption); gravity = Gravity.CENTER; setLineSpacing(0f, 1.15f) }
        action.apply {
            textSize = 15f
            setTextColor(Theme.mark)
            typeface = Fonts.medium
            gravity = Gravity.CENTER
            isClickable = true
            setOnClickListener { primaryAction() }
        }
        edgeMark.background = android.graphics.drawable.GradientDrawable().apply { setColor(Theme.hairline); cornerRadius = 1.5f.dp }
        for (p in listOf(pad, pad2)) {
            p.onHaptic = { h -> when (h) { PadHaptic.TAP -> Haptics.tick(); PadHaptic.GRAB -> Haptics.grab(); PadHaptic.RELEASE -> Haptics.release(); PadHaptic.STEP -> Haptics.step() } }
            p.onClick = { Remote.sticky.used() }
            p.onViewEnd = { applyPrefs() }
        }

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
        for (b in listOf(drawerButton, screenButton, keyboardButton, settingsButton, findButton)) addView(b)
        addView(displayButton)
        displayButton.onTap = { Remote.link.nextDisplay() }
        displayButton.onHold = { sheets.displays() }
        drawerButton.onTap = { toggleDrawer() }
        screenButton.onTap = { toggleScreen() }
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

    private fun loadDeck(h: RemoteHost) = Deck.restore(Remote.prefs.string(Deck.storeKey(h)), h)

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

    /** What the pad says, in the few states where it should say anything. */
    private fun status() {
        val l = Remote.link
        val c = context
        var text: String? = null
        var button: String? = null
        val name = l.current.value?.title ?: ""
        when (l.state.value) {
            Link.State.UNPAIRED -> { text = c.getString(R.string.status_unpaired); button = c.getString(R.string.scan_code) }
            Link.State.FORGOTTEN -> { text = c.getString(R.string.status_forgotten, name); button = c.getString(R.string.scan_code) }
            Link.State.UNREACHABLE -> {
                text = if (l.current.value?.relayAddress == null) c.getString(R.string.status_unreachable_local, name) else c.getString(R.string.status_unreachable_relay, name)
                if (l.macs.value.size > 1) button = c.getString(R.string.try_another)
            }
            Link.State.CONNECTING -> {}
            Link.State.REPLACED -> text = c.getString(R.string.status_replaced)
            Link.State.CONNECTED -> {
                if (!l.canControl.value) text = c.getString(if (host == RemoteHost.MAC) R.string.status_accessibility else R.string.status_control)
                when (l.screenError.value) {
                    "permission" -> text = c.getString(if (host == RemoteHost.MAC) R.string.status_screen_permission else R.string.status_screen_permission_pc)
                    "off" -> text = c.getString(R.string.status_screen_off)
                }
            }
        }
        if (l.waitingForMac.value) {
            text = c.getString(R.string.status_waiting, l.pairCheck ?: "")
            button = null
        }
        l.pairFailed.value?.let { text = it }
        message.text = text
        message.visibility = if (text == null) GONE else VISIBLE
        action.text = button
        action.visibility = if (button == null) GONE else VISIBLE
        val via = when (l.route.value) {
            LinkRoute.RELAY -> c.getString(R.string.via_internet, name)
            LinkRoute.DIRECT -> c.getString(R.string.via_direct, name)
            LinkRoute.LOCAL -> name
        }
        header.text = when {
            showing && l.state.value == Link.State.CONNECTED -> null
            l.state.value == Link.State.CONNECTED -> via
            l.state.value == Link.State.CONNECTING && name.isNotEmpty() -> c.getString(R.string.connecting_to, name)
            else -> null
        }
        val ready = l.state.value == Link.State.CONNECTED
        talk.alpha = if (ready) 1f else 0.35f
        if (cycleKey == null) allCells.forEach { it.alpha = if (ready) 1f else 0.35f }
        requestLayout()
    }

    private fun primaryAction() {
        if (Remote.link.state.value == Link.State.UNREACHABLE) sheets.switchMac() else sheets.pairing()
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
        status()
        requestLayout()
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
            displays = showing && Remote.link.displays.value.size >= 2)
        layout = l
        var padFrame = l.pad
        if (typing) {
            // the keyboard has the keys' place: the pad takes everything above it, and the row of modifiers sits on the keyboard
            val top = if (l.landscape) max(safe.top / d, 8f) else l.pad.top
            val side = if (l.landscape) max(safe.left / d, 12f) else l.pad.left
            padFrame = Frame(side, top, w - side, h - imeHeight / d - 48 - 8)
        }
        place(pad, padFrame)
        show(pad2, !typing && l.pad2 != null)
        if (!typing) place(pad2, l.pad2)
        show(talk, !typing && !l.talk.isEmpty)
        place(talk, l.talk)
        val railed = l.rail != null
        val keysOut = !typing && (!railed || drawerOpen)
        show(list, keysOut)
        place(list, l.list)
        list.arrange(l.keyW * d, l.keyH * d, PadLayout.GAP * d, if (l.landscape) 1.4f else null)
        for ((i, k) in dockCells.withIndex()) {
            place(k, l.dock[i])
            show(k, !typing && (keysOut || PadLayout.staysOut(i)))
        }
        show(arrowCell, !typing)
        place(arrowCell, l.arrowKey)
        place(appsCell, l.appsKey)
        show(appsCell, !typing && railed)
        pad.engine.scrollEdge = l.scrollEdge(padFrame.width)
        l.pad2?.let { pad2.engine.scrollEdge = l.scrollEdge(it.width) }
        place(drawerButton, l.drawerButton)
        show(drawerButton, railed && !typing)
        drawerButton.slab = true
        drawerButton.lit = drawerOpen
        place(screenButton, l.screenButton)
        show(screenButton, !typing)
        // lit while it's on, as a modifier is: a crossed-out eye over a live picture reads as off
        screenButton.slab = railed
        screenButton.lit = showing
        screenButton.tint = if (railed) Theme.mark else Theme.caption
        screenButton.contentDescription = context.getString(if (showing) R.string.hide_screen else R.string.show_screen)
        for ((b, r) in listOf(keyboardButton to l.keyboardButton, settingsButton to l.settingsButton, findButton to l.findButton)) {
            place(b, r)
            show(b, !typing)
            b.slab = railed
        }
        show(displayButton, !typing && !l.displayButton.isEmpty)
        if (!l.displayButton.isEmpty) place(displayButton, l.displayButton)
        displayButton.slab = railed
        place(strip, l.strip)
        show(strip, !typing && keysOut)
        // over the bottom of the pad, not over keys that are still in use while talking
        val chipsW = min(padFrame.width - 16, 300f)
        val cw = (chipsW - 12) / 3
        for ((i, ch) in chips.withIndex()) {
            val x = padFrame.centerX - chipsW / 2 + i * (cw + 6)
            place(ch, Frame(x, padFrame.bottom - 8 - 32, x + cw, padFrame.bottom - 8))
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
        Remote.screen.layout(pw.toDouble(), ph.toDouble(), l.alignY.toDouble())
        place(stage, Frame(0f, 0f, pw, ph))
        // a SurfaceView clears the glass under it: only there while the picture is
        show(stage, showing)
        cursor.measure(MeasureSpec.makeMeasureSpec((64 * d).toInt(), MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec((64 * d).toInt(), MeasureSpec.EXACTLY))
        cursor.layout(0, 0, (64 * d).toInt(), (64 * d).toInt())
        show(edgeMark, !showing)
        place(edgeMark, if (Remote.prefs.lefty) Frame(7f, ph / 2 - 34, 10f, ph / 2 + 34) else Frame(pw - 10, ph / 2 - 34, pw - 7, ph / 2 + 34))
        if (showing) edgeMark.visibility = GONE
        place(header, Frame(16f, 12f, pw - 16, 30f))
        show(header, !header.text.isNullOrEmpty())
        // above the chips, nearest the thumb; the newest words stay in view
        val wordsW = min(pw - 32, 420f)
        val chipsTop = ph - 8 - 32 - 8
        liveText.measure(MeasureSpec.makeMeasureSpec((wordsW * d).toInt(), MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
        val lh = liveText.measuredHeight / d
        place(liveText, Frame(pw / 2 - wordsW / 2, chipsTop - 6 - lh, pw / 2 + wordsW / 2, chipsTop - 6))
        show(liveText, !liveText.text.isNullOrEmpty())
        val inset = Frame(16f, 12f, pw - 16, ph - 12)
        message.measure(MeasureSpec.makeMeasureSpec(((inset.width - 16) * d).toInt(), MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
        val mh = message.measuredHeight / d
        val my = ph / 2 - mh / 2 - 20
        place(message, Frame(inset.left + 8, my, inset.right - 8, my + mh))
        show(message, !message.text.isNullOrEmpty())
        place(action, Frame(inset.left, my + mh + 8, inset.right, my + mh + 52))
        show(action, !action.text.isNullOrEmpty())

        exclusions = l.exclusions.map { r -> Rect((r.left * d).toInt(), (r.top * d).toInt(), (r.right * d).toInt(), (r.bottom * d).toInt()) }
        if (android.os.Build.VERSION.SDK_INT >= 29) systemGestureExclusionRects = exclusions
    }

    private var exclusions: List<Rect> = emptyList()

    companion object {
        /** long enough that it never happens in use: this only protects a phone left on the desk */
        const val IDLE_DIM = 300_000L
        const val IDLE_PACE = 45_000L
        @Suppress("unused") private fun now() = SystemClock.uptimeMillis()
    }
}
