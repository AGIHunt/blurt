// The connection to the computer (docs/design/remote.md §Connection; port of apps/ios/BlurtRemote/Net/Link.swift). The one thing competing
// apps most often get wrong, so the rule is: the user never has to do anything to get back. Opening the app connects; coming back from another
// app or the lock screen connects, usually before the thumb lands. It tries the last addresses and DNS-SD at the same time and takes whichever
// answers. Keys and clicks made before the session is up are dropped, never queued: a late ⌘W is worse than a missing one.
//
// Away from home the same session runs over the owner's relay, tried a moment after the local ways. Over it the phone looks for a direct path
// for the pointer and video, and keeps checking for the local network, which takes over the moment it's back.
//
// Main thread only.
package dev.blurt.remote.app.net

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.core.LinkRoute
import dev.blurt.remote.core.PhoneHandshake
import dev.blurt.remote.core.RemoteBlurtCommand
import dev.blurt.remote.core.RemoteDictationPhase
import dev.blurt.remote.core.RemoteFront
import dev.blurt.remote.core.RemoteFrameKind
import dev.blurt.remote.core.RemoteHandshakeError
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.core.RemotePairing
import dev.blurt.remote.core.RemotePointerPacket
import dev.blurt.remote.core.RemoteRelay
import dev.blurt.remote.core.RemoteScrollPhase
import dev.blurt.remote.core.RemoteSessionInfo
import dev.blurt.remote.core.ToMac
import dev.blurt.remote.core.ToPhone
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject

data class PairedMac(
    /** the computer's own id, which outlives its name and address */
    val id: String,
    val deviceID: String,
    val name: String,
    val port: Int,
    val addresses: List<String>,
    /** the relay the computer's owner set up, as last heard */
    val relayAddress: String? = null,
    /** what the user calls it here, when two have much the same name */
    val nickname: String? = null,
    /** "mac", "windows", "linux" as it last said: the keys follow it before it has said so again */
    val platform: String? = null,
) {
    val title: String get() = nickname?.takeIf { it.isNotEmpty() } ?: name
    val host: RemoteHost get() = RemoteHost.from(platform)

    fun json(): JSONObject = JSONObject().put("id", id).put("deviceID", deviceID).put("name", name).put("port", port)
        .put("addresses", JSONArray(addresses)).put("relayAddress", relayAddress).put("nickname", nickname).put("platform", platform)

    companion object {
        fun from(o: JSONObject) = PairedMac(o.getString("id"), o.getString("deviceID"), o.getString("name"), o.getInt("port"),
            (0 until (o.optJSONArray("addresses")?.length() ?: 0)).map { o.getJSONArray("addresses").getString(it) },
            o.optString("relayAddress").ifEmpty { null }, o.optString("nickname").ifEmpty { null }, o.optString("platform").ifEmpty { null })
    }
}

class Link(private val c: Context, private val vault: KeyVault) {
    enum class State {
        UNPAIRED, CONNECTING,
        /** nothing answers after a while */
        UNREACHABLE, CONNECTED,
        /** the computer has forgotten this phone */
        FORGOTTEN,
        /** another phone is driving; this one waits to be touched, or the two would keep throwing each other off */
        REPLACED,
    }

    private val main = Handler(Looper.getMainLooper())
    private val prefs = c.getSharedPreferences("link", Context.MODE_PRIVATE)

