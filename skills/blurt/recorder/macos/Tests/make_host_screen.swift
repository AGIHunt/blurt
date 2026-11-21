// A pretend Mac host's screen for the viewer's screenshots (`viewer fakehost PNG mac`): one coherent macOS desktop at 2560 × 1440
// (1280 × 720 points, 16:9, so the viewer window takes its shape with no band beside the picture). The menu bar with the Apple menu,
// status items and a clock; Terminal in front running zsh; an editor behind it; the Dock along the bottom. Every name in it is made up.
//
//   swift skills/blurt/recorder/macos/Tests/make_host_screen.swift OUT.png
//
// Regenerate it here rather than retouching the PNG.
import AppKit

let W: CGFloat = 1280, H: CGFloat = 720, scale: CGFloat = 2
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "host-mac.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
let gc = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gc
let cg = gc.cgContext
// top-left origin, in points
cg.translateBy(x: 0, y: H)
cg.scaleBy(x: 1, y: -1)
let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
NSGraphicsContext.current = flipped

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func text(_ s: String, _ p: CGPoint, _ font: NSFont, _ color: NSColor) {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: p)
}

func width(_ s: String, _ font: NSFont) -> CGFloat { NSAttributedString(string: s, attributes: [.font: font]).size().width }

func symbol(_ name: String, _ size: CGFloat, _ color: NSColor, at p: CGPoint, weight: NSFont.Weight = .regular) -> CGFloat {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))) else { return 0 }
    img.draw(in: NSRect(x: p.x, y: p.y - img.size.height / 2, width: img.size.width, height: img.size.height))
    return img.size.width
}

// MARK: the wallpaper: a soft macOS-like gradient with two glows

let sky = NSGradient(colors: [rgb(0x1B2F6B), rgb(0x3A4FA8), rgb(0x7D6BC4), rgb(0xE7A3B6)], atLocations: [0, 0.38, 0.72, 1],
                     colorSpace: .sRGB)!
sky.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -70)
for (c, r, col) in [(CGPoint(x: 1060, y: 160), CGFloat(420), rgb(0x6FD3E8, 0.38)), (CGPoint(x: 220, y: 640), CGFloat(460), rgb(0xF4B27C, 0.30))] {
    NSGradient(colors: [col, col.withAlphaComponent(0)])!.draw(fromCenter: c, radius: 0, toCenter: c, radius: r, options: [])
}

// MARK: windows

struct Win {
    var frame: NSRect
    var title: String
    var front: Bool
    var dark: Bool
}

func window(_ w: Win, body: (NSRect) -> Void) {
    let r = w.frame, radius: CGFloat = 12, bar: CGFloat = 30
    let shape = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(w.front ? 0.45 : 0.3)
    shadow.shadowBlurRadius = w.front ? 34 : 22
    shadow.shadowOffset = NSSize(width: 0, height: w.front ? -14 : -8)   // flipped: down
    shadow.set()
    (w.dark ? rgb(0x1E1E1E) : rgb(0xFFFFFF)).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // the title bar
    (w.dark ? rgb(0x2B2B2B) : rgb(0xF0F0F0)).setFill()
    NSRect(x: r.minX, y: r.minY, width: r.width, height: bar).fill()
    (w.dark ? rgb(0x000000, 0.6) : rgb(0x000000, 0.1)).setFill()
    NSRect(x: r.minX, y: r.minY + bar - 0.5, width: r.width, height: 0.5).fill()
    let lights: [UInt32] = w.front ? [0xFF5F57, 0xFEBC2E, 0x28C840] : [0xCDCDCD, 0xCDCDCD, 0xCDCDCD]
    for (i, c) in lights.enumerated() {
        let d = NSRect(x: r.minX + 13 + CGFloat(i) * 20, y: r.minY + bar / 2 - 6, width: 12, height: 12)
        (w.dark && !w.front ? rgb(0x4A4A4A) : rgb(c)).setFill()
        NSBezierPath(ovalIn: d).fill()
    }
    let tf = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let tc = w.dark ? rgb(0xFFFFFF, w.front ? 0.85 : 0.45) : rgb(0x000000, w.front ? 0.85 : 0.4)
    text(w.title, CGPoint(x: r.midX - width(w.title, tf) / 2, y: r.minY + bar / 2 - 8.5), tf, tc)
    body(NSRect(x: r.minX, y: r.minY + bar, width: r.width, height: r.height - bar))
    NSGraphicsContext.restoreGraphicsState()
    // a hairline edge, as macOS draws around every window
    (w.dark ? rgb(0xFFFFFF, 0.16) : rgb(0x000000, 0.18)).setStroke()
    let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
    edge.lineWidth = 0.5
    edge.stroke()
}

