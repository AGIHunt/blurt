# Blurt Remote for Android

2026-11-09. The Android phone as trackpad, keys, microphone and screen view for Blurt on a Mac, Windows or Linux computer. The product is
[remote.md](remote.md); the wire is [remote-protocol.md](remote-protocol.md). This page covers what is specific to Android.

## Core (`apps/android/core`)

A pure Kotlin/JVM library with no Android dependency. It holds the whole protocol and the phone's own logic, ported from the Swift reference
(`skills/blurt/recorder/macos/Sources/BlurtRemoteKit`, `apps/ios/BlurtRemote/Pad`, `Model/Deck.swift`). It is its own Gradle build
(`rootProject.name = "core"`, group `dev.blurt.remote`, package `dev.blurt.remote.core`, Kotlin 2.2, JVM toolchain 17). The app includes it with
`includeBuild("core")` and depends on `dev.blurt.remote:core`.

- **Dependencies:** kotlinx-serialization-json, used only at the `JsonElement` level. The Swift `Codable` shape is written by hand, so no
  generated serializers appear in the API. BouncyCastle `bcprov-jdk18on` provides X25519, HKDF-SHA256, ChaCha20-Poly1305, HMAC-SHA256 and
  SHA-256, because the platform's own XDH and ChaCha support is uneven before API 33. `java.util.Base64` needs API 26. OkHttp, sockets,
  `MediaCodec` and storage belong to the app: core has no `RemoteChannel`.
- **Run it:** `cd apps/android/core && JAVA_HOME=/opt/homebrew/opt/openjdk@17 gradle test` (system Gradle; core has no wrapper). The test
  task reads `tests/remote-vectors/vectors.json` by relative path (system property `blurt.vectors`).
- **Tests:**
  - every vector: each `toMac` / `toPhone` message decodes and re-encodes to an equal JSON value; the pointer, video and cursor bytes; and the
    whole handshake from the fixed private keys, byte for byte (public keys, shared secret, transcript, proof, both session keys, commitment,
    six digits, both hellos, the refusal, sealed and framed TCP frames both ways, sealed UDP packets), plus the relay room and the pairing URL
    round trip;
  - a loopback session (`PhoneHandshake` ↔ `MacHandshake` over in-memory frames) with the UDP replay window, reordering, and refusals;
  - `PadEngine`, `ViewPort` and `ScreenPlan` tests ported one for one from `PadEngineTests.swift`;
  - deck tests, run for every host.
- **Conventions:**
  - Swift `Data` → `ByteArray`. `UInt16` / `UInt8` fields → `Int`; `UInt32` → `Long`.
  - Enum constants are UPPER_SNAKE with `val raw` (the wire value) and `companion fun from(raw)`.
  - Valueless cases are `data object`. Classes that hold a `ByteArray` define `equals` by content.
  - Times are seconds (`Double`); pad positions are points (dp) as `Double`.
  - Readers never throw on bad input: they return `null`. The exceptions: `RemoteSealer.open`, `PhoneHandshake.finish` and
    `RemoteFrameReader.next`.
  - Hints, captions and section names in the deck are English; the app localises them, keyed by the exact English text.
- **Hosts:** `RemoteSessionInfo.host` picks the deck and the labels. `RemoteModifiers` bits mean the same everywhere; labels are ⌃⌥⇧⌘ on a
  Mac, `Win/Super+Ctrl+Alt+Shift` (joined with `+`) elsewhere. The defaults per host follow remote-protocol.md §Default keys per host.
  Where the spec leaves a choice:
  - Win+Tab (Task View) is a plain key, not a cycle.
  - The logo key alone is `RemoteChord(COMMAND, "")`, shown as Win / Super.
  - Ctrl+Shift+C shows "Ctrl ⇧C" (hint "Copy in Terminal").
  - 更多 on Windows: Win+D, Win+E, Win+L, Alt+F4, Ctrl+Shift+Esc, Win+Shift+S. On Linux: Super+D, Super+L, Alt+F4.
  - The key picker's PC chords use F5 for Reload, Alt+D for Address and Ctrl+PageUp/PageDown for the previous and next tab.
