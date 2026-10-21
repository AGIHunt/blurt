// Snap mode — "one picture + one sentence" (docs/design/snap-and-live.md §1).
//
// Two entry points, one hotkey (⌥⇧A):
//  • while recording: a full-resolution still of the recorded area at that instant → <session>/shots/NNN.png +
//    shots.jsonl (t = video time) + a "snap" event in events.jsonl. No pause, no prompt; the border flashes and the
//    thumbnail flies into the HUD. ⌥⇧M (marker) does the same and still logs its marker.
//  • not recording (menu-bar app): the area picker with release-to-capture, a shutter flash, the card flies to the
//    perch (Perch.swift) and a note bubble listens (NoteBubble.swift). A batch of shots is one session
//    <sessions>/<ts>-shots/ with meta.json {"mode": "shots"}; "🐔 整理 N 张" on the perch processes it.
//
// File contract: shots/<NNN>.png (+ .marked.png ink version, .wav voice note); shots.jsonl one line per change
// {"n","file","marked","t","wall","region","voice","text","strokes"} — the later line for the same n wins.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreImage
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Image helpers

let sharedCIContext = CIContext(options: [.cacheIntermediates: false])

func pngData(_ img: CGImage, scale: CGFloat) -> Data? {
    let d = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(d, UTType.png.identifier as CFString, 1, nil) else { return nil }
    let dpi = 72 * max(1, scale)   // so pasted / dropped images show at their on-screen size
    CGImageDestinationAddImage(dest, img, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? d as Data : nil
}

func loadCGImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func thumbnail(_ img: CGImage, maxPixels: CGFloat) -> CGImage {
    let s = min(1, maxPixels / CGFloat(max(img.width, img.height)))
    guard s < 1 else { return img }
    let w = max(1, Int(CGFloat(img.width) * s)), h = max(1, Int(CGFloat(img.height) * s))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return img }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage() ?? img
}

func cgImage(from pb: CVPixelBuffer) -> CGImage? {
    let ci = CIImage(cvPixelBuffer: pb)
    return sharedCIContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
}

/// Puts a picture on the clipboard (PNG + TIFF so every app can paste it).
func copyImageToPasteboard(_ url: URL) {
    guard let data = try? Data(contentsOf: url) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setData(data, forType: .png)
    if let tiff = NSImage(data: data)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
    pb.writeObjects([item])
}

func backingScale(forDisplay id: CGDirectDisplayID) -> CGFloat {
    NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    })?.backingScaleFactor ?? 2
}

// MARK: - Stills via ScreenCaptureKit

/// A full-resolution still of `rect` (global top-left points), without any of our own windows except `keep`
/// (the pen's ink is part of what the user means, so a snap while recording keeps it).
func captureStill(rect: CGRect, showsCursor: Bool, keep: Set<CGWindowID> = [], completion: @escaping (CGImage?, CGFloat) -> Void) {
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
        guard let content = content else { DispatchQueue.main.async { completion(nil, 2) }; return }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(c) }) ?? content.displays.first else {
            DispatchQueue.main.async { completion(nil, 2) }; return
        }
        let mine = content.windows.filter { $0.owningApplication?.processID == getpid() && !keep.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: mine)
        let clipped = rect.intersection(display.frame)
        let scale = backingScale(forDisplay: display.displayID)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: clipped.minX - display.frame.minX, y: clipped.minY - display.frame.minY,
                                width: clipped.width, height: clipped.height)
        cfg.width = Int((clipped.width * scale).rounded())
        cfg.height = Int((clipped.height * scale).rounded())
        cfg.showsCursor = showsCursor
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 14.0, *) {
            cfg.captureResolution = .best
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, _ in
                DispatchQueue.main.async { completion(img, scale) }
            }
        } else {
            OneShotCapture.run(filter: filter, cfg: cfg) { img in completion(img, scale) }
        }
    }
}

/// macOS 13: no SCScreenshotManager — run a stream until its first complete frame.
final class OneShotCapture: NSObject, SCStreamOutput {
    static var running: [OneShotCapture] = []
    var stream: SCStream?
    var done: ((CGImage?) -> Void)?
    let q = DispatchQueue(label: "blurt.oneshot")

