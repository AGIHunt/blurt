// BlurtCore/WelcomeLine.swift: the first launch's line only advertises keys that work, and a shortcut that doesn't is
// said on that same line.
import AppKit
import XCTest
@testable import BlurtCore

final class WelcomeLineTests: XCTestCase {
    func testEverythingWorks() {
        let l = WelcomeLine.compose(dictation: .works, dictationKey: "Fn", snap: "⌥⇧A", record: "⌥⇧R", conflicts: [])
        XCTAssertEqual(l.key, "app.toast.welcome")
        XCTAssertEqual(l.args, ["Fn", "⌥⇧A"])
        XCTAssertNil(l.action)
    }

    func testFnIsOnlyAdvertisedWhenDictationCanServeIt() {
        // the key isn't heard (no Accessibility): the line says how to turn it on, with the button
        let deaf = WelcomeLine.compose(dictation: .needsSetup, dictationKey: "Fn", snap: "⌥⇧A", record: nil, conflicts: [])
        XCTAssertEqual(deaf.key, "app.toast.welcome_setup")
        XCTAssertFalse(deaf.args.contains("Fn"))
        XCTAssertEqual(deaf.action, .turnOnDictation)
        // no speech model yet: download it first
        let noModel = WelcomeLine.compose(dictation: .noModel, dictationKey: "Fn", snap: "⌥⇧A", record: nil, conflicts: [])
        XCTAssertEqual(noModel.key, "app.toast.welcome_no_model")
        XCTAssertEqual(noModel.action, .downloadModel)
    }

    func testASnapKeyThatDoesNotWorkIsLeftOutAndNamed() {
        // ⇧⌘3 is macOS's: not advertised; the line says it won't work instead, and the button changes it
        let l = WelcomeLine.compose(dictation: .works, dictationKey: "Fn", snap: nil, record: "⌥⇧R", conflicts: ["⇧⌘3"])
        XCTAssertEqual(l.key, "app.toast.welcome_taken")
        XCTAssertEqual(l.args, ["⇧⌘3"])
        XCTAssertEqual(l.conflicts, ["⇧⌘3"])
        XCTAssertEqual(l.action, .changeShortcut)
        // several: how many (the list is in Settings)
        let many = WelcomeLine.compose(dictation: .off, dictationKey: "Fn", snap: nil, record: nil, conflicts: ["⌥⇧A", "⌥⇧R"])
        XCTAssertEqual(many.key, "app.toast.welcome_taken_many")
        XCTAssertEqual(many.args, ["2"])
        // a more urgent button stays; the conflict is still named
        let both = WelcomeLine.compose(dictation: .needsSetup, dictationKey: "Fn", snap: nil, record: nil, conflicts: ["⌥⇧A"])
        XCTAssertEqual(both.action, .turnOnDictation)
        XCTAssertEqual(both.conflicts, ["⌥⇧A"])
    }

    func testDictationModelsUnreadableDoesNotAdvertiseTheKey() {
        // the model list couldn't be read: Fn isn't promised (it may end in "no speech model"), the rest is
        let l = WelcomeLine.compose(dictation: .unknown, dictationKey: "Fn", snap: "⌥⇧A", record: "⌥⇧R", conflicts: [])
        XCTAssertEqual(l.key, "app.toast.welcome_no_dictation")
        XCTAssertFalse(l.args.contains("Fn"))
    }

    func testDictationOff() {
        XCTAssertEqual(WelcomeLine.compose(dictation: .off, dictationKey: "Fn", snap: "⌥⇧A", record: "⌥⇧R", conflicts: []).key,
                       "app.toast.welcome_no_dictation")
        XCTAssertEqual(WelcomeLine.compose(dictation: .off, dictationKey: "Fn", snap: "⌥⇧A", record: nil, conflicts: []).key,
                       "app.toast.welcome_snap_only")
        XCTAssertEqual(WelcomeLine.compose(dictation: .off, dictationKey: "Fn", snap: nil, record: nil, conflicts: []).key,
                       "app.toast.welcome_plain")
    }
}

/// Every welcome line, in both languages, fits on the island's one toast row with its button — it is the first sentence
/// a new user reads, and a cut-off one ("…download the speech model…") was what the first run showed. The budget is
/// the island's toast row (IslandContent.buildToast): 480 pt wide, the text 18 pt in, the button 18 pt from the right
/// edge with 10 pt before it, its title + 26 pt; text at 13 pt medium, plus the label's own inset.
final class WelcomeLineWidthTests: XCTestCase {
    static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Sources/BlurtApp/Resources").standardizedFileURL

    func table(_ lang: String, _ name: String) -> [String: String] {
        NSDictionary(contentsOf: Self.resources.appendingPathComponent("\(lang).lproj/\(name).strings")) as? [String: String] ?? [:]
    }

    func width(_ s: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    func room(button: String?) -> CGFloat {
        let right: CGFloat = 18 + (button.map { width($0, size: 12.5, weight: .semibold) + 26 + 10 } ?? 0)
        return 480 - 18 - right - 4
    }

    func testEveryVariantFitsTheIsland() {
        for lang in ["en", "zh-Hans"] {
            let main = table(lang, "Main"), capture = table(lang, "Capture"), dictation = table(lang, "Dictation")
            func f(_ key: String, _ args: [String]) -> String { String(format: main[key] ?? key, arguments: args.map { $0 as CVarArg }) }
            let keyNames = ["fn", "right_option", "either_option"].compactMap { dictation["dictation.key.\($0).short"] }
            XCTAssertEqual(keyNames.count, 3, lang)
            var lines: [(String, String?)] = []
            func add(_ l: WelcomeLine.Line) {
                let button: String? = switch l.action {
                case .turnOnDictation?: main["app.toast.welcome_setup.action"]
                case .downloadModel?: main["app.toast.welcome_no_model.action"]
                case .changeShortcut?: main["app.toast.change_shortcut"]
                case nil: nil
                }
                lines.append((f(l.key, l.args), button))
            }
            for k in keyNames {
                for snap in ["⌥⇧A", nil] {
                    add(WelcomeLine.compose(dictation: .works, dictationKey: k, snap: snap, record: "⌥⇧R", conflicts: []))
                }
            }
            for d in [WelcomeLine.Dictation.works, .needsSetup, .noModel, .unknown, .off] {
                for conflicts in [[], ["⌃⌥⇧⌘A"], ["⌥⇧A", "⌥⇧R", "⌥⇧V"]] {
                    for (snap, record) in [("⌥⇧A", "⌥⇧R"), ("⌥⇧A", nil), (nil, nil)] as [(String?, String?)] {
                        add(WelcomeLine.compose(dictation: d, dictationKey: keyNames[2], snap: snap, record: record, conflicts: conflicts))
                    }
                }
            }
            for (text, button) in lines {
                XCTAssertFalse(text.contains("app.toast"), "\(lang): missing string in \(text)")
                let w = width(text, size: 13, weight: .medium), r = room(button: button)
                XCTAssertLessThanOrEqual(w, r, "\(lang): “\(text)” is \(w) pt, the island has \(r) pt beside “\(button ?? "")”")
            }
        }
    }
}
