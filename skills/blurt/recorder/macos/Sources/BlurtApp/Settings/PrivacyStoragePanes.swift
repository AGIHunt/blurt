// Settings → Privacy (live permission state — the one full list of them —, local-only speech recognition, what is
// kept, Spotlight) and Settings → Storage (what takes space, model by model and folder by folder, and cleaning what
// can safely go: videos of organized recordings, unused models, caches — always to the Trash, never by default).
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

    func reload() {
        localASR = Config.shared["privacy.local_asr"] as? Bool ?? false
        keepLive = Retention.keepLiveAudio
        spotlight = Config.shared["spotlight"] as? Bool ?? true
    }

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
                PermissionSetupButton(flow: .all, source: .privacy, p: perms)
                PermissionRows(p: perms, source: .privacy)
            } header: { Text(T("settings.privacy.permissions_live")) } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text(T("settings.privacy.macos_applies_screen_recording"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    // Screen Recording allowed while Blurt runs: some macOS versions apply it only after a relaunch
                    if perms.screen != .granted || Permissions.askedScreen {
                        Button(T("settings.perm.restart")) { SystemAccess.relaunch() }.controlSize(.small)
                    }
                }
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
        .onAppear { m.reload(); perms.start() }
        .onDisappear { perms.stop() }
    }
}

// MARK: - Storage

/// Everything big that Blurt keeps, in four groups — recordings and snaps (per folder, plus the videos of organized
/// recordings, which can go), the models (one row per model, each with its size, "In use", and Move to Trash for one
/// Blurt downloaded that nothing uses), dictation (history, kept audio, Lab), and Blurt's own files (index, caches,
/// agent runs, jobs). Rows show up from the file system at once; which model is in use comes from the scripts
/// (transcribe.py models and dictation-models, polish.py models) a moment later. Nothing is deleted without the user asking, and what is
/// deleted goes to the Trash.
@MainActor
final class StorageModel: ObservableObject {
    struct Row: Identifiable {
        var id: String { path.path }
        var name: String
        var path: URL
        var bytes: Int64
        var detail: String = ""
        /// A model: what it is for (nil = not a model), whether something uses it, whether it may go to the Trash.
        var family: String?
        var inUse = false
        var removable = false
    }
    @Published var rows: [Row] = []                 // recording folders
    @Published var videos: [VideoRetention.Candidate] = []
    @Published var models: [Row] = []
    @Published var dictation: [Row] = []
    @Published var app: [Row] = []
    @Published var liveAudio: (count: Int, bytes: Int64) = (0, 0)
    @Published var autoDelete: Int? = VideoRetention.autoDays
    @Published var busy = false
    @Published var checkingModels = false
    @Published var message: String?

    var videoBytes: Int64 { videos.reduce(0) { $0 + $1.bytes } }
    func videos(olderThan days: Int?) -> [VideoRetention.Candidate] {
        guard let d = days else { return videos }
        return videos.filter { Date().timeIntervalSince($0.date) >= Double(d) * 86400 }
    }

