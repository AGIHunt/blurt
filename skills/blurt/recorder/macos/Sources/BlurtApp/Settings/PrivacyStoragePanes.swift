// Settings → Privacy (live permission state, local-only speech recognition, what is kept) and Settings → Storage
// (what takes space, and cleaning what can safely go).
import AppKit
import SwiftUI
import BlurtCore

// MARK: - retention

/// live/audio.pcm is the raw microphone stream live.py transcribes while recording. Once the recording is finished and
/// its transcript exists, it is redundant (the mp4 has the audio). privacy.keep_live_audio = true keeps it.
enum Retention {
    static var keepLiveAudio: Bool { Config.shared["privacy.keep_live_audio"] as? Bool ?? false }

    /// Sessions whose live/audio.pcm can go: transcript.json and recording.mp4 present, nothing written for 10 min.
    static func liveAudioFiles() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for root in FixWatcher.sessionRoots() {
            for d in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let pcm = d.appendingPathComponent("live/audio.pcm")
                guard fm.fileExists(atPath: pcm.path),
                      fm.fileExists(atPath: d.appendingPathComponent("transcript.json").path),
                      fm.fileExists(atPath: d.appendingPathComponent("recording.mp4").path) else { continue }
                let m = (try? fm.attributesOfItem(atPath: pcm.path)[.modificationDate] as? Date) ?? Date()
                if Date().timeIntervalSince(m) > 600 { out.append(pcm) }
            }
        }
        return out
    }

    /// Removes them (not to the Trash: they are large and the same audio is in recording.mp4). Returns bytes freed.
    @discardableResult
    static func dropLiveAudio() -> Int64 {
        var freed: Int64 = 0
        for f in liveAudioFiles() {
            freed += diskSize(f)
            try? FileManager.default.removeItem(at: f)
        }
        if freed > 0 { emit(["event": "retention", "freed": freed]) }
        return freed
    }

    /// At launch and after items.json changes, unless the user keeps them.
    static func sweep() {
        guard !keepLiveAudio else { return }
        DispatchQueue.global(qos: .utility).async { dropLiveAudio() }
    }
}

// MARK: - Privacy

@MainActor
final class PrivacyModel: ObservableObject {
    @Published var localASR = Config.shared["privacy.local_asr"] as? Bool ?? false
    @Published var keepLive = Retention.keepLiveAudio
    @Published var spotlight = Config.shared["spotlight"] as? Bool ?? true

    func setLocal(_ on: Bool) {
        localASR = on
        Config.shared.set("privacy.local_asr", on ? true : nil)
        if on, let b = Config.shared["asr.backend"] as? String, ["openai", "dashscope"].contains(b) {
            Config.shared.set("asr.backend", "sensevoice")
        }
    }
    func setKeep(_ on: Bool) { keepLive = on; Config.shared.set("privacy.keep_live_audio", on ? true : nil); if !on { Retention.sweep() } }
    func setSpotlight(_ on: Bool) {
        spotlight = on
        Config.shared.set("spotlight", on ? nil : false)
        if on { Spotlight.shared.refresh() } else { Spotlight.shared.removeAll() }
    }
}

struct PrivacyPane: View {
    @StateObject var perms = Permissions()
    @StateObject var m = PrivacyModel()