let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
let monoBold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)

// the editor, behind: a light code editor (as VS Code draws its light theme) with its sidebar and tab
window(Win(frame: NSRect(x: 520, y: 70, width: 690, height: 500), title: "checkout.ts — shop-api", front: false, dark: false)) { b in
    let side = NSRect(x: b.minX, y: b.minY, width: 180, height: b.height)
    rgb(0xF6F6F6).setFill()
    side.fill()
    rgb(0x000000, 0.08).setFill()
    NSRect(x: side.maxX - 0.5, y: b.minY, width: 0.5, height: b.height).fill()
    let sf = NSFont.systemFont(ofSize: 12), small = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    text("SHOP-API", CGPoint(x: side.minX + 14, y: b.minY + 12), small, rgb(0x000000, 0.45))
    let files: [(String, Int, Bool)] = [("src", 0, false), ("cart.ts", 1, false), ("checkout.ts", 1, true), ("orders.ts", 1, false),
                                        ("db.ts", 1, false), ("test", 0, false), ("package.json", 0, false), ("README.md", 0, false)]
    for (i, f) in files.enumerated() {
        let y = b.minY + 36 + CGFloat(i) * 24
        if f.2 {
            rgb(0x0A84FF, 0.14).setFill()
            NSBezierPath(roundedRect: NSRect(x: side.minX + 6, y: y - 3, width: side.width - 12, height: 22), xRadius: 5, yRadius: 5).fill()
        }
        let x = side.minX + 14 + CGFloat(f.1) * 14
        let folder = f.0 == "src" || f.0 == "test"
        _ = symbol(folder ? "folder.fill" : "doc.text", 11, folder ? rgb(0x4A90D9) : rgb(0x000000, 0.45), at: CGPoint(x: x, y: y + 8))
        text(f.0, CGPoint(x: x + 20, y: y), sf, rgb(0x000000, 0.8))
    }
    // the tab
    let tabs = NSRect(x: side.maxX, y: b.minY, width: b.maxX - side.maxX, height: 32)
    rgb(0xF3F3F3).setFill()
    tabs.fill()
    rgb(0xFFFFFF).setFill()
    NSRect(x: tabs.minX, y: tabs.minY, width: 130, height: 32).fill()
    text("checkout.ts", CGPoint(x: tabs.minX + 16, y: tabs.minY + 8), sf, rgb(0x000000, 0.8))
    let kw = rgb(0xAF00DB), fn = rgb(0x795E26), ty = rgb(0x267F99), str = rgb(0xA31515), num = rgb(0x098658), id = rgb(0x001080), plain = rgb(0x1F1F1F)
    let code: [[(String, NSColor)]] = [
        [("import", kw), (" { db } ", plain), ("from", kw), (" './db'", str)],
        [("import", kw), (" type { Cart } ", plain), ("from", kw), (" './cart'", str)],
        [],
        [("export async function ", kw), ("checkout", fn), ("(", plain), ("cart", id), (": ", plain), ("Cart", ty), (") {", plain)],
        [("  const ", kw), ("total", id), (" = ", plain), ("cart", id), (".items.", plain), ("reduce", fn), ("(", plain)],
        [("    (", plain), ("sum", id), (", ", plain), ("i", id), (") => ", plain), ("sum", id), (" + ", plain), ("i", id), (".price * ", plain),
         ("i", id), (".qty, ", plain), ("0", num), (")", plain)],
        [("  if", kw), (" (", plain), ("total", id), (" <= ", plain), ("0", num), (") ", plain), ("throw new ", kw), ("Error", ty), ("(", plain),
         ("'empty cart'", str), (")", plain)],
        [("  const ", kw), ("order", id), (" = ", plain), ("await ", kw), ("db", id), (".orders.", plain), ("create", fn), ("({", plain)],
        [("    total", id), (", ", plain), ("items", id), (": ", plain), ("cart", id), (".items,", plain)],
        [("  })", plain)],
        [("  return ", kw), ("order", id), (".id", plain)],
        [("}", plain)],
    ]
    for (i, line) in code.enumerated() {
        let y = tabs.maxY + 14 + CGFloat(i) * 21
        let n = "\(i + 1)"
        text(n, CGPoint(x: tabs.minX + 34 - width(n, mono), y: y), mono, rgb(0x000000, 0.3))
        var x = tabs.minX + 52
        for (s, c) in line {
            text(s, CGPoint(x: x, y: y), mono, c)
            x += width(s, mono)
        }
    }
}