    func load() async {
        busy = true
        defer { busy = false }
        let current = (NSApp.delegate as? App)?.lastSession.map { Set([$0.standardizedFileURL.path]) } ?? []
        let r = await Task.detached { () -> ([Row], [VideoRetention.Candidate], [Row], [Row], [Row], (Int, Int64)) in
            let fm = FileManager.default
            let roots = StorageModel.roots()
            var rows: [Row] = []
            for root in roots where fm.fileExists(atPath: root.path) {
                let n = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.count
                let ws = root.lastPathComponent == "recordings" ? root.deletingLastPathComponent() : root.deletingLastPathComponent().deletingLastPathComponent()
                // ~/Blurt holds two: its Unassigned store (inbox/sessions) and v0.6's recordings/ — name them apart
                let name = isDefaultWorkspace(ws) ? "~/Blurt/" + (root.path.dropFirst(ws.path.count + 1).split(separator: "/").first.map(String.init) ?? "") : ws.lastPathComponent
                rows.append(Row(name: name, path: root, bytes: diskSize(root),
                                detail: TP("settings.privacy.sessions", n) + " · " + (root.path as NSString).abbreviatingWithTildeInPath))
            }
            let videos = VideoRetention.candidates(roots: roots, olderThan: nil, excluding: current)
            let h = BlurtPaths.home
            func row(_ name: String, _ rel: String) -> Row? {
                let u = h.appendingPathComponent(rel)
                guard fm.fileExists(atPath: u.path) else { return nil }
                var b = diskSize(u)
                if rel == "index.db" { b += diskSize(h.appendingPathComponent("index.db-wal")) + diskSize(h.appendingPathComponent("index.db-shm")) }
                return Row(name: name, path: u, bytes: b, detail: (u.path as NSString).abbreviatingWithTildeInPath)
            }
            let dictation = [row(T("settings.storage.dictation_history"), "dictation/history.jsonl"),
                             row(T("settings.storage.dictation_audio"), "dictation/audio"),
                             row(T("settings.storage.dictation_lab"), "dictation/lab")].compactMap { $0 }
            let app = [row(T("settings.privacy.search_index"), "index.db"), row(T("settings.privacy.build_cache"), "build"),
                       row(T("settings.privacy.agent_runs"), "runs"), row(T("settings.storage.jobs"), "jobs"),
                       row(T("settings.storage.handoff"), "handoff"), row(T("settings.privacy.prompts"), "prompts"),
                       row(T("settings.privacy.benchmark_samples"), "bench"), row(T("settings.storage.tmp"), "tmp")].compactMap { $0 }
            let live = Retention.liveAudioFiles()
            return (rows, videos, StorageModel.scanModels(), dictation, app, (live.count, live.reduce(0) { $0 + diskSize($1) }))
        }.value
        rows = r.0; videos = r.1; dictation = r.3; app = r.4; liveAudio = r.5
        // fresh sizes; what the scripts said last time (names, in use, the shared-cache rows) until they say it again
        let before = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        models = r.2.map { fresh in
            guard var row = before[fresh.id] else { return fresh }
            row.bytes = fresh.bytes
            return row
        } + models.filter { $0.family != nil && !r.2.map(\.id).contains($0.id) && !$0.path.path.hasPrefix(BlurtPaths.home.path) }
        autoDelete = VideoRetention.autoDays
        await annotateModels()
    }

    /// Where recordings and snaps are: every store's sessions/ (FixWatcher.sessionRoots), plus ~/Blurt/recordings —
    /// where v0.6 kept them, still there (and often the biggest folder) on Macs that had it.
    nonisolated static func roots() -> [URL] {
        let legacy = defaultWorkspace.appendingPathComponent("recordings").standardizedFileURL
        let r = FixWatcher.sessionRoots()
        return r.contains(legacy) || !FileManager.default.fileExists(atPath: legacy.path) ? r : r + [legacy]
    }