    static func run(filter: SCContentFilter, cfg: SCStreamConfiguration, done: @escaping (CGImage?) -> Void) {
        let o = OneShotCapture()
        o.done = done
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        o.stream = s
        DispatchQueue.main.async { running.append(o) }
        do { try s.addStreamOutput(o, type: .screen, sampleHandlerQueue: o.q) } catch { DispatchQueue.main.async { o.finish(nil) }; return }
        s.startCapture { err in if err != nil { DispatchQueue.main.async { o.finish(nil) } } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { o.finish(nil) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let img = cgImage(from: pb)
        DispatchQueue.main.async { self.finish(img) }
    }

    func finish(_ img: CGImage?) {
        guard let d = done else { return }
        done = nil
        stream?.stopCapture { _ in }
        OneShotCapture.running.removeAll { $0 === self }
        d(img)
    }
}

// MARK: - Shots on disk

final class Shot {
    let n: Int
    var file: String
    var marked: String?
    var t: Double?
    var wall: Double
    var region: [Double]
    var voice: String?
    var text: String?
    var strokes: [[[Double]]] = []
    var deleted = false
    var pixelSize: CGSize = .zero
    var scale: CGFloat = 2
    var thumb: CGImage?
    var full: CGImage?           // kept while the note is open; reloaded from disk otherwise
    var markedThumb: CGImage?
    weak var batch: ShotBatch?

    init(n: Int, file: String, wall: Double, region: [Double]) {
        self.n = n; self.file = file; self.wall = wall; self.region = region
    }

    var url: URL? { batch?.dir.appendingPathComponent(file) }
    var markedURL: URL? { marked.flatMap { batch?.dir.appendingPathComponent($0) } }
    /// What gets copied / dragged: the inked version if there is one.
    var bestURL: URL? { markedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? url }
    var voiceURL: URL? { voice.flatMap { batch?.dir.appendingPathComponent($0) } }
    var hasNote: Bool { !(text ?? "").isEmpty || voice != nil }

    func image() -> CGImage? { full ?? url.flatMap(loadCGImage) }

    var line: [String: Any] {
        var o: [String: Any] = ["n": n, "file": file, "marked": marked ?? NSNull(), "t": t.map { ($0 * 1000).rounded() / 1000 } ?? NSNull(),
                                "wall": (wall * 1000).rounded() / 1000, "region": region, "voice": voice ?? NSNull(),
                                "text": text ?? NSNull(), "strokes": strokes]
        if deleted { o["deleted"] = true }
        return o
    }
}

func appendJSONL(_ url: URL, _ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    guard let fh = try? FileHandle(forWritingTo: url) else { return }
    defer { try? fh.close() }
    _ = try? fh.seekToEnd()
    fh.write(d)
    fh.write(Data([0x0A]))
}

/// The shots of one session — a recording (snaps while recording) or a `-shots` batch.
final class ShotBatch {
    let dir: URL
    let inRecording: Bool
    private(set) var shots: [Shot] = []
    private var nextN = 1
    private let io = DispatchQueue(label: "blurt.shots.io")
    var onChange: (() -> Void)?

    init(dir: URL, inRecording: Bool) {
        self.dir = dir
        self.inRecording = inRecording
    }

    var shotsDir: URL { dir.appendingPathComponent("shots") }
    var jsonl: URL { dir.appendingPathComponent("shots.jsonl") }
    var live: [Shot] { shots.filter { !$0.deleted } }

    func reserve() -> Int { defer { nextN += 1 }; return nextN }
    static func name(_ n: Int) -> String { String(format: "%03d", n) }

    /// Writes the PNG off the main thread; the shots.jsonl line follows once the file is there.
    @discardableResult
    func add(n: Int, image: CGImage, scale: CGFloat, region: CGRect, t: Double?, wall: Date = Date(), done: ((Shot) -> Void)? = nil) -> Shot {
        let file = "shots/\(ShotBatch.name(n)).png"
        let s = Shot(n: n, file: file, wall: wall.timeIntervalSince1970,
                     region: [region.minX, region.minY, region.width, region.height].map { Double(($0 * 10).rounded() / 10) })
        s.t = t
        s.batch = self
        s.scale = scale
        s.pixelSize = CGSize(width: image.width, height: image.height)
        s.thumb = thumbnail(image, maxPixels: 520)
        s.full = image
        shots.append(s)
        shots.sort { $0.n < $1.n }
        let url = dir.appendingPathComponent(file)
        let dirURL = shotsDir
        let line = s.line
        io.async {
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            if let d = pngData(image, scale: scale) { try? d.write(to: url) }
            appendJSONL(self.jsonl, line)
            DispatchQueue.main.async {
                if !self.inRecording { self.writeMeta() }
                done?(s)
                self.onChange?()
            }
        }
        return s
    }

    /// Appends the shot's current state (later line wins).
    func save(_ s: Shot) {
        let line = s.line
        io.async { appendJSONL(self.jsonl, line) }
        onChange?()
    }

    func delete(_ s: Shot) {
        s.deleted = true
        save(s)
        for u in [s.url, s.markedURL, s.voiceURL].compactMap({ $0 }) where FileManager.default.fileExists(atPath: u.path) {
            NSWorkspace.shared.recycle([u]) { _, _ in }
        }
        if !inRecording { writeMeta() }
    }

    func sync(_ then: @escaping () -> Void) { io.async { DispatchQueue.main.async(execute: then) } }

    // --- batch session (-shots) bookkeeping
    var meta: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
    }

    func writeMeta(state: String? = nil) {
        var m = meta
        m["mode"] = "shots"
        m["engine"] = "native-app"
        m["shots"] = live.count
        if m["started_at"] == nil {
            m["started_at"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: shots.first?.wall ?? Date().timeIntervalSince1970))
        }
        m["author"] = m["author"] ?? recordConfig()["author"] as? String ?? NSFullUserName()
        m["workspace"] = m["workspace"] ?? currentWorkspace().path
        if let s = state { m["state"] = s } else if m["state"] == nil { m["state"] = "collecting" }
        if let d = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("meta.json"))
        }
    }

    /// Re-reads shots.jsonl (later lines win) — the perch comes back after a restart.
    static func load(_ dir: URL) -> ShotBatch? {
        let b = ShotBatch(dir: dir, inRecording: false)
        guard let raw = try? String(contentsOf: b.jsonl, encoding: .utf8) else { return nil }
        var byN: [Int: [String: Any]] = [:]
        for line in raw.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let n = o["n"] as? Int else { continue }
            byN[n] = (byN[n] ?? [:]).merging(o) { $1 }
        }
        for (n, o) in byN.sorted(by: { $0.key < $1.key }) {
            let s = Shot(n: n, file: o["file"] as? String ?? "shots/\(name(n)).png", wall: o["wall"] as? Double ?? 0,
                         region: o["region"] as? [Double] ?? [])
            s.marked = o["marked"] as? String
            s.t = o["t"] as? Double
            s.voice = o["voice"] as? String
            s.text = o["text"] as? String
            s.strokes = o["strokes"] as? [[[Double]]] ?? []
            s.deleted = o["deleted"] as? Bool ?? false
            s.batch = b
            if !s.deleted, let u = s.url, let img = loadCGImage(u) {
                s.pixelSize = CGSize(width: img.width, height: img.height)
                s.scale = s.region.count == 4 && s.region[2] > 0 ? CGFloat(img.width) / CGFloat(s.region[2]) : 2
                s.thumb = thumbnail(img, maxPixels: 520)
                if let m = s.markedURL, let mi = loadCGImage(m) { s.markedThumb = thumbnail(mi, maxPixels: 520) }
            } else if !s.deleted { s.deleted = true }
            b.shots.append(s)
            b.nextN = max(b.nextN, n + 1)
        }
        return b
    }
}

