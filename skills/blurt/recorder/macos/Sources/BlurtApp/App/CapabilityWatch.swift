// The app's side of the capability switches (BlurtCore Capabilities.swift). A switch is written in three ways — Home's
// tiles and Settings → General (Capability.set), Settings → Dictation's own switch, and config.json edited by hand or
// by an agent — and whichever it was, this posts `Capability.didChange` once and makes the app follow: the shortcuts
// are registered again (App.applyCapabilityHotkeys), dictation starts or stops listening, the phone server starts or
// stops, and the surfaces that list capabilities (the main window's sidebar, toolbar and menus; Settings; the island)
// rebuild from their own observers.
import AppKit
import BlurtCore

final class CapabilityWatch {
    static let shared = CapabilityWatch()
    private var last: Set<Capability> = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        last = Capability.off
        NotificationCenter.default.addObserver(forName: Capability.didChange, object: nil, queue: .main) { [weak self] _ in self?.changed() }
        // Settings → Dictation's switch (and a hand edit Dictation picked up first) is the Dictation capability
        NotificationCenter.default.addObserver(forName: Dictation.settingsChanged, object: nil, queue: .main) { [weak self] _ in self?.look() }
    }

    /// Something may have changed the switches without saying so: say it.
    func look() {
        guard started, Capability.off != last else { return }
        NotificationCenter.default.post(name: Capability.didChange, object: nil)
    }

    private func changed() {
        let now = Capability.off
        guard now != last else { return }
        let flipped = now.symmetricDifference(last)
        last = now
        emit(["event": "capabilities", "off": now.map(\.rawValue).sorted()])
        appDelegate?.applyCapabilityHotkeys()
        MainActor.assumeIsolated {
            if flipped.contains(.dictation) {
                _ = Dictation.shared.reloadIfChanged()
                // dictation turned off: the speech models it was fetching stop with it (a stop the queue remembers,
                // so nothing resumes at the next launch); turning it back on offers them again on Home
                if now.contains(.dictation), ModelDownloads.shared.active { ModelDownloads.shared.stop() }
            }
            if flipped.contains(.phone) { RemoteServer.shared.capabilityChanged() }
        }
        appDelegate?.refreshStatus()
    }
}

enum MenuText {
    /// A text as one short menu line: its first line, cut at a word or a character with an ellipsis.
    static func oneLine(_ s: String, limit: Int) -> String {
        let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.count <= limit ? first : String(first.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
