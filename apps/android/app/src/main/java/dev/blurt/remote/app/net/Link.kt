// The connection to the computer (docs/design/remote.md §Connection; port of apps/ios/BlurtRemote/Net/Link.swift). The one thing competing
// apps most often get wrong, so the rule is: the user never has to do anything to get back. Opening the app connects; coming back from another
// app or the lock screen finds the session still there (kept three minutes by a foreground service, KeepService), or connects again, usually
// before the thumb lands. It tries the last addresses and DNS-SD at the same time and takes whichever answers. Keys and clicks made before
// the session is up are dropped, never queued: a late ⌘W is worse than a missing one.
//
// Away from home the same session runs over the owner's relay, tried a moment after the local ways. Over it the phone looks for a direct path
// for the pointer and video, and keeps checking for the local network, which takes over the moment it's back.
//
// Without an own relay, Blurt's go-between does the introducing (docs/design/remote-go-between.md): the host offers it as its relay, and
// once the direct path opens the whole session moves onto it (Channel). And an overlay address the computer listed (Tailscale, ZeroTier) is
// tried over TCP alongside, which wins over any relay.
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
import dev.blurt.remote.core.AwayTrouble
import dev.blurt.remote.core.GoBetweenBackoff
import dev.blurt.remote.core.HeldAudio
import dev.blurt.remote.core.LinkPath
import dev.blurt.remote.core.LinkRoute
import dev.blurt.remote.core.PairEnd
import dev.blurt.remote.core.PhoneHandshake
import dev.blurt.remote.core.RemoteBlurtCommand
import dev.blurt.remote.core.RemoteDictationPhase
import dev.blurt.remote.core.RemoteFeature
import dev.blurt.remote.core.RemoteOverlay
import dev.blurt.remote.core.RemoteFront
import dev.blurt.remote.core.RemoteFrameKind
import dev.blurt.remote.core.RemoteHandshakeError
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.core.RemotePairing
import dev.blurt.remote.core.RemotePointerPacket
import dev.blurt.remote.core.RemotePresence
import dev.blurt.remote.core.RemoteRelay
import dev.blurt.remote.core.RemoteScrollPhase
import dev.blurt.remote.core.RemoteSessionInfo
import dev.blurt.remote.core.Reconnect
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
    /** the addresses it last listed that may be reachable away from home over an overlay (Tailscale, ZeroTier): tried at `port` */
    val candidates: List<String> = emptyList(),
    /** the computer removed this phone, said in a session it had opened: its key is gone, and it has to be paired again */
    val removed: Boolean = false,
) {
    val title: String get() = nickname?.takeIf { it.isNotEmpty() } ?: name
    val host: RemoteHost get() = RemoteHost.from(platform)

    fun json(): JSONObject = JSONObject().put("id", id).put("deviceID", deviceID).put("name", name).put("port", port)
        .put("addresses", JSONArray(addresses)).put("relayAddress", relayAddress).put("nickname", nickname).put("platform", platform)
        .put("candidates", JSONArray(candidates)).apply { if (removed) put("removed", true) }

    companion object {
        fun from(o: JSONObject) = PairedMac(o.getString("id"), o.getString("deviceID"), o.getString("name"), o.getInt("port"),
            (0 until (o.optJSONArray("addresses")?.length() ?: 0)).map { o.getJSONArray("addresses").getString(it) },
            o.optString("relayAddress").ifEmpty { null }, o.optString("nickname").ifEmpty { null }, o.optString("platform").ifEmpty { null },
            (0 until (o.optJSONArray("candidates")?.length() ?: 0)).map { o.getJSONArray("candidates").getString(it) },
            o.optBoolean("removed", false))
    }
}

/** A pairing that didn't take: what went wrong, what to do next; `why.canRetry`: the same code can still work (Try Again). */
data class PairFailure(val why: PairEnd, val title: String, val help: String)

class Link(private val c: Context, private val vault: KeyVault) {
    enum class State {
        UNPAIRED, CONNECTING,
        /** nothing answers after a while */
        UNREACHABLE, CONNECTED,
        /** the computer has forgotten this phone */
        FORGOTTEN,
        /** another phone is driving; this one waits to be touched, or the two would keep throwing each other off */
        REPLACED,
        /** the person at the computer ended the session: nothing more until the user touches this phone */
        ENDED,
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
    /** what the computer's layout prints on its keys; null until it says, or from a host that can't */
    val legends = MutableStateFlow<dev.blurt.remote.core.RemoteLegends?>(null)
    val dictation = MutableStateFlow(RemoteDictationPhase.IDLE)
    /** the words so far: what's final, then what's still being said */
    val live = MutableStateFlow("" to "")
    val level = MutableStateFlow(0f)
    var rtt: Double? = null
        private set
    val route = MutableStateFlow(LinkRoute.LOCAL)
    /** which way the session runs, for the connection label; `route` follows from it */
    val path = MutableStateFlow(LinkPath.SAME_NETWORK)
    /** why Blurt's go-between couldn't carry the session, while nothing else has connected */
    val away = MutableStateFlow<AwayTrouble?>(null)
    /** the go-between said busy: it isn't asked again for a while (shared by every computer, as the go-between is) */
    private val busy = GoBetweenBackoff()
    /** the go-between said this network won't connect directly: not asked again before this (ms), unless Retry */
    private var noDirectUntil = 0L
    val displayAspect = MutableStateFlow(1.6)
    /** paired computers on this network right now, while Settings looks */
    val nearby = MutableStateFlow<Set<String>>(emptySet())
    val screenError = MutableStateFlow<String?>(null)
    /** a picture was being watched when the computer ended it: that's said, whoever asked for it */
    var pictureSeen = false
    /** the computer's screen is locked and it can't show that */
    val hostLocked = MutableStateFlow(false)
    /** on the go-between, nothing is carried until the direct path is open: not connected yet (the state stays CONNECTING) */
    val meeting = MutableStateFlow(false)
    /** this phone has no network at all */
    val offline = MutableStateFlow(false)
    /** what its relay says of a computer that can't be reached, asked now and then while it can't */
    val presence = MutableStateFlow<RemotePresence?>(null)
    /** typed on the phone's own keyboard while there was no session: kept, and asked about once there is one */
    val unsent = MutableStateFlow("")
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
    val pairFailed = MutableStateFlow<PairFailure?>(null)
    /** the last pairing link typed into the sheet: the sheet shows it again after a failure */
    var lastLink = ""
    /** when the computer began asking about the code in hand (ms) */
    private var askedAt: Long? = null

