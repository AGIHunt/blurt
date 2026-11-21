// Test builds only (BLURT_TEST_COMMANDS=1): the viewer's states for screenshots and scripted checks, and a pretend host in this process.
//
//   viewer fake [nodirect]       computers in every state (nodirect: Office PC couldn't connect directly)
//                                 (connected, available through the public connection service, offline) and one
//                                nearby, as if real: nothing saved, nothing connected
//   viewer list | add | settings the Computers window · its Add Computer sheet · Settings → 手机和电脑
//   viewer pairing [connecting|failed]   the Add Computer sheet showing six digits (or before they come, or after a no)
//   viewer fakehost PNG [windows|linux|mac] [nodirect|no|silent|late=S|removed=S|link|name=N]   a pretend host (nodirect: it says the direct
//                                path didn't open, as the public connection service's host does, then takes no more sessions); on 127.0.0.1 in this process,
//                                paired as a nearby computer is (its owner's yes comes by itself), whose screen is PNG encoded as H.264 and sent as a real
//                                host sends it. no: its owner says no · silent: nobody answers, and it gives up asking after two minutes, as RemoteServer
//                                does · late=S: it drops every connection for S seconds (not up yet) · removed=S: it removes this Mac S seconds into the
//                                session · link: not paired by itself; its port and id come as `viewer_host` for a link to it. It posts no input
//                                and captures nothing: what it is sent comes back as `viewer_host` events. Two displays, so the switcher shows.
//                                name=N: its name (one word; Office PC otherwise), e.g. name=Studio for a Mac host's screen (Tests/make_host_screen.swift)
//   viewer pair LINK|NAME        pair with a pasted blurtremote:// link, or the computer of that name found on this network
//   viewer rename page|list ID start|type TEXT|return|esc   a computer's name field on the page or in the Computers window
//   viewer open NAME             a paired computer's window · viewer quality auto|sharp|balanced|saver (for the next request)
//   viewer keys                  ⌘C (held, one repeat), F13, the keypad's Enter and ⌃⌘ alone into the front window, as captured
//   viewer point X Y             the pointer to X,Y (0…1 of the picture) and a click there
//   viewer displays [pin ID|follow] [hover ID|follow]   the front viewer window's display switcher (pinned to display ID or
//                                following the pointer first; the pointer over a display's tile and row, or the Follow row)
//   viewer capture on|off        Keys to Remote in the front viewer window
//   viewer mods STEP…            modifier changes and keys into the front window, as captured, 0.05 s apart: a step is the modifiers
//                                held (ctl+cmd, cmd, shift, none), kCODE (that key down and up) or click (a click where the pointer is)
//   viewer active on|off|real    as if Blurt came to the front or went behind (it never does in a test build: the user's keys stay theirs);
//                                real: NSApp.isActive again
//   viewer key                   the front viewer window counts as key (an app behind others has none; no activation)
//   viewer input ID              as if the user picked another input method (the test build's stand-in: the Mac's own is never touched)
//   viewer size W H              the front viewer window's content size, in points
//   viewer hint KEY              the picture's hint: release, release.app_only, no_control, file (a long file name being sent)
//   viewer state                 what the store and the windows say ("viewer_state")
//
// This Mac is only ever the viewer in these: no session here drives this Mac.
import AppKit
import BlurtCore
import BlurtRemoteKit
import CoreMedia
import Network
import VideoToolbox

enum ViewerTests {
    #if DEBUG || BLURT_TEST_HOOKS
    @MainActor static var fakeHost: ViewerFakeHost?
    #endif

