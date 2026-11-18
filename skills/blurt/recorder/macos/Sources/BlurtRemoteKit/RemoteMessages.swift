// What the iPhone and the Mac say to each other once a session is up (docs/design/remote.md §Protocol). Control messages are
// JSON over the session's TCP stream: they must arrive and they arrive in order. The pointer and scroll are small binary
// packets over UDP while UDP works, so a lost Wi-Fi frame costs one step of the cursor instead of holding everything
// behind it; with UDP blocked they go over TCP, same bytes.
import Foundation

/// One step of a key sequence, run on the Mac so its timing doesn't depend on the network (Esc Esc must land within
/// the app's double-press window however the Wi-Fi feels).
public enum RemoteStep: Codable, Hashable, Sendable {
    case key(RemoteChord)
    case text(String)
    case wait(Int)      // ms
}

public enum RemoteMouseButton: Int, Codable, Sendable { case left = 0, right = 1, middle = 2 }

/// Blurt's own commands: the same actions as the Mac's hotkeys, whatever keys the user gave them there.
public enum RemoteBlurtCommand: String, Codable, CaseIterable, Sendable {
    case snap, record, voiceNote, copyText, translate, cards
    case dictationCancel, dictationStructured, dictationTranslate, dictationSend
}

public enum ToMac: Codable, Sendable {
    /// `down` nil = press and release; true / false hold a key across messages (⌘ during ⌘Tab).
    case key(RemoteChord, down: Bool?)
    /// the modifiers the phone holds right now (sticky keys): they apply to clicks and scrolls too
    case mods(RemoteModifiers)
    case run([RemoteStep])
    case text(String)
    case button(RemoteMouseButton, down: Bool)
    /// the left button down for a drag: a click count of its own, so it isn't taken for a double click that selects words
    case dragBegin
    case dictationKey(down: Bool)
    case blurt(RemoteBlurtCommand)
    /// a three- or four-finger swipe and the like, as named system moves
    case system(RemoteSystemMove)
    case activate(bundle: String)
    /// a word on the Mac's screen, where the user is looking (the page the thumb just turned to)
    case hud(String)
    /// `nonce`: what the handshake's hello committed to (RemoteCrypto.check)
    case hello(device: String, micOnPhone: Bool, nonce: Data? = nil)
    case setMicOnPhone(Bool)
    /// nothing held any more: the phone left the app or the screen locked
    case releaseAll
    /// `ToPhone.newKey` is safe in the Keychain: this phone is paired
    case keyStored
    /// show this, or stop showing (nil)
    case screen(RemoteScreenRequest?)
    /// the part of the screen to send. It changes what's sent, not anything on the Mac.
    case screenCrop(RemoteCrop)
    /// the pointer to this place on the screen being shown, 0…1: the view moved away from it. `seq`: its number among this phone's
    /// pointer instructions (RemotePointerPacket.move), echoed in the cursor's place once made. 1.0.17+
    case pointerTo(x: Float, y: Float, seq: UInt32? = nil)
    /// show this display from now on, and put the pointer in its middle (nil: follow the pointer, the default). 1.0.15+
    case showDisplay(String?)
    /// the addresses this phone can be tried at, for a direct path
    case candidates([RemoteCandidate])
    case requestKeyframe
    /// what arrived lately: the Mac sends what the network can carry
    case screenReport(RemoteScreenReport)
    /// nobody is touching the phone: a few frames a second will do
    case screenPace(idle: Bool)
    /// this phone has dropped the Mac: the Mac drops it too
    case unpair
    /// paired again: the old entry for this phone goes
    case replaces(deviceID: String)
    /// this Mac has no relay and the phone knows one, from another of its Macs: one address serves them all
    case offerRelay(String)
    /// measurements for the log (no screen content)
    case screenStats(String)
    /// a test build's decoded frame, for judging sharpness
    case screenSnapshot(name: String, jpeg: Data)
    case ping(Double)
}

public enum RemoteSystemMove: String, Codable, Sendable {
    case missionControl, appExpose, spaceLeft, spaceRight, zoomIn, zoomOut, findCursor
}

public struct RemoteFront: Codable, Hashable, Sendable {
    public var bundle: String
    public var name: String
    public init(bundle: String, name: String) { self.bundle = bundle; self.name = name }
}

public enum RemoteDictationPhase: String, Codable, Sendable { case idle, listening, transcribing, polishing, unavailable }

