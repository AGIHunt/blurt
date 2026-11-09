// What the phone and the host say to each other once a session is up (Swift: RemoteMessages.swift; docs/design/remote-protocol.md §Messages).
// Control messages are JSON over the session's stream, in Swift's Codable shape (Json.kt). The pointer and scroll are small binary packets,
// over UDP while UDP works and over the stream otherwise, same bytes.
package dev.blurt.remote.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** One step of a key sequence, run on the host so its timing doesn't depend on the network (Esc Esc). */
sealed class RemoteStep {
    data class Key(val chord: RemoteChord) : RemoteStep()
    data class Text(val text: String) : RemoteStep()
    /** ms */
    data class Wait(val ms: Int) : RemoteStep()

    fun toJson(): JsonObject = when (this) {
        is Key -> J.case("key", "_0" to chord.toJson())
        is Text -> J.case("text", "_0" to J.str(text))
        is Wait -> J.case("wait", "_0" to J.int(ms))
    }

    companion object {
        fun fromJson(e: JsonElement?): RemoteStep? {
            val (name, o) = J.case(e) ?: return null
            return when (name) {
                "key" -> Key(RemoteChord.fromJson(o["_0"]) ?: return null)
                "text" -> Text(J.str(o, "_0") ?: return null)
                "wait" -> Wait(J.int(o, "_0") ?: return null)
                else -> null
            }
        }
    }
}

enum class RemoteMouseButton(val raw: Int) {
    LEFT(0), RIGHT(1), MIDDLE(2);

    companion object { fun from(raw: Int?): RemoteMouseButton? = entries.firstOrNull { it.raw == raw } }
}

/** Blurt's own commands: the same actions as the host's hotkeys, whatever keys the user gave them there. */
enum class RemoteBlurtCommand(val raw: String) {
    SNAP("snap"), RECORD("record"), VOICE_NOTE("voiceNote"), COPY_TEXT("copyText"), TRANSLATE("translate"), CARDS("cards"),
    DICTATION_CANCEL("dictationCancel"), DICTATION_STRUCTURED("dictationStructured"), DICTATION_TRANSLATE("dictationTranslate"),
    DICTATION_SEND("dictationSend");

    companion object { fun from(raw: String?): RemoteBlurtCommand? = entries.firstOrNull { it.raw == raw } }
}

/** A three- or four-finger swipe and the like, as named moves; each host maps them to its own. */
enum class RemoteSystemMove(val raw: String) {
    MISSION_CONTROL("missionControl"), APP_EXPOSE("appExpose"), SPACE_LEFT("spaceLeft"), SPACE_RIGHT("spaceRight"), ZOOM_IN("zoomIn"),
    ZOOM_OUT("zoomOut"), FIND_CURSOR("findCursor");

    companion object { fun from(raw: String?): RemoteSystemMove? = entries.firstOrNull { it.raw == raw } }
}

enum class RemoteDictationPhase(val raw: String) {
    IDLE("idle"), LISTENING("listening"), TRANSCRIBING("transcribing"), POLISHING("polishing"), UNAVAILABLE("unavailable");

    companion object { fun from(raw: String?): RemoteDictationPhase? = entries.firstOrNull { it.raw == raw } }
}

/** The app in front: a bundle id on a Mac, the exe name on Windows, the desktop file id (or WM class) on Linux. */
data class RemoteFront(val bundle: String, val name: String) {
    fun toJson(): JsonObject = J.obj("bundle" to J.str(bundle), "name" to J.str(name))

    companion object {
        fun fromJson(e: JsonElement?): RemoteFront? {
            val o = e as? JsonObject ?: return null
            return RemoteFront(J.str(o, "bundle") ?: return null, J.str(o, "name") ?: return null)
        }
    }
}

/**
 * One of the computer's displays: its frame in points in the desktop's own coordinates (top-left origin, y down, as the arrangement in the
 * computer's display settings), so the phone can draw the arrangement to scale.
 */
data class RemoteDisplay(
    /** stable while the display stays connected */
    val id: String,
    val name: String,
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
    /** the menu bar's / primary display */
    val main: Boolean,
) {
    fun toJson(): JsonObject = J.obj("id" to J.str(id), "name" to J.str(name), "x" to J.double(x), "y" to J.double(y), "width" to J.double(width),
        "height" to J.double(height), "main" to J.bool(main))

    companion object {
        fun fromJson(e: JsonElement?): RemoteDisplay? {
            val o = e as? JsonObject ?: return null
            return RemoteDisplay(J.str(o, "id") ?: return null, J.str(o, "name") ?: return null, J.double(o, "x") ?: return null,
                J.double(o, "y") ?: return null, J.double(o, "width") ?: return null, J.double(o, "height") ?: return null,
                J.bool(o, "main") ?: return null)
        }
    }
}