    static func command(_ arg: String) {
        #if DEBUG || BLURT_TEST_HOOKS
        guard ViewerStore.testing else { return }
        MainActor.assumeIsolated {
            let a = arg.split(separator: " ").map(String.init)
            let store = ViewerStore.shared
            switch a.first ?? "state" {
            case "fake":
                let now = Date()
                let list = [RemoteComputer(id: "fake-studio", deviceID: "d1", name: "Studio", port: 1, addresses: [], platform: "mac", lastSeen: now),
                            RemoteComputer(id: "fake-office", deviceID: "d2", name: "Office PC", port: 1, addresses: [], relayAddress: RemoteRelay.goBetween,
                                           platform: "windows", lastSeen: now.addingTimeInterval(-3600)),
                            RemoteComputer(id: "fake-linux", deviceID: "d3", name: "ubuntu-dev", port: 1, addresses: [], platform: "linux",
                                           lastSeen: now.addingTimeInterval(-2 * 86400))]
                let nearby = [ViewerStore.Nearby(id: "fake-air", name: "MacBook Air", endpoint: .hostPort(host: "127.0.0.1", port: 1))]
                // `viewer fake nodirect`: Office PC's last try through the public connection service found no direct path
                store.testFake(computers: list, nearby: nearby, live: ["fake-studio": (.local, 0.004)], pairing: nil,
                               failed: a.count > 1 && a[1] == "nodirect" ? ["fake-office": .noDirect] : [:])
            case "pairing":
                // `viewer pairing connecting|failed`: the same card before the digits come, and after a no
                let step = a.count > 1 ? a[1] : "check"
                let p: ViewerStore.Pairing = switch step {
                case "connecting": .init(name: "MacBook Air")
                case "failed": .init(name: "MacBook Air", failed: T("viewer.add.refused", "MacBook Air"), canRetry: true)
                default: .init(name: "MacBook Air", check: "482713")
                }
                store.testFake(computers: store.computers, nearby: store.nearby, live: [:], pairing: p)
                ComputersWindowController.shared.show()
            case "pair":
                // a pasted pairing link (another network), or a computer found nearby by its name
                let rest = a.dropFirst().joined(separator: " ")
                if rest.hasPrefix(RemotePairing.scheme) { store.pair(link: rest) } else {
                    store.watch("test")
                    @MainActor func tryPair(_ n: Int) {
                        if let found = store.unpaired.first(where: { $0.name == rest }) { return store.pair(found) }
                        guard n > 0 else { return emit(["event": "viewer_pairing", "error": "not found", "nearby": store.nearby.map(\.name)]) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { tryPair(n - 1) } }
                    }
                    tryPair(20)
                }
            case "open":
                let name = a.dropFirst().joined(separator: " ")
                if let c = store.computers.first(where: { $0.name == name }) { store.open(c) }
            case "rename": RenameTests.post(a)      // = phonepage rename
            case "quality":
                Config.shared.set("record.viewer.quality", a.count > 1 && a[1] != "auto" ? a[1] : nil)
            case "list": ComputersWindowController.shared.show()
            case "add":
                ComputersWindowController.shared.show()
                NotificationCenter.default.post(name: .viewerAdd, object: nil)
            case "settings": SettingsController.shared.show(pane: "remote")
            case "fakehost":
                let png = a.count > 1 ? a[1] : ""
                guard let img = NSImage(contentsOfFile: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    return emit(["event": "viewer_host", "error": "no image"])
                }
                fakeHost?.stop()
                let opts = Array(a.dropFirst(3))
                func secs(_ k: String) -> Double? { opts.first { $0.hasPrefix(k + "=") }.flatMap { Double($0.dropFirst(k.count + 1)) } }
                let name = opts.first { $0.hasPrefix("name=") }.map { String($0.dropFirst(5)) } ?? "Office PC"
                let h = ViewerFakeHost(image: img, platform: a.count > 2 ? a[2] : "windows", name: name, noDirect: opts.contains("nodirect"),
                                       answer: opts.contains("no") ? .no : opts.contains("silent") ? .silent : .yes, late: secs("late"), removeAfter: secs("removed"))
                fakeHost = h
                h.start { port in
                    MainActor.assumeIsolated {
                        if opts.contains("link") { return emit(["event": "viewer_host", "port": Int(port), "id": h.id]) }
                        let n = ViewerStore.Nearby(id: h.id, name: name, endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
                        store.pair(n)
                    }
                }
            case "displays":
                // (no activation: a test build never comes in front of the user's apps, where it would take their keys)
                ViewerWindowController.front?.window?.orderFront(nil)
                ViewerWindowController.front?.testOpenDisplays(Array(a.dropFirst()))
            case "keys":
                // a keyboard's own sequence into the front window, as the capture hands it over: ⌘C, F13, the keypad's Enter, ⌃⌘ alone
                guard let w = ViewerWindowController.front else { break }
                w.setCaptured(true)
                typealias E = ViewerKeyboard.Event
                let cmd = CGEventFlags.maskCommand, ctl = CGEventFlags.maskControl
                let seq: [E] = [E(code: 55, down: true, repeating: false, flags: cmd, modifiersOnly: true),
                                E(code: 8, down: true, repeating: false, flags: cmd, modifiersOnly: false),
                                E(code: 8, down: true, repeating: true, flags: cmd, modifiersOnly: false),
                                E(code: 8, down: false, repeating: false, flags: cmd, modifiersOnly: false),
                                E(code: 55, down: false, repeating: false, flags: [], modifiersOnly: true),
                                E(code: 105, down: true, repeating: false, flags: [], modifiersOnly: false),
                                E(code: 105, down: false, repeating: false, flags: [], modifiersOnly: false),
                                E(code: 76, down: true, repeating: false, flags: [], modifiersOnly: false),
                                E(code: 76, down: false, repeating: false, flags: [], modifiersOnly: false),
                                E(code: 59, down: true, repeating: false, flags: ctl, modifiersOnly: true),
                                E(code: 55, down: true, repeating: false, flags: [ctl, cmd], modifiersOnly: true),
                                E(code: 55, down: false, repeating: false, flags: ctl, modifiersOnly: true),
                                E(code: 59, down: false, repeating: false, flags: [], modifiersOnly: true)]
                for (i, e) in seq.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) { MainActor.assumeIsolated { w.key(e) } } }
            case "point":
                // the pointer to x,y (0…1 of the picture) and a click there
                guard let w = ViewerWindowController.front, a.count > 2, let x = Float(a[1]), let y = Float(a[2]) else { break }
                w.link.pointerTo(x: x, y: y)
                w.beforeInput()
                w.link.send(.button(.left, down: true))
                w.link.send(.button(.left, down: false))
            case "capture":
                ViewerWindowController.front?.setCaptured(a.count > 1 && a[1] == "on")
            case "mods":
                guard let w = ViewerWindowController.front else { break }
                typealias E = ViewerKeyboard.Event
                let bits: [String: CGEventFlags] = ["ctl": .maskControl, "cmd": .maskCommand, "shift": .maskShift, "opt": .maskAlternate, "fn": .maskSecondaryFn]
                let codes: [(CGEventFlags, UInt16)] = [(.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59), (.maskSecondaryFn, 63)]
                var flags: CGEventFlags = []
                var steps: [() -> Void] = []
                for t in a.dropFirst() {
                    if t == "click" { steps.append { w.beforeInput(); w.link.send(.button(.left, down: true)); w.link.send(.button(.left, down: false)) }; continue }
                    if t.hasPrefix("k"), let code = UInt16(t.dropFirst()) {
                        let f = flags
                        steps.append { w.key(E(code: code, down: true, repeating: false, flags: f, modifiersOnly: false)) }
                        steps.append { w.key(E(code: code, down: false, repeating: false, flags: f, modifiersOnly: false)) }
                        continue
                    }
                    var next: CGEventFlags = []
                    for n in t.split(separator: "+") { if let b = bits[String(n)] { next.insert(b) } }
                    // one flagsChanged per key that changed, as a keyboard sends them
                    for (b, code) in codes where flags.contains(b) != next.contains(b) {
                        if next.contains(b) { flags.insert(b) } else { flags.remove(b) }
                        let f = flags, down = next.contains(b)
                        steps.append { w.key(E(code: code, down: down, repeating: false, flags: f, modifiersOnly: true)) }
                    }
                }
                for (i, step) in steps.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) { step() } }
            case "active":
                ViewerKeyboard.testActive = a.count > 1 && a[1] == "real" ? nil : a.count > 1 && a[1] == "on"
                ViewerWindowController.activeChanged()
            case "key":
                ViewerKeyboard.testKey = ViewerWindowController.front?.window
            case "input":
                let id = a.count > 1 ? a[1] : InputMethod.testPlain
                InputMethod.test = InputMethod.Source(id: id, plain: id.hasPrefix("com.apple.keylayout."))
            case "size":
                guard a.count > 2, let wd = Double(a[1]), let ht = Double(a[2]), let win = ViewerWindowController.front?.window else { break }
                win.setContentSize(NSSize(width: wd, height: ht))
            case "hint":
                ViewerWindowController.front?.testHint(a.count > 1 ? a[1] : "release.app_only")
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    emit(["event": "viewer_state", "computers": store.computers.map { [$0.name, ViewerStore.line(store.row($0)), $0.alias ?? ""] },
                          "nearby": store.nearby.map(\.name), "pairing": store.pairing?.check ?? NSNull(),
                          "active": ViewerKeyboard.appActive, "input": InputMethod.current()?.id ?? "",
                          "windows": NSApp.windows.compactMap { ($0.windowController as? ViewerWindowController).map { w in
                              ["title": w.window?.title ?? "", "subtitle": w.window?.subtitle ?? "", "captured": w.captured, "key": ViewerKeyboard.isKey(w.window),
                               "size": NSStringFromSize(w.window?.contentLayoutRect.size ?? .zero), "overlay": w.testOverlay, "hint": w.testHintState, "toolbar": w.testToolbar] } }])
                }
            }
        }
        #endif
    }
}

