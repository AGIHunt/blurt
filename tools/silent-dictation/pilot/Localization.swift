import Foundation
import Combine

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    var id: String { rawValue }
}

// Keep message keys and arguments, so existing status messages also change language immediately.
struct UIMessage {
    let key: String
    let arguments: [CVarArg]
    init(_ key: String, _ arguments: CVarArg...) {
        self.key = key; self.arguments = arguments
    }
}

struct PilotError: LocalizedError {
    let message: UIMessage
    init(_ key: String, _ arguments: CVarArg...) {
        message = UIMessage(key: key, arguments: arguments)
    }
    var errorDescription: String? { Localizer.shared.render(message) }
}

extension UIMessage {
    init(key: String, arguments: [CVarArg]) { self.key = key; self.arguments = arguments }
}

final class Localizer: ObservableObject {
    static let shared = Localizer()
    private let defaults: UserDefaults
    private let resources: Bundle
    private let preferredLanguages: () -> [String]
    @Published var selection: InterfaceLanguage {
        didSet { defaults.set(selection.rawValue, forKey: "pilot.interfaceLanguage"); refresh() }
    }
    @Published private(set) var resolvedLanguage = "en"

    init(defaults: UserDefaults = .standard, resources: Bundle = .main,
         preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults; self.resources = resources; self.preferredLanguages = preferredLanguages
        selection = InterfaceLanguage(rawValue: defaults.string(forKey: "pilot.interfaceLanguage") ?? "system") ?? .system
        refresh()
    }

    static func resolve(_ selection: InterfaceLanguage, preferred: [String]) -> String {
        if selection != .system { return selection.rawValue }
        for language in preferred {
            let parts = language.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
            if parts.first == "en" { return "en" }
            if parts.first == "zh" {
                if parts.contains("hans") { return "zh-Hans" }
                if parts.contains("hant") || parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) { return "zh-Hant" }
                return "zh-Hans"
            }
        }
        return "en"
    }

    func refresh() { resolvedLanguage = Self.resolve(selection, preferred: preferredLanguages()) }
    var locale: Locale { Locale(identifier: resolvedLanguage) }

    func text(_ key: String) -> String {
        for language in [resolvedLanguage, "en"] {
            if let path = resources.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
                let value = bundle.localizedString(forKey: key, value: key, table: "Localizable")
                if value != key { return value }
            }
        }
        return key
    }

    func render(_ message: UIMessage) -> String {
        String(format: text(message.key), locale: locale, arguments: message.arguments)
    }

    func label(_ language: InterfaceLanguage) -> String {
        switch language {
        case .system: return text("language.system")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }
}