data class RemoteCandidate(val host: String, /** u16 */ val port: Int) {
    fun toJson(): JsonObject = J.obj("host" to J.str(host), "port" to J.int(port))

    companion object {
        fun fromJson(e: JsonElement?): RemoteCandidate? {
            val o = e as? JsonObject ?: return null
            return RemoteCandidate(J.str(o, "host") ?: return null, J.uint16(o, "port") ?: return null)
        }
    }
}

data class RemoteSessionInfo(
    /** the computer's name, whatever it is: the field keeps its name on the wire */
    val macName: String,
    /** u16 */
    val udpPort: Int,
    /** u32 */
    val udpSession: Long,
    /** false: the host can't press keys or move the pointer yet (Accessibility, Wayland's Remote Desktop, an elevated window) */
    val canControl: Boolean,
    val version: String,
    /** over the relay: where the host may be reached directly */
    val candidates: List<RemoteCandidate> = emptyList(),
    /** the main display, width ÷ height */
    val displayAspect: Double = 1.6,
    /** the relay the host's owner set up */
    val relay: String? = null,
    /** "mac", "windows" or "linux"; null from a Mac before 1.0.15 */
    val platform: String? = RemoteHost.MAC.raw,
) {
    val host: RemoteHost get() = RemoteHost.from(platform)

    fun toJson(): JsonObject = J.obj(
        "macName" to J.str(macName), "udpPort" to J.int(udpPort), "udpSession" to J.int(udpSession), "canControl" to J.bool(canControl),
        "version" to J.str(version), "candidates" to J.list(candidates) { it.toJson() }, "displayAspect" to J.double(displayAspect),
        "relay" to J.str(relay), "platform" to J.str(platform),
    )

    companion object {
        fun fromJson(e: JsonElement?): RemoteSessionInfo? {
            val o = e as? JsonObject ?: return null
            return RemoteSessionInfo(
                J.str(o, "macName") ?: return null, J.uint16(o, "udpPort") ?: return null, J.uint32(o, "udpSession") ?: return null,
                J.bool(o, "canControl") ?: return null, J.str(o, "version") ?: return null,
                J.list(o, "candidates") { RemoteCandidate.fromJson(it) } ?: return null, J.double(o, "displayAspect") ?: return null,
                J.str(o, "relay"), J.str(o, "platform"),
            )
        }
    }
}

/** Phone → host. */
sealed class ToMac {
    /** `down` null = press and release; true / false hold a key across messages (⌘ during ⌘Tab). */
    data class Key(val chord: RemoteChord, val down: Boolean? = null) : ToMac()
    /** the modifiers the phone holds right now (sticky keys), RemoteModifiers bits: they apply to clicks and scrolls too */
    data class Mods(val mods: Int) : ToMac()
    data class Run(val steps: List<RemoteStep>) : ToMac()
    data class Text(val text: String) : ToMac()
    data class Button(val button: RemoteMouseButton, val down: Boolean) : ToMac()
    /** the left button down for a drag: a click count of its own, so it isn't taken for a double click that selects words */
    data object DragBegin : ToMac()
    data class DictationKey(val down: Boolean) : ToMac()
    data class Blurt(val command: RemoteBlurtCommand) : ToMac()
    data class System(val move: RemoteSystemMove) : ToMac()
    /** Mac only */
    data class Activate(val bundle: String) : ToMac()
    /** a word on the host's screen, where the user is looking */
    data class Hud(val text: String) : ToMac()
    /** `nonce`: what the handshake's hello committed to (RemoteCrypto.check) */
    class Hello(val device: String, val micOnPhone: Boolean, val nonce: ByteArray? = null) : ToMac() {
        override fun equals(other: Any?): Boolean = other is Hello && other.device == device && other.micOnPhone == micOnPhone &&
            (other.nonce?.let { n -> nonce?.contentEquals(n) == true } ?: (nonce == null))