/// Burns the user's strokes (normalized 0–1 point lists) into a copy of the shot → NNN.marked.png.
func renderMarked(_ img: CGImage, strokes: [[[Double]]], lineWidthPx: CGFloat) -> CGImage? {
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(lineWidthPx)
    ctx.setStrokeColor(accent.cgColor)
    ctx.setShadow(offset: .zero, blur: lineWidthPx * 0.4, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    for s in strokes where !s.isEmpty {
        let pts = s.map { CGPoint(x: CGFloat($0[0]) * CGFloat(w), y: (1 - CGFloat($0[1])) * CGFloat(h)) }
        if pts.count == 1 {
            let r = lineWidthPx * 4.5
            ctx.strokeEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: r * 2, height: r * 2))
            continue
        }
        ctx.beginPath()
        ctx.move(to: pts[0])
        for i in 1..<pts.count - 1 {
            ctx.addQuadCurve(to: CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2), control: pts[i])
        }
        ctx.addLine(to: pts[pts.count - 1])
        ctx.strokePath()
    }
    return ctx.makeImage()
}

// MARK: - Chrome: shutter flash, border flash, flying thumbnails

/// A short-lived click-through window that is never captured.
func chromeWindow(_ frame: NSRect) -> NSWindow {
    let w = overlayWindow(frame, view: NSView())
    w.contentView?.wantsLayer = true
    w.level = .statusBar
    return w
}