    private val _state = MutableStateFlow(State.UNPAIRED)
    val state: StateFlow<State> = _state
    private val _macs = MutableStateFlow<List<PairedMac>>(emptyList())
    val macs: StateFlow<List<PairedMac>> = _macs
    private val _current = MutableStateFlow<PairedMac?>(null)
    val current: StateFlow<PairedMac?> = _current
    val canControl = MutableStateFlow(true)
    val front = MutableStateFlow<RemoteFront?>(null)
    val dictation = MutableStateFlow(RemoteDictationPhase.IDLE)
    /** the words so far: what's final, then what's still being said */
    val live = MutableStateFlow("" to "")
    val level = MutableStateFlow(0f)
    var rtt: Double? = null
        private set
    val route = MutableStateFlow(LinkRoute.LOCAL)
    val displayAspect = MutableStateFlow(1.6)
    /** paired computers on this network right now, while Settings looks */
    val nearby = MutableStateFlow<Set<String>>(emptySet())
    val screenError = MutableStateFlow<String?>(null)
    /** the computer this session is with: its keys */
    val host = MutableStateFlow(RemoteHost.MAC)
    /** its displays, from hosts that can show more than one; and which one the picture is of (null: not known) */
    val displays = MutableStateFlow<List<dev.blurt.remote.core.RemoteDisplay>>(emptyList())
    val shownDisplay = MutableStateFlow<String?>(null)

    /** a link from outside (the camera app, a web page): asks before pairing */
    val offered = MutableStateFlow<RemotePairing?>(null)
    /** the computer is asking its owner about the code this phone used, with these six digits */
    val waitingForMac = MutableStateFlow(false)
    var pairCheck: String? = null
        private set
    /** a pairing that didn't take, for the pad to say */
    val pairFailed = MutableStateFlow<String?>(null)

    private val discovery = Discovery(c)
    private var browse: Discovery.Browse? = null
    private var nearbyBrowse: Discovery.Browse? = null
    private var channel: Channel? = null
    private val attempts = mutableListOf<Channel>()
    private var retry: Runnable? = null
    private var pinger: Runnable? = null
    private var lastPong = 0L
    private var firstAttempt: Long? = null
    private var active = false
    private var generation = 0
    private var refused = false
    private var lastRelayTry = 0L
    private var lastLocalTry = 0L
    private var pingCount = 0
    private var pendingMove: Pair<Float, Float>? = null
    private var pendingScroll: Pair<Float, Float>? = null
    private var flushing = false
    private var lastInfo: RemoteSessionInfo? = null

    /** A code isn't a pairing until the computer has answered it: those already paired stay as they are until then. */
    private data class Joining(val mac: PairedMac, val back: PairedMac?, var since: Long)
    private var joining: Joining? = null
    /** paired again: the entry this one took over from, for the computer to drop */
    private var replacing: String? = null
    private var joinOpens = 0

    private fun now() = System.currentTimeMillis()

    init {
        _macs.value = runCatching {
            val a = JSONArray(prefs.getString("macs.v1", "[]"))
            (0 until a.length()).map { PairedMac.from(a.getJSONObject(it)) }
        }.getOrDefault(emptyList())
        _current.value = _macs.value.firstOrNull { it.id == prefs.getString("currentMac", null) } ?: _macs.value.firstOrNull()
        _state.value = if (_current.value == null) State.UNPAIRED else State.CONNECTING
        host.value = _current.value?.host ?: RemoteHost.MAC
    }

    private fun saveMacs() {
        prefs.edit().putString("macs.v1", JSONArray(_macs.value.map { it.json() }).toString()).putString("currentMac", _current.value?.id).apply()
    }

    private fun setCurrent(m: PairedMac?) {
        _current.value = m
        if (m != null) host.value = m.host
    }

    // MARK: pairing

    /** A link from outside: a web page could open one too, and this phone's keys and microphone would go to whoever made it. So it asks; only
     *  the app's own scanner goes straight through. */
    fun openExternal(url: String) { offered.value = RemotePairing.parse(url) }

    /** The in-app scanner, or the user said yes. False: not a Blurt code. */
    fun open(url: String, confirmed: Boolean = false): Boolean {
        val p = RemotePairing.parse(url.trim()) ?: return false
        // a code for a computer already here replaces it: asked first, as a link from outside is, since a code can claim any computer's id
        if (!confirmed && _macs.value.any { it.id == p.macID }) {
            main.postDelayed({ offered.value = p }, 600)
            return true
        }
        pair(p)
        return true
    }