        override fun hashCode(): Int = device.hashCode() * 31 + (nonce?.contentHashCode() ?: 0)
        override fun toString(): String = "Hello(device=$device, micOnPhone=$micOnPhone, nonce=${nonce?.size})"
    }
    data class SetMicOnPhone(val on: Boolean) : ToMac()
    /** nothing held any more: the phone left the app or the screen locked */
    data object ReleaseAll : ToMac()
    /** `ToPhone.NewKey` is stored: this phone is paired */
    data object KeyStored : ToMac()
    /** show this, or stop showing (null) */
    data class Screen(val request: RemoteScreenRequest?) : ToMac()
    /** the part of the screen to send */
    data class ScreenCrop(val crop: RemoteCrop) : ToMac()
    /** the pointer to this place on the screen being shown, 0…1 */
    data class PointerTo(val x: Float, val y: Float) : ToMac()
    /** show this display (a RemoteDisplay id) from now on, the pointer in its middle; null: follow the pointer, the default. 1.0.15+ */
    data class ShowDisplay(val display: String?) : ToMac()
    /** the addresses this phone can be tried at, for a direct path */
    data class Candidates(val candidates: List<RemoteCandidate>) : ToMac()
    data object RequestKeyframe : ToMac()
    data class ScreenReport(val report: RemoteScreenReport) : ToMac()
    /** nobody is touching the phone: a few frames a second will do */
    data class ScreenPace(val idle: Boolean) : ToMac()
    /** this phone has dropped the host: the host drops it too */
    data object Unpair : ToMac()
    /** paired again: the old entry for this phone goes */
    data class Replaces(val deviceID: String) : ToMac()
    /** this host has no relay and the phone knows one, from another of its computers */
    data class OfferRelay(val address: String) : ToMac()
    /** measurements for the log (no screen content) */
    data class ScreenStats(val text: String) : ToMac()
    /** a test build's decoded frame */
    class ScreenSnapshot(val name: String, val jpeg: ByteArray) : ToMac() {
        override fun equals(other: Any?): Boolean = other is ScreenSnapshot && other.name == name && other.jpeg.contentEquals(jpeg)
        override fun hashCode(): Int = name.hashCode() * 31 + jpeg.contentHashCode()
        override fun toString(): String = "ScreenSnapshot(name=$name, ${jpeg.size} bytes)"
    }
    data class Ping(val t: Double) : ToMac()

    fun toJson(): JsonObject = when (this) {
        is Key -> J.case("key", "_0" to chord.toJson(), "down" to J.bool(down))
        is Mods -> J.case("mods", "_0" to J.int(mods))
        is Run -> J.case("run", "_0" to J.list(steps) { it.toJson() })
        is Text -> J.case("text", "_0" to J.str(text))
        is Button -> J.case("button", "_0" to J.int(button.raw), "down" to J.bool(down))
        DragBegin -> J.case("dragBegin")
        is DictationKey -> J.case("dictationKey", "down" to J.bool(down))
        is Blurt -> J.case("blurt", "_0" to J.str(command.raw))
        is System -> J.case("system", "_0" to J.str(move.raw))
        is Activate -> J.case("activate", "bundle" to J.str(bundle))
        is Hud -> J.case("hud", "_0" to J.str(text))
        is Hello -> J.case("hello", "device" to J.str(device), "micOnPhone" to J.bool(micOnPhone), "nonce" to J.data(nonce))
        is SetMicOnPhone -> J.case("setMicOnPhone", "_0" to J.bool(on))
        ReleaseAll -> J.case("releaseAll")
        KeyStored -> J.case("keyStored")
        is Screen -> J.case("screen", "_0" to request?.toJson())
        is ScreenCrop -> J.case("screenCrop", "_0" to crop.toJson())
        is PointerTo -> J.case("pointerTo", "x" to J.float(x), "y" to J.float(y))
        is ShowDisplay -> J.case("showDisplay", "_0" to J.str(display))
        is Candidates -> J.case("candidates", "_0" to J.list(candidates) { it.toJson() })
        RequestKeyframe -> J.case("requestKeyframe")
        is ScreenReport -> J.case("screenReport", "_0" to report.toJson())
        is ScreenPace -> J.case("screenPace", "idle" to J.bool(idle))
        Unpair -> J.case("unpair")
        is Replaces -> J.case("replaces", "deviceID" to J.str(deviceID))
        is OfferRelay -> J.case("offerRelay", "_0" to J.str(address))
        is ScreenStats -> J.case("screenStats", "_0" to J.str(text))
        is ScreenSnapshot -> J.case("screenSnapshot", "name" to J.str(name), "jpeg" to J.data(jpeg))
        is Ping -> J.case("ping", "_0" to J.double(t))
    }

