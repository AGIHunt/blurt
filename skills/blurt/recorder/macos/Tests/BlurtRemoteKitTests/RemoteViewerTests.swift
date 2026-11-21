// A computer driving another (docs/design/remote-desktop-viewer.md): its keys, the modifier swap between systems, the release chord, the
// clipboard's limit, the picture's size, and the wire's new parts as older peers read them.
import XCTest
@testable import BlurtRemoteKit

final class RemoteViewerTests: XCTestCase {
    func testMacKeyCodesHaveTheirNames() {
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 0), "A")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 8), "C")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 36), "Return")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 122), "F1")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 111), "F12")
        // a full keyboard's: F13–F20, the keypad, Help as Insert, Clear as Num Lock
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 105), "F13", "F13 before PrintScreen, which shares its code")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 80), "F19")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 90), "F20")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 82), "Keypad0")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 92), "Keypad9")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 76), "KeypadEnter")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 114), "Insert")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 71), "NumLock")
        XCTAssertEqual(RemoteViewerKeys.name(macKeyCode: 10), "IntlBackslash")
        // modifiers travel as `mods`, not as keys
        for code: UInt16 in [54, 55, 56, 58, 59, 60, 61, 62, 63] { XCTAssertNil(RemoteViewerKeys.name(macKeyCode: code), "\(code)") }
        // PC keys a Mac host presses as the keys in their place
        XCTAssertEqual(RemoteKey.named("PrintScreen")?.code, 105)
        XCTAssertEqual(RemoteKey.named("Pause")?.code, 113)
        // every name is one key, and every new one is known to the host's table
        XCTAssertEqual(Set(RemoteKey.all.map(\.name)).count, RemoteKey.all.count)
        for n in ["F13", "F14", "F15", "F16", "F17", "F18", "F19", "KeypadDecimal", "KeypadMultiply", "KeypadPlus", "KeypadMinus", "KeypadDivide", "KeypadEquals"] {
            XCTAssertNotNil(RemoteKey.named(n), n)
        }
    }

    func testModifiersAcrossSystems() {
        func m(_ v: RemoteModifiers, _ from: RemoteHost, _ to: RemoteHost, _ on: Bool = true) -> RemoteModifiers {
            RemoteViewerKeys.map(v, from: from, to: to, mapping: on)
        }
        // a Mac driving Windows or Linux: ⌘ as Ctrl, ⌃ as Win / Super, ⌥ stays Alt, ⇧ stays
        XCTAssertEqual(m(.command, .mac, .windows), .control)
        XCTAssertEqual(m(.control, .mac, .linux), .command)
        XCTAssertEqual(m([.command, .shift], .mac, .windows), [.control, .shift])
        XCTAssertEqual(m([.command, .control], .mac, .windows), [.command, .control])
        XCTAssertEqual(m(.option, .mac, .windows), .option)
        // Windows or Linux driving a Mac: Ctrl as ⌘, Win / Super as ⌃
        XCTAssertEqual(m(.control, .windows, .mac), .command)
        XCTAssertEqual(m(.command, .linux, .mac), .control)
        XCTAssertEqual(m([.control, .option], .windows, .mac), [.command, .option])
        // the same family, or the ⋯ menu's switch off: as pressed
        XCTAssertEqual(m(.command, .mac, .mac), .command)
        XCTAssertEqual(m(.control, .windows, .linux), .control)
        XCTAssertEqual(m(.command, .mac, .windows, false), .command)
    }

    func testTheReleaseChordIsTheTwoAlone() {
        var r = RemoteReleaseChord()
        XCTAssertFalse(r.modifiers(.control))
        XCTAssertFalse(r.modifiers([.control, .command]))
        XCTAssertTrue(r.modifiers(.command), "one of the two let go: released")
        XCTAssertFalse(r.modifiers([]))
        // ⌃⌘F is a shortcut for the host, not the release
        XCTAssertFalse(r.modifiers([.control, .command]))
        r.key()
        XCTAssertFalse(r.modifiers(.control))
        XCTAssertFalse(r.modifiers([]))
        // ⌃⌘⇧ isn't the chord
        XCTAssertFalse(r.modifiers([.control, .command]))
        XCTAssertFalse(r.modifiers([.control, .command, .shift]))
        XCTAssertFalse(r.modifiers([.control, .command]))
        r.key()
        XCTAssertFalse(r.modifiers([]))
        // Fn held along (a laptop's arrow keys) doesn't count
        XCTAssertFalse(r.modifiers([.control, .command, .function]))
        XCTAssertTrue(r.modifiers([]))
        // Windows and Linux: Ctrl+Alt
        var w = RemoteReleaseChord([.control, .option])
        XCTAssertFalse(w.modifiers([.control, .option]))
        XCTAssertTrue(w.modifiers([]))
    }

    func testTheReleaseChordSendsNothing() {
        // ⌃ down, ⌘ down, ⌘ up, ⌃ up (the dogfood run's R27: a Windows host saw Win, then Ctrl+Win, before the release)
        var h = RemoteHeldModifiers()
        XCTAssertEqual(h.modifiers(.control), .none)
        XCTAssertEqual(h.modifiers([.control, .command]), .none)
        XCTAssertEqual(h.modifiers(.control), .release)
        XCTAssertEqual(h.sent, [])
        // the other order, and Fn held along
        h = RemoteHeldModifiers()
        XCTAssertEqual(h.modifiers([.command, .function]), .none)
        XCTAssertEqual(h.modifiers([.command, .control, .function]), .none)
        XCTAssertEqual(h.modifiers([.control, .function]), .release)
    }

    func testShortcutsStillGetTheirModifiers() {
        // ⌘C: ⌘ waits, then goes before the C; letting go goes at once
        var h = RemoteHeldModifiers()
        XCTAssertEqual(h.modifiers(.command), .none)
        XCTAssertEqual(h.other(), [.command])
        XCTAssertEqual(h.modifiers([]), .send([[]]))
        // ⌃⌘F: both go before the F, and letting go after it isn't the release
        XCTAssertEqual(h.modifiers(.control), .none)
        XCTAssertEqual(h.modifiers([.control, .command]), .none)
        XCTAssertEqual(h.other(), [[.control, .command]])
        XCTAssertEqual(h.modifiers(.control), .send([.control]))
        XCTAssertEqual(h.modifiers([]), .send([[]]))
        // ⌘⇧: a modifier outside the chord sends at once
        XCTAssertEqual(h.modifiers(.command), .none)
        XCTAssertEqual(h.modifiers([.command, .shift]), .send([[.command, .shift]]))
        XCTAssertEqual(h.modifiers(.command), .send([.command]))
        XCTAssertEqual(h.modifiers([]), .send([[]]))
        // ⇧ alone and ⌥ alone go as they come
        XCTAssertEqual(h.modifiers(.shift), .send([.shift]))
        XCTAssertEqual(h.modifiers([]), .send([[]]))
        // ⌃ alone, tapped: the Windows key's tap (Start) still reaches the host
        XCTAssertEqual(h.modifiers(.control), .none)
        XCTAssertEqual(h.modifiers([]), .send([.control, []]))
        // ⌘-click: the click sends ⌘ first; a ⌃ added while ⌘ is down waits, and let go is still the release (the window then lets go of
        // the ⌘ the host has)
        XCTAssertEqual(h.modifiers(.command), .none)
        XCTAssertEqual(h.other(), [.command])
        XCTAssertEqual(h.other(), [])
        XCTAssertEqual(h.modifiers([.command, .control]), .none)
        XCTAssertEqual(h.modifiers(.command), .release)
        XCTAssertEqual(h.sent, .command)
    }

    func testTheClipboardsLimit() {
        XCTAssertTrue(RemoteClipboard.fits("a"))
        XCTAssertFalse(RemoteClipboard.fits(""))
        XCTAssertTrue(RemoteClipboard.fits(String(repeating: "a", count: 65_536)))
        XCTAssertFalse(RemoteClipboard.fits(String(repeating: "a", count: 65_537)))
        // counted in UTF-8 bytes, not characters: 21,846 three-byte characters are 65,538 bytes
        XCTAssertTrue(RemoteClipboard.fits(String(repeating: "字", count: 21_845)))
        XCTAssertFalse(RemoteClipboard.fits(String(repeating: "字", count: 21_846)))
    }

    func testTheWindowIsThePicturesCeiling() {
        let window = RemotePixelSize(width: 2400, height: 1350)
        // on the same network: Sharp at the window's own pixels, at the panel's rate
        let home = RemoteScreenPlan(.auto, local: true, window: window, panel: 120)
        XCTAssertEqual(home, RemoteScreenPlan(.sharp, local: true, window: window, panel: 120))
        XCTAssertEqual([home.width, home.height, home.bitrate, home.fps], [2400, 1350, 12_000_000, 120])
        // away: Balanced, the phone's rates for as many pixels, at most 2560 across
        let away = RemoteScreenPlan(.auto, local: false, window: window)
        XCTAssertEqual([away.width, away.height, away.fps], [2400, 1350, 30])
        XCTAssertEqual(away.bitrate, 6_545_454)
        let wide = RemoteScreenPlan(.balanced, local: false, window: RemotePixelSize(width: 5120, height: 2880))
        XCTAssertEqual([wide.width, wide.height, wide.bitrate], [2560, 1440, 7_447_272])
        let small = RemoteScreenPlan(.balanced, local: true, window: RemotePixelSize(width: 1000, height: 700))
        XCTAssertEqual([small.width, small.height, small.bitrate], [1000, 700, 4_000_000])
        // Data Saver: 1280 × 800 at most, 1 Mbps, 15 frames. Low Data Mode alone doesn't choose it: Auto stays Balanced away (a hotspot)
        let saver = RemoteScreenPlan(.saver, local: true, window: window)
        XCTAssertEqual([saver.width, saver.height, saver.bitrate, saver.fps], [1280, 720, 1_000_000, 15])
        XCTAssertEqual(RemoteScreenPlan(.auto, local: false, lowData: true, window: window), RemoteScreenPlan(.balanced, local: false, window: window))
        // Sharp away: the window, 8 Mbps, 30 frames
        let sharp = RemoteScreenPlan(.sharp, local: false, window: window)
        XCTAssertEqual([sharp.width, sharp.height, sharp.bitrate, sharp.fps], [2400, 1350, 8_000_000, 30])
        // odd sizes come out even, for the encoder
        XCTAssertEqual(RemoteScreenPlan(.sharp, local: true, window: RemotePixelSize(width: 1601, height: 901)).width, 1600)

        // the request carries the window, and the host fits the picture into the smaller of the two boxes
        let r = home.request(display: "1", features: ["nack"], window: window)
        XCTAssertEqual(r.window, window)
        XCTAssertEqual(r.box.width, 2400)
        var bigger = r
        bigger.width = 5000
        bigger.height = 3000
        XCTAssertEqual(bigger.box.width, 2400)
        XCTAssertEqual(bigger.box.height, 1350)
        // a phone's request has none, and its box is its own
        let phone = RemoteScreenRequest(target: "display", width: 2622, height: 1206, bitrate: 12_000_000)
        XCTAssertNil(phone.window)
        XCTAssertEqual(phone.box.width, 2622)
    }

    func testOlderPeersAndTheViewersMessages() throws {
        // a phone's request has no window key; a viewer's does
        let phone = try JSONEncoder().encode(ToMac.screen(RemoteScreenRequest(target: "display", width: 1, height: 1, bitrate: 1)))
        XCTAssertFalse(String(decoding: phone, as: UTF8.self).contains("window"))
        let old = Data(#"{"screen":{"_0":{"target":"display","crop":{"x":0,"y":0,"w":1,"h":1},"width":10,"height":10,"bitrate":1,"fps":1}}}"#.utf8)
        guard case let .screen(r)? = try? JSONDecoder().decode(ToMac.self, from: old) else { return XCTFail() }
        XCTAssertNil(r?.window)
        // the clipboard and the capture both ways decode; a peer before them drops the case
        guard case let .clipboard(t) = try JSONDecoder().decode(ToMac.self, from: Data(#"{"clipboard":{"_0":"x"}}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(t, "x")
        guard case let .keysCaptured(on) = try JSONDecoder().decode(ToMac.self, from: Data(#"{"keysCaptured":{"_0":true}}"#.utf8)) else { return XCTFail() }
        XCTAssertTrue(on)
        guard case let .clipboard(h) = try JSONDecoder().decode(ToPhone.self, from: Data(#"{"clipboard":{"_0":"y"}}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(h, "y")
        // nearby pairing: its own ids, one key everyone knows
        XCTAssertTrue(RemoteNearby.isNearby(RemoteNearby.newID()))
        XCTAssertFalse(RemoteNearby.isNearby("abc"))
        XCTAssertEqual(RemoteNearby.key.count, 32)
    }

    func testWhatAPublicServiceEndingSays() {
        typealias L = RemoteViewerLink
        XCTAssertEqual(L.away(refused: true, closeCode: nil, moved: false, heardNoDirect: false), .busy)
        XCTAssertEqual(L.away(refused: false, closeCode: nil, moved: false, heardNoDirect: true), .noDirect)
        // the budget ran out before the move: no direct path; after it, the session goes on over UDP and that's nothing
        XCTAssertEqual(L.away(refused: false, closeCode: RemoteRelay.overBudget, moved: false, heardNoDirect: false), .noDirect)
        XCTAssertNil(L.away(refused: false, closeCode: RemoteRelay.overBudget, moved: true, heardNoDirect: false))
        XCTAssertNil(L.away(refused: false, closeCode: 4000, moved: false, heardNoDirect: false))
        XCTAssertNil(L.away(refused: false, closeCode: nil, moved: false, heardNoDirect: false))
    }

    func testTheListsStates() {
        let now = Date()
        let service = RemoteComputer(id: "a", deviceID: "d", name: "Mini", port: 1, addresses: [], relayAddress: RemoteRelay.goBetween, lastSeen: now)
        let own = RemoteComputer(id: "b", deviceID: "d", name: "PC", port: 1, addresses: [], relayAddress: "wss://relay.example.com")
        let tail = RemoteComputer(id: "c", deviceID: "d", name: "Box", port: 1, addresses: ["100.101.102.103"])
        let none = RemoteComputer(id: "e", deviceID: "d", name: "Old", port: 1, addresses: ["192.168.1.2"], lastSeen: now)
        func row(_ c: RemoteComputer, connected: Bool = false, route: RemoteViewerLink.Route? = nil, nearby: Bool = false,
                 failed: RemoteViewerLink.Away? = nil) -> RemoteViewerRow {
            .of(c, connected: connected, route: route, nearby: nearby, failed: failed)
        }
        XCTAssertEqual(row(service), .available(.goBetween))
        // no direct path last time: said in the list until it connects, Try Again, or another network clears it
        XCTAssertEqual(row(service, failed: .noDirect), .noDirect)
        XCTAssertEqual(row(service, failed: .busy), .available(.goBetween))
        XCTAssertEqual(row(service, connected: true, route: .goBetween, failed: .noDirect), .connected(.goBetween))
        XCTAssertEqual(row(service, nearby: true, failed: .noDirect), .available(.local), "on the same network it doesn't need the service")
        XCTAssertEqual(row(own, failed: .noDirect), .available(.relay), "an own relay carries what the service can't")
        // its own relay down (2026-11-20, the office): said on the card; the service is tried meanwhile
        XCTAssertEqual(row(own, failed: .relayDown), .relayDown)
        XCTAssertEqual(row(own, nearby: true, failed: .relayDown), .available(.local))
        // what its relay says (peek): not waiting there is asleep (it said so) or offline, never "available"
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(RemoteViewerRow.of(own, connected: false, route: nil, nearby: false, failed: nil, presence: RemotePresence(host: false, asleep: t, seen: t)), .asleep(t))
        XCTAssertEqual(RemoteViewerRow.of(own, connected: false, route: nil, nearby: false, failed: nil, presence: RemotePresence(host: false, seen: t)), .offline(t))
        XCTAssertEqual(RemoteViewerRow.of(own, connected: false, route: nil, nearby: false, failed: nil, presence: RemotePresence(host: true)), .available(.relay))
        XCTAssertEqual(RemoteViewerRow.of(own, connected: false, route: nil, nearby: true, failed: nil, presence: RemotePresence(host: false, asleep: t)), .available(.local),
                       "on the same network it answers whatever the relay says")
        XCTAssertEqual(row(tail), .available(.tailscale))
        XCTAssertEqual(row(none), .offline(now))
    }

    func testTerminalsOnTheRemote() {
        XCTAssertTrue(RemoteTerminals.isTerminal("com.googlecode.iterm2"))
        XCTAssertTrue(RemoteTerminals.isTerminal("WindowsTerminal.exe"))
        XCTAssertTrue(RemoteTerminals.isTerminal("C:\\Windows\\System32\\cmd.exe"))
        XCTAssertTrue(RemoteTerminals.isTerminal("/usr/libexec/gnome-terminal-server"))
        XCTAssertFalse(RemoteTerminals.isTerminal("notepad.exe"))
        XCTAssertFalse(RemoteTerminals.isTerminal("com.apple.Safari"))
    }
}
