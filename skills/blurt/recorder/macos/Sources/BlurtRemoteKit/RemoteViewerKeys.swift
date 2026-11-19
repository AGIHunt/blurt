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
        if q == .auto { tier = lowData ? .saver : local ? .sharp : .balanced }
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