    /** UTF-8 JSON, the body of a control frame (after its kind byte). */
    fun encode(): ByteArray = J.bytes(toJson())

    companion object {
        /** null: not JSON, not this shape, or a case this version doesn't know (a newer phone). */
        fun decode(bytes: ByteArray): ToMac? = fromJson(J.parse(bytes))

        fun fromJson(e: JsonElement?): ToMac? {
            val (name, o) = J.case(e) ?: return null
            return when (name) {
                "key" -> Key(RemoteChord.fromJson(o["_0"]) ?: return null, J.bool(o, "down"))
                "mods" -> Mods(J.int(o, "_0")?.takeIf { it in 0..255 } ?: return null)
                "run" -> Run(J.list(o, "_0") { RemoteStep.fromJson(it) } ?: return null)
                "text" -> Text(J.str(o, "_0") ?: return null)
                "button" -> Button(RemoteMouseButton.from(J.int(o, "_0")) ?: return null, J.bool(o, "down") ?: return null)
                "dragBegin" -> DragBegin
                "dictationKey" -> DictationKey(J.bool(o, "down") ?: return null)
                "blurt" -> Blurt(RemoteBlurtCommand.from(J.str(o, "_0")) ?: return null)
                "system" -> System(RemoteSystemMove.from(J.str(o, "_0")) ?: return null)
                "activate" -> Activate(J.str(o, "bundle") ?: return null)
                "hud" -> Hud(J.str(o, "_0") ?: return null)
                "hello" -> Hello(J.str(o, "device") ?: return null, J.bool(o, "micOnPhone") ?: return null,
                    if (J.has(o, "nonce")) J.data(o, "nonce") ?: return null else null)
                "setMicOnPhone" -> SetMicOnPhone(J.bool(o, "_0") ?: return null)
                "releaseAll" -> ReleaseAll
                "keyStored" -> KeyStored
                "screen" -> Screen(if (J.has(o, "_0")) RemoteScreenRequest.fromJson(o["_0"]) ?: return null else null)
                "screenCrop" -> ScreenCrop(RemoteCrop.fromJson(o["_0"]) ?: return null)
                "pointerTo" -> PointerTo(J.float(o, "x") ?: return null, J.float(o, "y") ?: return null)
                "showDisplay" -> ShowDisplay(if (J.has(o, "_0")) J.str(o, "_0") ?: return null else null)
                "candidates" -> Candidates(J.list(o, "_0") { RemoteCandidate.fromJson(it) } ?: return null)
                "requestKeyframe" -> RequestKeyframe
                "screenReport" -> ScreenReport(RemoteScreenReport.fromJson(o["_0"]) ?: return null)
                "screenPace" -> ScreenPace(J.bool(o, "idle") ?: return null)
                "unpair" -> Unpair
                "replaces" -> Replaces(J.str(o, "deviceID") ?: return null)
                "offerRelay" -> OfferRelay(J.str(o, "_0") ?: return null)
                "screenStats" -> ScreenStats(J.str(o, "_0") ?: return null)
                "screenSnapshot" -> ScreenSnapshot(J.str(o, "name") ?: return null, J.data(o, "jpeg") ?: return null)
                "ping" -> Ping(J.double(o, "_0") ?: return null)
                else -> null
            }
        }
    }
}

/** Host → phone. */
sealed class ToPhone {
    data class Session(val info: RemoteSessionInfo) : ToPhone()
    data class CanControl(val on: Boolean) : ToPhone()
    data class Front(val front: RemoteFront) : ToPhone()
    data class Dictation(val phase: RemoteDictationPhase) : ToPhone()
    /** the words so far: what's final, then the part still being said */
    data class Live(val committed: String, val pending: String) : ToPhone()
    /** the mic level, 0…1, while listening */
    data class Level(val level: Float) : ToPhone()
    /** what a take typed, once it landed */
    data class Typed(val text: String) : ToPhone()
    /** short message for the user, already localised on the host */
    data class Notice(val text: String) : ToPhone()
    data class Pong(val t: Double) : ToPhone()
    data object UdpOK : ToPhone()
    data object Removed : ToPhone()
    data class Relay(val address: String?) : ToPhone()
    /** another phone took over: don't reconnect until the user touches this one */
    data object Replaced : ToPhone()
    /** a code used over the relay: someone at the host has to say yes */
    data object PairingWaits : ToPhone()
    /** a voice note started from the phone wants the phone's microphone (true), or is over (false) */
    data class Listen(val on: Boolean) : ToPhone()
    /** first session after a scan: the QR code's key is spent, this one takes its place */
    class NewKey(val key: ByteArray) : ToPhone() {
        override fun equals(other: Any?): Boolean = other is NewKey && other.key.contentEquals(key)
        override fun hashCode(): Int = key.contentHashCode()
        override fun toString(): String = "NewKey(${key.size} bytes)"
    }
    /** the two clocks at one moment, so a frame's age can be read on the phone */
    data class Clock(val phone: Double, val mac: Double) : ToPhone()
    data class ScreenFailed(val text: String) : ToPhone()
    /** the source's size in points, the codec its frames are in ("hevc" when null), and which RemoteDisplay it is (null from older hosts) */
    data class ScreenView(val width: Double, val height: Double, val codec: String? = null, val display: String? = null) : ToPhone()
    /** every display the computer has, whenever that changes (and once a session is up); only from hosts that can show more than one. 1.0.15+ */
    data class Displays(val displays: List<RemoteDisplay>) : ToPhone()
    class CursorShape(val png: ByteArray, val hotX: Double, val hotY: Double, val width: Double, val height: Double) : ToPhone() {
        override fun equals(other: Any?): Boolean = other is CursorShape && other.png.contentEquals(png) && other.hotX == hotX && other.hotY == hotY &&
            other.width == width && other.height == height