    fun pair(p: RemotePairing) {
        if (joining?.mac?.deviceID == p.deviceID || _macs.value.any { it.deviceID == p.deviceID }) return     // the same code, read twice
        vault.store(p.key, p.deviceID)
        val m = PairedMac(p.macID, p.deviceID, p.macName, p.port, p.addresses, p.relay, nickname = _macs.value.firstOrNull { it.id == p.macID }?.nickname,
            platform = _macs.value.firstOrNull { it.id == p.macID }?.platform)
        joining?.let { vault.remove(it.mac.deviceID) }
        joining = Joining(m, if (joining != null) joining!!.back else _current.value, now())
        joinOpens = 0
        pairFailed.value = null
        switchTo(m)
    }

    /** The code never got an answer, or a refusal: back where things were, and say why. */
    private fun joinFailed() {
        val j = joining ?: return
        val asked = waitingForMac.value
        joining = null
        waitingForMac.value = false
        vault.remove(j.mac.deviceID)
        val t = when {
            asked -> c.getString(R.string.pair_not_allowed, j.mac.name)
            j.mac.relayAddress == null -> c.getString(R.string.pair_unreachable_local, j.mac.name)
            else -> c.getString(R.string.pair_unreachable_relay, j.mac.name)
        }
        pairFailed.value = t
        main.postDelayed({ if (pairFailed.value == t) pairFailed.value = null }, 8000)
        leave()
        setCurrent(_macs.value.firstOrNull { it.id == j.back?.id } ?: _macs.value.firstOrNull())
        _state.value = if (_current.value == null) State.UNPAIRED else State.CONNECTING
        disconnect()
        connect()
    }

    fun choose(m: PairedMac) {
        if (m.id == _current.value?.id) return
        abandonJoin()
        switchTo(m)
    }

    private fun abandonJoin() {
        joining?.let { vault.remove(it.mac.deviceID) }
        joining = null
        waitingForMac.value = false
    }

    private fun switchTo(m: PairedMac?) {
        leave()
        setCurrent(m)
        if (joining == null) saveMacs()
        _state.value = if (m == null) State.UNPAIRED else State.CONNECTING
        disconnect()
        connect()
    }

    /** Nothing of this computer goes with the phone to the next: not a held key, a take, its picture or what went wrong with it. */
    private fun leave() {
        if (dictation.value != RemoteDictationPhase.IDLE) send(ToMac.Blurt(RemoteBlurtCommand.DICTATION_CANCEL))
        Remote.sticky.clear()
        send(ToMac.Mods(0))
        send(ToMac.ReleaseAll)
        Remote.screen.stop()
        dictation.value = RemoteDictationPhase.IDLE
        live.value = "" to ""
        front.value = null
        screenError.value = null
        displays.value = emptyList()
        shownDisplay.value = null
        refused = false
        firstAttempt = null
        lastRelayTry = 0
    }

    fun rename(m: PairedMac, name: String) {
        val n = _macs.value.indexOfFirst { it.id == m.id }
        if (n < 0) return
        val r = _macs.value[n].copy(nickname = name.trim())
        _macs.value = _macs.value.toMutableList().also { it[n] = r }
        if (_current.value?.id == m.id) setCurrent(r)
        saveMacs()
    }

    /** While Settings is open: which of the paired computers are here. Asks nothing of them. */
    fun watchNearby(on: Boolean) {
        nearbyBrowse?.stop()
        nearbyBrowse = null
        if (!on) { nearby.value = emptySet(); return }
        nearbyBrowse = discovery.browse({ f -> nearby.value = nearby.value + f.id }, { id -> nearby.value = nearby.value - id })
    }

    fun forget(m: PairedMac) {
        if (_current.value?.id == m.id && _state.value == State.CONNECTED) send(ToMac.Unpair)
        vault.remove(m.deviceID)
        _macs.value = _macs.value.filter { it.id != m.id }
        if (_current.value?.id == m.id) {
            abandonJoin()
            switchTo(_macs.value.firstOrNull())
        }
        saveMacs()
    }

    // MARK: app life

