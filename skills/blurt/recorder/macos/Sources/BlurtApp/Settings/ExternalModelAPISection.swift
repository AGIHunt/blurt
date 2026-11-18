// Settings → Models. Only a copy action reads the service's API key.
import AppKit
import SwiftUI
import BlurtCore

private struct ModelAPIStatus: Decodable {
    struct Model: Decodable {
        let id: String
        let capability: String

        var capabilityName: String {
            switch capability {
            case "chat", "transcription", "ocr": return M("models.api.\(capability)")
            default: return capability
            }
        }
    }

    let running: Bool
    let scope: String
    let messages_base_url: String?
    let needs_restart: Bool?
    let base_url: String
    let models: [Model]
}

@MainActor
struct ExternalModelAPISection: View {
    @State private var status: ModelAPIStatus?
    @State private var scope = "local"
    @State private var selected = ""
    @State private var format = "openai"
    @State private var busy = false
    @State private var message: String?
    @State private var preparing: String?
    @State private var runtimeMessage: String?

    var body: some View {
        SettingsGroup("speech.api", footer: M("models.api.detail")) {
            row("models.api.service", detail: serviceDetail) {
                Button(M("models.api.refresh")) { Task { await control("status") } }
                if let status {
                    Button(M(status.running ? "models.api.stop" : "models.api.start")) {
                        Task { await control(status.running ? "stop" : "start") }
                    }
                }
            }
            if let status {
                let access = status.running ? status.scope : scope
                row("models.api.access", detail: access == "lan" ? M("models.api.lan_detail") : nil) {
                    if status.running {
                        Text(M("models.api.\(status.scope)"))
                    } else {
                        ChoicePopup(label: M("models.api.access"), choices: [
                            ("local", M("models.api.local")), ("lan", M("models.api.lan"))
                        ], selection: $scope)
                    }
                }
                let model = status.models.first { $0.id == selected }
                row("models.api.model", detail: model?.capabilityName ?? M("models.api.empty")) {
                    if let model {
                        ChoicePopup(label: M("models.api.model"), choices: status.models.map { ($0.id, $0.id) }, selection: $selected)
                            .help(model.id)
                        Button(M("models.api.copy")) { copy(model.id) }
                    }
                }
                if status.running {
                    if model?.capability == "chat", status.needs_restart != true {
                        row("models.api.format") {
                            ChoicePopup(label: M("models.api.format"), choices: [("openai", "OpenAI Chat Completions"),
                                ("messages", "Messages-compatible API")], selection: $format)
                        }
                    }
                    row("models.api.base", detail: baseURL(status)) {
                        Button(M("models.api.copy")) { copy(baseURL(status)) }
                    }
                    row("models.sheet.key") {
                        Button(M("models.api.copy")) { Task { await copyConfig(.key) } }
                    }
                }
                if let model {
                    row("models.api.runtime", detail: runtimeDetail) {
                        Button(M("models.api.prepare")) { Task { await prepare(model.id) } }
                            .disabled(preparing != nil)
                    }
                }
                if status.running, let model {
                    row("models.api.config") {
                        Button(M("models.api.copy_json")) { Task { await copyConfig(.json(model.id)) } }
                        Button(M("models.api.copy_python")) { Task { await copyConfig(.python(model.id)) } }
                    }
                }
            }
            if let message { SettingsLine { Text(message).font(.callout).textSelection(.enabled) } }
        }
        .disabled(busy)
        .onAppear { Task { await control("status") } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object is SettingsWindow, SettingsNavigator.shared.pane == .speech {
                Task { await control("status") }
            }
        }
    }

    private func usesMessages(_ status: ModelAPIStatus) -> Bool {
        format == "messages" && status.messages_base_url != nil && status.needs_restart != true
            && status.models.first(where: { $0.id == selected })?.capability == "chat"
    }

    private func baseURL(_ status: ModelAPIStatus) -> String {
        usesMessages(status) ? (status.messages_base_url ?? status.base_url) : status.base_url
    }

    private var serviceDetail: String {
        if busy || (status == nil && message == nil) { return M("models.api.working") }
        guard let status else { return M("models.api.unknown") }
        if status.needs_restart == true { return M("models.api.restart") }
        return M(status.running ? "models.api.running" : "models.api.stopped")
    }

    private func row<C: View>(_ key: String, detail: String? = nil, @ViewBuilder controls: () -> C) -> some View {
        SettingRow("speech.api.\(key)", title: M(key), detail: detail) {
            HStack(spacing: 8, content: controls)
        }
    }

    private func control(_ action: String) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let args = action == "start" ? [action, "--scope", scope] : [action]
            let result = try await SkillCLI.shared.run("model_api.py", args)
            if result.ok, let next = result.decode(ModelAPIStatus.self) {
                status = next
                if !next.models.contains(where: { $0.id == selected }) { selected = next.models.first(where: { $0.capability == "chat" })?.id ?? next.models.first?.id ?? "" }
                if next.running || action == "stop" { scope = "local" }
            } else {
                status = nil
                message = result.ok ? M("models.api.unknown") : result.errorText
            }
        } catch {
            status = nil
            message = error.localizedDescription
        }
    }

    private enum ConfigCopy { case key, json(String), python(String) }

    private var runtimeDetail: String {
        if let preparing { return M("models.api.preparing", preparing) }
        return runtimeMessage ?? M("models.api.runtime_detail")
    }

    private func prepare(_ id: String) async {
        guard preparing == nil else { return }
        preparing = id
        defer { preparing = nil }
        do {
            let result = try await SkillCLI.shared.run("model_api.py", ["prepare", "--model", id], timeout: 30 * 60)
            runtimeMessage = result.ok ? M("models.api.prepared", id) : result.errorText
        } catch { runtimeMessage = error.localizedDescription }
    }

    private func copyConfig(_ field: ConfigCopy) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let result = try await SkillCLI.shared.run("model_api.py", ["config"])
            guard result.ok else { message = result.errorText; return }
            guard let current = result.decode(ModelAPIStatus.self), current.running, !current.base_url.isEmpty,
                  let config = result.json, let key = config["api_key"] as? String, !key.isEmpty else {
                message = M("models.api.changed")
                return
            }
            switch field {
            case .json(let model):
                guard current.models.contains(where: { $0.id == model }) else { message = M("models.api.changed"); return }
                let data = try JSONSerialization.data(withJSONObject: ["base_url": baseURL(current), "api_key": key, "model": model],
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                copy(String(decoding: data, as: UTF8.self))
            case .python(let model):
                guard let examples = config[usesMessages(current) ? "messages_python_examples" : "python_examples"] as? [String: String], let example = examples[model],
                      !example.isEmpty else { message = M("models.api.changed"); return }
                copy(example)
            case .key:
                copy(key)
            }
        } catch { message = error.localizedDescription }
    }

    private func copy(_ text: String) {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        message = M(clipboard.setString(text, forType: .string) ? "models.api.copied" : "models.api.copy_error")
    }
}