        override fun hashCode(): Int = png.contentHashCode() * 31 + width.hashCode()
        override fun toString(): String = "CursorShape(${png.size} bytes, hot=$hotX,$hotY, $width×$height)"
    }

    fun toJson(): JsonObject = when (this) {
        is Session -> J.case("session", "_0" to info.toJson())
        is CanControl -> J.case("canControl", "_0" to J.bool(on))
        is Front -> J.case("front", "_0" to front.toJson())
        is Dictation -> J.case("dictation", "_0" to J.str(phase.raw))
        is Live -> J.case("live", "committed" to J.str(committed), "pending" to J.str(pending))
        is Level -> J.case("level", "_0" to J.float(level))
        is Typed -> J.case("typed", "_0" to J.str(text))
        is Notice -> J.case("notice", "_0" to J.str(text))
        is Pong -> J.case("pong", "_0" to J.double(t))
        UdpOK -> J.case("udpOK")
        Removed -> J.case("removed")
        is Relay -> J.case("relay", "_0" to J.str(address))
        Replaced -> J.case("replaced")
        PairingWaits -> J.case("pairingWaits")
        is Listen -> J.case("listen", "_0" to J.bool(on))
        is NewKey -> J.case("newKey", "_0" to J.data(key))
        is Clock -> J.case("clock", "phone" to J.double(phone), "mac" to J.double(mac))
        is ScreenFailed -> J.case("screenFailed", "_0" to J.str(text))
        is ScreenView -> J.case("screenView", "width" to J.double(width), "height" to J.double(height), "codec" to J.str(codec), "display" to J.str(display))
        is Displays -> J.case("displays", "_0" to J.list(displays) { it.toJson() })
        is CursorShape -> J.case("cursorShape", "png" to J.data(png), "hotX" to J.double(hotX), "hotY" to J.double(hotY), "width" to J.double(width),
            "height" to J.double(height))
    }

    fun encode(): ByteArray = J.bytes(toJson())

    companion object {
        /** null: not JSON, not this shape, or a case this version doesn't know (a newer host). */
        fun decode(bytes: ByteArray): ToPhone? = fromJson(J.parse(bytes))

        fun fromJson(e: JsonElement?): ToPhone? {
            val (name, o) = J.case(e) ?: return null
            return when (name) {
                "session" -> Session(RemoteSessionInfo.fromJson(o["_0"]) ?: return null)
                "canControl" -> CanControl(J.bool(o, "_0") ?: return null)
                "front" -> Front(RemoteFront.fromJson(o["_0"]) ?: return null)
                "dictation" -> Dictation(RemoteDictationPhase.from(J.str(o, "_0")) ?: return null)
                "live" -> Live(J.str(o, "committed") ?: return null, J.str(o, "pending") ?: return null)
                "level" -> Level(J.float(o, "_0") ?: return null)
                "typed" -> Typed(J.str(o, "_0") ?: return null)
                "notice" -> Notice(J.str(o, "_0") ?: return null)
                "pong" -> Pong(J.double(o, "_0") ?: return null)
                "udpOK" -> UdpOK
                "removed" -> Removed
                "relay" -> Relay(if (J.has(o, "_0")) J.str(o, "_0") ?: return null else null)
                "replaced" -> Replaced
                "pairingWaits" -> PairingWaits
                "listen" -> Listen(J.bool(o, "_0") ?: return null)
                "newKey" -> NewKey(J.data(o, "_0") ?: return null)
                "clock" -> Clock(J.double(o, "phone") ?: return null, J.double(o, "mac") ?: return null)
                "screenFailed" -> ScreenFailed(J.str(o, "_0") ?: return null)
                "screenView" -> ScreenView(J.double(o, "width") ?: return null, J.double(o, "height") ?: return null, J.str(o, "codec"), J.str(o, "display"))
                "displays" -> Displays(J.list(o, "_0") { RemoteDisplay.fromJson(it) } ?: return null)
                "cursorShape" -> CursorShape(J.data(o, "png") ?: return null, J.double(o, "hotX") ?: return null, J.double(o, "hotY") ?: return null,
                    J.double(o, "width") ?: return null, J.double(o, "height") ?: return null)
                else -> null
            }
        }
    }
}