// Terminal, in front: zsh in a dark profile
window(Win(frame: NSRect(x: 92, y: 150, width: 610, height: 400), title: "shop-api — zsh — 80×24", front: true, dark: true)) { b in
    let prompt = "dev@Studio shop-api % "
    let lines: [[(String, NSColor, NSFont)]] = [
        [(prompt, rgb(0xFFFFFF, 0.6), mono), ("git status", rgb(0xFFFFFF, 0.92), mono)],
        [("On branch main", rgb(0xFFFFFF, 0.85), mono)],
        [("Your branch is up to date with 'origin/main'.", rgb(0xFFFFFF, 0.85), mono)],
        [],
        [(prompt, rgb(0xFFFFFF, 0.6), mono), ("npm test", rgb(0xFFFFFF, 0.92), mono)],
        [("> shop-api@2.4.1 test", rgb(0xFFFFFF, 0.55), mono)],
        [("> vitest run", rgb(0xFFFFFF, 0.55), mono)],
        [],
        [(" ✓ ", rgb(0x32D74B), monoBold), ("src/cart.test.ts ", rgb(0xFFFFFF, 0.85), mono), ("(12 tests) 41ms", rgb(0xFFFFFF, 0.5), mono)],
        [(" ✓ ", rgb(0x32D74B), monoBold), ("src/checkout.test.ts ", rgb(0xFFFFFF, 0.85), mono), ("(8 tests) 63ms", rgb(0xFFFFFF, 0.5), mono)],
        [(" ✓ ", rgb(0x32D74B), monoBold), ("src/orders.test.ts ", rgb(0xFFFFFF, 0.85), mono), ("(15 tests) 88ms", rgb(0xFFFFFF, 0.5), mono)],
        [],
        [(" Test Files  ", rgb(0xFFFFFF, 0.5), mono), ("3 passed", rgb(0x32D74B), monoBold), (" (3)", rgb(0xFFFFFF, 0.5), mono)],
        [("      Tests  ", rgb(0xFFFFFF, 0.5), mono), ("35 passed", rgb(0x32D74B), monoBold), (" (35)", rgb(0xFFFFFF, 0.5), mono)],
        [],
        [(prompt, rgb(0xFFFFFF, 0.6), mono)],
    ]
    var last = CGPoint.zero
    for (i, line) in lines.enumerated() {
        let y = b.minY + 12 + CGFloat(i) * 20.5
        var x = b.minX + 14
        for (s, c, f) in line {
            text(s, CGPoint(x: x, y: y), f, c)
            x += width(s, f)
        }
        last = CGPoint(x: x, y: y)
    }
    // the cursor block
    rgb(0xFFFFFF, 0.75).setFill()
    NSRect(x: last.x + 1, y: last.y + 1, width: 7.5, height: 15).fill()
}

// MARK: the menu bar