    /** when the app last came to the front: how long the way back took goes in the log (debug builds) */
    private var cameBack = 0L

    fun foreground() {
        active = true
        cameBack = android.os.SystemClock.uptimeMillis()
        joining?.since = now()      // scanning with the camera app, say
        if (_state.value != State.CONNECTED && _state.value != State.REPLACED) connect()
    }

    /** The user reached for this phone while another had the computer: take it back. */
    fun touched() {
        if (_state.value == State.REPLACED) connect()
    }

    /** The shade or a dialog over the app: let go of what's held, keep the connection. */
    fun leaving() = send(ToMac.ReleaseAll)

    fun background() {
        active = false
        if (waitingForMac.value) joinFailed()      // nobody's there to see it, and the code is spent
        Remote.sticky.clear()
        send(ToMac.ReleaseAll)
        disconnect()
        // another phone has the computer: coming back doesn't take it from them, a touch does
        if (_current.value != null && _state.value != State.REPLACED) _state.value = State.CONNECTING
    }

    // MARK: connecting

    private fun connect() {
        val mac = _current.value ?: return
        if (!active || channel != null || !attempts.all { it.isRelay }) return
        val key = vault.read(mac.deviceID) ?: run { _state.value = State.FORGOTTEN; return }
        generation += 1
        if (firstAttempt == null) firstAttempt = now()
        if (_state.value in setOf(State.CONNECTED, State.UNPAIRED, State.REPLACED)) _state.value = State.CONNECTING
        tryLocal(mac, key)
        // the relay a moment later, so at home it's never the one that wins; and not every round
        val address = RELAY_ONLY ?: mac.relayAddress
        if (address != null && now() - lastRelayTry > 4000) {
            val g0 = generation
            main.postDelayed({
                if (channel != null || !active || g0 != generation) return@postDelayed
                val url = RemoteRelay.url(address, RemoteRelay.room(key), "phone") ?: return@postDelayed
                lastRelayTry = now()
                attempt(RelayTransport(url), relay = true, mac = mac, key = key)
            }, if (RELAY_ONLY != null) 0 else 1200)
        }
        // keep trying while the app is open; say so after a while
        val g = generation
        val r = Runnable {
            if (channel != null || !active || g != generation) return@Runnable
            val j = joining
            if (j != null && !waitingForMac.value && (refused || now() - j.since > 15_000)) return@Runnable joinFailed()
            // a refusal alone proves nothing, anyone on the network can send one: only if no other way in worked
            if (refused) _state.value = State.FORGOTTEN
            else if (firstAttempt?.let { now() - it > 8000 } == true) _state.value = State.UNREACHABLE
            // a relay attempt gets longer than a local one: it has further to go
            cancelAttempts(keepRelay = now() - lastRelayTry < 9000)
            connect()
        }
        retry = r
        main.postDelayed(r, 3000)
    }

    private fun tryLocal(mac: PairedMac, key: ByteArray) {
        if (RELAY_ONLY != null) return
        lastLocalTry = now()
        for (a in mac.addresses) attempt(TcpTransport(a, mac.port), relay = false, mac = mac, key = key)
        browse?.stop()
        val tried = mutableSetOf<String>()
        browse = discovery.browse({ f ->
            if (f.id != mac.id) return@browse
            for (a in f.addresses) {
                val k = "${a.hostAddress}:${f.port}"
                if (!tried.add(k) || mac.addresses.contains(a.hostAddress) && f.port == mac.port) continue
                if (channel == null || channel?.isRelay == true) attempt(TcpTransport(a.hostAddress ?: continue, f.port, a), relay = false, mac = mac, key = key)
            }
        })
    }