- **Displays** (1.0.15+, additive): the host sends `ToPhone.Displays` when it can show more than one, and `ScreenView.display` says which
  one a stream shows. The phone pins one with `ToMac.ShowDisplay(id)` or `RemoteScreenRequest.display`, and goes back to following the pointer
  with `null`. The switcher works as on iOS: it shows only with 2 or more displays, a tap cycles left to right, a hold opens a to-scale map
  of the arrangement with "Follow pointer", and nothing covers the picture.
- **Faces:** a face is `sf:<SF Symbol>` or `mark:<name>`, as on iOS; the app maps each to a Material Symbol.
  - Marks: `apps selectAll tabClose tabNew tabNext tabPrevious`.
  - Symbols used by the standard decks and catalogues: `arrow.clockwise arrow.left arrow.left.square arrow.left.to.line arrow.right
    arrow.right.square arrow.right.to.line arrow.up.and.down.and.arrow.left.and.right arrow.uturn.backward arrow.uturn.backward.square
    arrow.uturn.forward camera.viewfinder character.bubble checkmark.circle chevron.left chevron.left.square chevron.right
    chevron.right.square clipboard clock.arrow.circlepath command.square delete.left delete.left.fill delete.right doc.badge.gearshape
    doc.on.doc doc.text.magnifyingglass eraser folder gauge.with.dots.needle.33percent globe link lock macwindow.on.rectangle
    magnifyingglass menubar.dock.rectangle minus.magnifyingglass plus.magnifyingglass record.circle rectangle.3.group
    rectangle.bottomthird.inset.filled rectangle.grid.2x2 rectangle.stack return return.left scissors scissors.badge.ellipsis scope
    sidebar.left space square.2.layers.3d square.and.arrow.down terminal text.badge.checkmark text.bubble text.justify.left text.viewfinder
    waveform xmark.circle xmark.square`.
  - Fallbacks when a key has no glyph: `bird` for a Blurt command and `macwindow` for a system move.
  - The face picker offers `Deck.icons`.

### Public API (`dev.blurt.remote.core`)