/// White shutter flash over a freshly captured area (standalone snaps — the area is already captured).
func shutterFlash(_ r: NSRect) {
    let w = chromeWindow(r)
    let l = w.contentView!.layer!
    l.backgroundColor = NSColor.white.cgColor
    l.opacity = 0
    w.orderFrontRegardless()
    let a = CAKeyframeAnimation(keyPath: "opacity")
    a.values = [0, 0.85, 0]
    a.keyTimes = [0, 0.18, 1]
    a.duration = reduceMotion ? 0.2 : 0.32
    CATransaction.begin()
    CATransaction.setCompletionBlock { w.orderOut(nil) }
    l.add(a, forKey: "flash")
    CATransaction.commit()
}

/// A bright ring just outside the recorded area — the area itself must not change, it is being recorded.
func borderFlash(around r: NSRect) {
    let pad: CGFloat = 14
    let w = chromeWindow(r.insetBy(dx: -pad, dy: -pad))
    let l = w.contentView!.layer!
    let ring = CAShapeLayer()
    let inner = NSRect(x: pad, y: pad, width: r.width, height: r.height)
    let p = CGMutablePath()
    p.addRoundedRect(in: inner.insetBy(dx: -5, dy: -5), cornerWidth: 6, cornerHeight: 6)
    ring.path = p
    ring.fillColor = nil
    ring.strokeColor = NSColor.white.cgColor
    ring.lineWidth = 5
    ring.shadowColor = NSColor.white.cgColor
    ring.shadowOpacity = 1
    ring.shadowRadius = 6
    ring.shadowOffset = .zero
    ring.opacity = 0
    l.addSublayer(ring)
    w.orderFrontRegardless()
    let a = CAKeyframeAnimation(keyPath: "opacity")
    a.values = [0, 1, 0]
    a.keyTimes = [0, 0.15, 1]
    a.duration = 0.45
    CATransaction.begin()
    CATransaction.setCompletionBlock { w.orderOut(nil) }
    ring.add(a, forKey: "flash")
    CATransaction.commit()
}

