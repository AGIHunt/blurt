// Shared pieces of the Settings panes and the setup assistant: status dots, the live permission model, config
// helpers, a project-config reader/writer.
import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI
import BlurtCore

// MARK: - Look

enum Tone { case good, warn, bad, off }

/// A state as a small disc: good (ok, with a check: done is always a check shape, §2.3), warn (attention), bad (error),
/// off (quiet).
struct StatusDot: View {
    var tone: Tone
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
            .overlay {
                if tone == .good {
                    Path { p in
                        p.move(to: CGPoint(x: 2.6, y: 4.7)); p.addLine(to: CGPoint(x: 4, y: 6.1)); p.addLine(to: CGPoint(x: 6.5, y: 3.1))
                    }
                    .stroke(Color.brandOnOk, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 9, height: 9)
                }
            }
            .accessibilityHidden(true)
    }
    var color: Color {
        switch tone {
        case .good: return .brandOk
        case .warn: return .brandAttn
        case .bad: return .brandErr
        case .off: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

extension View {
    /// A selected choice (a model, a style): a brand-ink border with a brand-tint ring outside it (§3.4), never a
    /// filled card. Unselected rows get the same padding, so nothing moves when the choice changes.
    func choiceCard(_ selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return padding(.vertical, 5).padding(.horizontal, 7)
            .overlay {
                if selected {
                    shape.strokeBorder(Color.brandInk, lineWidth: 1)
                        .background(shape.stroke(Color.brandTint, lineWidth: 6))
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, -7)
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
            .help(T("settings.kit.copy"))
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
    }
}

// MARK: - Permissions (live)

/// The four permissions as macOS reports them now (SystemAccess, simulated in test builds), refreshed while a pane or
/// the assistant shows them.
@MainActor
final class Permissions: ObservableObject {
    typealias State = SystemAccess.State
    @Published var screen: State = .notAsked
    @Published var mic: State = .notAsked
    @Published var accessibility: State = .notAsked
    /// Input Monitoring: dictation notices its key with it (with Fn, Accessibility alone does).
    @Published var inputMonitoring: State = .notAsked
    /// the 🌐 key set to "Do Nothing" (not a permission: System Settings → Keyboard), so its row updates too
    @Published var fnKey: State = .notAsked
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

    func state(_ k: PermissionKind) -> State {
        switch k {
        case .screen: return screen
        case .microphone: return mic
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        case .fnKey: return fnKey
        }
    }

    func refresh() {
        let s = SystemAccess.state(.screen), m = SystemAccess.state(.microphone)
        let a = SystemAccess.state(.accessibility), i = SystemAccess.state(.inputMonitoring)
        if s != screen { screen = s }
        if m != mic { mic = m }
        if a != accessibility { accessibility = a }
        if i != inputMonitoring { inputMonitoring = i }
        let f = SystemAccess.state(.fnKey)
        if f != fnKey { fnKey = f }
        emitOnChange()
    }

    private var last = ""
    private func emitOnChange() {
        let sig = "\(screen.rawValue),\(mic.rawValue),\(accessibility.rawValue),\(inputMonitoring.rawValue)"
        guard sig != last else { return }
        last = sig
        emit(["event": "permissions", "screen": screen.rawValue, "mic": mic.rawValue, "accessibility": accessibility.rawValue,
              "input_monitoring": inputMonitoring.rawValue])
    }

    static var askedScreen: Bool { Config.shared["app.asked_screen"] as? Bool ?? false }

    /// The exact System Settings pane (the rows' small link).
    static func openPane(_ k: PermissionKind) { SystemAccess.openPane(k) }
}

/// The permission rows (Settings → Privacy: all four; the setup assistant: what dictation needs, without the small
/// System Settings link): live state, why in one line, and Allow — the permission guide for that one permission
/// (Blurt put in the list, the pane, the helper panel).
struct PermissionRows: View {
    @ObservedObject var p: Permissions
    var source: PermissionGuide.Source
    var kinds: [PermissionKind] = [.screen, .microphone, .accessibility, .inputMonitoring]
    var paneLink = true
    @ObservedObject var guide = PermissionGuide.shared

    var body: some View {
        ForEach(kinds, id: \.self) { k in
            row(k, p.state(k))
        }
    }

    func row(_ k: PermissionKind, _ st: Permissions.State) -> some View {
        let now = guide.running && guide.current == k
        return HStack(alignment: .center, spacing: 10) {
            // granted: ok with a check; missing (not set or turned down): the attention dot (§3.4)
            StatusDot(tone: st == .granted ? .good : .warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(PermissionGuide.name(k))
                Text(PermissionGuide.why(k)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(now ? T("settings.perm.now") : st == .granted ? T("settings.kit.allowed") : st == .denied ? T("settings.kit.not_allowed") : T("settings.kit.not_set"))
                .foregroundStyle(st == .granted ? .secondary : .primary).font(.callout)
            if st != .granted {
                Button(T("settings.kit.allow")) { PermissionGuide.shared.start(.all, only: [k], source: source) }
                if paneLink {
                    Button { Permissions.openPane(k) } label: { Image(nsImage: BlurtIcon.externalLink.symbolImage(pointSize: 12)) }
                        .buttonStyle(.borderless).help(T("settings.kit.system_settings")).accessibilityLabel(T("settings.kit.system_settings"))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Set Up Permissions": the guide through everything still missing, with the done line once it has run.
struct PermissionSetupButton: View {
    var flow: PermissionFlowKind
    var source: PermissionGuide.Source
    @ObservedObject var p: Permissions
    /// the done line here (false: the pane shows it higher up)
    var banner = true
    @ObservedObject var guide = PermissionGuide.shared

    var body: some View {
        let missing = guide.missing(flow)
        let _ = p.screen                // re-evaluated as the states change
        // nothing to say (all granted, no fresh done line): no row at all, not an empty one in the form
        if (banner && guide.finished != nil) || !missing.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
            if banner { PermissionDoneBanner() }
            if !missing.isEmpty {
                HStack(spacing: 10) {
                    Button(guide.running ? T("settings.perm.setup_running") : T("settings.perm.setup")) {
                        guide.start(flow, source: source)
                    }
                    Text(missing.map(PermissionGuide.name).joined(separator: T("settings.perm.list_sep")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                }
            }
        }
        }
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

func byteString(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false      // "0 KB", not "Zero KB"
    return f.string(fromByteCount: n)
}

/// Size of a file or a folder (recursively), on a background queue please.
func diskSize(_ u: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue { return Int64((try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0) }
    var total: Int64 = 0
    let root = u.resolvingSymlinksInPath().path + "/"
    if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) {
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
            else if v?.isSymbolicLink == true {
                // a link out of the folder (a Hugging Face cache whose blobs live elsewhere) counts once; links
                // inside it (snapshots → blobs) are already counted as their targets
                let t = f.resolvingSymlinksInPath()
                guard !t.path.hasPrefix(root),
                      let tv = try? t.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                      tv.isRegularFile == true else { continue }
                total += Int64(tv.totalFileAllocatedSize ?? 0)
            }
        }
    }
    return total
}
typealias CoreAgent = BlurtCore.AgentStatus   // the shell has its own AgentStatus (AgentHub.swift)