    /// $BLURT_HOME/models: asr/ and polish/ hold one model per folder; anything else at the top is one model (or a
    /// file every local model needs, like the voice-activity detector).
    nonisolated static func scanModels() -> [Row] {
        let fm = FileManager.default
        let dir = BlurtPaths.home.appendingPathComponent("models")
        var out: [Row] = []
        for e in ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
            where !e.lastPathComponent.hasPrefix(".") {
            if ["asr", "polish"].contains(e.lastPathComponent) {
                for m in ((try? fm.contentsOfDirectory(at: e, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
                    where !m.lastPathComponent.hasPrefix(".") {
                    out.append(Row(name: m.lastPathComponent, path: m, bytes: diskSize(m), family: nil))
                }
            } else {
                out.append(Row(name: e.lastPathComponent, path: e, bytes: diskSize(e), family: nil))
            }
        }
        return out
    }

    /// Which model is which and what uses it (BlurtCore ModelUsage): transcribe.py models and dictation-models (speech
    /// recognition: recordings, live captions, voice notes, dictation) and polish.py models (dictation's clean-up).
    /// Models of theirs in the shared Hugging Face cache are listed too, with their size, but never removed here: other
    /// apps may use that cache.
    func annotateModels() async {
        checkingModels = true
        defer { checkingModels = false }
        async let asr = try? SkillCLI.shared.run("transcribe.py", ["models"], timeout: 180)
        async let dictation = try? SkillCLI.shared.run("transcribe.py", ["dictation-models"], timeout: 180)
        async let polish = try? SkillCLI.shared.run("polish.py", ["models"], timeout: 60)
        let known = await ModelUsage.merge(asr: asr?.json, dictation: dictation?.json, polish: polish?.json)
        guard !known.isEmpty else { return }
        func family(_ k: ModelUsage.Kind) -> String {
            T(k == .vad ? "settings.storage.model.vad" : k == .polish ? "settings.storage.model.polish" : "settings.storage.model.asr")
        }
        let own = BlurtPaths.home.appendingPathComponent("models").standardizedFileURL.path
        var rows = models.filter { $0.path.standardizedFileURL.path.hasPrefix(own) }
        for i in rows.indices {
            guard let k = known[rows[i].path.standardizedFileURL.path] else { continue }
            rows[i].name = k.name
            rows[i].family = family(k.kind)
            rows[i].inUse = k.inUse
            rows[i].removable = k.removable
        }
        // the shared Hugging Face cache: its repo folders (the snapshots are links into them)
        for (p, k) in known.sorted(by: { $0.key < $1.key }) where !p.hasPrefix(own) {
            let u = URL(fileURLWithPath: p)
            let bytes = await Task.detached { diskSize(u) }.value
            rows.append(Row(name: k.name, path: u, bytes: bytes, detail: T("settings.storage.model.shared_cache"),
                            family: family(k.kind), inUse: k.inUse, removable: false))
        }
        models = rows
    }

    func dropLive() async {
        let freed = await Task.detached { Retention.dropLiveAudio() }.value
        message = T("settings.privacy.freed") + byteString(freed)
        await load()
    }

    func trash(_ urls: [URL]) {
        NSWorkspace.shared.recycle(urls) { done, _ in
            Task { @MainActor in
                emit(["event": "storage_trash", "files": done.count])
                await self.load()
            }
        }
    }

    /// The videos of organized recordings older than `days` (nil = all) go to the Trash.
    func deleteVideos(olderThan days: Int?) {
        let c = videos(olderThan: days)
        guard !c.isEmpty else { return }
        message = T("settings.storage.videos.freed", byteString(c.reduce(0) { $0 + $1.bytes }))
        Housekeeping.trashVideos(c, auto: false) { Task { @MainActor in await self.load() } }
    }

    /// "Delete videos automatically". Turning it on deletes what is already older at once (Housekeeping), so the pane
    /// asks first when that is anything (StoragePane's .auto).
    func setAutoDelete(_ d: Int?) {
        autoDelete = d
        VideoRetention.autoDays = d
        if d != nil {
            Housekeeping.deleteOldVideos()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Task { @MainActor in await self.load() } }
        }
    }
}

struct StoragePane: View {
    @StateObject var m = StorageModel()
    /// What the confirmation is about.
    enum Ask: Identifiable {
        case videos(Int?), auto(Int), trash(StorageModel.Row)
        var id: String { switch self { case .videos(let d): return "v\(d ?? 0)"; case .auto(let d): return "a\(d)"; case .trash(let r): return r.id } }
    }
    @State var ask: Ask?

    var body: some View {
        PaneFrame {
            Section {
                if m.rows.isEmpty && !m.busy { Text(T("settings.privacy.no_recordings")).foregroundStyle(.secondary) }
                ForEach(m.rows) { r in
                    row(r.name, detail: r.detail, bytes: r.bytes) { reveal(r.path) }
                }
                videosRow
                Picker(T("settings.storage.videos.auto"), selection: Binding(get: { m.autoDelete ?? 0 }, set: { setAuto($0) })) {
                    Text(T("settings.storage.videos.never")).tag(0)
                    ForEach(VideoRetention.choices, id: \.self) { d in Text(T("settings.storage.videos.after", d)).tag(d) }
                }
            } header: {
                HStack { Text(T("settings.privacy.recordings_screenshots")); Spacer(); if m.busy { ProgressView().controlSize(.mini) } }
            } footer: {
                Text(T("settings.storage.videos.footer")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if m.models.isEmpty && !m.busy { Text(T("settings.storage.model.none")).foregroundStyle(.secondary) }
                ForEach(m.models) { r in modelRow(r) }
            } header: {
                HStack { Text(T("settings.storage.models")); Spacer(); if m.checkingModels { ProgressView().controlSize(.mini) } }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text(T("settings.storage.model.footer")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(T("settings.kit.speech")) { AppEnvironment.settings?.show(pane: SettingsPane.speech.rawValue) }.controlSize(.small)
                    Button(T("dictation.settings.tab")) { AppEnvironment.settings?.show(pane: SettingsPane.dictation.rawValue) }.controlSize(.small)
                }
            }

            if !m.dictation.isEmpty {
                Section {
                    ForEach(m.dictation) { r in row(r.name, detail: r.detail, bytes: r.bytes) { reveal(r.path) } }
                } header: { Text(T("dictation.settings.tab")) } footer: {
                    Text(T("settings.storage.dictation.footer")).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                row(T("settings.privacy.raw_live_caption_audio"), detail: TP("settings.privacy.live_audio", m.liveAudio.count), bytes: m.liveAudio.bytes) {
                    Button(T("settings.privacy.clean_up")) { Task { await m.dropLive() } }.disabled(m.liveAudio.count == 0)
                }
                ForEach(m.app) { r in
                    row(r.name, detail: r.detail, bytes: r.bytes) {
                        if ["build", "prompts", "bench", "tmp"].contains(r.path.lastPathComponent) {
                            Button(T("settings.privacy.move_trash")) { ask = .trash(r) }
                        }
                        revealButton(r.path)
                    }
                }
                if let msg = m.message { Text(msg).font(.caption).foregroundStyle(.secondary) }
            } header: { Text(T("settings.privacy.blurt_own_files")) } footer: {
                Text(T("settings.privacy.index_can_be_deleted")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await m.load() }
        .alert(alertTitle, isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }), presenting: ask) { a in
            Button({ if case .auto = a { return T("settings.storage.videos.auto_on") }; return T("settings.privacy.move_trash") }(), role: .destructive) {
                switch a {
                case .videos(let d): m.deleteVideos(olderThan: d)
                case .auto(let d): m.setAutoDelete(d)
                case .trash(let r): m.trash([r.path])
                }
                ask = nil
            }
            Button(T("settings.privacy.cancel"), role: .cancel) { ask = nil }
        } message: { a in
            switch a {
            case .videos(let d):
                let c = m.videos(olderThan: d)
                Text(TP("settings.storage.videos.count", c.count) + " (" + byteString(c.reduce(0) { $0 + $1.bytes }) + "). " + T("settings.storage.videos.confirm"))
            case .auto(let d):
                let c = m.videos(olderThan: d)
                Text(T("settings.storage.videos.auto_confirm") + " " + TP("settings.storage.videos.count", c.count) + " (" + byteString(c.reduce(0) { $0 + $1.bytes }) + "). " + T("settings.storage.videos.confirm"))
            case .trash(let r): Text((r.path.path as NSString).abbreviatingWithTildeInPath)
            }
        }
    }

    var alertTitle: String {
        switch ask {
        case .videos: return T("settings.storage.videos.confirm_title")
        case .auto(let d): return T("settings.storage.videos.auto_confirm_title", d)
        default: return T("settings.privacy.move_trash_2")
        }
    }

    /// Never applies at once; an age does too when no video is that old yet, else it asks first — choosing it moves
    /// those videos to the Trash right away.
    func setAuto(_ d: Int) {
        if d == 0 { m.setAutoDelete(nil) } else if m.videos(olderThan: d).isEmpty { m.setAutoDelete(d) } else { ask = .auto(d) }
    }

    /// The videos of organized recordings: how much they take, and a menu to send the older ones to the Trash.
    var videosRow: some View {
        row(T("settings.storage.videos"), detail: TP("settings.storage.videos.count", m.videos.count), bytes: m.videoBytes) {
            Menu(T("settings.storage.videos.delete")) {
                ForEach(VideoRetention.choices, id: \.self) { d in
                    let c = m.videos(olderThan: d)
                    Button(T("settings.storage.videos.older", d) + " (" + byteString(c.reduce(0) { $0 + $1.bytes }) + ")") { ask = .videos(d) }
                        .disabled(c.isEmpty)
                }
                Divider()
                Button(T("settings.storage.videos.all")) { ask = .videos(nil) }
            }
            .fixedSize()
            .disabled(m.videos.isEmpty)
        }
    }

    func modelRow(_ r: StorageModel.Row) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(r.name)
                    if r.inUse {
                        Text(T("settings.storage.model.in_use")).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .foregroundStyle(Color.brandInk).background(Capsule().fill(Color.brandTint))
                    }
                }
                Text([r.family, r.detail.isEmpty ? nil : r.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(byteString(r.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if r.removable { Button(T("settings.privacy.move_trash")) { ask = .trash(r) } }
            revealButton(r.path)
        }
    }

    func reveal(_ u: URL) -> some View { revealButton(u) }

    /// One reveal action everywhere: Show in Finder.
    func revealButton(_ u: URL) -> some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Image(systemName: "arrow.up.forward.app") }
            .buttonStyle(.borderless).help(T("action.reveal_in_finder")).accessibilityLabel(T("action.reveal_in_finder"))
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