```kotlin
// Keys
enum class RemoteHost(val raw: String) { MAC, WINDOWS, LINUX; companion { fun from(raw: String?): RemoteHost } }      // unknown/null → MAC
object RemoteModifiers {
    const val COMMAND = 1; const val SHIFT = 2; const val OPTION = 4; const val CONTROL = 8; const val FUNCTION = 16; const val NONE = 0
    fun contains(mods: Int, bit: Int): Boolean
    fun ordered(host: RemoteHost = MAC): List<Pair<Int, String>>
    fun label(bit: Int, host: RemoteHost = MAC): String                 // ⌘ / Win / Super, ⌥ / Alt, ⌃ / Ctrl, ⇧ / Shift
    fun glyphs(mods: Int, host: RemoteHost = MAC): String              // "⌃⇧" / "Ctrl+Shift"
}
class RemoteKey { val name: String; val code: Int; val glyph: String; fun label(host: RemoteHost = MAC): String
    companion { val all: List<RemoteKey>; fun named(name: String): RemoteKey? } }
data class RemoteChord(val mods: Int = 0, val key: String) { fun label(host: RemoteHost = MAC): String; val label: String
    fun toJson(): JsonObject; companion { fun fromJson(e: JsonElement?): RemoteChord? } }

// Messages (each type: toJson(): JsonObject, companion fromJson(JsonElement?): T?; ToMac/ToPhone also encode(): ByteArray, decode(ByteArray): T?)
sealed class RemoteStep { Key(chord) · Text(text) · Wait(ms: Int) }
enum class RemoteMouseButton(raw: Int) { LEFT, RIGHT, MIDDLE }
enum class RemoteBlurtCommand(raw: String) { SNAP, RECORD, VOICE_NOTE, COPY_TEXT, TRANSLATE, CARDS, DICTATION_CANCEL, DICTATION_STRUCTURED, DICTATION_TRANSLATE, DICTATION_SEND }
enum class RemoteSystemMove(raw: String) { MISSION_CONTROL, APP_EXPOSE, SPACE_LEFT, SPACE_RIGHT, ZOOM_IN, ZOOM_OUT, FIND_CURSOR }
enum class RemoteDictationPhase(raw: String) { IDLE, LISTENING, TRANSCRIBING, POLISHING, UNAVAILABLE }
data class RemoteFront(val bundle: String, val name: String)
data class RemoteCandidate(val host: String, val port: Int)
data class RemoteDisplay(val id: String, val name: String, val x: Double, val y: Double, val width: Double, val height: Double, val main: Boolean)
    // points, desktop coordinates: top-left origin, y down
data class RemoteSessionInfo(val macName: String, val udpPort: Int, val udpSession: Long, val canControl: Boolean, val version: String,
    val candidates: List<RemoteCandidate> = emptyList(), val displayAspect: Double = 1.6, val relay: String? = null,
    val platform: String? = "mac") { val host: RemoteHost }
sealed class ToMac {
    Key(chord: RemoteChord, down: Boolean? = null) · Mods(mods: Int) · Run(steps: List<RemoteStep>) · Text(text) · Button(button, down)
    DragBegin · DictationKey(down) · Blurt(command) · System(move) · Activate(bundle) · Hud(text)
    Hello(device: String, micOnPhone: Boolean, nonce: ByteArray? = null) · SetMicOnPhone(on) · ReleaseAll · KeyStored
    Screen(request: RemoteScreenRequest?) · ScreenCrop(crop) · PointerTo(x: Float, y: Float) · Candidates(candidates: List<RemoteCandidate>)
    ShowDisplay(display: String?) /* null = follow the pointer */
    RequestKeyframe · ScreenReport(report) · ScreenPace(idle) · Unpair · Replaces(deviceID) · OfferRelay(address) · ScreenStats(text)
    ScreenSnapshot(name, jpeg: ByteArray) · Ping(t: Double)
}
sealed class ToPhone {
    Session(info) · CanControl(on) · Front(front) · Dictation(phase) · Live(committed, pending) · Level(level: Float) · Typed(text)
    Notice(text) · Pong(t: Double) · UdpOK · Removed · Relay(address: String?) · Replaced · PairingWaits · Listen(on) · NewKey(key: ByteArray)
    Clock(phone: Double, mac: Double) · ScreenFailed(text) · ScreenView(width: Double, height: Double, codec: String? = null, display: String? = null,
        features: List<String>? = null /* repairs the host uses, 1.0.15+ */)
    Displays(displays: List<RemoteDisplay>)
    CursorShape(png: ByteArray, hotX: Double, hotY: Double, width: Double, height: Double)
}
enum class RemoteFrameKind(raw: Int) { CONTROL, AUDIO, POINTER, VIDEO, PROBE, CURSOR, VIDEO_FEEDBACK; companion { fun from(raw: Int): RemoteFrameKind? } }
enum class RemoteScrollPhase(raw: Int) { BEGAN, CHANGED, ENDED }
sealed class RemotePointerPacket { Move(dx, dy) · Scroll(dx, dy, phase) · ScrollFling(vx, vy) · ScrollStop
    fun encoded(): ByteArray; companion { fun decode(d: ByteArray): RemotePointerPacket? } }
object RemoteCursor { fun encode(x: Float, y: Float): ByteArray; fun decode(d: ByteArray): Pair<Float, Float>? }

// Video
data class RemoteCrop(val x: Float, val y: Float, val w: Float, val h: Float) { val valid: RemoteCrop
    companion { val WHOLE: RemoteCrop; fun centered(zoom: Float): RemoteCrop } }
object RemoteVideoCodec { const val HEVC = "hevc"; const val H264 = "h264"; val DECODABLE: List<String> }
data class RemoteScreenRequest(val target: String, val crop: RemoteCrop = WHOLE, val width: Int, val height: Int, val bitrate: Int,
    val fps: Int = 60, val codecs: List<String>? = RemoteVideoCodec.DECODABLE, val display: String? = null /* null = follow the pointer */,
    val features: List<String>? = null /* repairs offered: RemoteVideoFeature */)
data class RemoteScreenReport(val frames: Int, val lost: Int, val rtt: Double?, val received: Int)
class RemoteVideoPacket(val frame: Long, val index: Int, val count: Int, val keyframe: Boolean, val captured: Double, val payload: ByteArray,
    val refresh: Boolean = false, val ackRequested: Boolean = false) {     // byte 8: flags; index ≥ count: a parity piece
    val isParity: Boolean; val flags: Int; fun with(index: Int, payload: ByteArray): RemoteVideoPacket; fun encoded(): ByteArray
    companion { const val HEADER_SIZE = 17; const val PAYLOAD_SIZE = 1180; fun decode(d: ByteArray): RemoteVideoPacket?
        fun split(data: ByteArray, frame: Long, keyframe: Boolean, captured: Double, size: Int = PAYLOAD_SIZE, refresh: Boolean = false,
            ackRequested: Boolean = false): List<RemoteVideoPacket> } }
class RemoteVideoAssembler { class Frame(val data: ByteArray, val keyframe: Boolean, val captured: Double, val id: Long, val refresh: Boolean = false,
        val ackRequested: Boolean = false) { var firstAt: Double; var lastAt: Double }
    fun add(p: RemoteVideoPacket): Frame?; val waitingForKey: Boolean; val dropped: Int }
object RemoteVideoPayload { class Unpacked(val crop: RemoteCrop, val parameterSets: List<ByteArray>, val picture: ByteArray)
    fun pack(crop: RemoteCrop, parameterSets: List<ByteArray>, picture: ByteArray): ByteArray; fun unpack(d: ByteArray): Unpacked? }

// Repairs (RemoteVideoRepair.swift; remote-realtime.md)
object RemoteVideoFeature { const val NACK = "nack"; const val LTR = "ltr"; const val FEC = "fec"; val ALL: List<String> }
sealed class RemoteVideoFeedback { data class Missing(val frame: Long, val pieces: List<Int> /* empty = the whole frame */)
    Nack(missing: List<Missing>) · Ack(newest: Long, earlier: Long) · Lost(after: Long)
    fun encoded(): ByteArray; companion { const val MAX_SIZE = 1100; fun decode(b: ByteArray): RemoteVideoFeedback?; fun nacks(m: List<Missing>): List<RemoteVideoFeedback> } }
object RemoteVideoFEC { const val MAX_PARITY = 64; fun parity(pieces: List<RemoteVideoPacket>, group: Int): List<RemoteVideoPacket>
    fun recover(parity: ByteArray, slot: Int, count: Int, have: Map<Int, ByteArray>): Pair<Int, ByteArray>? }
class RemoteVideoHistory(val maxAge: Double = 1.0, val maxBytes: Int = 6_000_000) {     // the host's side
    fun add(id: Long, packets: List<ByteArray>, now: Double); fun pieces(id: Long, indices: List<Int>): List<ByteArray>; fun clear() }
class RemoteVideoReceiver(var nack: Boolean, var ltr: Boolean, now: Double = 0.0) {     // not thread-safe; times in seconds
    sealed class Output { Frame(frame) · Feedback(feedback) · Keyframe }
    var rtt: Double; val broken: Boolean; val patience: Double; val dropped: Int; val repaired: Int; val nacked: Int; val refreshes: Int
    fun add(p: RemoteVideoPacket, now: Double): List<Output>; fun tick(now: Double): List<Output>
    fun decoded(f: RemoteVideoAssembler.Frame, now: Double): List<Output>; fun decoderFailed(now: Double) }

// Crypto and framing
object RemoteCrypto {
    const val VERSION = 1
    fun random(n: Int): ByteArray; fun newKey(): ByteArray; fun newID(): String
    fun base64url(d: ByteArray): String; fun base64url(s: String): ByteArray?
    fun sha256(vararg parts: ByteArray): ByteArray; fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray
    fun transcript(id: String, phoneEph: ByteArray, macEph: ByteArray): ByteArray; fun check(transcript: ByteArray, nonce: ByteArray): String
    fun commitment(nonce: ByteArray): ByteArray; fun same(a: ByteArray, b: ByteArray): Boolean; fun proof(paired: ByteArray, transcript: ByteArray): ByteArray
    fun publicKey(privateKey: ByteArray): ByteArray; fun sharedSecret(privateKey: ByteArray, publicKey: ByteArray): ByteArray?
    fun sessionKeys(secret: ByteArray, paired: ByteArray, transcript: ByteArray): Pair<ByteArray, ByteArray>   // (toMac, toPhone)
}
class RemoteHandshakeError(val kind: Kind) : Exception { enum class Kind { NOT_PAIRED, BAD_PROOF, BAD_MESSAGE, VERSION } }
class RemoteFrameError : Exception
class PhoneHandshake(val id: String, paired: ByteArray, ephemeral: ByteArray = newKey(), val nonce: ByteArray = newKey()) {
    val publicKey: ByteArray; fun hello(): ByteArray; fun finish(reply: ByteArray): RemoteSealer   // throws RemoteHandshakeError
}
object MacHandshake { class Answer(val reply: ByteArray, val sealer: RemoteSealer?, val id: String?, val key: ByteArray?, val commitment: ByteArray?)
    fun answer(hello: ByteArray, ephemeral: ByteArray = newKey(), lookup: (String) -> ByteArray?): Answer }
class RemoteSealer(sendKey: ByteArray, receiveKey: ByteArray, val transcript: ByteArray = ByteArray(0)) {   // not thread-safe
    fun check(nonce: ByteArray): String
    fun seal(plain: ByteArray): ByteArray; fun open(frame: ByteArray): ByteArray                     // TCP; open throws
    fun sealPacket(plain: ByteArray, session: Long): ByteArray; fun openPacket(p: ByteArray): ByteArray?   // UDP; null = drop
    companion { fun sessionOfPacket(p: ByteArray): Long? }
}
class RemoteFrameReader { var limit: Int /* MAX_HELLO until the first sealed frame, then MAX_FRAME */
    fun feed(d: ByteArray); fun next(): ByteArray?   // throws RemoteFrameError
    companion { const val MAX_FRAME = 1 shl 20; const val MAX_HELLO = 1024; fun framed(d: ByteArray): ByteArray } }

// Pairing, relay, STUN
class RemotePairing(val macID: String, val deviceID: String, val key: ByteArray, val macName: String, val port: Int,
    val addresses: List<String>, val relay: String? = null) { val url: String
    companion { const val SERVICE_TYPE = "_blurt-remote._tcp"; const val SCHEME = "blurtremote"; fun parse(url: String): RemotePairing? } }
object RemoteRelay { const val PHONE_LEFT = 4000; const val MAC_GONE = 4001; const val REPLACED = 4002
    fun room(key: ByteArray): String; fun address(typed: String): String?; fun url(address: String, room: String, role: String): String? }
object RemoteSTUN { const val SERVER = "stun.cloudflare.com"; const val PORT = 3478
    fun newTransaction(): ByteArray; fun request(txn: ByteArray): ByteArray; fun parse(d: ByteArray, txn: ByteArray): RemoteCandidate? }

// Pointer
data class RemotePointerCurve(val slowGain: Float = 1f, val fastGain: Float = 5.5f, val slow: Float = 60f, val fast: Float = 900f) {
    fun scaled(s: Float): RemotePointerCurve; fun gain(speed: Float): Float; fun apply(dx: Float, dy: Float, dt: Float): Pair<Float, Float> }
class RemoteSubpixel { fun whole(dx: Float, dy: Float): Pair<Int, Int>; fun reset() }

// Pad (geometry in points, time in seconds)
data class PadPoint(val x: Double, val y: Double) { companion { val ZERO } }
data class PadSize(val width: Double, val height: Double)
data class PadRect(val x: Double, val y: Double, val width: Double, val height: Double) { minX maxX midX minY maxY midY isEmpty
    fun intersection(o: PadRect): PadRect; fun insetBy(dx: Double, dy: Double): PadRect; fun contains(p: PadPoint): Boolean; companion { val UNIT } }
data class PadTouch(val id: Int, val x: Double, val y: Double)
enum class PadHaptic { TAP, GRAB, RELEASE, STEP }
sealed class PadOutput { Move(dx: Float, dy: Float) · Click(button) · Button(button, down) · Scroll(dx: Float, dy: Float, phase) · Fling(vx: Float, vy: Float)
    ScrollStop · System(move) · Haptic(haptic) · View(scale: Double, dx: Double, dy: Double, at: PadPoint) · PointAt(point) · DragTo(point) · ViewEnd }
class PadEngine {
    fun began(ts: List<PadTouch>, now: Double): List<PadOutput>; fun moved(ts: List<PadTouch>, now: Double): List<PadOutput>
    fun ended(ids: List<Int>, now: Double): List<PadOutput>; fun tick(now: Double): List<PadOutput>; val needsTicks: Boolean; fun cancel(): List<PadOutput>
    var curve: RemotePointerCurve; var pinchZoomsView: Boolean; var touchMode: Boolean; var scrollEdge: ClosedFloatingPointRange<Double>?; var scrollGain: Double
    companion { SLOP = 6.0, TAP_TIME = 0.22, DOUBLE_WINDOW = 0.30, DOUBLE_REACH = 44.0, HOLD_TIME = 0.40, DRAG_GRACE = 0.45, HOLD_LIMIT = 1.2,
        COAST_TIME = 2.0, PINCH_STEP = 36.0, SWIPE_TRIP = 40.0, PINCH_RATIO = 0.14 }
}
class ViewPort { val zoom: Double; val rect: PadRect; val isWhole: Boolean; val visible: PadRect; val crop: RemoteCrop
    fun reshape(s: Double, alignY: Double); fun change(scale: Double, move: PadPoint, anchor: PadPoint); fun settle(); fun follow(p: PadPoint): Boolean
    companion { CLOSEST = 8.0, STRETCH = 0.8, SNAP = 1.08, MARGIN = 0.12 } }
enum class ScreenQuality(raw: String) { AUTO, SHARP, BALANCED, SAVER; val title: String; val detail: String; companion { fun from(raw: String?): ScreenQuality } }
enum class LinkRoute { LOCAL, DIRECT, RELAY }
data class ScreenPlan(val width: Int, val height: Int, val bitrate: Int, val fps: Int) {
    companion { operator fun invoke(q: ScreenQuality, route: LinkRoute, cellular: Boolean, lowData: Boolean /* Data Saver */, native: PadSize,
        panel: Int = 60 /* top refresh rate: at home fps = min(120, max(60, panel)) */): ScreenPlan } }

// Deck (immutable; editing returns a new Deck)
sealed class KeyAction { Chord(chord, cycle = false) · Sequence(steps) · Text(text, enter) · Arrows · Sticky(mods: Int) · NextTab · Blurt(command) · System(move) }
data class KeySlot(val id: String = newID(), val action: KeyAction, val glyph: String? = null, val caption: String? = null,
    val hint: String? = null, val span: Int? = null) {
    constructor(action: KeyAction, glyph: String? = null, caption: String? = null, hint: String? = null)
    fun keyName(host = MAC): String?; fun face(host = MAC): String; fun detail(host = MAC): String?; fun title(host = MAC): String
    companion { fun newID(): String } }
data class KeySection(val id: String = newID(), val name: String, val slots: List<KeySlot>, val columns: Int = Deck.COLUMNS) {
    constructor(name: String, slots: List<KeySlot>, columns: Int = Deck.COLUMNS) }
data class KeyGroup(val group: String, val slots: List<KeySlot>)
data class Deck(val dock: List<KeySlot>, val sections: List<KeySection>) {
    fun move(from: String, onto: String): Deck; fun replace(id: String, slot: KeySlot): Deck; fun remove(id: String): Deck
    fun add(slot: KeySlot, section: String, index: Int? = null): Deck; fun addSection(name: String): Deck
    fun renameSection(id: String, name: String): Deck; fun removeSection(id: String): Deck; fun toJson(): String
    companion { const val COLUMNS = 6; const val DOCK_COUNT = 9; const val MAX_SECTIONS = 6
        fun storeKey(host: RemoteHost): String; fun fromJson(json: String): Deck?; fun restore(json: String?, host: RemoteHost): Deck
        val spaceBar: KeySlot; fun standard(host: RemoteHost = MAC): Deck; fun catalogue(host: RemoteHost = MAC): List<KeyGroup>; val icons: List<String> }
}
```