    private fun attempt(t: Transport, relay: Boolean, mac: PairedMac, key: ByteArray) {
        if (!relay && channel != null && channel?.isRelay != true) return
        val ch = Channel(t, PhoneHandshake(mac.deviceID, key), relay)
        ch.onOpen = { main.post { opened(ch) } }
        ch.onControl = { d ->
            val m = ToPhone.decode(d)
            // a word from a computer no longer in hand says nothing about the one that is
            if (m != null) main.post { if (channel === ch) heard(m) }
        }
        ch.onVideo = { Remote.screen.packet(it) }
        ch.onProbe = { Remote.screen.probeBack(it) }
        ch.onCursor = { Remote.screen.cursor(it) }
        ch.onDirect = { found ->
            main.post {
                if (channel !== ch) return@post
                route.value = if (found) LinkRoute.DIRECT else LinkRoute.RELAY
                Remote.screen.planChanged()
                // a path that went quiet may come back, or another may open
                if (!found) lastInfo?.let { i -> main.postDelayed({ if (route.value == LinkRoute.RELAY && channel === ch) lookForDirect(i) }, 15_000) }
            }
        }
        ch.onClose = { failure ->
            main.post {
                attempts.remove(ch)
                if (failure?.kind == RemoteHandshakeError.Kind.NOT_PAIRED) refused = true
                if (channel === ch) lost()
            }
        }
        attempts += ch
        ch.start()
    }

    private fun opened(ch: Channel) {
        val old = channel
        if (old != null) {
            // back on the local network: it takes over from the relay
            if (!old.isRelay || ch.isRelay) { ch.close(); return }
            channel = null
            old.close()
            stopPinging()
        }
        attempts.remove(ch)
        cancelAttempts()
        channel = ch
        route.value = if (ch.isRelay) LinkRoute.RELAY else LinkRoute.LOCAL
        firstAttempt = null
        refused = false
        lastPong = now()
        // a code that keeps getting sessions which never come to a question is being tried for digits: give up on it
        if (joining != null) {
            joinOpens += 1
            if (joinOpens > 3) { ch.close(); return joinFailed() }
        }
        ch.send(ToMac.Hello(deviceName(), Remote.mic.usable, ch.nonce))
        val p = object : Runnable {
            override fun run() { ping(); if (pinger === this) main.postDelayed(this, 500) }
        }
        pinger = p
        main.postDelayed(p, 500)
    }

    private fun deviceName(): String =
        Settings.Global.getString(c.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() } ?: Build.MODEL

    private fun stopPinging() {
        pinger?.let { main.removeCallbacks(it) }
        pinger = null
    }

    private fun cancelAttempts(keepRelay: Boolean = false) {
        retry?.let { main.removeCallbacks(it) }
        browse?.stop()
        browse = null
        val a = attempts.filter { !(keepRelay && it.isRelay) }
        attempts.removeAll(a)
        a.forEach { it.close() }
    }

    private fun ping() {
        val relay = channel?.isRelay == true
        if (now() - lastPong > if (relay) 8000 else 2500) return lost()
        pingCount += 1
        // over the relay, one in four: every message counts against the free plan
        if (!relay || pingCount % 4 == 0) send(ToMac.Ping(Net.now()))
        val mac = _current.value
        if (relay && attempts.isEmpty() && now() - lastLocalTry > 10_000 && mac != null) vault.read(mac.deviceID)?.let { tryLocal(mac, it) }
    }

    private fun lost() {
        stopPinging()
        val ch = channel
        channel = null
        ch?.close()
        Remote.mic.stop()
        Remote.screen.connectionLost()
        dictation.value = RemoteDictationPhase.IDLE
        if (waitingForMac.value) return joinFailed()       // the computer said no, or the way to it went
        if (_current.value == null || _state.value == State.FORGOTTEN || _state.value == State.REPLACED) return
        _state.value = State.CONNECTING
        connect()
    }

    private fun disconnect() {
        stopPinging()
        cancelAttempts()
        val ch = channel
        channel = null
        ch?.close()
        Remote.mic.stop()
    }