let bar = NSRect(x: 0, y: 0, width: W, height: 24)
rgb(0xFFFFFF, 0.42).setFill()
bar.fill()
let mf = NSFont.systemFont(ofSize: 13), mfb = NSFont.systemFont(ofSize: 13, weight: .bold)
let ink = rgb(0x000000, 0.86)
text("\u{F8FF}", CGPoint(x: 18, y: 3), NSFont.systemFont(ofSize: 15), ink)
var mx: CGFloat = 46
text("Terminal", CGPoint(x: mx, y: 4), mfb, ink)
mx += width("Terminal", mfb) + 20
for m in ["Shell", "Edit", "View", "Window", "Help"] {
    text(m, CGPoint(x: mx, y: 4), mf, ink)
    mx += width(m, mf) + 20
}
// right: the clock, then status items leftwards
let clock = "Fri Nov 21  10:24"
var rx = W - 16 - width(clock, mf)
text(clock, CGPoint(x: rx, y: 4), mf, ink)
for s in ["switch.2", "magnifyingglass", "wifi"] {
    rx -= 30
    _ = symbol(s, 13, ink, at: CGPoint(x: rx, y: 12), weight: .medium)
}

// MARK: the Dock

let apps = ["/System/Library/CoreServices/Finder.app", "/System/Cryptexes/App/System/Applications/Safari.app", "/System/Applications/Mail.app",
            "/System/Applications/Messages.app", "/System/Applications/Calendar.app", "/System/Applications/Notes.app",
            "/System/Applications/Music.app", "/System/Applications/Utilities/Terminal.app", "/Applications/Visual Studio Code.app",
            "/System/Applications/System Settings.app"].filter { FileManager.default.fileExists(atPath: $0) }
let running: Set<String> = ["/System/Library/CoreServices/Finder.app", "/System/Applications/Utilities/Terminal.app", "/Applications/Visual Studio Code.app",
                            "/System/Cryptexes/App/System/Applications/Safari.app"]
let trash = "/System/Library/CoreServices/Dock.app/Contents/Resources/trashempty.png"
let icon: CGFloat = 50, gap: CGFloat = 6, pad: CGFloat = 8
let count = CGFloat(apps.count) + 1
let dockW = pad * 2 + count * icon + (count - 1) * gap + 14
let dock = NSRect(x: (W - dockW) / 2, y: H - 6 - (icon + pad * 2), width: dockW, height: icon + pad * 2)
NSGraphicsContext.saveGraphicsState()
let ds = NSShadow()
ds.shadowColor = NSColor.black.withAlphaComponent(0.18)
ds.shadowBlurRadius = 18
ds.shadowOffset = NSSize(width: 0, height: -4)
ds.set()
rgb(0xFFFFFF, 0.34).setFill()
NSBezierPath(roundedRect: dock, xRadius: 20, yRadius: 20).fill()
NSGraphicsContext.restoreGraphicsState()
rgb(0xFFFFFF, 0.5).setStroke()
let dockEdge = NSBezierPath(roundedRect: dock.insetBy(dx: 0.5, dy: 0.5), xRadius: 20, yRadius: 20)
dockEdge.lineWidth = 1
dockEdge.stroke()
var ix = dock.minX + pad
for a in apps {
    let img = NSWorkspace.shared.icon(forFile: a)
    img.size = NSSize(width: 256, height: 256)
    img.draw(in: NSRect(x: ix, y: dock.minY + pad, width: icon, height: icon), from: .zero, operation: .sourceOver, fraction: 1,
             respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    if running.contains(a) {
        rgb(0x000000, 0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: ix + icon / 2 - 2, y: dock.maxY - 5, width: 4, height: 4)).fill()
    }
    ix += icon + gap
}
// the divider, then the Trash
rgb(0x000000, 0.16).setFill()
NSRect(x: ix + 3, y: dock.minY + 12, width: 1, height: dock.height - 24).fill()
ix += 14
if let t = NSImage(contentsOfFile: trash) ?? NSImage(named: NSImage.trashEmptyName) {
    t.draw(in: NSRect(x: ix, y: dock.minY + pad, width: icon, height: icon), from: .zero, operation: .sourceOver, fraction: 1,
           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) \(rep.pixelsWide)x\(rep.pixelsHigh)")
