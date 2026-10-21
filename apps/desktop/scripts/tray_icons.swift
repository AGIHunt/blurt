// Renders the monochrome tray icons from icons/tray.svg (macOS: NSImage reads SVG).
//   swift apps/desktop/scripts/tray_icons.swift
// → icons/tray-black.png (64 px; light panels, and the macOS template image) and icons/tray-white.png (dark panels:
//   the Windows taskbar and the GNOME top bar by default). Re-run when the SVG changes; the PNGs are committed.
import AppKit

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../src-tauri/icons").standardized
let svg = try! Data(contentsOf: dir.appendingPathComponent("tray.svg"))
let src = NSImage(data: svg)!
let px = 64

for (name, color) in [("tray-black.png", NSColor.black), ("tray-white.png", NSColor.white)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let r = NSRect(x: 0, y: 0, width: px, height: px)
    src.draw(in: r)
    color.set()
    r.fill(using: .sourceIn)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    print(dir.appendingPathComponent(name).path)
}
