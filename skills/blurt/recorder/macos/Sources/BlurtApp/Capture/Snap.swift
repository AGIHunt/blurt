// Stills and the captures model (docs/design/next-round.md K7).
//
//  • while recording, ⌥⇧A: a full-resolution still of the recorded area at that instant → <session>/shots/NNN.png +
//    shots.jsonl (t = video time) + a "snap" event in events.jsonl. No pause, no prompt; the border flashes and the
//    thumbnail flies into the island. The island's snap button also pauses and opens the note. ⌥⇧M = marker + snap.
//  • not recording: see Captures.swift (the area picker, then a hanging card or straight into the island).
//
// File contract: shots/<NNN>.png (+ .marked.png ink version, .wav voice note); shots.jsonl one line per change
// {"n","type","file","marked","t","wall","region","voice","text","said","strokes","project"} — later lines for the
// same n win key by key; {"n","project","assigned_by"} assigns a card, {"n","deleted":true} deletes one.

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
    // tests: BLURT_TEST_STILL=<png> stands in for the screen (no Screen Recording grant, nothing private captured)
    if let p = ProcessInfo.processInfo.environment["BLURT_TEST_STILL"], let img = loadCGImage(URL(fileURLWithPath: p)) {
        DispatchQueue.main.async { completion(img, 2) }
        return
    }
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

// MARK: - Captures on disk

/// A capture of a shots batch: a still (shot) or a voice input (voice) — K7.
enum CaptureKind: String { case shot, voice }

final class Shot {
    let n: Int
    var kind: CaptureKind = .shot
    var file: String?            // shots/NNN.png; nil for voice
    var marked: String?
    var t: Double?
    var wall: Double
    var region: [Double]
    var voice: String?           // shots/NNN.wav: the note on a shot, or the voice input itself
    var text: String?            // typed note
    var said: String?            // transcript of `voice` (voice inputs)
    var duration: Double?        // voice inputs
    var strokes: [[[Double]]] = []
    var deleted = false
    /// project id | "inbox" | nil (nil and not assigned = a card waiting on a thread)
    var project: String?
    var assignedBy: String?      // capture | user | ai
    var pixelSize: CGSize = .zero
    var scale: CGFloat = 2
    var thumb: CGImage?
    var full: CGImage?           // kept while the note is open; reloaded from disk otherwise
    var markedThumb: CGImage?
    weak var batch: ShotBatch?

    init(n: Int, file: String?, wall: Double, region: [Double]) {
        self.n = n; self.file = file; self.wall = wall; self.region = region
    }