    private val discovery = Discovery(c)
    private var browse: Discovery.Browse? = null
    private var nearbyBrowse: Discovery.Browse? = null
    @Volatile private var channel: Channel? = null
    private val attempts = mutableListOf<Channel>()
    private var retry: Runnable? = null
    private var pinger: Runnable? = null
    private var lastPong = 0L
    private var firstAttempt: Long? = null
    private var active = false
    private var generation = 0
    private var refused = false
    private var lastRelayTry = 0L
    /** relay connections that ended before a session, in a row (Reconnect.relayAgainMs), and the next one's wait */
    private var relayEnds = 0
    private var relayAgain: Runnable? = null
    /** the last session came over a relay or an overlay network: next time the relay starts with the local ways */
    private var lastAway = false
    /** the session in hand hasn't said `session` yet */
    private var sessionDue: Runnable? = null
    /** in the background with the session kept (background()) */
    private var parked = false
    private var parkEnds: Runnable? = null
    private var parkedAt = 0L
    private var lastRefusal = 0L
    /** the computer's own relay failed this many times in a row without opening: from 2, the public connection service is tried too
     * (its host waits there meanwhile), and the card says why */
    private var relayFails = 0
    private var lastMeetTry = 0L
    private var lastLocalTry = 0L
    private var pingCount = 0
    private var pendingMove: Pair<Float, Float>? = null
    /** this phone's pointer instructions so far, moves and placements alike (u32, counting round): the computer says how far it has got
     *  with each word on where its pointer is (RemoteCursor), so the pointer drawn here never jumps back to a place from before the
     *  last moves */
    var pointerSeq = 0L
        private set
    fun nextPointerSeq(): Long {
        pointerSeq = (pointerSeq + 1) and 0xFFFF_FFFFL
        return pointerSeq
    }
    private var pendingScroll: Pair<Float, Float>? = null
    private var flushing = false
    private var lastInfo: RemoteSessionInfo? = null

    /** A code isn't a pairing until the computer has answered it: those already paired stay as they are until then. */
    private data class Joining(val mac: PairedMac, val back: PairedMac?, var since: Long)
    private var joining: Joining? = null
    /** paired again: the entry this one took over from, for the computer to drop */
    private var replacing: String? = null
    private var joinOpens = 0

    /** monotonic: the phone's clock may be set while a session runs, and time out of sight counts */
    private fun now() = android.os.SystemClock.elapsedRealtime()

    init {
        _macs.value = runCatching {
            val a = JSONArray(prefs.getString("macs.v1", "[]"))
            (0 until a.length()).map { PairedMac.from(a.getJSONObject(it)) }
        }.getOrDefault(emptyList())
        _current.value = _macs.value.firstOrNull { it.id == prefs.getString("currentMac", null) } ?: _macs.value.firstOrNull()
        _state.value = if (_current.value == null) State.UNPAIRED else State.CONNECTING
        host.value = _current.value?.host ?: RemoteHost.MAC
        watchNetwork()
    }

    /** Wi-Fi came, went or became another one: told on the main thread, the first word (what's there now) apart. */
    private fun watchNetwork() {
        val cm = c.getSystemService(android.net.ConnectivityManager::class.java) ?: return
        // a network that went is still listed for a moment
        val look = Runnable { offline.value = !Addresses.online(c) }
        fun lookSoon() {
            main.removeCallbacks(look)
            main.postDelayed(look, 600)
        }
        look.run()
        var seen: Pair<android.net.Network, String>? = null
        var known = false
        fun now(n: android.net.Network, lp: android.net.LinkProperties) {
            val at = n to (lp.interfaceName ?: "") + lp.linkAddresses.map { it.toString() }.filter { "temporary" !in it }.sorted()
            val changed = known && seen != at
            seen = at
            known = true
            if (changed) networkChanged()
        }
        runCatching {
            cm.registerDefaultNetworkCallback(object : android.net.ConnectivityManager.NetworkCallback() {
                override fun onLinkPropertiesChanged(network: android.net.Network, lp: android.net.LinkProperties) { main.post { now(network, lp) } }
                override fun onAvailable(network: android.net.Network) { main.post { offline.value = false } }
                override fun onLost(network: android.net.Network) { main.post { if (seen?.first == network) seen = null; lookSoon() } }
            })
        }
    }

    /** What didn't work on the last network may on this one, and what was being tried goes out of one that's gone: start over now. A session
     *  in hand is asked to prove itself instead. */
    private fun networkChanged() {
        askAgain(asked = true)
        if (!active || _current.value == null) return
        if (channel != null) {
            prove()
            lastLocalTry = 0       // the same network may be back: looked for now, not in 10 s
        } else if (_state.value == State.CONNECTING || _state.value == State.UNREACHABLE) {
            firstAttempt = null
            cancelAttempts()
            connect()
        }
    }

    /** What was held against the ways in is put aside: the user came back, asked again, or changed networks. The go-between's refusal is
     *  waited out only as long as its own rate limit, as killing and opening the app would. */
    private fun askAgain(asked: Boolean) {
        noDirectUntil = 0
        refused = false
        relayEnds = 0
        if (away.value == AwayTrouble.NO_DIRECT || away.value == AwayTrouble.RELAY_DOWN) away.value = null
        busy.notAfter((lastRefusal + Reconnect.busyFloorMs(asked)) / 1000.0)
    }