## App (`apps/android/app`)

The phone, tablet and foldable app: a port of `apps/ios/BlurtRemote`'s behaviour, not its UIKit. Build and pair: [apps/android/README.md](../../apps/android/README.md).
AGP 9.5, Kotlin 2.2.20 (AGP's built-in Kotlin), minSdk 26, compile/target 36, Compose (Material 3) for the sheets only. No Google Play
Services, Firebase or ML Kit: QR codes are ZXing on CameraX frames, so it runs on phones sold in mainland China.

| Part | Files | What it does, and where it differs from the iPhone |
|---|---|---|
| Connection | `net/Link.kt`, `Channel.kt`, `Transport.kt`, `Discovery.kt`, `NetWatch.kt`, `KeyVault.kt` | Link.swift one for one: last addresses and DNS-SD (`NsdManager`, Android 14's `registerServiceInfoCallback`, one-at-a-time `resolveService` before) at once, the relay 1.2 s later (OkHttp WebSocket, wss:// or ws://), reconnect on resume with no prompt, keys dropped while disconnected, `releaseAll` on leaving. The channel (RemoteChannel.swift's phone side) runs on one `HandlerThread`, the only thread that touches the sealer. UDP is a `DatagramSocket` (DSCP EF) probed six times; over the relay one socket does STUN and the knocking, so what STUN saw is what the computer's packets meet. Paired keys: an AES-256-GCM key in the Android Keystore wraps each one in app-private prefs that backups leave out. |
| Main screen | `pad/PadScreen.kt`, `PadLayout.kt`, `Controls.kt` | Plain Views laid out by hand from PadLayout (dp = the iPhone's pt): phone portrait and landscape as on the iPhone; the cutout's end plays the Dynamic Island's part, with no cutout the end away from the thumb. One activity handles rotation, folding and resizing itself (`configChanges`), so none of them ends the session. Immersive with transient bars; the keys at the screen's sides get their edge strips back (`systemGestureExclusionRects`, lower 200 dp a side); orientation is locked while a finger is down; screen on while open, dimmed after 5 min. |
| Big screens | `PadLayout` modes `SPLIT`, `STACK` | Width ≥ 600 and height ≥ 480 dp: a large stage plus a 402 dp panel of the phone's keys, never stretched, with a trackpad of its own above them (beside the stage when wide, under it when tall). Foldables through Jetpack WindowManager: tabletop (fold across, half open) = picture above the fold, pad and keys below; book (fold down the middle) = picture on one half, pad and keys on the thumb's half; nothing is laid across the fold. |
| Pad | `pad/TrackpadView.kt` | Raw `MotionEvent`s into core's PadEngine in dp, `requestUnbufferedDispatch`, palms by touch major (88 dp) or `TOOL_TYPE_PALM`/`FLAG_CANCELED`. A mouse on a tablet: first click takes pointer capture; relative moves, buttons and wheel go across; a touch gives it back. |
| Keys | `keys/*` | KeyCell, KeyList, PageStrip, Sticky, TypeField as on the iPhone (fire on lift, cycle keys with 22 dp detents and edge stepping, the arrow key, repeats, 120 ms list-or-key). Faces: Material Symbols Rounded at weight 300 (`tools/symbols.py` cuts the font to the 107 the app uses, 22 KB), the six marks drawn on a Canvas. Deck strings are English in core and translated by `DeckText`. Hardware keyboards: every key down/up goes across under its own name (`HardwareKeys.kt`). |
| Screen | `pad/ScreenStream.kt`, `StageView.kt`, `CursorView.kt` | MediaCodec, asynchronous, hardware decoder first; `codecs` best first from MediaCodecList (hardware HEVC, hardware H.264, then software H.264 before software HEVC); `KEY_LOW_LATENCY` where the decoder has the feature, plus the vendors' own low-latency keys. Loss is repaired (core's `RemoteVideoReceiver`, ticked every 4 ms on the decode thread): nack and fec offered always, ltr on decoders that take a refresh (`takesRefresh`, `RefreshDecodeTest`); each decoded picture released at once, the newest of several; the panel's top rate asked for while frames come (`Surface.setFrameRate`, `preferredDisplayModeId`). Debug builds: a made-up network from launch extras (`TestWeather.kt`). Numbers: [remote-realtime.md](remote-realtime.md) §Android. Frames render into a SurfaceTexture drawn by a GLSurfaceView: each latched frame's timestamp says which crop it carries, and it is drawn there in the same pass, which is the iPhone's "crop and pixels in one commit". The last whole frame is kept in a texture as the backdrop. Corners are rounded 6 dp in the shader. |
| Talk | `talk/*` | AudioRecord, VOICE_RECOGNITION source, 16 kHz mono PCM16 in 100 ms pieces from key-down. The microphone permission is asked the first time the talk key is pressed. |
| Sheets | `sheets/*` | Compose over the main screen in the same window: Settings, pairing (CameraX + ZXing, or paste the link), the key editor (long-press drag; into the dock swaps), confirmation for links from outside. On a big screen a sheet is a 560 dp card. |

`apps/android/fakehost` is a fake computer for trying all of this without Blurt: core's MacHandshake, pairing with an automatic yes (or
`--ask`), every message logged, and with `--picture` a still image streamed through ffmpeg (H.264 or HEVC, whichever the phone asks for
first) so the screen view has something to show.
`--scroll` scrolls the picture 2 px a frame; it uses the nack and fec repairs a phone offers (`--no-repairs` for an older host, `--fec G`
to force parity) and answers a keyframe request by starting its encoder over; `--port` moves it off 47811/47812. `--two-displays` adds a second display; `PinchTest` (androidTest) does the two-finger pinch adb's input can't.