    var body: some View {
        PaneFrame {
            Section {
                PermissionRows(p: perms)
            } header: { Text(T("settings.privacy.permissions_live")) } footer: {
                Text(T("settings.privacy.macos_applies_screen_recording"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(T("settings.privacy.local_speech_recognition_only"), isOn: Binding(get: { m.localASR }, set: { m.setLocal($0) }))
                Hint(T("settings.privacy.audio_never_goes_cloud"))
                Toggle(T("settings.privacy.keep_raw_live_caption"),
                       isOn: Binding(get: { m.keepLive }, set: { m.setKeep($0) }))
                Hint(T("settings.privacy.deleted_by_default_once"))
                Toggle(T("settings.privacy.items_appear_spotlight"), isOn: Binding(get: { m.spotlight }, set: { m.setSpotlight($0) }))
            } header: { Text(T("settings.privacy.data")) } footer: {
                Text(T("settings.privacy.recordings_screenshots_items_stay"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { perms.start() }
        .onDisappear { perms.stop() }
    }
}

// MARK: - Storage

@MainActor
final class StorageModel: ObservableObject {
    struct Row: Identifiable { var id: String { path.path }; var name: String; var path: URL; var bytes: Int64; var count: Int? }
    @Published var rows: [Row] = []
    @Published var app: [Row] = []
    @Published var liveAudio: (count: Int, bytes: Int64) = (0, 0)
    @Published var busy = false
    @Published var message: String?

    func load() async {
        busy = true
        defer { busy = false }
        let (r, a, l) = await Task.detached { () -> ([Row], [Row], (Int, Int64)) in
            var rows: [Row] = []
            for root in FixWatcher.sessionRoots() where FileManager.default.fileExists(atPath: root.path) {
                let n = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.count
                let ws = root.lastPathComponent == "recordings" ? root.deletingLastPathComponent() : root.deletingLastPathComponent().deletingLastPathComponent()
                rows.append(Row(name: isDefaultWorkspace(ws) ? "~/Blurt" : ws.lastPathComponent, path: root, bytes: diskSize(root), count: n))
            }
            let h = BlurtPaths.home
            var app: [Row] = []
            for (name, rel) in [(T("settings.privacy.speech_models"), "models"), (T("settings.privacy.search_index"), "index.db"),
                                (T("settings.privacy.build_cache"), "build"), (T("settings.privacy.agent_runs"), "runs"),
                                (T("settings.privacy.prompts"), "prompts"), (T("settings.privacy.benchmark_samples"), "bench")] {
                let u = h.appendingPathComponent(rel)
                var b = diskSize(u)
                if rel == "index.db" { b += diskSize(h.appendingPathComponent("index.db-wal")) + diskSize(h.appendingPathComponent("index.db-shm")) }
                if FileManager.default.fileExists(atPath: u.path) { app.append(Row(name: name, path: u, bytes: b, count: nil)) }
            }
            let live = Retention.liveAudioFiles()
            return (rows, app, (live.count, live.reduce(0) { $0 + diskSize($1) }))
        }.value
        rows = r; app = a; liveAudio = l
    }

    func dropLive() async {
        let freed = await Task.detached { Retention.dropLiveAudio() }.value
        message = T("settings.privacy.freed") + byteString(freed)
        await load()
    }
    func trash(_ u: URL) {
        NSWorkspace.shared.recycle([u]) { _, _ in Task { @MainActor in await self.load() } }
    }
}

struct StoragePane: View {
    @StateObject var m = StorageModel()
    @State var confirm: URL?

    var body: some View {
        PaneFrame {
            Section {
                ForEach(m.rows) { r in
                    row(r.name, detail: TP("settings.privacy.sessions", r.count ?? 0) + " · " + (r.path.path as NSString).abbreviatingWithTildeInPath, bytes: r.bytes) {
                        Button { NSWorkspace.shared.open(r.path) } label: { Image(systemName: "arrow.up.forward.app") }.buttonStyle(.borderless)
                            .help(T("action.open")).accessibilityLabel(T("action.open"))
                    }
                }
            } header: {
                HStack { Text(T("settings.privacy.recordings_screenshots")); Spacer(); if m.busy { ProgressView().controlSize(.mini) } }
            }
            Section {
                row(T("settings.privacy.raw_live_caption_audio"),
                    detail: TP("settings.privacy.live_audio", m.liveAudio.count),
                    bytes: m.liveAudio.bytes) {
                    Button(T("settings.privacy.clean_up")) { Task { await m.dropLive() } }.disabled(m.liveAudio.count == 0)
                }
                ForEach(m.app) { r in
                    row(r.name, detail: (r.path.path as NSString).abbreviatingWithTildeInPath, bytes: r.bytes) {
                        if r.path.lastPathComponent == "build" || r.path.lastPathComponent == "prompts" || r.path.lastPathComponent == "bench" {
                            Button(T("settings.privacy.move_trash")) { confirm = r.path }
                        } else {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([r.path]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                .help(T("action.reveal_in_finder")).accessibilityLabel(T("action.reveal_in_finder"))
                        }
                    }
                }
                if let msg = m.message { Text(msg).font(.caption).foregroundStyle(.secondary) }
            } header: { Text(T("settings.privacy.blurt_own_files")) } footer: {
                Text(T("settings.privacy.index_can_be_deleted"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await m.load() }
        .alert(T("settings.privacy.move_trash_2"), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(T("settings.privacy.move_trash"), role: .destructive) { if let u = confirm { m.trash(u) }; confirm = nil }
            Button(T("settings.privacy.cancel"), role: .cancel) { confirm = nil }
        } message: { Text(confirm?.path ?? "") }
    }

    func row<A: View>(_ name: String, detail: String, bytes: Int64, @ViewBuilder action: () -> A) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(byteString(bytes)).monospacedDigit().foregroundStyle(.secondary)
            action()
        }
    }
}
