// A computer driving another (docs/design/remote-desktop-viewer.md): what its real keyboard means on the host, how big a picture to
// ask for, and how a viewer pairs with a computer it found on the same network. Nothing here touches a window or a socket.
import CryptoKit
import Foundation

public enum RemoteViewerKeys {
    /// A Mac key code (kVK_*) to its wire name; nil for a modifier (they travel as `mods`) or a key with no name.
    public static func name(macKeyCode code: UInt16) -> String? { RemoteKey.named(code: code)?.name }

    /// The modifiers held on the viewer's keyboard, as the host's keyboard has them. A Mac driving Windows or Linux sends ⌘ as Ctrl and ⌃
    /// as the Windows / Super key, ⌥ staying Alt; Windows or Linux driving a Mac the reverse: Ctrl as ⌘, the Windows / Super key as ⌃. On
    /// the wire both are the same swap of the command and control bits. `mapping` off (the ⋯ menu), or the same family: as pressed.
    public static func map(_ m: RemoteModifiers, from viewer: RemoteHost, to host: RemoteHost, mapping: Bool) -> RemoteModifiers {
        guard mapping, (viewer == .mac) != (host == .mac) else { return m }
        var out = m.subtracting([.command, .control])
        if m.contains(.command) { out.insert(.control) }
        if m.contains(.control) { out.insert(.command) }
        return out
    }
}

/// ⌃⌘ on a Mac viewer (Ctrl+Alt on Windows and Linux) gives the keyboard and mouse back: pressed together and let go with no other key in
/// between. So ⌃⌘F and ⌃⌘Q still reach the host; only the two alone release.
public struct RemoteReleaseChord: Sendable {
    public let chord: RemoteModifiers
    private var armed = false
    public init(_ chord: RemoteModifiers = [.control, .command]) { self.chord = chord }

    /// The modifiers changed: true when this is the release.
    public mutating func modifiers(_ m: RemoteModifiers) -> Bool {
        let held = m.subtracting(.function)
        if held == chord { armed = true; return false }
        if armed, held.isEmpty || chord.isSuperset(of: held) && held != chord {
            // one of the two let go first: the release, once the other goes too (or now, whichever comes first)
            armed = false
            return true
        }
        if !chord.isSuperset(of: held) { armed = false }
        return false
    }

    /// Any other key went down: whatever this was, it's a shortcut, not the release.
    public mutating func key() { armed = false }
}

/// What the host hears of the viewer's modifiers. A press of the release chord's keys alone (⌃, ⌘, or both) waits here: it may be the
/// release, which sends nothing, and a Windows host would otherwise see the Windows key and Ctrl+Windows go by each time the keys come
/// back. It goes once something says it's a shortcut: a key, a click or a scroll (`other`), or a modifier outside the chord. Let go
/// alone without becoming the chord, it goes as a tap (⌃ alone is the Windows key: Start). Letting go of keys the host has goes at once.
/// Modifiers as pressed here (Fn apart); the window maps them for the host.
public struct RemoteHeldModifiers: Sendable {
    public enum Change: Equatable, Sendable {
        /// nothing for the host now
        case none
        /// these, in order
        case send([RemoteModifiers])
        /// the release chord: the keys come back, and the host is sent nothing of it
        case release
    }

    private var chord: RemoteReleaseChord
    /// what the host was last sent
    public private(set) var sent: RemoteModifiers = []
    /// a press of the chord's keys not sent yet
    public private(set) var waiting: RemoteModifiers?

    public init(_ chord: RemoteReleaseChord = RemoteReleaseChord()) { self.chord = chord }

    public mutating func modifiers(_ m: RemoteModifiers) -> Change {
        let held = m.subtracting(.function)
        if chord.modifiers(m) { waiting = nil; return .release }
        if held.isEmpty {
            // a lone ⌃ or ⌘ let go: a tap for the host
            let tap = waiting.map { [$0] } ?? []
            waiting = nil
            return send(tap + [[]])
        }
        if chord.chord.isSuperset(of: held), !sent.isSuperset(of: held) {
            waiting = held
            return .none
        }
        waiting = nil
        return send([held])
    }

    /// A key, a click or a scroll: what waits goes first. Returns what to send before it.
    public mutating func other() -> [RemoteModifiers] {
        chord.key()
        guard let w = waiting else { return [] }
        waiting = nil
        sent = w
        return [w]
    }