Decisions made here, beyond the iPhone's:

- **The cutout's end plays the Dynamic Island's part** in landscape; with no cutout the rarely-needed end is away from the thumb (Left-Handed
  flips it). Phone landscape needs 560 dp of width; a narrower window that is wider than tall (split screen) keeps the portrait block, its keys
  shrinking to 34 dp before the pad goes under 120 dp.
- **Big screens** (≥ 600 × 480 dp) never stretch keys: the panel is the iPhone's 402 dp. Wide = side by side, tall = stacked.
- **A fold decides at any hinge angle**: across the screen it stacks, down the middle it splits, whatever the posture reads; nothing is laid
  over the fold. Turning, folding and resizing are handled in the activity, so the session, held keys and zoom carry through, and the stream
  is asked for its new size.
- **Modifier faces** (⌃ ⌥ ⇧ ⌘) are Material Symbols, not text: Android's fallback glyphs for ⌃ and ⇧ are thin and small beside ⌘. A PC's
  modifier words share one size. Tabs shrink to 9 dp (the iPhone's 70 %), then show the current page with dots.
- **Mint stays "listening"**: the sheets use Blurt's teal (#1AA487), as the iPhone's do.
- **A display switcher** (core's `Displays`) sits beside Find Pointer only while the picture shows and there are two or more.
- **The screen's surface exists only while the picture shows**: a SurfaceView clears the glass under it.
- **Hardware keyboards** send every key down and up under its own name; Ctrl stays Ctrl on every host.

Measured 2026-11-09 on the Android 16 emulator (Pixel 9, Pixel Tablet, 7.6" foldable) against the fake host over the emulator's loopback:

| | |
|---|---|
| Back from the home screen to connected | 119–146 ms (549 ms the first time), five runs |
| Fake host restarted, to connected | by itself, no prompt |
| Talk key down to the first audio at the host | 114 ms (one 100 ms piece) |
| Pointer moves | over UDP once the probe got through, about 100 a second while the finger moved |
| Picture | HEVC (the emulator's codecs: hevc, h264), decoded and placed; occasional keyframe loss on loopback bursts, so the UDP receive buffer is 4 MB |
| Pinch on the picture | crop requests about every 150 ms (≈ 7/s) while it moves |
| Cold start, debug build | about 2.0 s to first frame; 0.35 s of it onCreate to onResume |

Not tried yet: a real phone (Wi-Fi, mobile data, a real relay, direct paths through NAT, hardware decoders and their low-latency keys),
a real camera reading a code, hardware keyboards and mice on a tablet, a cover screen (the AVD has one panel), TalkBack.
