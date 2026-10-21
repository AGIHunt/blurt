// Renders every BlurtIcon (Swift vectors) to PNGs per appearance + the kind eggs + a few SF symbols, offscreen.
import AppKit
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func png(_ im: NSImage, px: Int, _ name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    im.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
for app in ["aqua", "darkAqua"] {
    NSAppearance(named: app == "aqua" ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance {
        for i in BlurtIcon.allCases {
            png(i.image(size: 48, color: app == "aqua" ? .black : .white), px: 96, "\(app)-\(i.rawValue).png")
            png(i.image(size: 48, color: .labelColor), px: 96, "label-\(app)-\(i.rawValue).png")
        }
        for k in EggKind.allCases { png(BlurtIcon.egg(k, size: 48, seed: 7), px: 96, "\(app)-zegg-\(k.rawValue).png") }
        for i in [BlurtIcon.check, .pause, .search, .trash, .warning, .x, .chicken] {
            png(i.symbolImage(pointSize: 36), px: 96, "\(app)-sf-\(i.rawValue).png")
        }
    }
}
// inline icons in text (menus, toasts, status lines): one strip per appearance
for app in ["aqua", "darkAqua"] {
    let f = NSFont.menuFont(ofSize: 0), s = NSFont.systemFont(ofSize: 11, weight: .medium)
    func plain(_ t: String, _ font: NSFont = f, _ c: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: c])
    }
    let lines: [NSAttributedString] = [
        plain("1. ") + BlurtIcon.check.attributed(font: f, color: .systemGreen, preferSymbol: true) + plain("  Codex"),
        plain("2. ") + BlurtIcon.x.attributed(font: f, color: .systemRed, preferSymbol: true) + plain("  Claude Code"),
        plain("10/21 09:30  ·  2:12  ") + BlurtIcon.check.attributed(font: f, color: .secondaryLabelColor, preferSymbol: true),
        plain("Process with Kimi  ") + BlurtIcon.x.label("not logged in", font: f, color: .secondaryLabelColor, iconColor: .systemRed, preferSymbol: true),
        BlurtIcon.recordFill.label("0:04  listening — pause to save", font: s, color: .secondaryLabelColor, iconColor: .systemRed),
        BlurtIcon.check.label("Saved", font: s, color: .systemGreen, preferSymbol: true),
        BlurtIcon.warning.label("⌥⇧A is taken by another app", font: s, color: .systemOrange, preferSymbol: true),
        BlurtIcon.chicken.label("blurt is running", font: .systemFont(ofSize: 13, weight: .medium)),
        BlurtIcon.snap.label("Drag an area, release to snap", font: .systemFont(ofSize: 13, weight: .medium)),
    ]
    let W = 420, H = lines.count * 26 + 12
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W * 2, pixelsHigh: H * 2, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSAppearance(named: app == "aqua" ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (app == "aqua" ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()
        for (i, l) in lines.enumerated() { l.draw(at: NSPoint(x: 12, y: H - 30 - i * 26)) }
        NSGraphicsContext.restoreGraphicsState()
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("text-\(app).png"))
}

precondition(BlurtIcon.chicken.image(size: 16).isTemplate)
precondition(BlurtIcon(named: "close") == .x && BlurtIcon(named: "process") == .chicken)
let s = BlurtIcon.chicken.label("整理 3 张", font: .systemFont(ofSize: 13), color: .white)
precondition(s.length > 3)
precondition(BlurtIcon.mic.cgImage(size: 12, scale: 2, color: CGColor(gray: 1, alpha: 1))?.width == 24)
print("ok", BlurtIcon.allCases.count)