    private fun heard(m: ToPhone) {
        when (m) {
            is ToPhone.Session -> {
                val i = m.info
                canControl.value = i.canControl
                if (dev.blurt.remote.app.BuildConfig.DEBUG && cameBack > 0) {
                    android.util.Log.i("Link", "connected ${android.os.SystemClock.uptimeMillis() - cameBack} ms after coming to the front, ${route.value}")
                    cameBack = 0
                }
                _state.value = State.CONNECTED
                val cur = _current.value
                val n = _macs.value.indexOfFirst { it.id == cur?.id }
                if (cur != null && (cur.name != i.macName || cur.platform != (i.platform ?: "mac"))) {
                    val r = cur.copy(name = i.macName, platform = i.platform ?: "mac")
                    if (n >= 0) _macs.value = _macs.value.toMutableList().also { it[n] = r }
                    setCurrent(r)
                    if (n >= 0) saveMacs()
                }
                host.value = i.host
                displayAspect.value = i.displayAspect
                lastInfo = i
                noteRelay(i.relay)
                replacing?.let { send(ToMac.Replaces(it)); replacing = null }
                // one relay serves all of them: a computer with none takes the one the others use
                if (i.relay == null) _macs.value.mapNotNull { it.relayAddress }.firstOrNull()?.let { send(ToMac.OfferRelay(it)) }
                Remote.screen.resume()
                if (channel?.isRelay == true) lookForDirect(i) else channel?.openUDP(i.udpPort, i.udpSession)
                // the computer let go of everything when the last session ended
                send(ToMac.Mods(Remote.sticky.held))
            }
            is ToPhone.CanControl -> canControl.value = m.on
            is ToPhone.Front -> front.value = m.front
            is ToPhone.Dictation -> {
                dictation.value = m.phase
                if (m.phase != RemoteDictationPhase.LISTENING) level.value = 0f
                if (m.phase == RemoteDictationPhase.IDLE) live.value = "" to ""
                Remote.mic.macPhase(m.phase)
            }
            is ToPhone.Live -> live.value = m.committed to m.pending
            is ToPhone.Listen -> {
                // a voice note started from here is heard through this phone, as the talk key is
                if (m.on) {
                    // couldn't have the microphone (a call has it): the computer hears this note with its own; the setting stays, so the
                    // next note tries the phone again
                    if (!Remote.mic.usable || !Remote.mic.start(dev.blurt.remote.app.talk.MicStream.Holder.NOTE)) {
                        send(ToMac.SetMicOnPhone(false))
                        send(ToMac.SetMicOnPhone(Remote.mic.usable))
                        send(ToMac.Hud(c.getString(R.string.mic_unavailable)))
                    }
                } else {
                    Remote.mic.stop(dev.blurt.remote.app.talk.MicStream.Holder.NOTE)
                }
            }
            is ToPhone.Level -> level.value = m.level
            is ToPhone.Typed, is ToPhone.Notice -> {}
            is ToPhone.Pong -> {
                lastPong = now()
                rtt = Net.now() - m.t
            }
            ToPhone.UdpOK -> channel?.udpConfirmed()
            is ToPhone.Clock -> Remote.screen.clock(m.phone, m.mac)
            is ToPhone.ScreenFailed -> {
                Remote.screen.stop()
                screenError.value = m.text
            }
            is ToPhone.ScreenView -> {
                shownDisplay.value = m.display
                Remote.screen.source(m.width, m.height, m.codec)
            }
            is ToPhone.Displays -> displays.value = m.displays
            is ToPhone.CursorShape -> Remote.screen.shape(m.png, m.hotX, m.hotY, m.width, m.height)
            is ToPhone.Relay -> noteRelay(m.address)
            ToPhone.PairingWaits -> {
                pairCheck = channel?.check
                waitingForMac.value = true
                val d = joining?.mac?.deviceID
                main.postDelayed({ if (waitingForMac.value && joining?.mac?.deviceID == d) joinFailed() }, 120_000)
            }
            is ToPhone.NewKey -> {
                val cur = _current.value ?: return
                vault.store(m.key, cur.deviceID)
                if (joining != null) {
                    joining = null
                    waitingForMac.value = false
                    _macs.value.firstOrNull { it.id == cur.id }?.let { old ->
                        if (old.deviceID != cur.deviceID) {
                            vault.remove(old.deviceID)
                            replacing = old.deviceID
                        }
                    }
                    _macs.value = listOf(cur) + _macs.value.filter { it.id != cur.id }
                    saveMacs()
                }
                send(ToMac.KeyStored)
            }
            ToPhone.Removed -> _current.value?.let { forget(it) }
            ToPhone.Replaced -> {
                _state.value = State.REPLACED
                disconnect()
            }
        }
    }

