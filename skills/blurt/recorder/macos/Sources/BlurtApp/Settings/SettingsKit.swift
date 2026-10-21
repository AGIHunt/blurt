// Shared pieces of the Settings panes and the setup assistant: status dots, the live permission model, config
// helpers, a project-config reader/writer.
import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI
import BlurtCore

// MARK: - Look

enum Tone { case good, warn, bad, off }

struct StatusDot: View {
    var tone: Tone
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
    var color: Color {
        switch tone {
        case .good: return .green
        case .warn: return .yellow
        case .bad: return .red
        case .off: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

/// A pane's frame: every pane has the same size, so switching panes doesn't make the window jump.
struct PaneFrame<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 660, height: 560)
    }
}

struct Hint: View {
    var text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// `code` in a monospaced, selectable, copyable chip.
struct CommandText: View {
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help(L("拷贝", "Copy"))
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
    }
}

// MARK: - Permissions (live)

@MainActor
final class Permissions: ObservableObject {
    enum State: String { case granted, denied, notAsked = "not_asked" }
    @Published var screen: State = .notAsked
    @Published var mic: State = .notAsked
    @Published var accessibility: State = .notAsked
    private var timer: Timer?
    private var observers: [Any] = []

    init() { refresh() }

    /// While a pane / the assistant shows them: once a second, and when the app comes back to the front.
    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }
    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    func refresh() {
        let s: State = CGPreflightScreenCaptureAccess() ? .granted : (Permissions.askedScreen ? .denied : .notAsked)
        let m: State
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: m = .granted
        case .denied, .restricted: m = .denied
        default: m = .notAsked
        }
        let a: State = AXIsProcessTrusted() ? .granted : .notAsked
        if s != screen { screen = s }
        if m != mic { mic = m }
        if a != accessibility { accessibility = a }
        emitOnChange()
    }

    private var last = ""
    private func emitOnChange() {
        let sig = "\(screen.rawValue),\(mic.rawValue),\(accessibility.rawValue)"
        guard sig != last else { return }
        last = sig
        emit(["event": "permissions", "screen": screen.rawValue, "mic": mic.rawValue, "accessibility": accessibility.rawValue])
    }

    static var askedScreen: Bool { Config.shared["app.asked_screen"] as? Bool ?? false }

    func requestScreen() {
        Config.shared.set("app.asked_screen", true)
        if !CGRequestScreenCaptureAccess() { Permissions.openPane("Privacy_ScreenCapture") }
        refresh()
    }
    func requestMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.refresh() } }
        } else { Permissions.openPane("Privacy_Microphone") }
    }
    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { Permissions.openPane("Privacy_Accessibility") }
    }

    static func openPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

struct PermissionRows: View {
    @ObservedObject var p: Permissions

    var body: some View {
        row(L("屏幕录制", "Screen Recording"), L("录屏和截图都需要", "Needed to record and to snap"), p.screen,
            action: p.screen == .granted ? nil : { p.requestScreen() }, settings: "Privacy_ScreenCapture")
        row(L("麦克风", "Microphone"), L("录你的讲解；不开也能录屏，只是没声音", "Your narration; recording works without it, just silent"), p.mic,
            action: p.mic == .notAsked ? { p.requestMic() } : nil, settings: "Privacy_Microphone")
        row(L("辅助功能", "Accessibility"), L("按住 ⌃ 画笔需要（全局读取修饰键）", "For the hold-⌃ pen (reads modifier keys globally)"), p.accessibility,
            action: p.accessibility == .granted ? nil : { p.requestAccessibility() }, settings: "Privacy_Accessibility")
    }

    func row(_ title: String, _ why: String, _ st: Permissions.State, action: (() -> Void)?, settings: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(tone: st == .granted ? .good : st == .denied ? .bad : .warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(st == .granted ? L("已允许", "Allowed") : st == .denied ? L("未允许", "Not allowed") : L("未设置", "Not set"))
                .foregroundStyle(st == .granted ? .secondary : .primary).font(.callout)
            if let a = action {
                Button(L("允许…", "Allow…"), action: a)
            } else if st != .granted {
                Button(L("系统设置…", "System Settings…")) { Permissions.openPane(settings) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Config helpers

/// <repo>/.blurt/config.json, read and written whole (pretty, sorted — like _common.save_json).
enum ProjectConfig {
    static func url(_ ws: URL) -> URL { ws.appendingPathComponent(".blurt/config.json") }
    static func read(_ ws: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: url(ws)), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
    static func set(_ ws: URL, _ section: String, _ key: String, _ value: Any?) {
        var all = read(ws)
        var sec = all[section] as? [String: Any] ?? [:]
        sec[key] = value
        all[section] = sec.isEmpty ? nil : sec
        try? FileManager.default.createDirectory(at: url(ws).deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url(ws), options: .atomic) }
    }
}

func isDefaultWorkspace(_ u: URL) -> Bool { u.standardizedFileURL == defaultWorkspace.standardizedFileURL }

func byteString(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

/// Size of a file or a folder (recursively), on a background queue please.
func diskSize(_ u: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue { return Int64((try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0) }
    var total: Int64 = 0
    if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) {
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
    }
    return total
}
typealias CoreAgent = BlurtCore.AgentStatus   // the shell has its own AgentStatus (AgentHub.swift)