/** A frame's first byte says what follows. */
enum class RemoteFrameKind(val raw: Int) {
    /** JSON */
    CONTROL(0),
    /** 16 kHz mono PCM16 little-endian */
    AUDIO(1),
    /** RemotePointerPacket */
    POINTER(2),
    /** RemoteVideoPacket: datagrams, or the relay's stream */
    VIDEO(3),
    /** 8 bytes the other side sends straight back, datagrams only */
    PROBE(4),
    /** RemoteCursor: x, y as f32 LE, 0…1 of the source; outside it, the pointer is elsewhere */
    CURSOR(5);

    companion object { fun from(raw: Int): RemoteFrameKind? = entries.firstOrNull { it.raw == raw } }
}

enum class RemoteScrollPhase(val raw: Int) {
    BEGAN(1), CHANGED(2), ENDED(3);

    companion object { fun from(raw: Int): RemoteScrollPhase? = entries.firstOrNull { it.raw == raw } }
}

/** The pointer and scroll, one packet per display frame at most: a type byte, then f32 LE values. */
sealed class RemotePointerPacket {
    /** points on the host, after the phone's acceleration */
    data class Move(val dx: Float, val dy: Float) : RemotePointerPacket()
    data class Scroll(val dx: Float, val dy: Float, val phase: RemoteScrollPhase) : RemotePointerPacket()
    /** the fingers left with this speed (points/s): the host coasts on from there */
    data class ScrollFling(val vx: Float, val vy: Float) : RemotePointerPacket()
    data object ScrollStop : RemotePointerPacket()

    fun encoded(): ByteArray {
        val b = ByteBuffer.allocate(10).order(ByteOrder.LITTLE_ENDIAN)
        when (this) {
            is Move -> b.put(0).putFloat(dx).putFloat(dy)
            is Scroll -> b.put(1).put(phase.raw.toByte()).putFloat(dx).putFloat(dy)
            is ScrollFling -> b.put(2).putFloat(vx).putFloat(vy)
            ScrollStop -> b.put(3)
        }
        return b.array().copyOf(b.position())
    }

    companion object {
        fun decode(d: ByteArray): RemotePointerPacket? {
            fun f(at: Int): Float? {
                if (d.size < at + 4) return null
                val r = ByteBuffer.wrap(d, at, 4).order(ByteOrder.LITTLE_ENDIAN).getFloat()
                return if (r.isFinite() && kotlin.math.abs(r) < 100_000) r else null
            }
            val t = d.firstOrNull()?.toInt() ?: return null
            return when (t) {
                0 -> Move(f(1) ?: return null, f(5) ?: return null)
                1 -> {
                    if (d.size < 2) return null
                    val p = RemoteScrollPhase.from(d[1].toInt() and 0xFF) ?: return null
                    Scroll(f(2) ?: return null, f(6) ?: return null, p)
                }
                2 -> ScrollFling(f(1) ?: return null, f(5) ?: return null)
                3 -> ScrollStop
                else -> null
            }
        }
    }
}

/** Kind 5: where the pointer is, x and y as f32 LE, 0…1 of the source being shown. */
object RemoteCursor {
    fun encode(x: Float, y: Float): ByteArray = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putFloat(x).putFloat(y).array()

    fun decode(d: ByteArray): Pair<Float, Float>? {
        if (d.size < 8) return null
        val b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN)
        val x = b.getFloat(0)
        val y = b.getFloat(4)
        return if (x.isFinite() && y.isFinite()) x to y else null
    }
}