/// Flies an image from one global rect to another along a gentle arc (Tendedero-style: ease-in-out, lifts ~30 pt
/// mid-flight, picks up the card's tilt, a frame appears around the photo on the way).
func flyImage(_ img: CGImage, from: NSRect, to: NSRect, duration: CFTimeInterval = 0.65, tilt: CGFloat = 0,
              polaroid: Bool = true, shrinkAway: Bool = false, done: @escaping () -> Void) {
    let reduce = reduceMotion
    let screen = NSScreen.screens.first(where: { $0.frame.intersects(to) }) ?? NSScreen.screens[0]
    let span = screen.frame.union(from.intersection(screen.frame).isEmpty ? screen.frame : from)
    let w = chromeWindow(span)
    let root = w.contentView!.layer!
    let local = { (r: NSRect) in r.offsetBy(dx: -span.minX, dy: -span.minY) }
    let a = local(from), b = local(to)
    let card = CALayer()
    card.bounds = CGRect(origin: .zero, size: a.size)
    card.position = CGPoint(x: a.midX, y: a.midY)
    card.contents = img
    card.contentsGravity = .resizeAspectFill
    card.masksToBounds = false
    card.shadowColor = NSColor.black.cgColor
    card.shadowOpacity = 0.28
    card.shadowRadius = 10
    card.shadowOffset = CGSize(width: 0, height: -4)
    if polaroid {
        card.borderColor = NSColor(white: 1, alpha: 1).cgColor
        card.borderWidth = 0
        card.cornerRadius = 0
    }
    root.addSublayer(card)
    w.orderFrontRegardless()
    if reduce {
        CATransaction.begin()
        CATransaction.setCompletionBlock { w.orderOut(nil); done() }
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 1; f.toValue = 0; f.duration = 0.2
        card.opacity = 0
        card.add(f, forKey: "fade")
        CATransaction.commit()
        return
    }
    let steps = 40
    var pos: [NSValue] = [], size: [NSValue] = []
    for i in 0...steps {
        let r = CGFloat(i) / CGFloat(steps)
        let k = r < 0.5 ? 4 * r * r * r : 1 - pow(-2 * r + 2, 3) / 2      // easeInOutCubic
        let x = a.midX + (b.midX - a.midX) * k
        let y = a.midY + (b.midY - a.midY) * k + sin(.pi * k) * 30
        pos.append(NSValue(point: NSPoint(x: x, y: y)))
        size.append(NSValue(size: NSSize(width: a.width + (b.width - a.width) * k, height: a.height + (b.height - a.height) * k)))
    }
    let pa = CAKeyframeAnimation(keyPath: "position"); pa.values = pos
    let sa = CAKeyframeAnimation(keyPath: "bounds.size"); sa.values = size
    let ra = CABasicAnimation(keyPath: "transform.rotation.z"); ra.fromValue = 0; ra.toValue = -tilt * .pi / 180
    ra.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    let bw = CABasicAnimation(keyPath: "borderWidth"); bw.fromValue = 0; bw.toValue = polaroid ? 3 : 0
    let g = CAAnimationGroup()
    g.animations = [pa, sa, ra, bw]
    if shrinkAway {
        let op = CAKeyframeAnimation(keyPath: "opacity"); op.values = [1, 1, 0]; op.keyTimes = [0, 0.75, 1]
        g.animations?.append(op)
    }
    g.duration = duration
    g.fillMode = .forwards
    g.isRemovedOnCompletion = false
    CATransaction.begin()
    CATransaction.setCompletionBlock {
        done()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { w.orderOut(nil) }
    }
    card.add(g, forKey: "fly")
    CATransaction.commit()
}

// MARK: - Snaps while recording

final class RecordingSnaps {
    weak var rec: Recorder?
    let batch: ShotBatch
    var onLanded: ((Shot) -> Void)?

    init(rec: Recorder, session: URL) {
        self.rec = rec
        batch = ShotBatch(dir: session, inRecording: true)
    }

    var count: Int { batch.live.count }

    /// `via`: "hotkey" | "hud" | "marker" | "stdin"
    func snap(via: String) {
        guard let rec = rec, rec.sessionStart.isValid, !rec.stopping else { return }
        let t = rec.elapsed()
        let n = batch.reserve()
        let file = "shots/\(ShotBatch.name(n)).png"
        rec.log("snap", ["n": n, "file": file, "via": via])
        emit(["event": "snap", "n": n, "t": (t * 1000).rounded() / 1000, "file": file])
        let region = rec.region
        let pb = rec.latestFrame()            // fallback: the frame the video got at this instant
        var keep = Set<CGWindowID>()
        if let iw = rec.inkWin { keep.insert(CGWindowID(iw.windowNumber)) }
        borderFlash(around: toNS(region))
        captureStill(rect: region, showsCursor: true, keep: keep) { [weak self] img, scale in
            guard let self = self else { return }
            var image = img, sc = scale
            if image == nil, let pb = pb, let f = cgImage(from: pb) { image = f; sc = CGFloat(f.width) / max(1, region.width) }
            guard let im = image else {
                emit(["event": "error", "code": "snap", "message": "could not capture shot \(n)"])
                return
            }
            self.batch.add(n: n, image: im, scale: sc, region: region, t: t) { s in
                emit(["event": "snap_saved", "n": n, "file": s.file, "size": [im.width, im.height]])
            }
            if let s = self.batch.shots.first(where: { $0.n == n }) { self.onLanded?(s) }
        }
    }

    func setText(_ s: Shot, _ text: String?) {
        let v = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        s.text = (v?.isEmpty ?? true) ? nil : v
        batch.save(s)
    }
}

// MARK: - Standalone snaps (menu-bar app, not recording)

