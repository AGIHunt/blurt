// Debug builds only: the main screen as if a computer were connected, for layout work and screenshots without one (apps/ios/README.md
// §Develop). `SIMCTL_CHILD_BLURT_REMOTE_PRETEND=1` lights the keys; `=screen` also shows a made-up desktop where the picture goes.
// Tests set the fold here, since a simulator without one can't report it.
#if DEBUG
import BlurtRemoteKit
import UIKit

enum Pretend {
    static var connected = ProcessInfo.processInfo.environment["BLURT_REMOTE_PRETEND"] != nil
    static var screen = ProcessInfo.processInfo.environment["BLURT_REMOTE_PRETEND"] == "screen"
    /// `BLURT_REMOTE_PRETEND_BOARD=1`: with the computer keyboard out
    static var board = ProcessInfo.processInfo.environment["BLURT_REMOTE_PRETEND_BOARD"] != nil
    /// stands in for UIKit's reserved regions
    static var surround: PadSurround?
    /// and for the safe area: a render of another device's room on whatever simulator runs the tests
    static var safe: UIEdgeInsets?
    /// `BLURT_REMOTE_PRETEND_DISPLAYS=1`: a laptop with a monitor beside it, for the display switcher
    static let displays: [RemoteDisplay] = ProcessInfo.processInfo.environment["BLURT_REMOTE_PRETEND_DISPLAYS"] == nil ? [] : [
        RemoteDisplay(id: "1", name: "Built-in Retina Display", x: 0, y: 0, width: 1728, height: 1117, main: true),
        RemoteDisplay(id: "2", name: "DELL P2725QE", x: 1728, y: -523, width: 2560, height: 1440, main: false),
    ]
    /// `BLURT_REMOTE_PRETEND_TRANSFERS=1`: the Transfer sheet's list filled with each kind of row, and a computer that takes files and gives its
    /// clipboard; `=sheet` opens the sheet, `=toast` shows the pad's toast for an image copied (docs/design/remote-files.md)
    static let transfers = ProcessInfo.processInfo.environment["BLURT_REMOTE_PRETEND_TRANSFERS"]

