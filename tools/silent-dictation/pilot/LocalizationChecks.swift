// Run against the built app bundle without opening a window or capture device.
import Foundation

@main struct LocalizationChecks {
    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let cases: [([String], String)] = [
            (["zh-Hans-CN", "en"], "zh-Hans"), (["zh-SG"], "zh-Hans"),
            (["zh-Hant", "en"], "zh-Hant"), (["zh-TW"], "zh-Hant"),
            (["zh_HK"], "zh-Hant"), (["zh-MO"], "zh-Hant"),
            (["zh-Hans-HK"], "zh-Hans"), (["en-GB", "zh-Hans"], "en"),
            (["fr-FR", "zh-Hant"], "zh-Hant"), (["fr-FR"], "en"), ([], "en")
        ]
        for (preferred, expected) in cases {
            precondition(Localizer.resolve(.system, preferred: preferred) == expected)
        }
        precondition(Localizer.resolve(.english, preferred: ["zh-Hans"]) == "en")
        let suite = "local.blurt.pilot.localization-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let strings = Localizer(defaults: defaults, resources: bundle, preferredLanguages: { ["zh-Hans-CN"] })
        precondition(strings.selection == .system)
        precondition(strings.text("record.start") == "开始录制")
        let message = UIMessage("status.remaining", 7)
        precondition(strings.render(message).contains("7 段"))
        strings.selection = .english
        precondition(strings.text("record.start") == "Record take")
        precondition(strings.render(message) == "Camera and microphone are off. 7 takes remain.")
        let restored = Localizer(defaults: defaults, resources: bundle, preferredLanguages: { ["zh-Hans"] })
        precondition(restored.selection == .english)
        strings.selection = .traditionalChinese
        precondition(strings.text("record.start") == "開始錄製")
        strings.selection = .system
        precondition(strings.text("record.start") == "开始录制")

        var catalogs: [[String: String]] = []
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let folder = bundle.resourceURL!.appendingPathComponent("\(language).lproj")
            let data = try Data(contentsOf: folder.appendingPathComponent("Localizable.strings"))
            let catalog = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: String]
            precondition(!catalog.values.contains(where: { $0.isEmpty }))
            catalogs.append(catalog)
            let infoData = try Data(contentsOf: folder.appendingPathComponent("InfoPlist.strings"))
            let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as! [String: String]
            precondition(info["NSCameraUsageDescription"] != nil && info["NSMicrophoneUsageDescription"] != nil)
        }
        let formats = try NSRegularExpression(pattern: "%[@d]")
        func placeholders(_ text: String) -> [String] {
            formats.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
        }
        for catalog in catalogs.dropFirst() {
            precondition(Set(catalog.keys) == Set(catalogs[0].keys))
            for key in catalog.keys { precondition(placeholders(catalog[key]!) == placeholders(catalogs[0][key]!)) }
        }
        print("Localization checks passed: system preference resolution, live status formatting, persistence, 3 complete catalogs, permission strings.")
    }
}