    private fun noteRelay(typed: String?) {
        val address = typed?.let { RemoteRelay.address(it) }
        val cur = _current.value ?: return
        if (cur.relayAddress == address) return
        val n = _macs.value.indexOfFirst { it.id == cur.id }
        val r = cur.copy(relayAddress = address)
        setCurrent(r)
        if (n >= 0) {
            _macs.value = _macs.value.toMutableList().also { it[n] = r }
            saveMacs()
        }
    }

    fun setAspect(a: Double) { if (kotlin.math.abs(a - displayAspect.value) > 0.001) displayAspect.value = a }

    /** Trade addresses with the computer and knock, from one fixed local port. */
    private fun lookForDirect(i: RemoteSessionInfo) {
        if (NO_DIRECT) return
        val ch = channel ?: return
        ch.lookForDirect(i.candidates, i.udpSession) { mine -> main.post { if (channel === ch) send(ToMac.Candidates(mine)) } }
    }

    // MARK: sending

    fun send(m: ToMac) { channel?.send(m) }

    /** The computer's displays left to right, as its display settings arrange them. */
    val displaysInOrder: List<dev.blurt.remote.core.RemoteDisplay> get() = displays.value.sortedWith(compareBy({ it.x }, { it.y }))

    /** The next display to the right, round to the first: the switcher's tap. */
    fun nextDisplay() {
        val list = displaysInOrder
        if (list.size < 2) return
        val at = list.indexOfFirst { it.id == shownDisplay.value }
        showDisplay(list[(at + 1).mod(list.size)].id)
    }

    /** null: follow the pointer from display to display */
    fun showDisplay(id: String?) {
        send(ToMac.ShowDisplay(id))
        if (id != null) shownDisplay.value = id
    }

    /** `inOrder`: behind what was sent before it, as a scroll right after the pointer was placed must be */
    fun pointer(p: RemotePointerPacket, inOrder: Boolean = false) {
        val ch = channel ?: return
        // over the relay every message counts: 30 a second is plenty, and it's already no place for a fine stroke
        if (route.value != LinkRoute.RELAY) return ch.sendPointer(p, inOrder)
        when {
            p is RemotePointerPacket.Move -> pendingMove = ((pendingMove?.first ?: 0f) + p.dx) to ((pendingMove?.second ?: 0f) + p.dy)
            p is RemotePointerPacket.Scroll && p.phase == RemoteScrollPhase.CHANGED ->
                pendingScroll = ((pendingScroll?.first ?: 0f) + p.dx) to ((pendingScroll?.second ?: 0f) + p.dy)
            else -> { flush(); ch.sendPointer(p); return }
        }
        if (!flushing) {
            flushing = true
            main.postDelayed({ flush() }, 33)
        }
    }

    private fun flush() {
        flushing = false
        val ch = channel
        pendingMove?.let { ch?.sendPointer(RemotePointerPacket.Move(it.first, it.second)) }
        pendingScroll?.let { ch?.sendPointer(RemotePointerPacket.Scroll(it.first, it.second, RemoteScrollPhase.CHANGED)) }
        pendingMove = null
        pendingScroll = null
    }

    fun audio(d: ByteArray) { channel?.sendAudio(d) }
    fun datagram(k: RemoteFrameKind, d: ByteArray) { channel?.sendDatagram(k, d) }
    val ready: Boolean get() = channel != null && _state.value == State.CONNECTED

    companion object {
        /** a test run: only this way in (debug builds) */
        val RELAY_ONLY: String? = null
        const val NO_DIRECT = false
    }
}