    /// The rows: one going out in a batch, the next waiting, one paused, one coming in, two received, one sent, one that couldn't go.
    static func fillTransfers(peer: String) {
        let docs = Link.documents, now = Date()
        // received files that exist, so a tap has something to open
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).jpegData(withCompressionQuality: 0.8) { c in
            UIColor(red: 0.95, green: 0.93, blue: 0.86, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            ("3. 解方程 2x + 5 = 17" as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 26), .foregroundColor: UIColor.darkGray])
        }
        try? photo.write(to: docs.appendingPathComponent("作业 3.jpg"))
        try? Data("报价".utf8).write(to: docs.appendingPathComponent("Q4 报价单.xlsx"))
        func r(_ id: String, _ name: String, _ size: Int, _ done: Int, incoming: Bool, _ phase: TransferRow.Phase, index: Int? = nil, count: Int? = nil,
               file: String? = nil, left: Double? = nil, ago: Double) -> TransferRow {
            TransferRow(id: id, wire: id, name: name, size: size, done: done, incoming: incoming, phase: phase, index: index, count: count, peer: peer,
                        file: file, at: now.addingTimeInterval(-ago), secondsLeft: left)
        }
        Transfers.shared.pretend([
            r("out-1", "片段 2.mov", 412_000_000, 148_000_000, incoming: false, .going, index: 2, count: 3, left: 184, ago: 10),
            r("out-2", "片段 3.mov", 236_000_000, 0, incoming: false, .waiting, index: 3, count: 3, ago: 10),
            r("in-1", "设计稿.zip", 86_000_000, 35_000_000, incoming: true, .going, left: 42, ago: 30),
            r("out-3", "Q3 汇报.key", 52_000_000, 31_700_000, incoming: false, .paused, ago: 60),
            r("in-2", "作业 3.jpg", photo.count, photo.count, incoming: true, .done, file: "作业 3.jpg", ago: 300),
            r("in-3", "Q4 报价单.xlsx", 48_200, 48_200, incoming: true, .done, file: "Q4 报价单.xlsx", ago: 900),
            r("out-4", "合同扫描.pdf", 2_400_000, 2_400_000, incoming: false, .done, ago: 1800),
            r("out-5", "旧备份.zip", 5_100_000_000, 0, incoming: false, .failed("too_big"), ago: 3600),
        ])
    }

    /// `BLURT_REMOTE_PRETEND_TURN=left|right|down`: the window turns that way once it's up, for screenshots of a simulator nobody turns
    static func turn(_ s: UIWindowScene?) {
        guard let t = ProcessInfo.processInfo.environment["BLURT_REMOTE_PRETEND_TURN"], let s else { return }
        let o: UIInterfaceOrientationMask = t == "left" ? .landscapeLeft : t == "right" ? .landscapeRight : t == "down" ? .portraitUpsideDown : .portrait
        s.requestGeometryUpdate(.iOS(interfaceOrientations: o))
    }

    /// A desktop of the computer's shape: a menu bar, a terminal with an agent at work, an editor beside it. Nothing personal.
    static func desktop(aspect: CGFloat) -> UIImage {
        let w: CGFloat = 1512, h = (w / aspect).rounded()
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: f).image { c in
            let g = c.cgContext
            let wall = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor(red: 0.16, green: 0.22, blue: 0.36, alpha: 1).cgColor,
                                                                                     UIColor(red: 0.42, green: 0.30, blue: 0.46, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            g.drawLinearGradient(wall, start: .zero, end: CGPoint(x: w, y: h), options: [])
            UIColor(white: 0.1, alpha: 0.55).setFill()
            g.fill(CGRect(x: 0, y: 0, width: w, height: 30))
            let bar: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: UIColor.white]
            ("  Terminal     File   Edit   View   Window   Help" as NSString).draw(at: CGPoint(x: 18, y: 6), withAttributes: bar)
            ("Mon 9:41" as NSString).draw(at: CGPoint(x: w - 110, y: 6), withAttributes: bar)

            func window(_ r: CGRect, title: String, dark: Bool, lines: [(String, UIColor)], size: CGFloat) {
                let p = UIBezierPath(roundedRect: r, cornerRadius: 12)
                g.saveGState()
                g.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: UIColor(white: 0, alpha: 0.45).cgColor)
                (dark ? UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1) : UIColor(white: 0.97, alpha: 1)).setFill()
                p.fill()
                g.restoreGState()
                for (i, c) in [UIColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    c.setFill()
                    UIBezierPath(ovalIn: CGRect(x: r.minX + 16 + CGFloat(i) * 20, y: r.minY + 13, width: 12, height: 12)).fill()
                }
                (title as NSString).draw(at: CGPoint(x: r.midX - CGFloat(title.count) * 3.6, y: r.minY + 10),
                                         withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: dark ? UIColor(white: 0.7, alpha: 1) : UIColor(white: 0.35, alpha: 1)])
                var y = r.minY + 46
                for (t, col) in lines {
                    (t as NSString).draw(at: CGPoint(x: r.minX + 20, y: y), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: col])
                    y += size * 1.55
                    if y > r.maxY - 20 { break }
                }
            }
            let grey = UIColor(white: 0.62, alpha: 1), white = UIColor(white: 0.92, alpha: 1), mint = UIColor(red: 0.38, green: 0.86, blue: 0.74, alpha: 1)
            let orange = UIColor(red: 0.96, green: 0.62, blue: 0.38, alpha: 1)
            window(CGRect(x: 40, y: 60, width: w * 0.5, height: h - 100), title: "~/projects/notes — claude", dark: true, lines: [
                ("> Add a dark mode toggle to the settings page", white),
                ("", grey),
                ("● I'll look at how settings are laid out first.", mint),
                ("  Read src/settings/SettingsView.swift (212 lines)", grey),
                ("  Read src/theme/Theme.swift (88 lines)", grey),
                ("", grey),
                ("● The theme already has light and dark palettes.", mint),
                ("  I'll add a toggle that switches between them", white),
                ("  and remembers the choice.", white),
                ("", grey),
                ("  Update src/settings/SettingsView.swift", orange),
                ("   + Toggle(\"Dark Mode\", isOn: $prefs.dark)", mint),
                ("   + .onChange(of: prefs.dark) { theme.apply($0) }", mint),
                ("", grey),
                ("  Run swift test", orange),
                ("   Executed 48 tests, with 0 failures", grey),
                ("", grey),
                ("● Done. The toggle is under Appearance.", mint),
                ("", grey),
                ("> ▌", white),
            ], size: 17)
            window(CGRect(x: w * 0.5 + 64, y: 90, width: w * 0.5 - 104, height: h - 160), title: "SettingsView.swift", dark: false, lines: [
                ("struct SettingsView: View {", UIColor(red: 0.6, green: 0.2, blue: 0.6, alpha: 1)),
                ("    @ObservedObject var prefs: Prefs", UIColor(white: 0.25, alpha: 1)),
                ("", grey),
                ("    var body: some View {", UIColor(white: 0.25, alpha: 1)),
                ("        Form {", UIColor(white: 0.25, alpha: 1)),
                ("            Section(\"Appearance\") {", UIColor(red: 0.75, green: 0.2, blue: 0.15, alpha: 1)),
                ("                Toggle(\"Dark Mode\",", UIColor(red: 0.75, green: 0.2, blue: 0.15, alpha: 1)),
                ("                       isOn: $prefs.dark)", UIColor(white: 0.25, alpha: 1)),
                ("            }", UIColor(white: 0.25, alpha: 1)),
                ("            Section(\"Account\") {", UIColor(red: 0.75, green: 0.2, blue: 0.15, alpha: 1)),
                ("                Text(\"Signed in\")", UIColor(white: 0.25, alpha: 1)),
                ("            }", UIColor(white: 0.25, alpha: 1)),
                ("        }", UIColor(white: 0.25, alpha: 1)),
                ("    }", UIColor(white: 0.25, alpha: 1)),
                ("}", UIColor(white: 0.25, alpha: 1)),
            ], size: 15)
        }
    }
}
#endif
