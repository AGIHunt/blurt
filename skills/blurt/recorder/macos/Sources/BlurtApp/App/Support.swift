import AppKit
import BlurtCore
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Options & utilities

struct Options {
    var out = ""
    var events: String? = nil
    var standalone = false         // launched as an app (no --out): lives in the menu bar, records into a workspace
    var fps = 30
    var maxWidth = 2560
    var countdown = 3
    var lang: String? = nil       // --lang en|zh-Hans: overrides config `lang` (K10, Loc.setting)
    var region: CGRect? = nil      // skip picker (global top-left points)
    var lastRegion: CGRect? = nil  // offered in the picker
    var preselect: CGRect? = nil   // picker opens with this selection (testing / "last region")
    var mic = true
    var micName: String? = nil
    var systemAudio = false        // second audio track: what the Mac plays (meeting voices, demo sound), macOS 13+
    var live = true                // mic also → <session>/live/audio.pcm for live.py (LiveAudio.swift); --no-live

    static func parse() -> Options {
        var o = Options()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        func rect(_ s: String?) -> CGRect? {
            guard let p = s?.split(separator: ",").compactMap({ Double($0) }), p.count == 4 else { return nil }
            return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
        }
        while let a = it.next() {
            switch a {
            case "--out": o.out = it.next() ?? o.out
            case "--events": o.events = it.next()
            case "--fps": o.fps = Int(it.next() ?? "") ?? o.fps
            case "--max-width": o.maxWidth = Int(it.next() ?? "") ?? o.maxWidth
            case "--countdown": o.countdown = Int(it.next() ?? "") ?? o.countdown
            case "--lang": o.lang = it.next()
            case "--region": o.region = rect(it.next())
            case "--last-region": o.lastRegion = rect(it.next())
            case "--preselect": o.preselect = rect(it.next())
            case "--no-mic": o.mic = false
            case "--mic": o.micName = it.next()
            case "--system-audio": o.systemAudio = true
            case "--no-live": o.live = false
            default: break
            }
        }
        if o.out.isEmpty { o.standalone = true }
        return o
    }
}

// MARK: - Config shared with record.py (~/.blurt/config.json)

// BLURT_HOME (as in record.py) relocates config/build state; tests use it to stay out of the user's real setup.
let blurtHome = BlurtPaths.home
let configURL = BlurtPaths.config

func readConfig() -> [String: Any] { Config.shared.all }

func recordConfig() -> [String: Any] { Config.shared.record }

func setRecordConfig(_ key: String, _ value: Any?) { Config.shared.set("record." + key, value) }

func saveLastRegion(_ r: CGRect) { setRecordConfig("last_region", [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]) }

func lastRegionFromConfig() -> CGRect? {
    guard let r = recordConfig()["last_region"] as? [Double], r.count == 4 else { return nil }
    return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
}

func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let s = String(data: d, encoding: .utf8) {
        print(s)
        fflush(stdout)
    }
}

/// Global coordinates: AppKit uses bottom-left origin, CoreGraphics / ScreenCaptureKit use top-left.
var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
func toCG(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
func toNS(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }

/// Our chrome is hidden from every screen capture; BLURT_DEBUG_CHROME=1 makes it screenshot-able (still excluded
/// from blurt's own recording via the content filter).
let chromeSharing: NSWindow.SharingType = ProcessInfo.processInfo.environment["BLURT_DEBUG_CHROME"] == nil ? .none : .readOnly

func activateApp() {
    if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
}

func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

@available(*, deprecated, message: "the coral is retired: BrandColor.Island.fill / .rec, or BrandColor.markup for the pen")
let accent = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.24, alpha: 1)   // coral
@available(*, deprecated, message: "BrandColor.Island.attn (or BrandColor.attn on app surfaces)")
let amber = NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.24, alpha: 1)

func pill(_ text: String, font: NSFont, fg: NSColor, bg: NSColor, at p: NSPoint, pad: CGFloat = 8, icon: BlurtIcon? = nil) -> NSRect {
    let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg])
    let sz = s.size()
    let iw = icon == nil ? 0 : pillIconWidth(font)
    let r = NSRect(x: p.x, y: p.y, width: sz.width + pad * 2 + iw, height: sz.height + pad)
    bg.setFill()
    NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    if let icon = icon {     // a brand icon in front of the text (never an emoji)
        let side = (font.pointSize * 1.2).rounded()
        icon.image(size: side, color: fg).draw(in: NSRect(x: r.minX + pad, y: r.midY - side / 2, width: side, height: side),
                                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    s.draw(at: NSPoint(x: r.minX + pad + iw, y: r.minY + pad / 2))
    return r
}

/// Room an icon takes in a pill: the icon (1.2 × the font size) and a gap.
func pillIconWidth(_ font: NSFont) -> CGFloat { (font.pointSize * 1.2).rounded() + 6 }
