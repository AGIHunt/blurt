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

    func testDictationModelsUnreadableSaysDictationIsNotSetUp() {
        // the model list couldn't be read (the speech tools didn't install: offline first run): Fn isn't promised, and
        // the line says dictation isn't set up yet, with Set Up… — not a line that just leaves dictation out
        let l = WelcomeLine.compose(dictation: .unknown, dictationKey: "Fn", snap: "⌥⇧A", record: "⌥⇧R", conflicts: [])
        XCTAssertEqual(l.key, "app.toast.welcome_not_set_up")
        XCTAssertEqual(l.action, .setUpDictation)
        XCTAssertFalse(l.args.contains("Fn"))
    }

    func testDictationModelsUnreadableOnlineSaysSoWithTryAgain() {
        // the list failed while online, twice (a script error): not "isn't set up" (it sent people to set up what was
        // there) — the models couldn't be checked, with Try Again
        let l = WelcomeLine.compose(dictation: .unreadable, dictationKey: "Fn", snap: "⌥⇧A", record: "⌥⇧R", conflicts: [])
        XCTAssertEqual(l.key, "app.toast.welcome_unreadable")
        XCTAssertEqual(l.action, .readModelsAgain)
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

    // MARK: only the keys of capabilities that are on (Capabilities.swift)

    func testCardsOffNamesNoSnapKey() {
        let l = WelcomeLine.compose(dictation: .works, dictationKey: "Fn", snap: "⌥A", record: "⌥R", conflicts: [], off: [.cards])
        XCTAssertEqual(l.key, "app.toast.welcome_dictation_only")
        XCTAssertEqual(l.args, ["Fn"])
        // …and without dictation there is no key left that the line has words for: where Blurt lives, nothing else
        let plain = WelcomeLine.compose(dictation: .off, dictationKey: "Fn", snap: "⌥A", record: "⌥R", conflicts: [], off: [.cards])
        XCTAssertEqual(plain.key, "app.toast.welcome_plain")
        XCTAssertEqual(plain.args, [])
    }

    func testRecordingOffNamesNoRecordKey() {
        let l = WelcomeLine.compose(dictation: .off, dictationKey: "Fn", snap: "⌥A", record: "⌥R", conflicts: [], off: [.recording])
        XCTAssertEqual(l.key, "app.toast.welcome_snap_only")
        XCTAssertEqual(l.args, ["⌥A"])
    }

    func testDictationOffSaysNothingAboutDictation() {
        // switched off as a capability: no key, no "dictation is off · Turn On…", no model to download
        for d in [WelcomeLine.Dictation.works, .needsSetup, .noModel, .unknown, .unreadable, .off] {
            let l = WelcomeLine.compose(dictation: d, dictationKey: "Fn", snap: "⌥A", record: "⌥R", conflicts: [], off: [.dictation])
            XCTAssertEqual(l.key, "app.toast.welcome_no_dictation", "\(d)")
            XCTAssertEqual(l.args, ["⌥A", "⌥R"], "\(d)")
            XCTAssertNil(l.action, "\(d)")
        }
    }

    func testOnlyDictationOn() {
        let l = WelcomeLine.compose(dictation: .works, dictationKey: "Fn", snap: "⌥A", record: "⌥R", conflicts: [],
                                    off: [.cards, .screenText, .recording, .phone])
        XCTAssertEqual(l.key, "app.toast.welcome_dictation_only")
        XCTAssertEqual(l.args, ["Fn"])
    }

    func testEverythingOffIsThePlainLine() {
        let l = WelcomeLine.compose(dictation: .works, dictationKey: "Fn", snap: "⌥A", record: "⌥R", conflicts: [],
                                    off: Set(Capability.allCases))
        XCTAssertEqual(l.key, "app.toast.welcome_plain")
        XCTAssertEqual(l.args, [])
        XCTAssertNil(l.action)
    }

    func testScreenTextAndPhoneChangeNothing() {
        let all = WelcomeLine.compose(dictation: .works, dictationKey: "Fn", snap: "⌥A", record: "⌥R", conflicts: [])
        XCTAssertEqual(WelcomeLine.compose(dictation: .works, dictationKey: "Fn", snap: "⌥A", record: "⌥R", conflicts: [],
                                           off: [.screenText, .phone]), all)
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
                case .setUpDictation?: main["app.toast.welcome_not_set_up.action"]
                case .readModelsAgain?: main["app.toast.welcome_unreadable.action"]
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
            for d in [WelcomeLine.Dictation.works, .needsSetup, .noModel, .unknown, .unreadable, .off] {
                for conflicts in [[], ["⌃⌥⇧⌘A"], ["⌥⇧A", "⌥⇧R", "⌥⇧V"]] {
                    for (snap, record) in [("⌥⇧A", "⌥⇧R"), ("⌥⇧A", nil), (nil, nil)] as [(String?, String?)] {
                        add(WelcomeLine.compose(dictation: d, dictationKey: keyNames[2], snap: snap, record: record, conflicts: conflicts))
                    }
                }
            }
            // the other launch lines that explain a problem: a config.json that can't be read, shortcuts that don't
            // work (one by name, several by count), models waiting for the network, dictation not set up
            lines.append((main["app.config.unreadable"] ?? "app.toast?", main["app.config.show"]))
            lines.append((main["app.config.not_saved"] ?? "app.toast?", main["app.config.show"]))
            lines.append((String(format: capture["capture.keys.wont_work"] ?? "app.toast?", "⌃⌥⇧⌘A"), main["app.toast.change_shortcut"]))
            lines.append((String(format: capture["capture.keys.wont_work_many"] ?? "app.toast?", "11"), main["app.toast.change_shortcut"]))
            lines.append((main["app.models.offline"] ?? "app.toast?", table(lang, "Settings")["onboarding.models.retry"]))
            lines.append((dictation["dictation.toast.not_set_up"] ?? "app.toast?", dictation["dictation.toast.not_set_up.action"]))
            for (text, button) in lines {
                XCTAssertFalse(text.contains("app.toast"), "\(lang): missing string in \(text)")
                let w = width(text, size: 13, weight: .medium), r = room(button: button)
                XCTAssertLessThanOrEqual(w, r, "\(lang): “\(text)” is \(w) pt, the island has \(r) pt beside “\(button ?? "")”")
            }
        }
    }
}