    var url: URL? { file.flatMap { batch?.dir.appendingPathComponent($0) } }
    var markedURL: URL? { marked.flatMap { batch?.dir.appendingPathComponent($0) } }
    /// What gets copied / dragged: the inked version if there is one (a voice input: its wav).
    var bestURL: URL? { markedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? url ?? voiceURL }
    var voiceURL: URL? { voice.flatMap { batch?.dir.appendingPathComponent($0) } }
    var hasNote: Bool { !(text ?? "").isEmpty || voice != nil }
    /// Waiting on a thread: not assigned to a project, not handed to the AI, not deleted, not part of a recording.
    var isCard: Bool { !deleted && project == nil && assignedBy == nil && batch?.inRecording == false }
    /// What the card says: the typed note, else the transcript.
    var words: String? { [text, said].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } }

    func image() -> CGImage? { full ?? url.flatMap(loadCGImage) }

    var line: [String: Any] {
        var o: [String: Any] = ["n": n, "type": kind.rawValue, "file": file ?? NSNull(), "marked": marked ?? NSNull(),
                                "t": t.map { ($0 * 1000).rounded() / 1000 } ?? NSNull(),
                                "wall": (wall * 1000).rounded() / 1000, "region": region, "voice": voice ?? NSNull(),
                                "text": text ?? NSNull(), "strokes": strokes, "project": project ?? NSNull()]
        if kind == .voice { o["duration"] = duration.map { ($0 * 100).rounded() / 100 } ?? NSNull() }
        if kind == .voice || said != nil { o["said"] = said ?? NSNull() }     // v0.7: a still's spoken note, transcribed
        if let a = assignedBy { o["assigned_by"] = a }
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

/// The captures of one session — a recording (snaps while recording) or a `-shots` batch in a store (K1 / K7).
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
    func add(n: Int, image: CGImage, scale: CGFloat, region: CGRect, t: Double?, project: String? = nil, wall: Date = Date(),
             done: ((Shot) -> Void)? = nil) -> Shot {
        let file = "shots/\(ShotBatch.name(n)).png"
        let s = Shot(n: n, file: file, wall: wall.timeIntervalSince1970,
                     region: [region.minX, region.minY, region.width, region.height].map { Double(($0 * 10).rounded() / 10) })
        s.t = t
        s.scale = scale
        s.pixelSize = CGSize(width: image.width, height: image.height)
        s.thumb = thumbnail(image, maxPixels: 520)
        s.full = image
        insert(s, project: project)
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

    /// A voice input whose wav (shots/NNN.wav) is already written.
    @discardableResult
    func addVoice(n: Int, duration: Double, project: String?, wall: Date = Date()) -> Shot {
        let s = Shot(n: n, file: nil, wall: wall.timeIntervalSince1970, region: [])
        s.kind = .voice
        s.voice = "shots/\(ShotBatch.name(n)).wav"
        s.duration = duration
        insert(s, project: project)
        save(s)
        if !inRecording { writeMeta() }
        return s
    }

    private func insert(_ s: Shot, project: String?) {
        s.batch = self
        s.project = project
        if project != nil { s.assignedBy = "capture" }
        shots.append(s)
        shots.sort { $0.n < $1.n }
    }

    /// Appends the shot's current state (later line wins).
    func save(_ s: Shot) {
        let line = s.line
        io.async { appendJSONL(self.jsonl, line) }
        onChange?()
    }

    /// K7: an assignment is its own short line `{"n", "project", "assigned_by"}`; handing it to the AI ("ai") keeps
    /// project null until ingest routes the item.
    func assign(_ s: Shot, project: String?, by: String) {
        s.project = by == "ai" ? nil : project
        s.assignedBy = by
        let o: [String: Any] = ["n": s.n, "project": s.project ?? NSNull(), "assigned_by": by]
        io.async { appendJSONL(self.jsonl, o) }
        onChange?()
    }

    /// Captured with a project, but it hangs as a card after all (no note): `{"n", "project": null, "assigned_by": null}`.
    func release(_ s: Shot) {
        s.project = nil
        s.assignedBy = nil
        io.async { appendJSONL(self.jsonl, ["n": s.n, "project": NSNull(), "assigned_by": NSNull()]) }
        onChange?()
    }

    /// `{"n", "deleted": true}`; the files go to the Trash (recoverable). `done` gets where each one went (for Undo).
    func delete(_ s: Shot, done: (([URL: URL]) -> Void)? = nil) {
        s.deleted = true
        io.async { appendJSONL(self.jsonl, ["n": s.n, "deleted": true]) }
        let files = [s.url, s.markedURL, s.voiceURL].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !inRecording { writeMeta() }
        onChange?()
        guard !files.isEmpty else { done?([:]); return }
        NSWorkspace.shared.recycle(files) { moved, _ in DispatchQueue.main.async { done?(moved) } }
    }

    /// Undo of delete: the files back out of the Trash, `{"n", "deleted": false}`.
    func undelete(_ s: Shot, from trashed: [URL: URL]) {
        for (orig, now) in trashed where !FileManager.default.fileExists(atPath: orig.path) {
            try? FileManager.default.moveItem(at: now, to: orig)
        }
        s.deleted = false
        io.async { appendJSONL(self.jsonl, ["n": s.n, "deleted": false]) }
        if !inRecording { writeMeta() }
        onChange?()
    }

    func sync(_ then: @escaping () -> Void) { io.async { DispatchQueue.main.async(execute: then) } }

    // --- batch session (-shots) bookkeeping
    var meta: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
    }

    /// meta.json {"mode": "shots", "project": <the store's project id; null in the inbox>, "state", …}
    func writeMeta(state: String? = nil, project: String?? = nil) {
        var m = meta
        m["mode"] = "shots"
        m["engine"] = "native-app"
        m["shots"] = live.count
        if m["started_at"] == nil {
            m["started_at"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: shots.first?.wall ?? Date().timeIntervalSince1970))
        }
        m["author"] = m["author"] ?? recordConfig()["author"] as? String ?? NSFullUserName()
        if let p = project { m["project"] = p ?? NSNull() }
        if let s = state { m["state"] = s } else if m["state"] == nil { m["state"] = "collecting" }
        if let d = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("meta.json"))
        }
    }

    /// Re-reads shots.jsonl (later lines win, key by key).
    static func load(_ dir: URL) -> ShotBatch? {
        let b = ShotBatch(dir: dir, inRecording: false)
        guard let raw = try? String(contentsOf: b.jsonl, encoding: .utf8) else { return nil }
        var byN: [Int: [String: Any]] = [:]
        for line in raw.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let n = o["n"] as? Int else { continue }
            byN[n] = (byN[n] ?? [:]).merging(o) { $1 }
        }
        for (n, o) in byN.sorted(by: { $0.key < $1.key }) {
            let kind = CaptureKind(rawValue: o["type"] as? String ?? "shot") ?? .shot
            let s = Shot(n: n, file: kind == .voice ? nil : o["file"] as? String ?? "shots/\(name(n)).png", wall: o["wall"] as? Double ?? 0,
                         region: o["region"] as? [Double] ?? [])
            s.kind = kind
            s.marked = o["marked"] as? String
            s.t = o["t"] as? Double
            s.voice = o["voice"] as? String
            s.text = o["text"] as? String
            s.said = o["said"] as? String
            s.duration = o["duration"] as? Double
            s.strokes = o["strokes"] as? [[[Double]]] ?? []
            s.deleted = o["deleted"] as? Bool ?? false
            s.project = o["project"] as? String
            s.assignedBy = o["assigned_by"] as? String
            s.batch = b
            if kind == .shot, !s.deleted, let u = s.url, let img = loadCGImage(u) {
                s.pixelSize = CGSize(width: img.width, height: img.height)
                s.scale = s.region.count == 4 && s.region[2] > 0 ? CGFloat(img.width) / CGFloat(s.region[2]) : 2
                s.thumb = thumbnail(img, maxPixels: 520)
                if let m = s.markedURL, let mi = loadCGImage(m) { s.markedThumb = thumbnail(mi, maxPixels: 520) }
            } else if kind == .shot, !s.deleted { s.deleted = true }
            if kind == .voice, !s.deleted, !(s.voiceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) { s.deleted = true }
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

/// Flies an image from one global rect to another along a gentle arc (lifts ~30 pt mid-flight, picks up a tilt).
/// `springy`: the progress follows a spring (response 0.55 s, damping 0.72 — K7's fly-up), so it lands with a little
/// overshoot, as if caught; else ease-in-out over `duration`. The corners round to `cornerRadius` on the way.
/// Driven frame by frame on the display (model values, like the island and the cards), so it can be recorded.
func flyImage(_ img: CGImage, from: NSRect, to: NSRect, duration: CFTimeInterval = 0.65, tilt: CGFloat = 0,
              polaroid: Bool = false, shrinkAway: Bool = false, springy: Bool = false, cornerRadius: CGFloat = 0,
              done: @escaping () -> Void) {
    let screen = NSScreen.screens.first(where: { $0.frame.intersects(to) }) ?? NSScreen.screens[0]
    let span = screen.frame.union(from.intersection(screen.frame).isEmpty ? screen.frame : from)
    let w = chromeWindow(span)
    let root = w.contentView!.layer!
    let local = { (r: NSRect) in r.offsetBy(dx: -span.minX, dy: -span.minY) }
    let a = local(from), b = local(to)
    let card = CALayer()                 // the shadow
    card.bounds = CGRect(origin: .zero, size: a.size)
    card.position = CGPoint(x: a.midX, y: a.midY)
    card.shadowColor = NSColor.black.cgColor
    card.shadowOpacity = 0.28
    card.shadowRadius = 12
    card.shadowOffset = CGSize(width: 0, height: -5)
    let photo = CALayer()                // the picture, clipped to the corners
    photo.frame = card.bounds
    photo.contents = img
    photo.contentsGravity = .resizeAspectFill
    photo.masksToBounds = true
    if polaroid { photo.borderColor = NSColor.white.cgColor }
    card.addSublayer(photo)
    root.addSublayer(card)
    w.orderFrontRegardless()
    if reduceMotion {
        CATransaction.begin()
        CATransaction.setCompletionBlock { w.orderOut(nil); done() }
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 1; f.toValue = 0; f.duration = 0.2
        card.opacity = 0
        card.add(f, forKey: "fade")
        CATransaction.commit()
        return
    }
    var spring = Spring(0, response: 0.55, damping: 0.72)
    spring.target = 1
    let t0 = CACurrentMediaTime()
    var last = t0
    let driver = MotionDriver(view: w.contentView!)
    driver.tick = { dt in
        let now = CACurrentMediaTime()
        let k: CGFloat
        var finished = false
        if springy {
            k = spring.step(CGFloat(now - last))
            finished = now - t0 > 0.3 && spring.resting || now - t0 > 2
        } else {
            let u = CGFloat((now - t0) / duration)
            k = Ease.inOutCubic(u)
            finished = u >= 1
        }
        last = now
        let p = finished ? 1 : k
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.position = CGPoint(x: a.midX + (b.midX - a.midX) * p, y: a.midY + (b.midY - a.midY) * p + sin(.pi * min(1, p)) * (springy ? 14 : 30))
        card.bounds.size = CGSize(width: max(1, a.width + (b.width - a.width) * p), height: max(1, a.height + (b.height - a.height) * p))
        photo.frame = card.bounds
        photo.cornerRadius = cornerRadius * min(1, max(0, p))
        photo.borderWidth = polaroid ? 3 * min(1, max(0, p)) : 0
        card.setAffineTransform(CGAffineTransform(rotationAngle: -tilt * .pi / 180 * min(1, max(0, p))))
        if shrinkAway { card.opacity = Float(p < 0.75 ? 1 : max(0, (1 - p) / 0.25)) }
        CATransaction.commit()
        if finished {
            DispatchQueue.main.async {
                done()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { w.orderOut(nil); driver.stop() }
            }
            return false
        }
        return true
    }
    flights.append(driver)
    driver.wake()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { flights.removeAll { $0 === driver } }
}
/// Flights in the air (each keeps its own display link alive).
private var flights: [MotionDriver] = []

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

    /// `via`: "hotkey" | "island" | "marker" | "command"; `then` gets the saved shot (the island's button opens its note)
    func snap(via: String, then: ((Shot) -> Void)? = nil) {
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
                emit(["event": "snap_saved", "n": n, "file": s.file ?? "", "size": [im.width, im.height]])
            }
            if let s = self.batch.shots.first(where: { $0.n == n }) { self.onLanded?(s); then?(s) }
        }
    }

    func setText(_ s: Shot, _ text: String?) {
        let v = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        s.text = (v?.isEmpty ?? true) ? nil : v
        batch.save(s)
    }
}