/// Fixed hotkey modifiers can be overridden for tests (BLURT_HOTKEY_MODS=ctrl+opt+shift+cmd) so a test build never
/// fights the user's running Blurt for ⌥⇧ shortcuts.
func hotkeyMods(_ spec: String?) -> Int? {
    guard let spec = spec, !spec.isEmpty else { return nil }
    var m = 0
    for p in spec.lowercased().split(separator: "+") {
        switch p {
        case "ctrl", "control": m |= controlKey
        case "opt", "option", "alt": m |= optionKey
        case "shift": m |= shiftKey
        case "cmd", "command": m |= cmdKey
        default: break
        }
    }
    return m
}

func isShotsSession(_ dir: URL) -> Bool {
    dir.lastPathComponent.hasSuffix("-shots") || FileManager.default.fileExists(atPath: dir.appendingPathComponent("shots.jsonl").path)
        && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.mp4").path)
}

/// The prompt for an unattended run on a shots session (nil for recordings: App.process keeps its own).
func shotsPrompt(_ dir: URL) -> String? {
    guard isShotsSession(dir) else { return nil }
    return L("用 blurt skill 处理这批截图：\(dir.path)\n这是截图模式的 session（mode: shots，没有录屏视频）：每张截图锚定一条，截图就是这一条的首帧；有语音备注的先转写；.marked.png 上已经有用户的笔迹。\n这是口喷鸡 App 发起的无人值守后台运行：不要提问，也不要启动审核页（items.json 一出现 App 就会打开它）；写好 items.json 后用两三句话总结。",
             "Use the blurt skill to process this batch of screenshots: \(dir.path)\nIt is a shots session (mode: shots, no video): each shot anchors one item and is that item's primary frame; transcribe voice notes first; .marked.png files already carry the user's ink.\nThis is an unattended background run started by the Blurt app: don't ask questions and don't start the review page (the app opens it as soon as items.json appears); write items.json, then summarise in 2–3 sentences.")
}

final class Snapper {
    var batch: ShotBatch?
    var prevApp: NSRunningApplication?
    var app: App? { NSApp.delegate as? App }
    var collectTimer: Timer?
    var collectSeen = Set<String>()

    /// ⌥⇧A when not recording. While a note is open: save it, then take the next shot.
    func hotkey() {
        guard let app = app, app.resident, app.rec == nil else { return }
        if app.picker != nil { return }
        if NoteBubble.shared.isOpen { NoteBubble.shared.commit() }
        guard !app.busy else { return }
        pick()
    }

    func rememberFrontApp() {
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid() { prevApp = f }
    }

    func restoreFocus() {
        if let p = prevApp, !p.isTerminated { p.activate() }
    }