    /** The session in hand may have died unseen (the app was out of sight or frozen, the network changed): it answers soon, or it's started
     *  over. */
    private fun prove() {
        val ch = channel ?: return
        lastPong = now() + Reconnect.proofMs(ch.isRelay) - (if (ch.isRelay) 8000 else 2500)
        send(ToMac.Ping(Net.now()))
    }

    private fun setState(s: State) {
        if (_state.value == s) return
        _state.value = s
        // why it can't be reached, from its relay: asked on the way in, then now and then while it lasts
        main.removeCallbacks(peeker)
        if (s == State.UNREACHABLE) peeker.run() else if (s == State.CONNECTED) presence.value = null
    }

    private val peeker = object : Runnable {
        override fun run() {
            peek()
            main.postDelayed(this, PEEK_EVERY_MS)
        }
    }

    private fun peek() {
        val m = _current.value ?: return
        // a code not yet answered has no room of its own there; what the go-between refused or couldn't do is said instead of this
        if (!active || joining != null || away.value == AwayTrouble.BUSY || away.value == AwayTrouble.NO_DIRECT) return
        val url = m.relayAddress?.let { a -> vault.read(m.deviceID)?.let { RemoteRelay.peekURL(a, RemoteRelay.room(it)) } } ?: return
        RelayTransport.get(url) { body ->
            val p = body?.let { RemotePresence.parse(it) }
            main.post { if (_current.value?.deviceID == m.deviceID && _state.value == State.UNREACHABLE) presence.value = p }
        }
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
     *  the app's own scanner goes straight through. One this phone is paired by already (Android hands an old one over again when it brings
     *  the app back) asks nothing. */
    fun openExternal(url: String) {
        val p = RemotePairing.parse(url)
        if (p != null && (joining?.mac?.deviceID == p.deviceID || _macs.value.any { it.deviceID == p.deviceID })) return
        offered.value = p
    }

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
            platform = _macs.value.firstOrNull { it.id == p.macID }?.platform, candidates = _macs.value.firstOrNull { it.id == p.macID }?.candidates ?: emptyList())
        joining?.let { vault.remove(it.mac.deviceID) }
        joining = Joining(m, if (joining != null) joining!!.back else _current.value, now())
        joinOpens = 0
        pairFailed.value = null
        switchTo(m)
    }

    /** What a pairing that didn't take says: the failure, then what to do next (as the Mac viewer says it). */
    private fun failure(why: PairEnd, m: PairedMac): PairFailure {
        val scan = c.getString(R.string.pair_scan_new, m.name)
        return when (why) {
            PairEnd.SPENT -> PairFailure(why, c.getString(R.string.pair_spent), scan)
            PairEnd.DECLINED -> PairFailure(why, c.getString(R.string.pair_not_allowed, m.name), scan)
            PairEnd.UNANSWERED -> PairFailure(why, c.getString(R.string.pair_unanswered, m.name), scan)
            PairEnd.LEFT -> PairFailure(why, c.getString(R.string.pair_left), scan)
            PairEnd.UNREACHABLE -> PairFailure(why, c.getString(R.string.pair_unreachable, m.name),
                if (m.relayAddress == null) c.getString(R.string.pair_unreachable_local) else c.getString(R.string.pair_unreachable_relay, m.name))
        }
    }

    /** The code in hand can't be reached yet: said, and it goes on trying; if the computer turns up and asks, its digits take this one's
     *  place, so they can be compared. */
    private fun joinUnreachable() {
        val j = joining ?: return
        if (pairFailed.value == null) pairFailed.value = failure(PairEnd.UNREACHABLE, j.mac)
    }

    /** The pad's OK under why a pairing didn't take. */
    fun dismissPairFailure() { pairFailed.value = null }

    /** The code never got an answer, or a refusal: back where things were, and say why, with Scan Code for a new one. Said until it's read
     *  (the card's buttons), or until the next pairing begins. */
    private fun joinFailed(why: PairEnd) {
        val j = joining ?: return
        joining = null
        waitingForMac.value = false
        askedAt = null
        vault.remove(j.mac.deviceID)
        pairFailed.value = failure(why, j.mac)
        leave()
        setCurrent(_macs.value.firstOrNull { it.id == j.back?.id } ?: _macs.value.firstOrNull())
        setState(if (_current.value == null) State.UNPAIRED else State.CONNECTING)
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
        askedAt = null
        pairFailed.value = null
    }

    private fun switchTo(m: PairedMac?) {
        leave()
        setCurrent(m)
        if (joining == null) saveMacs()
        setState(if (m == null) State.UNPAIRED else State.CONNECTING)
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
        legends.value = null
        screenError.value = null
        hostLocked.value = false
        meeting.value = false
        presence.value = null
        unsent.value = ""
        displays.value = emptyList()
        shownDisplay.value = null
        away.value = null
        noDirectUntil = 0
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

    /** The computer removed this phone in a session: its key is deleted and the record kept, marked removed, so the pad and the list say
     *  so and offer a new code. Pairing again replaces the record by the computer's id. */
    private fun removedHere(m: PairedMac) {
        vault.remove(m.deviceID)
        _macs.value = _macs.value.map { if (it.id == m.id && it.deviceID == m.deviceID) it.copy(removed = true) else it }
        if (_current.value?.id == m.id) setCurrent(_macs.value.firstOrNull { it.id == m.id } ?: m.copy(removed = true))
        saveMacs()
        setState(State.FORGOTTEN)
        disconnect()
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
        val back = !active
        active = true
        cameBack = android.os.SystemClock.uptimeMillis()
        joining?.since = now()      // scanning with the camera app, say
        if (parked) {
            unpark()
            if (channel != null) {
                prove()
                Remote.screen.unpause()
                return
            }
        }
        if (back) {
            firstAttempt = null
            askAgain(asked = false)
        }
        if (_state.value != State.CONNECTED && _state.value != State.REPLACED && _state.value != State.ENDED) connect()
    }

    /** The card's Take Over or Reconnect: another phone has the computer, or its owner ended the session. */
    fun takeBack() {
        if (_state.value != State.REPLACED && _state.value != State.ENDED) return
        firstAttempt = null
        askAgain(asked = true)
        setState(State.CONNECTING)
        connect()
    }

    /**
     * The pad's Retry, when nothing has answered for a while: the same attempts, started over now, and the pad says "connecting" again
     * while they run. It was already trying every 3 s; this is for the moment the user has just woken the computer or started Blurt.
     */
    fun tryAgain() {
        val sameCode = joining != null && pairFailed.value?.why?.canRetry == true
        if (!active || _current.value == null || (_state.value != State.UNREACHABLE && !sameCode)) return
        firstAttempt = null
        // a code that couldn't be reached: the same code once more; what went wrong is gone until it goes wrong again
        if (sameCode) {
            pairFailed.value = null
            joining?.since = now()
        }
        setState(State.CONNECTING)
        askAgain(asked = true)
        cancelAttempts()
        connect()
    }

    /** The shade or a dialog over the app: let go of what's held, keep the connection. */
    fun leaving() = send(ToMac.ReleaseAll)

    fun background() {
        active = false
        Remote.sticky.clear()
        send(ToMac.ReleaseAll)
        // a message answered, a code copied: back within three minutes, and the session is still there. Android gives an app out of sight
        // silence, so a take through this phone's microphone ends here with what was said; a voice note ends with the session
        if (Remote.prefs.stayConnected && channel != null && (_state.value == State.CONNECTED || waitingForMac.value)) {
            if (Remote.mic.busy) endTake()
            if (!Remote.mic.busy) return park()
        }
        left()
    }

    private fun park() {
        parked = true
        parkedAt = now()
        Remote.screen.pause()
        // a pairing being asked about isn't a connection yet: nothing says it is
        val kept = _state.value == State.CONNECTED && KeepService.start(c, _current.value?.title ?: "")
        parkFor(Reconnect.keepInBackgroundMs(kept))
    }

    private fun parkFor(ms: Long) {
        parkEnds?.let { main.removeCallbacks(it) }
        val r = Runnable { parkOver() }
        parkEnds = r
        main.postDelayed(r, maxOf(0, parkedAt + ms - now()))
    }

    /** Android didn't let the service run after all: the session is kept only as long as the process may hang on. */
    fun keepFailed() { if (parked) parkFor(Reconnect.keepInBackgroundMs(false)) }

    /** The notification's Disconnect, or the app swiped away. */
    fun keepEnded() = parkOver()

    /** Long enough out of sight, or the session went meanwhile: it ends here, and coming back starts anew. */
    private fun parkOver() {
        if (!parked) return
        unpark()
        left()
    }

    private fun unpark() {
        if (!parked) return
        parked = false
        parkEnds?.let { main.removeCallbacks(it) }
        parkEnds = null
        KeepService.stop()
    }

    /** Nothing is kept: the computer hears the session end. */
    private fun left() {
        if (waitingForMac.value) joinFailed(PairEnd.LEFT)      // nobody's there to see it, and the code is spent
        disconnect()
        // another phone has the computer: coming back doesn't take it from them, a touch does
        if (_current.value != null && _state.value != State.REPLACED && _state.value != State.ENDED) setState(State.CONNECTING)
    }

    // MARK: connecting

    private fun connect() {
        val mac = _current.value ?: return
        if (!active || channel != null || !attempts.all { it.isRelay }) return
        // replaced or ended there: nothing until the user touches this phone, whatever retry was already queued
        if (_state.value == State.REPLACED || _state.value == State.ENDED) return
        relayAgain?.let { main.removeCallbacks(it) }
        val key = vault.read(mac.deviceID) ?: run { setState(State.FORGOTTEN); return }
        generation += 1
        if (firstAttempt == null) firstAttempt = now()
        if (_state.value in setOf(State.CONNECTED, State.UNPAIRED, State.REPLACED, State.ENDED)) setState(State.CONNECTING)
        tryLocal(mac, key)
        // the relay a moment later, so at home it's never the one that wins (with the local ways when the last session was away). Overlay
        // addresses alongside it.
        val g0 = generation
        main.postDelayed({
            if (channel != null || !active || g0 != generation) return@postDelayed
            tryOverlay(mac, key)
            tryRelays(mac, key)
        }, if (RELAY_ONLY != null) 0 else Reconnect.relayDelayMs(lastAway))
        // keep trying while the app is open; say so after a while
        val g = generation
        val r = Runnable {
            if (channel != null || !active || g != generation) return@Runnable
            val j = joining
            // a code refused before anyone was asked has run out or was used; one that can't be reached is said, and tried on
            if (j != null && !waitingForMac.value) {
                if (refused) return@Runnable joinFailed(PairEnd.SPENT)
                if (now() - j.since > 15_000) joinUnreachable()
            }
            // a refusal alone proves nothing, anyone on the network can send one: only if no other way in worked
            if (refused && attempts.none { it.isRelay }) setState(State.FORGOTTEN)
            else if (firstAttempt?.let { now() - it > Reconnect.unreachableAfterMs(mac.relayAddress != null) } == true || away.value != null) setState(State.UNREACHABLE)
            // a relay attempt gets longer than a local one: it has further to go
            cancelAttempts(keepRelay = now() - lastRelayTry < 9000)
            connect()
        }
        retry = r
        main.postDelayed(r, 3000)
    }

    /** The go-between isn't asked in a loop: not while it's busy, nor for a minute after it said this network won't connect directly. */
    private fun mayTryRelay(address: String): Boolean =
        !RemoteRelay.isGoBetween(address) || busy.mayTry(now() / 1000.0) && now() >= noDirectUntil

    private fun tryLocal(mac: PairedMac, key: ByteArray) {
        if (RELAY_ONLY != null) return
        lastLocalTry = now()
        // Tailscale's addresses are tried with the overlay ones, on a shorter fuse
        for (a in mac.addresses) if (!RemoteOverlay.isTailscale(a)) attempt(TcpTransport(a, mac.port), relay = false, mac = mac, key = key)
        browse?.stop()
        val tried = mutableSetOf<String>()
        browse = discovery.browse({ f ->
            if (f.id != mac.id) return@browse
            for (a in f.addresses) {
                val k = "${a.hostAddress}:${f.port}"
                if (!tried.add(k) || mac.addresses.contains(a.hostAddress) && f.port == mac.port) continue
                if (channel == null || channel?.isRelay == true) attempt(TcpTransport(a.hostAddress ?: continue, f.port, a), relay = false, mac = mac, key = key,
                    discovered = true)
            }
        })
    }

    /**
     * Away from the same network: the overlay addresses the computer listed (Tailscale, ZeroTier and the like), each over TCP at its port
     * with 1.5 s to answer, alongside the relay or the go-between. One that answers wins over either. With a phone VPN that isn't the
     * overlay's (one runs at a time), they just time out.
     */
    private fun tryOverlay(mac: PairedMac, key: ByteArray) {
        if (RELAY_ONLY != null) return
        val list = (mac.addresses.filter { RemoteOverlay.isTailscale(it) } + mac.candidates.filter { it !in mac.addresses && RemoteOverlay.mayBeOverlay(it) }).distinct()
        for (a in list) attempt(TcpTransport(a, mac.port, timeoutMs = RemoteOverlay.CONNECT_TIMEOUT_MS), relay = false, mac = mac, key = key)
    }

    private fun setPath(p: LinkPath) {
        path.value = p
        route.value = p.route
    }

    /** The go-between ended a session: this network won't connect directly. */
    private fun noDirect() {
        away.value = AwayTrouble.NO_DIRECT
        noDirectUntil = now() + 60_000
    }

    private fun attempt(t: Transport, relay: Boolean, mac: PairedMac, key: ByteArray, goBetween: Boolean = false, discovered: Boolean = false,
                        address: String? = null) {
        if (!active || !relay && channel != null && channel?.isRelay != true) return
        val ch = Channel(t, PhoneHandshake(mac.deviceID, key), relay, goBetween, discovered)
        ch.relayAddress = address
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
                setPath(if (found) LinkPath.DIRECT else if (ch.goBetween) LinkPath.GO_BETWEEN else LinkPath.OWN_RELAY)
                Remote.screen.planChanged()
                // a path that went quiet may come back, or another may open
                if (!found) lastInfo?.let { i -> main.postDelayed({ if (route.value == LinkRoute.RELAY && channel === ch) lookForDirect(i) }, 15_000) }
            }
        }
        ch.onMoved = {
            main.post {
                if (channel !== ch) return@post
                // everything goes direct now: the go-between has done its part
                setPath(LinkPath.DIRECT)
                away.value = null
                busy.worked()
                if (meeting.value) carrying() else Remote.screen.planChanged()
            }
        }
        ch.onClose = { failure ->
            main.post {
                // one let go of here (another way in won, the app left) says nothing about the relay
                val tried = attempts.remove(ch)
                if (ch.isRelay && !ch.goBetween && (tried || ch.wasReady)) {
                    if (ch.wasReady) {
                        relayFails = 0
                        if (away.value == AwayTrouble.RELAY_DOWN) away.value = null
                    } else if (++relayFails >= 2 && away.value == null) away.value = AwayTrouble.RELAY_DOWN
                }
                if (ch.goBetween) {
                    if (ch.relayClose == RemoteRelay.BUDGET) noDirect()
                    // refused at the door (429, Cloudflare's 1015, any upgrade that didn't happen): out of today's quota, or rate-limited
                    if (ch.relayRefused?.let { Reconnect.isRefusal(it) } == true) {
                        // one refusal a wait, however many connections it came to
                        if (busy.mayTry(now() / 1000.0)) busy.refused(now() / 1000.0)
                        lastRefusal = now()
                        if (channel == null) away.value = AwayTrouble.BUSY
                    }
                }
                if (failure?.kind == RemoteHandshakeError.Kind.NOT_PAIRED) refused = true
                if (channel === ch) lost() else if (relay && tried) relayEnded(mac, key)
            }
        }
        attempts += ch
        ch.start()
    }

    /** A relay connection ended with no session: the computer may be just coming back to its room (it has only now found the last session
     *  gone), so the next one comes soon, not at the next round. */
    private fun relayEnded(mac: PairedMac, key: ByteArray) {
        if (channel != null || !active || _current.value?.deviceID != mac.deviceID || (_state.value != State.CONNECTING && _state.value != State.UNREACHABLE)) return
        relayEnds += 1
        relayAgain?.let { main.removeCallbacks(it) }
        val r = Runnable { tryRelays(mac, key) }
        relayAgain = r
        main.postDelayed(r, Reconnect.relayAgainMs(relayEnds))
    }

    /** The computer's relay, and Blurt's go-between beside it when that relay is down: each unless one is already being tried. */
    private fun tryRelays(mac: PairedMac, key: ByteArray) {
        if (channel != null || !active || _current.value?.deviceID != mac.deviceID) return
        val address = RELAY_ONLY ?: mac.relayAddress ?: return
        if (attempts.none { it.relayAddress == address } && mayTryRelay(address)) tryRelay(address, mac, key)
        if (RELAY_ONLY == null && !RemoteRelay.isGoBetween(address) && relayFails >= 2 && now() - lastMeetTry > 4000 &&
            attempts.none { it.relayAddress == RemoteRelay.GO_BETWEEN } && mayTryRelay(RemoteRelay.GO_BETWEEN)) {
            lastMeetTry = now()
            tryRelay(RemoteRelay.GO_BETWEEN, mac, key)
        }
    }

    private fun tryRelay(address: String, mac: PairedMac, key: ByteArray) {
        val url = RemoteRelay.url(address, RemoteRelay.room(key), "phone") ?: return
        lastRelayTry = now()
        attempt(RelayTransport(url), relay = true, mac = mac, key = key, goBetween = RemoteRelay.isGoBetween(address), address = address)
    }

    private fun opened(ch: Channel) {
        val old = channel
        if (old != null) {
            // back on the local network: it takes over from the relay
            if (!old.isRelay || ch.isRelay) { ch.close(); return }
            channel = null
            old.close()
            stopPinging()
            // a key held over the change goes on: what's said meanwhile waits for the computer to listen again
            if (talkHeld) holdTake()
        }
        meeting.value = false
        hostLocked.value = false
        attempts.remove(ch)
        cancelAttempts()
        channel = ch
        // a refusal on the way was someone else's: what comes next may be a drop, and it must be come back from
        if (_state.value == State.FORGOTTEN) setState(State.CONNECTING)
        if (away.value == AwayTrouble.RELAY_DOWN) away.value = null
        setPath(when {
            ch.goBetween -> LinkPath.GO_BETWEEN
            ch.isRelay -> LinkPath.OWN_RELAY
            else -> {
                val at = ch.remoteAddress
                LinkPath.of(at?.hostAddress?.substringBefore('%') ?: ch.label.substringBeforeLast(':'), ch.discovered || (at != null && Addresses.onMyNetwork(c, at)),
                    throughVpn = ch.localAddress?.let { Addresses.throughVpn(c, it) } == true)
            }
        })
        firstAttempt = null
        refused = false
        lastPong = now()
        relayEnds = 0
        lastAway = ch.isRelay || path.value == LinkPath.TAILSCALE || path.value == LinkPath.OVERLAY
        // a computer that answers pings but never greets: not waited for
        sessionDue?.let { main.removeCallbacks(it) }
        val due = Runnable { if (channel === ch && _state.value != State.CONNECTED && joining == null) lost() }
        sessionDue = due
        main.postDelayed(due, Reconnect.sessionDueMs(ch.isRelay))
        // a code that keeps getting sessions which never come to a question is being tried for digits: give up on it
        if (joining != null) {
            joinOpens += 1
            if (joinOpens > 3) { ch.close(); return joinFailed(PairEnd.SPENT) }
        }
        ch.send(ToMac.Hello(deviceName(), Remote.mic.usable, ch.nonce, listOf(RemoteFeature.MOVE)))
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
        if (!keepRelay) relayAgain?.let { main.removeCallbacks(it) }
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
        // over the relay, one in four: every message counts against the free plan (once moved off the go-between, nothing goes through it)
        if (!relay || channel?.moved == true || pingCount % 4 == 0) send(ToMac.Ping(Net.now()))
        val mac = _current.value
        if (active && relay && attempts.isEmpty() && now() - lastLocalTry > 10_000 && mac != null) vault.read(mac.deviceID)?.let { tryLocal(mac, it); tryOverlay(mac, it) }
    }

    private fun lost() {
        stopPinging()
        val ch = channel
        channel = null
        ch?.close()
        meeting.value = false
        hostLocked.value = false
        // the talk key is still held: the microphone goes on, and what it hears waits for the session
        if (talkHeld && !parked) holdTake() else dropTake()
        Remote.screen.connectionLost()
        dictation.value = RemoteDictationPhase.IDLE
        sessionDue?.let { main.removeCallbacks(it) }
        // out of sight: nothing is started from here, coming back does that
        if (parked) return parkOver()
        // the computer let go while it was asking: its owner said no, or nobody answered in its two minutes
        if (waitingForMac.value) return joinFailed(PairEnd.of(askedAt, now()))
        if (_current.value == null || _state.value == State.FORGOTTEN || _state.value == State.REPLACED || _state.value == State.ENDED) return
        setState(State.CONNECTING)
        // over a relay the same network is looked for every 10 s: one of those tries may be running, and connect() starts no round beside one
        // (PR #118: the pad stayed at Reconnecting until the app was opened again)
        cancelAttempts(keepRelay = true)
        connect()
    }

    private fun disconnect() {
        stopPinging()
        sessionDue?.let { main.removeCallbacks(it) }
        cancelAttempts()
        val ch = channel
        channel = null
        ch?.close()
        meeting.value = false
        hostLocked.value = false
        dropTake()
        Remote.screen.connectionLost()
        unpark()      // another device took it, say: there's nothing left to keep
    }

    /** The session carries everything from here: connected. */
    private fun carrying() {
        sessionDue?.let { main.removeCallbacks(it) }
        meeting.value = false
        if (dev.blurt.remote.app.BuildConfig.DEBUG && cameBack > 0) {
            android.util.Log.i("Link", "connected ${android.os.SystemClock.uptimeMillis() - cameBack} ms after coming to the front, ${route.value}")
            cameBack = 0
        }
        setState(State.CONNECTED)
        // a new session: the computer has forgotten the last one's held keys, and stopped its picture
        if (parked) Remote.screen.pause() else Remote.screen.resume()
        send(ToMac.Mods(Remote.sticky.held))
        if (talkHeld) {
            if (Remote.mic.usable) {
                holdTake()
                Remote.mic.start()
            }
            downAt = now()
            send(ToMac.DictationKey(true))
        }
    }

    private fun heard(m: ToPhone) {
        when (m) {
            is ToPhone.Session -> {
                val i = m.info
                sessionDue?.let { main.removeCallbacks(it) }
                canControl.value = i.canControl
                // connected some other way, or the go-between is introducing: either way nothing to say about it now (noDirect may follow)
                if (channel?.goBetween != true) away.value = null
                channel?.allowMove(i.features?.contains(RemoteFeature.MOVE) == true)
                noteCandidates(i)
                pointerSeq = 0      // a new session: the computer has forgotten the last one's numbers too
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
                // one relay serves all of them: a computer with none of its own (or only the go-between) takes the one the others use
                if (i.relay == null || RemoteRelay.isGoBetween(i.relay))
                    _macs.value.mapNotNull { it.relayAddress }.firstOrNull { !RemoteRelay.isGoBetween(it) }?.let { send(ToMac.OfferRelay(it)) }
                val ch = channel
                if (ch != null && ch.goBetween && !ch.moved) {
                    // met, not connected: the keys light up and the picture starts once everything goes direct
                    meeting.value = true
                    setState(State.CONNECTING)
                    val due = Runnable { if (channel === ch && meeting.value) lost() }
                    sessionDue = due
                    main.postDelayed(due, Reconnect.MEETING_DUE_MS)
                } else carrying()
                if (ch?.isRelay == true) lookForDirect(i) else ch?.openUDP(i.udpPort, i.udpSession)
            }
            is ToPhone.CanControl -> canControl.value = m.on
            is ToPhone.Front -> front.value = m.front
            is ToPhone.Legends -> legends.value = m.legends
            is ToPhone.Dictation -> {
                dictation.value = m.phase
                if (m.phase == RemoteDictationPhase.LISTENING) heardTake()
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
            is ToPhone.Typed -> {}
            // the computer's own words for this user (a new device paired there)
            is ToPhone.Notice -> android.widget.Toast.makeText(c, m.text, android.widget.Toast.LENGTH_LONG).show()
            is ToPhone.Pong -> {
                lastPong = now()
                if (dev.blurt.remote.app.BuildConfig.DEBUG && cameBack > 0 && active && _state.value == State.CONNECTED) {
                    android.util.Log.i("Link", "kept, answered ${android.os.SystemClock.uptimeMillis() - cameBack} ms after coming to the front, ${route.value}")
                    cameBack = 0
                }
                rtt = Net.now() - m.t
                channel?.rttHint = rtt
            }
            // the host is about to close: this network won't let the two meet directly
            ToPhone.NoDirect -> noDirect()
            // Channel reads it off the old stream itself; one in the datagrams says nothing more
            ToPhone.StreamMoved -> {}
            ToPhone.UdpOK -> channel?.udpConfirmed()
            is ToPhone.Clock -> Remote.screen.clock(m.phone, m.mac)
            is ToPhone.ScreenFailed -> {
                if (Remote.screen.on && !Remote.screen.stale) pictureSeen = true
                Remote.screen.stop()
                screenError.value = m.text
            }
            is ToPhone.ScreenView -> {
                shownDisplay.value = m.display
                Remote.screen.source(m.width, m.height, m.codec, m.display, m.features)
            }
            is ToPhone.Displays -> displays.value = m.displays
            // a computer host sends its clipboard to computer viewers only; nothing for a phone to do
            is ToPhone.Clipboard -> {}
            is ToPhone.ScreenLocked -> hostLocked.value = m.locked
            is ToPhone.FileProgress, is ToPhone.FileSaved, is ToPhone.FileFailed -> {}     // a phone sends no files
            is ToPhone.CursorShape -> Remote.screen.shape(m.png, m.hotX, m.hotY, m.width, m.height)
            is ToPhone.Relay -> noteRelay(m.address)
            ToPhone.PairingWaits -> {
                pairCheck = channel?.check
                waitingForMac.value = true
                askedAt = now()
                // the computer asks now, whatever was said before (it may have turned up after "Can't reach"): the digits take its place
                pairFailed.value = null
                val d = joining?.mac?.deviceID
                main.postDelayed({ if (waitingForMac.value && joining?.mac?.deviceID == d) joinFailed(PairEnd.UNANSWERED) }, PairEnd.QUESTION_LIFE_MS)
            }
            is ToPhone.NewKey -> {
                val cur = _current.value ?: return
                vault.store(m.key, cur.deviceID)
                if (joining != null) {
                    joining = null
                    waitingForMac.value = false
                    askedAt = null
                    pairFailed.value = null
                    lastLink = ""
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
            // said in a session it had opened, so it's so: the key goes, and the list says Removed until it's paired again. A refused key
            // with no session (anyone on the network can send one) only says so, the key kept (`refused` → FORGOTTEN)
            ToPhone.Removed -> _current.value?.let { removedHere(it) }
            ToPhone.Replaced -> {
                setState(State.REPLACED)
                disconnect()
            }
            ToPhone.Ended -> {
                setState(State.ENDED)
                disconnect()
            }
        }
    }

    /** The computer's overlay addresses as it last listed them (a list that says nothing keeps the last one). */
    private fun noteCandidates(i: RemoteSessionInfo) {
        val list = i.candidates.map { it.host }.filter { RemoteOverlay.mayBeOverlay(it) }.distinct()
        val cur = _current.value ?: return
        if (list.isEmpty() || list == cur.candidates) return
        val n = _macs.value.indexOfFirst { it.id == cur.id }
        val r = cur.copy(candidates = list)
        setCurrent(r)
        if (n >= 0) {
            _macs.value = _macs.value.toMutableList().also { it[n] = r }
            saveMacs()
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

    /** Until the session carries everything (on the go-between, before the direct path is open), nothing that acts on the computer goes. */
    fun send(m: ToMac) {
        if (!ready && acts(m)) return
        channel?.send(m)
    }

    private fun acts(m: ToMac): Boolean = when (m) {
        is ToMac.Key -> m.down != false
        is ToMac.Mods -> m.mods != 0
        is ToMac.Button -> m.down
        is ToMac.DictationKey -> m.down
        is ToMac.Screen -> m.request != null
        is ToMac.Run, is ToMac.Text, is ToMac.Blurt, is ToMac.System, is ToMac.Activate, is ToMac.PointerTo, is ToMac.ShowDisplay, is ToMac.ScreenCrop,
        ToMac.DragBegin -> true
        else -> false
    }

    /** The talk key held while the session isn't up (it went under the thumb, or the app is just coming back): it starts dictation once the
     *  session opens, if it's still held, with what was said meanwhile (HeldAudio). Let go of before that, nothing of it goes, like any key. */
    @Volatile private var talkHeld = false
    private val heldAudio = HeldAudio()
    /** when the key went down on the computer, the last time it was pressed there for a key held here already */
    private var downAt = 0L
    private var upAt = 0L
    /** let go of while the computer had yet to say it listens: the key comes up there behind what was held */
    private var upWaits: Runnable? = null

    fun dictationKey(down: Boolean) {
        if (down) {
            upWaits?.let { main.removeCallbacks(it) }
            upWaits = null
            talkHeld = true
            heldAudio.hold(_state.value != State.CONNECTED)
            send(ToMac.DictationKey(true))
            return
        }
        if (!talkHeld) return       // ended already (micTaken)
        talkHeld = false
        if (_state.value != State.CONNECTED) return dropTake()
        if (heldAudio.holding) {
            Remote.mic.stop(dev.blurt.remote.app.talk.MicStream.Holder.TALK)
            upSoon(2000)
        } else keyUp()
    }

    private fun keyUp() {
        upAt = now()
        send(ToMac.DictationKey(false))
    }

    private fun upSoon(ms: Long) {
        upWaits?.let { main.removeCallbacks(it) }
        val r = Runnable {
            upWaits = null
            // it never listened: nothing to send
            if (heldAudio.holding) dropTake()
            keyUp()
        }
        upWaits = r
        main.postDelayed(r, ms)
    }

    /** The session went with the talk key held: the microphone goes on, what it hears is kept. */
    private fun holdTake() {
        if (!heldAudio.holding) heldAudio.hold(true)
        Remote.mic.stop(dev.blurt.remote.app.talk.MicStream.Holder.NOTE)
        Remote.mic.again()
    }

    private fun dropTake() {
        upWaits?.let { main.removeCallbacks(it) }
        upWaits = null
        heldAudio.hold(false)
        Remote.mic.stop()
    }

    /** The computer listens: what the microphone heard while the session was away goes first, in order. Let go of meanwhile, the key comes up
     *  behind it, and not so soon that the press looks like a tap (which would go on listening hands-free). */
    private fun heardTake() {
        heldAudio.release { channel?.sendAudio(it) }
        if (upWaits != null) upSoon(maxOf(0, downAt + 600 - now()))
    }

    /** This phone's microphone can't go on with the take: it ends there with what was said, held or hands-free. */
    private fun endTake() {
        // let go of just now: a take that was held is ending there already, and only a hands-free one goes on listening
        if (talkHeld) dictationKey(false) else if (now() - upAt < 1000) main.postDelayed({ tapIfListening() }, 700) else tapIfListening()
        Remote.mic.stop(dev.blurt.remote.app.talk.MicStream.Holder.TALK)
    }

    private fun tapIfListening() {
        if (!ready || talkHeld || dictation.value != RemoteDictationPhase.LISTENING) return
        send(ToMac.DictationKey(true))
        keyUp()
    }

    /** A call or another app has the microphone (MicStream): the take is finished there, and the phone says why it stopped. */
    fun micTaken() {
        endTake()
        android.widget.Toast.makeText(c, R.string.mic_taken, android.widget.Toast.LENGTH_LONG).show()
    }

    /** Words typed on the phone's keyboard, or pasted from it. With no session they're kept, not lost and not sent by themselves: by the time
     *  it's back they might land in another window. The pad asks. */
    fun type(t: String) {
        if (t.isEmpty()) return
        if (ready) sendText(t) else unsent.value = (unsent.value + t).takeLast(MOST_UNSENT)
    }

    /** In pieces, as a frame holds only so much. */
    private fun sendText(t: String) {
        var at = 0
        while (at < t.length) {
            var end = minOf(t.length, at + 4000)
            if (end < t.length && Character.isHighSurrogate(t[end - 1])) end -= 1
            send(ToMac.Text(t.substring(at, end)))
            at = end
        }
    }

    fun sendUnsent() {
        val t = unsent.value
        unsent.value = ""
        sendText(t)
    }

    fun dropUnsent() { unsent.value = "" }

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
    fun pointer(p0: RemotePointerPacket, inOrder: Boolean = false) {
        val p = if (p0 is RemotePointerPacket.Move) p0.copy(seq = nextPointerSeq()) else p0
        if (!ready) return
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
        pendingMove?.let { ch?.sendPointer(RemotePointerPacket.Move(it.first, it.second, pointerSeq)) }
        pendingScroll?.let { ch?.sendPointer(RemotePointerPacket.Scroll(it.first, it.second, RemoteScrollPhase.CHANGED)) }
        pendingMove = null
        pendingScroll = null
    }

    /** from the microphone's thread */
    fun audio(d: ByteArray) = heldAudio.add(d) { if (ready) channel?.sendAudio(it) }
    fun datagram(k: RemoteFrameKind, d: ByteArray) { channel?.sendDatagram(k, d) }
    val ready: Boolean get() = channel != null && _state.value == State.CONNECTED
    /** no session, but one is being looked for */
    val comingBack: Boolean get() = _current.value != null && (_state.value == State.CONNECTING || _state.value == State.UNREACHABLE)

    companion object {
        /** a test run: only this way in (debug builds) */
        val RELAY_ONLY: String? = null
        const val NO_DIRECT = false
        private const val PEEK_EVERY_MS = 30_000L
        private const val MOST_UNSENT = 4000
    }
}