public struct RemoteSessionInfo: Codable, Hashable, Sendable {
    public var macName: String
    public var udpPort: UInt16
    public var udpSession: UInt32
    /// false: macOS hasn't given Blurt Accessibility, so keys and the pointer do nothing yet
    public var canControl: Bool
    public var version: String
    /// over the relay: where the Mac may be reached directly
    public var candidates: [RemoteCandidate]
    /// the main display, width ÷ height: the pad takes this shape while the screen shows
    public var displayAspect: Double
    /// the relay the Mac's owner set up (Settings → Phone): the phone only tries one if there's an address here
    public var relay: String?
    /// what the computer is: "mac", "windows" or "linux" (nil from a Mac before 1.0.15). The phone's keys follow it: ⌘ on a Mac, Ctrl and
    /// the Windows key elsewhere (docs/design/remote-protocol.md §Hosts). `macName` stays the field's name on the wire, whatever the computer.
    public var platform: String?
    public init(macName: String, udpPort: UInt16, udpSession: UInt32, canControl: Bool, version: String, candidates: [RemoteCandidate] = [], displayAspect: Double = 1.6, relay: String? = nil, platform: String? = RemoteHost.mac.rawValue) {
        self.macName = macName; self.udpPort = udpPort; self.udpSession = udpSession; self.canControl = canControl; self.version = version
        self.candidates = candidates; self.displayAspect = displayAspect; self.relay = relay; self.platform = platform
    }
    public var host: RemoteHost { platform.flatMap(RemoteHost.init(rawValue:)) ?? .mac }
}

public enum ToPhone: Codable, Sendable {
    case session(RemoteSessionInfo)
    case canControl(Bool)
    case front(RemoteFront)
    case dictation(RemoteDictationPhase)
    /// the words so far: what's final, then the part still being said
    case live(committed: String, pending: String)
    /// the mic level, 0…1, while listening
    case level(Float)
    /// what a take typed, once it landed
    case typed(String)
    /// short message for the user, already localised on the Mac (a toast the island shows too)
    case notice(String)
    case pong(Double)
    case udpOK
    case removed
    case relay(String?)
    /// another phone took over: don't reconnect until the user touches this one
    case replaced
    /// a code used over the relay: someone at the Mac has to say yes
    case pairingWaits
    /// a voice note started from the phone wants the phone's microphone (true), or is over (false)
    case listen(Bool)
    /// first session after a scan: the QR code's key is spent, this one takes its place
    case newKey(Data)
    /// the two clocks at one moment, so a frame's age can be read on the phone
    case clock(phone: Double, mac: Double)
    case screenFailed(String)
    /// what's being shown: the source's size in points, and the codec its frames are in ("hevc" when nil, as from Macs before 1.0.15)
    /// `features`: the repairs this host uses for this stream, of those the phone offered in its request (RemoteVideoFeature); nil = none. 1.0.15+
    case screenView(width: Double, height: Double, codec: String? = nil, display: String? = nil, features: [String]? = nil)
    /// every display the computer has, whenever that changes (and once a session is up). Only sent by hosts that can show more than one. 1.0.15+
    case displays([RemoteDisplay])
    case cursorShape(png: Data, hotX: Double, hotY: Double, width: Double, height: Double)
}

/// A frame's first byte says what follows.
/// One of the computer's displays: its frame in points in the desktop's own coordinates (top-left origin, y down, as the
/// arrangement in the computer's display settings), so the phone can draw the arrangement and know which way is which.
public struct RemoteDisplay: Codable, Hashable, Sendable {
    /// stable while the display stays connected (CGDirectDisplayID / monitor device name / portal stream id)
    public var id: String
    public var name: String
    public var x: Double, y: Double, width: Double, height: Double
    /// the menu bar's / primary display
    public var main: Bool
    public init(id: String, name: String, x: Double, y: Double, width: Double, height: Double, main: Bool) {
        self.id = id; self.name = name; self.x = x; self.y = y; self.width = width; self.height = height; self.main = main
    }
}

/// The computer on the other end. Key names and RemoteModifiers mean the same on every host; each host maps them to its own keys:
/// command is ⌘ on a Mac and the Windows / Super key elsewhere, control is Ctrl, option is Alt (docs/design/remote-protocol.md §Hosts).
public enum RemoteHost: String, Codable, CaseIterable, Sendable {
    case mac, windows, linux
}

public enum RemoteFrameKind: UInt8, Sendable {
    case control = 0    // JSON
    case audio = 1      // 16 kHz mono PCM16 little-endian
    case pointer = 2    // RemotePointerPacket
    case video = 3      // RemoteVideoPacket, datagrams only
    case probe = 4      // 8 bytes the other side sends straight back, datagrams only
    case cursor = 5     // RemoteCursor: x, y as Float32 little-endian, 0…1 of the source; outside it, the pointer is elsewhere
    case videoFeedback = 6  // RemoteVideoFeedback, phone → host, datagrams only; only to a host that named a feature in screenView. 1.0.15+
}