    func pick(preselect: CGRect? = nil) {
        guard let app = app else { return }
        rememberFrontApp()
        app.busy = true
        let p = PickerController()
        p.snapMode = true
        p.onDone = { [weak self, weak app] r in
            unregisterHotkey(.pickEnter); unregisterHotkey(.pickEsc); unregisterHotkey(.pickFull)
            app?.picker = nil
            app?.busy = false
            guard let r = r else { self?.restoreFocus(); return }
            setRecordConfig("last_snap_region", [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)])
            self?.capture(r)
        }
        app.picker = p
        registerHotkey(.pickEnter, key: kVK_Return, mods: 0)
        registerHotkey(.pickEsc, key: kVK_Escape, mods: 0)
        registerHotkey(.pickFull, key: kVK_ANSI_F, mods: 0)
        if let r = recordConfig()["last_snap_region"] as? [Double], r.count == 4 {
            opts.lastRegion = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        } else {
            opts.lastRegion = lastRegionFromConfig()
        }
        p.show(preselect: preselect)
    }

    func ensureBatch() -> ShotBatch {
        if let b = batch { return b }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = sessionsRoot(for: currentWorkspace()).appendingPathComponent(f.string(from: Date()) + "-shots")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("shots"), withIntermediateDirectories: true)
        let b = ShotBatch(dir: dir, inRecording: false)
        b.onChange = { perch.refreshControls() }
        batch = b
        perch.batch = b
        return b
    }

    /// `region`: global top-left points. Also used directly by tests (`snapregion x,y,w,h`).
    func capture(_ region: CGRect, withNote: Bool = true) {
        let ns = toNS(region)
        captureStill(rect: region, showsCursor: false) { [weak self] img, scale in
            guard let self = self else { return }
            guard let img = img else {
                self.app?.toast(L("截图失败：需要「录屏」权限", "Couldn't take the shot — Screen Recording permission needed"))
                self.restoreFocus()
                return
            }
            shutterFlash(ns)
            self.playShutter()
            let b = self.ensureBatch()
            let n = b.reserve()
            let shot = b.add(n: n, image: img, scale: scale, region: region, t: nil)
            emit(["event": "snap", "n": n, "file": shot.file, "session": b.dir.path])
            perch.hang(shot, from: ns)
            if withNote { NoteBubble.shared.begin(shot, mode: .listen) } else { self.restoreFocus() }
        }
    }

    func playShutter() {
        guard recordConfig()["snap_sound"] as? Bool ?? true else { return }
        let p = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if FileManager.default.fileExists(atPath: p) { NSSound(contentsOfFile: p, byReference: true)?.play() }
    }

    /// "🐔 整理 N 张": the batch becomes a session to process — same code path as a finished recording.
    func processBatch() {
        guard let b = batch, !b.live.isEmpty, let app = app else { return }
        NoteBubble.shared.commit()
        b.sync {
            b.writeMeta(state: "processing")
            let mode = recordConfig()["process"] as? String ?? "off"
            let kinds = Array(repeating: "note", count: min(5, b.live.count))
            perch.gather(into: kinds)
            self.batch = nil
            perch.batch = nil
            app.process(b.dir, with: mode == "codex" ? "codex" : "claude")
        }
    }

    /// "清空": the whole batch goes to the Trash (recoverable), the perch empties with a cascade of falls.
    func clearBatch() {
        guard let b = batch else { return }
        NoteBubble.shared.cancel()
        perch.dropAll()
        batch = nil
        perch.batch = nil
        b.sync { NSWorkspace.shared.recycle([b.dir]) { _, _ in } }
    }

    func delete(_ s: Shot) {
        if NoteBubble.shared.shot === s { NoteBubble.shared.cancel() }
        s.batch?.delete(s)
        if let b = batch, b.live.isEmpty {
            batch = nil
            perch.batch = nil
            b.sync { NSWorkspace.shared.recycle([b.dir]) { _, _ in } }
        }
    }

    /// The perch comes back after a restart with the batch that was still being collected.
    func restore() {
        let root = sessionsRoot(for: currentWorkspace())
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-shots") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let d = dirs.first, !FileManager.default.fileExists(atPath: d.appendingPathComponent("items.json").path),
              let b = ShotBatch.load(d), (b.meta["state"] as? String ?? "collecting") == "collecting", !b.live.isEmpty else { return }
        b.onChange = { perch.refreshControls() }
        batch = b
        perch.batch = b
        for s in b.live { perch.hang(s, from: nil, quiet: true) }
    }

    // --- optional: collect the system's own screenshots (⌘⇧3/4/5) onto the perch
    var collecting: Bool { recordConfig()["collect_system_shots"] as? Bool ?? false }

    func screenshotFolder() -> URL {
        let d = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let p = (d.map { ($0 as NSString).expandingTildeInPath }).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        return URL(fileURLWithPath: p ?? (NSHomeDirectory() + "/Desktop"))
    }

    func syncCollector() {
        collectTimer?.invalidate()
        collectTimer = nil
        guard collecting else { return }
        let folder = screenshotFolder()
        let since = Date()
        collectSeen = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        collectTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.scanScreenshots(folder, since: since) }
    }

    func scanScreenshots(_ folder: URL, since: Date) {
        guard let app = app, app.rec == nil else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where !collectSeen.contains(name) {
            collectSeen.insert(name)
            let url = folder.appendingPathComponent(name)
            guard ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()), !name.hasPrefix("."),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attrs[.creationDate] as? Date ?? .distantPast) >= since, isScreenCapture(url),
                  let img = loadCGImage(url) else { continue }
            let b = ensureBatch()
            let n = b.reserve()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let sz = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
            let shot = b.add(n: n, image: img, scale: scale, region: CGRect(origin: .zero, size: sz), t: nil)
            shot.region = []        // unknown: taken by the system
            perch.hang(shot, from: nil)
        }
    }

    func isScreenCapture(_ url: URL) -> Bool {
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let v = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool { return v }
        let n = url.lastPathComponent.lowercased()
        return n.hasPrefix("screenshot") || n.hasPrefix("screen shot") || n.hasPrefix("截屏") || n.hasPrefix("屏幕快照")
    }
}

let snapper = Snapper()
