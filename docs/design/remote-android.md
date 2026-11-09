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
    Clock(phone: Double, mac: Double) · ScreenFailed(text) · ScreenView(width: Double, height: Double, codec: String? = null, display: String? = null)
    Displays(displays: List<RemoteDisplay>)
    CursorShape(png: ByteArray, hotX: Double, hotY: Double, width: Double, height: Double)
}
enum class RemoteFrameKind(raw: Int) { CONTROL, AUDIO, POINTER, VIDEO, PROBE, CURSOR; companion { fun from(raw: Int): RemoteFrameKind? } }
enum class RemoteScrollPhase(raw: Int) { BEGAN, CHANGED, ENDED }
sealed class RemotePointerPacket { Move(dx, dy) · Scroll(dx, dy, phase) · ScrollFling(vx, vy) · ScrollStop
    fun encoded(): ByteArray; companion { fun decode(d: ByteArray): RemotePointerPacket? } }
object RemoteCursor { fun encode(x: Float, y: Float): ByteArray; fun decode(d: ByteArray): Pair<Float, Float>? }

// Video
data class RemoteCrop(val x: Float, val y: Float, val w: Float, val h: Float) { val valid: RemoteCrop
    companion { val WHOLE: RemoteCrop; fun centered(zoom: Float): RemoteCrop } }
object RemoteVideoCodec { const val HEVC = "hevc"; const val H264 = "h264"; val DECODABLE: List<String> }
data class RemoteScreenRequest(val target: String, val crop: RemoteCrop = WHOLE, val width: Int, val height: Int, val bitrate: Int,
    val fps: Int = 60, val codecs: List<String>? = RemoteVideoCodec.DECODABLE, val display: String? = null /* null = follow the pointer */)
data class RemoteScreenReport(val frames: Int, val lost: Int, val rtt: Double?, val received: Int)
class RemoteVideoPacket(val frame: Long, val index: Int, val count: Int, val keyframe: Boolean, val captured: Double, val payload: ByteArray) {
    fun encoded(): ByteArray
    companion { const val HEADER_SIZE = 17; const val PAYLOAD_SIZE = 1180; fun decode(d: ByteArray): RemoteVideoPacket?
        fun split(data: ByteArray, frame: Long, keyframe: Boolean, captured: Double, size: Int = PAYLOAD_SIZE): List<RemoteVideoPacket> } }
class RemoteVideoAssembler { class Frame(val data: ByteArray, val keyframe: Boolean, val captured: Double, val id: Long)
    fun add(p: RemoteVideoPacket): Frame?; val waitingForKey: Boolean; val dropped: Int }
object RemoteVideoPayload { class Unpacked(val crop: RemoteCrop, val parameterSets: List<ByteArray>, val picture: ByteArray)
    fun pack(crop: RemoteCrop, parameterSets: List<ByteArray>, picture: ByteArray): ByteArray; fun unpack(d: ByteArray): Unpacked? }

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
    companion { operator fun invoke(q: ScreenQuality, route: LinkRoute, cellular: Boolean, lowData: Boolean /* Data Saver */, native: PadSize): ScreenPlan } }

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