extension Notification.Name {
    /// Add Computer: the Computers window opens its sheet (ViewerStore.requestAdd, tests)
    static let viewerAdd = Notification.Name("blurt.viewer.add")
}

#if DEBUG || BLURT_TEST_HOOKS
/// A pretend host for the viewer's own end-to-end runs on this Mac: the wire as RemoteServer speaks it, a still picture for a screen, and a
/// log line for every input it would have made. Nothing is posted and nothing captured.
final class ViewerFakeHost {
    let id = "fake-host-" + RemoteCrypto.newID().prefix(6)
    private let q = DispatchQueue(label: "blurt.viewer.fakehost")
    private let tcp: NWListener
    private let udp: NWListener
    private let image: CGImage
    private let platform: String
    private let name: String
    /// as the public connection service on a network with no direct path: `noDirect` a second after the session, then no more sessions
    private let noDirect: Bool
    /// its owner's answer to the pairing question: yes, no, or none (the host gives up asking after two minutes, a bare close as a no)
    enum Answer { case yes, no, silent }
    private let answer: Answer
    /// connections dropped until then: a host not up yet
    private var deafUntil: Date?
    /// this Mac removed, that many seconds into its session
    private let removeAfter: Double?
    private var ended = false
    private var channel: RemoteChannel?
    private var pairedID: String?
    private var pairedKey: Data?
    private var newKey: Data?
    private var sending = false
    private var shown = "1"
    private var frameID: UInt32 = 0
    private var encoded: (sets: [Data], picture: Data)?
    private var encodedSize = (0, 0)
    private var saw = false

