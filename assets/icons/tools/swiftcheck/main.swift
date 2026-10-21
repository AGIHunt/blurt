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
precondition(BlurtIcon.chicken.image(size: 16).isTemplate)
precondition(BlurtIcon(named: "close") == .x && BlurtIcon(named: "process") == .chicken)
let s = BlurtIcon.chicken.label("整理 3 张", font: .systemFont(ofSize: 13), color: .white)
precondition(s.length > 3)
precondition(BlurtIcon.mic.cgImage(size: 12, scale: 2, color: CGColor(gray: 1, alpha: 1))?.width == 24)
print("ok", BlurtIcon.allCases.count)