/// The pointer and scroll, one packet per display frame at most.
public enum RemotePointerPacket: Equatable, Sendable {
    /// points on the Mac, after the phone's acceleration. `seq`: this phone's count of pointer instructions so far (moves and
    /// `ToMac.pointerTo` share it, from 1, wrapping), four more bytes after the two values; hosts before 1.0.17 read past them. A host that
    /// has seen one says how far it has got with every cursor place (RemoteCursor), so the phone knows which of its moves that place includes.
    case move(dx: Float, dy: Float, seq: UInt32? = nil)
    case scroll(dx: Float, dy: Float, phase: RemoteScrollPhase)
    /// the fingers left with this speed (points/s): the Mac coasts on from there
    case scrollFling(vx: Float, vy: Float)
    case scrollStop

    public func encoded() -> Data {
        var d = Data(capacity: 13)
        func f(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        switch self {
        case let .move(x, y, seq):
            d.append(0); f(x); f(y)
            if let seq { withUnsafeBytes(of: seq.littleEndian) { d.append(contentsOf: $0) } }
        case let .scroll(x, y, p): d.append(1); d.append(p.rawValue); f(x); f(y)
        case let .scrollFling(x, y): d.append(2); f(x); f(y)
        case .scrollStop: d.append(3)
        }
        return d
    }

    public init?(_ d: Data) {
        let b = [UInt8](d)
        func f(_ at: Int) -> Float? {
            guard b.count >= at + 4 else { return nil }
            let v = UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
            let r = Float(bitPattern: v)
            return r.isFinite && abs(r) < 100_000 ? r : nil
        }
        guard let t = b.first else { return nil }
        switch t {
        case 0:
            guard let x = f(1), let y = f(5) else { return nil }
            let seq = b.count >= 13 ? UInt32(b[9]) | UInt32(b[10]) << 8 | UInt32(b[11]) << 16 | UInt32(b[12]) << 24 : nil
            self = .move(dx: x, dy: y, seq: seq)
        case 1:
            guard b.count >= 2, let p = RemoteScrollPhase(rawValue: b[1]), let x = f(2), let y = f(6) else { return nil }
            self = .scroll(dx: x, dy: y, phase: p)
        case 2:
            guard let x = f(1), let y = f(5) else { return nil }
            self = .scrollFling(vx: x, vy: y)
        case 3: self = .scrollStop
        default: return nil
        }
    }
}

public enum RemoteScrollPhase: UInt8, Sendable { case began = 1, changed = 2, ended = 3 }

/// Where the host's pointer is (frame kind 5): x, y as f32 LE, 0…1 of the display shown. To a phone that numbers its pointer instructions,
/// four more bytes: the newest of them the host has made (u32 LE). A place whose number is behind the phone's own count doesn't include
/// its last moves yet, so the phone keeps showing its own guess instead of jumping back to it. Phones before 1.0.17 take 8 bytes only,
/// and are never sent 12: they send no numbers.
public struct RemoteCursor: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var seq: UInt32?
    public init(x: Float, y: Float, seq: UInt32? = nil) { self.x = x; self.y = y; self.seq = seq }

    public func encoded() -> Data {
        var d = Data(capacity: 12)
        for v in [x, y] { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        if let seq { withUnsafeBytes(of: seq.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    public init?(_ d: Data) {
        let b = [UInt8](d)
        guard b.count == 8 || b.count == 12 else { return nil }
        func u(_ at: Int) -> UInt32 { UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24 }
        x = Float(bitPattern: u(0)); y = Float(bitPattern: u(4))
        guard x.isFinite, y.isFinite else { return nil }
        seq = b.count == 12 ? u(8) : nil
    }

    /// `a` is `b` or later, counting round: the host has made everything up to `b`.
    public static func covers(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) >= 0 }

    /// How long the phone still keeps its own guess of the pointer before the host's last word replaces it; 0 or less: now.
    /// `host`: the number that word came with. `sent`: the phone's own count. `quiet`: seconds since the phone last moved the pointer.
    /// A word that includes everything sent counts at once. One that doesn't is the pointer before the last moves: taking it would jump
    /// the pointer back and then forward again, so it waits for the one that does, however late the network makes it. Only a move lost on
    /// the way never gets its number: after `max(0.5, 4 × rtt)` the host's word counts anyway (`lossless`, the relay's stream, where
    /// nothing is lost but much can queue: 3 s). A host that sends no numbers (before 1.0.17): `max(0.12, 1.5 × rtt)`, as it was.
    public static func wait(host: UInt32?, sent: UInt32, quiet: Double, rtt: Double, lossless: Bool) -> Double {
        guard let host else { return max(0.12, rtt * 1.5) - quiet }
        if covers(host, sent) { return 0 }
        return (lossless ? 3 : max(0.5, rtt * 4)) - quiet
    }
}