    init(image: CGImage, platform: String, name: String = "Office PC", noDirect: Bool = false, answer: Answer = .yes, late: Double? = nil, removeAfter: Double? = nil) {
        self.image = image
        self.platform = platform
        self.name = name
        self.noDirect = noDirect
        self.answer = answer
        self.deafUntil = late.map { Date().addingTimeInterval($0) }
        self.removeAfter = removeAfter
        tcp = try! NWListener(using: .tcp, on: .any)
        udp = try! NWListener(using: .udp, on: .any)
    }

    func start(_ ready: @escaping (UInt16) -> Void) {
        udp.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.q)
            self.receive(c)
        }
        udp.start(queue: q)
        tcp.newConnectionHandler = { [weak self] c in self?.wire(c) }
        tcp.stateUpdateHandler = { [weak self] s in
            guard case .ready = s, let p = self?.tcp.port?.rawValue else { return }
            DispatchQueue.main.async { ready(p) }
        }
        tcp.start(queue: q)
    }

    func stop() {
        sending = false
        channel?.close()
        tcp.cancel()
        udp.cancel()
    }

    private func note(_ s: String) { emit(["event": "viewer_host", "line": s]) }

    private func wire(_ c: NWConnection) {
        if ended { return c.cancel() }
        if let d = deafUntil, Date() < d { c.start(queue: q); note("dropped (late)"); return c.cancel() }
        let ch = RemoteChannel(connection: c, role: .mac(lookup: { [weak self] id in
            guard let self else { return nil }
            return id == self.pairedID ? self.pairedKey : RemoteNearby.isNearby(id) && self.pairedKey == nil ? RemoteNearby.key : nil
        }), queue: q)
        channel?.close()
        channel = ch
        saw = false
        var id = ""
        ch.onOpen = { id = $0 ?? "" }
        ch.onControl = { [weak self, weak ch] d in
            guard let self, let ch, let m = try? JSONDecoder().decode(ToMac.self, from: d) else { return }
            self.handle(m, ch, id: id)
        }
        ch.onPointer = { [weak self] p in self?.note("pointer \(p)") }
        ch.onProbe = { [weak ch] d in ch?.sendDatagram(.probe, d) }
        ch.onVideoFeedback = { _ in }
        ch.start()
    }

    private func handle(_ m: ToMac, _ ch: RemoteChannel, id: String) {
        switch m {
        case let .hello(device, _, nonce, features):
            note("hello \(device) \((features ?? []).joined(separator: ","))")
            if id == pairedID { return session(ch) }
            guard RemoteNearby.isNearby(id), let n = nonce, let check = ch.check(revealing: n) else { return ch.close() }
            note("asks \(check)")
            ch.send(ToPhone.pairingWaits)
            switch answer {
            case .no:
                q.asyncAfter(deadline: .now() + 2) { self.note("owner said no"); ch.close() }
                return
            case .silent:
                q.asyncAfter(deadline: .now() + 120) { self.note("nobody answered"); ch.close() }
                return
            case .yes: break
            }
            let k = RemoteCrypto.newKey()
            newKey = k
            pairedID = id
            // the owner's yes, a moment later
            q.asyncAfter(deadline: .now() + 1.5) { ch.send(ToPhone.newKey(k)) }
        case .keyStored:
            pairedKey = newKey
            session(ch)
        case let .screen(r):
            guard let r else { sending = false; note("screen off"); return }
            note("screen \(r.width)x\(r.height) window \(r.window.map { "\($0.width)x\($0.height)" } ?? "-") \(r.bitrate / 1000) kbps \(r.fps) fps")
            let box = r.box
            let k = min(Double(box.width) / Double(image.width), Double(box.height) / Double(image.height), 1)
            let size = (Int(Double(image.width) * k) / 2 * 2, Int(Double(image.height) * k) / 2 * 2)
            if encoded == nil || encodedSize != size { encoded = Self.encode(image, width: size.0, height: size.1); encodedSize = size }
            ch.send(ToPhone.screenView(width: Double(image.width) / 2, height: Double(image.height) / 2, codec: RemoteVideoCodec.h264, display: shown))
            if !sending { sending = true; frames(ch) }
        case let .showDisplay(d):
            shown = d ?? "1"
            note("showDisplay \(d ?? "follow")")
            ch.send(ToPhone.screenView(width: Double(image.width) / 2, height: Double(image.height) / 2, codec: RemoteVideoCodec.h264, display: shown))
        case let .key(c, down): note("key \(c.key) \(down.map { $0 ? "down" : "up" } ?? "tap")")
        case let .mods(mm): note("mods \(RemoteHost(rawValue: platform)?.label(mm) ?? "")")
        case let .button(b, down): note("button \(b) \(down ? "down" : "up")")
        case let .pointerTo(x, y, seq):
            ch.sendDatagram(.cursor, RemoteCursor(x: x, y: y, seq: seq).encoded())
        case let .keysCaptured(on):
            note("captured \(on)")
            if on { q.asyncAfter(deadline: .now() + 0.2) { ch.send(ToPhone.clipboard("text copied on the host")) } }
        case let .clipboard(t): note("clipboard \(t.utf8.count) bytes")
        case let .ping(t): ch.send(ToPhone.pong(t))
        case .releaseAll: note("releaseAll")
        default: break
        }
    }

    private func session(_ ch: RemoteChannel) {
        if noDirect {
            ch.send(ToPhone.session(RemoteSessionInfo(macName: name, udpPort: 9, udpSession: 9, canControl: true, version: "test",
                                                      relay: RemoteRelay.goBetween, platform: platform, features: [RemoteFeature.move, RemoteFeature.viewer])))
            q.asyncAfter(deadline: .now() + 1) {
                self.note("noDirect")
                self.ended = true
                ch.send(ToPhone.noDirect)
                self.q.asyncAfter(deadline: .now() + 0.3) { ch.close() }
            }
            return
        }
        ch.send(ToPhone.session(RemoteSessionInfo(macName: name, udpPort: udp.port?.rawValue ?? 0, udpSession: 9, canControl: true, version: "test",
                                                  candidates: [RemoteCandidate(host: "127.0.0.1", port: udp.port?.rawValue ?? 0)],
                                                  displayAspect: Double(image.width) / Double(image.height), platform: platform,
                                                  features: [RemoteFeature.move, RemoteFeature.viewer])))
        let w = Double(image.width) / 2, h = Double(image.height) / 2
        ch.send(ToPhone.displays([RemoteDisplay(id: "1", name: "DELL U2723QE", x: 0, y: 0, width: w, height: h, main: true),
                                  RemoteDisplay(id: "2", name: "Built-in Display", x: w, y: h * 0.3, width: w * 0.8, height: h * 0.8, main: false)]))
        if let r = removeAfter {
            q.asyncAfter(deadline: .now() + r) {
                // its owner's Remove: forgotten here, then told; the old key opens nothing after
                self.note("removed")
                self.pairedID = nil
                self.pairedKey = nil
                self.sending = false
                ch.send(ToPhone.removed)
                self.q.asyncAfter(deadline: .now() + 0.3) { ch.close() }
            }
        }
    }

    /// The still picture as a keyframe, sent again twice a second (a real host sends a still screen once, then sharpens it).
    private func frames(_ ch: RemoteChannel) {
        guard sending, let e = encoded else { return }
        frameID &+= 1
        let payload = RemoteVideoPayload.pack(crop: .whole, parameterSets: e.sets, picture: e.picture)
        for p in RemoteVideoPacket.split(payload, frame: frameID, keyframe: true, captured: CACurrentMediaTime()) { ch.sendDatagram(.video, p.encoded()) }
        q.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.frames(ch) }
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self, err == nil, let data, let ch = self.channel else { return }
            self.q.async {
                guard ch.packet(data) else { return }
                ch.useFlow(c)
                if !self.saw { self.saw = true; ch.send(ToPhone.udpOK) }
            }
            self.receive(c)
        }
    }

    /// One H.264 keyframe of the image: its parameter sets and its NAL units with 4-byte lengths, as a host sends them.
    static func encode(_ img: CGImage, width: Int, height: Int) -> (sets: [Data], picture: Data)? {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                         compressionSessionOut: &session) == noErr, let session else { return nil }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 20_000_000 as CFNumber)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.interpolationQuality = .high
        ctx?.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pb, [])
        var out: (sets: [Data], picture: Data)?
        let done = DispatchSemaphore(value: 0)
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: .zero, duration: .invalid,
                                        frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary, infoFlagsOut: nil) { st, _, sample in
            defer { done.signal() }
            guard st == noErr, let sample, let f = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return }
            var sets: [Data] = []
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(f, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var n = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(f, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n,
                                                                   parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let p { sets.append(Data(bytes: p, count: n)) }
            }
            var d = Data(count: CMBlockBufferGetDataLength(block))
            d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            out = (sets, d)
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        _ = done.wait(timeout: .now() + 3)
        VTCompressionSessionInvalidate(session)
        return out
    }
}
#endif