    private mutating func send(_ list: [RemoteModifiers]) -> Change {
        var out: [RemoteModifiers] = []
        for m in list where m != (out.last ?? sent) { out.append(m) }
        guard let last = out.last else { return .none }
        sent = last
        return .send(out)
    }
}

/// How a viewer pairs with a computer it found on the same network, with no code to scan: a device id with this prefix and a key everyone
/// knows. The key buys nothing on its own: the host asks its owner for a yes, showing the six digits the viewer shows too, which only match
/// when no one sits between them (RemoteCrypto.check). Only on the host's own network listener, never over a relay.
public enum RemoteNearby {
    public static let idPrefix = "nearby-"
    public static let key = Data(SHA256.hash(data: Data("blurt-remote-nearby-1".utf8)))
    public static func isNearby(_ id: String) -> Bool { id.hasPrefix(idPrefix) }
    public static func newID() -> String { idPrefix + RemoteCrypto.newID() }
}

/// How much picture a viewer asks for: the same choice and the same rates as a phone's (apps/ios ScreenPlan), with the window as the
/// ceiling instead of a phone's screen. Auto is Sharp on the same network and Balanced away; Low Data Mode is Data Saver.
public enum RemoteScreenQuality: String, CaseIterable, Sendable {
    case auto, sharp, balanced, saver
}

public struct RemoteScreenPlan: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var bitrate: Int
    public var fps: Int

    /// `window`: the picture's place in pixels. `local`: the same network (an overlay network counts as away, as for a phone). `panel`: the
    /// display's top rate.
    public init(_ q: RemoteScreenQuality, local: Bool, lowData: Bool = false, window: RemotePixelSize, panel: Int = 60) {
        let w = max(64, window.width), h = max(64, window.height)
        func size(_ maxW: Int, _ maxH: Int) -> (Int, Int) {
            let k = min(1, Double(maxW) / Double(w), Double(maxH) / Double(h))
            return (Int(Double(w) * k) / 2 * 2, Int(Double(h) * k) / 2 * 2)
        }
        var tier = q
        // Auto follows the path, not Low Data Mode: on a phone's hotspot (which macOS marks Low Data) Data Saver's picture was too soft to
        // use, and UU Remote's wasn't (2026-11-20). The window says the hotspot costs data instead; Data Saver stays one click away.
        if q == .auto { tier = local ? .sharp : .balanced }
        switch tier {
        case .saver:
            (width, height) = size(1280, 800)
            bitrate = 1_000_000
            fps = 15
        case .sharp where local:
            (width, height) = (w / 2 * 2, h / 2 * 2)
            bitrate = 12_000_000
            fps = min(120, max(60, panel))
        case .sharp:
            (width, height) = (w / 2 * 2, h / 2 * 2)
            bitrate = 8_000_000
            fps = 30
        default:
            // as a phone's Balanced: 4 Mbps for 1800 × 1100, up to 8 for more pixels
            (width, height) = size(2560, 1600)
            bitrate = min(8_000_000, max(4_000_000, Int(Double(width * height) / (1800 * 1100) * 4_000_000)))
            fps = 30
        }
    }

    public func request(display: String?, features: [String]?, window: RemotePixelSize) -> RemoteScreenRequest {
        RemoteScreenRequest(target: "display", width: width, height: height, bitrate: bitrate, fps: fps, codecs: RemoteVideoCodec.decodable,
                            display: display, features: features, window: window)
    }
}

/// Terminals on the remote, by what its host reports as the app in front: a Mac's bundle id, Windows' and Linux's program name. A
/// take typed into one loses its closing full stop; ⌘C / ⌘V there are copy and paste (Ctrl+Shift+C / V), never an interrupt.
public enum RemoteTerminals {
    public static let ids: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                                   "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby"]
    public static let programs: Set<String> = ["windowsterminal", "cmd", "powershell", "pwsh", "conhost", "openconsole", "wezterm-gui", "alacritty",
                                        "kitty", "gnome-terminal-server", "gnome-terminal", "kgx", "ptyxis", "konsole", "xterm", "tilix",
                                        "terminator", "xfce4-terminal", "foot", "ghostty", "warp", "tabby", "hyper", "mintty"]
    public static func isTerminal(_ front: String) -> Bool {
        if ids.contains(front) { return true }
        var p = (front.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased()
        if p.hasSuffix(".exe") { p.removeLast(4) }
        return programs.contains(p)
    }
}

