// Settings → Privacy and Settings → Storage.
//
// Privacy leads with what stays on this Mac (one line: nothing leaves it, or — with an agent on — only what organizing
// and hand-offs send to it; "Where files are kept…" opens Storage). Then the permissions, folded into one line while
// all four are allowed (status said once, at the right: the check and "All allowed"); a disclosure shows them one by
// one, and anything missing opens the list by itself, missing first, each with its Allow… (the long reasons are
// tooltips). The Screen Recording row says macOS applies a change after a restart, with Restart Blurt, only when
// Screen Recording was asked for while Blurt runs (SystemAccess.screenAskedThisRun). Then the three data choices, each
// one line: where speech is recognized (Automatic / On This Mac Only, its line saying what happens now), keeping the
// microphone audio, Spotlight. Every row starts at the same left edge; headings have no rule under them.
//
// Storage, laid out like macOS's own Storage pane: how much Blurt takes and a bar of what it is, then one list per kind
// (recordings, models, app data) whose rows share one anatomy and one size column; what can be done with a row is in
// its ⋯ menu (hover, focus, right-click), never a wall of buttons at rest. Cleaning what can safely go — videos of
// organized recordings, kept live-caption audio, unused models, caches — is always Move to Trash, never by default, at
// once like Finder, with Undo (the island's button, ⌘Z; BlurtCore TrashRestore: a folder made again takes its old
// contents back, what can't come back is said); only turning on automatic deletion asks. Storage's model rows are
// named from the catalogues at once (BlurtCore ModelCatalog), never by folder; a folder no catalogue knows is an older
// model nothing uses — Move to Trash, with Undo. Empty rows are left out; paths are tooltips, never lines.
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
    @ObservedObject var speech = SpeechModel.shared

    var body: some View {
        SettingsPage(.privacy, lead: SettingsLead(text: PrivacyPromise.text)) {
            SettingsGroup("privacy.permissions", content: {
                PermissionsSummary(p: perms)
            })
            SettingsGroup("privacy.data") {
                // where speech is recognized, said for where things stand (Automatic with no cloud key set: here too)
                SettingRow("privacy.local_asr", detail: localDetail, help: T("settings.privacy.local_asr.help")) {
                    ChoicePopup(label: T("settings.privacy.local_speech_recognition_only"),
                                choices: [(false, T("settings.privacy.local_asr.auto")), (true, T("settings.privacy.local_asr.local"))],
                                selection: Binding(get: { m.localASR }, set: { m.setLocal($0) }))
                }
                SettingToggle("privacy.keep_live", isOn: Binding(get: { m.keepLive }, set: { m.setKeep($0) }))
                SettingToggle("privacy.spotlight", isOn: Binding(get: { m.spotlight }, set: { m.setSpotlight($0) }))
            }
        }
        // the lead's "Where files are kept…": Settings goes to Storage itself
        .environment(\.openURL, OpenURLAction { _ in
            AppEnvironment.settings?.show(pane: "storage")
            return .handled
        })
        .onAppear { m.reload(); perms.start() }
        .onDisappear { perms.stop() }
        .task { if speech.state == nil { await speech.load() } }      // which cloud services have a key
    }

    /// On this Mac only: never the cloud. Automatic: here anyway while no cloud key is set; with one, it may go there.
    var localDetail: String {
        if m.localASR { return T("settings.privacy.local_asr.on") }
        let cloud = speech.models.filter { !$0.local && $0.installed }.map(\.title)
        return cloud.isEmpty ? T("settings.privacy.local_asr.off_none") : T("settings.privacy.local_asr.off_keys", Loc.list(cloud))
    }
}

/// The page's lead: what stays on this Mac, said as it is — with an agent on (the default), organizing and hand-offs
/// send what they need to it, so "nothing is uploaded" would be untrue then — and where the files are (a link to
/// Storage).
enum PrivacyPromise {
    @MainActor static var text: Text {
        // record.agents = [] turns every agent off; unset is the registry's default order (agents on)
        let agentsOff = Agents.shared.order?.isEmpty == true
        let line = T(agentsOff ? "settings.privacy.recordings_screenshots_items_stay" : "settings.privacy.stay_with_agents")
        var text = AttributedString(line.hasSuffix("。") ? line : line + " ")     // no space after a full-width stop
        var link = AttributedString(T("settings.privacy.where_files"))
        link.link = URL(string: "blurt-settings:storage")
        link.foregroundColor = .brandInk
        text.append(link)
        return Text(text)
    }
}

/// The permissions: one line while all four are allowed, the four rows under a disclosure. Something missing (or a
/// Screen Recording change waiting for a restart) opens it by itself, what needs the user first; the user's own
/// click wins after that.
private struct PermissionsSummary: View {
    @ObservedObject var p: Permissions
    @ObservedObject var guide = PermissionGuide.shared
    /// the user's own choice; nil = open exactly while something needs attention
    @State private var shown: Bool?
    static let kinds: [PermissionKind] = [.screen, .microphone, .accessibility, .inputMonitoring]

    /// Not allowed, and needed for what Blurt does now.
    func needs(_ k: PermissionKind) -> Bool { p.state(k) != .granted && !guide.satisfied(k) }

    var body: some View {
        let missing = Self.kinds.filter(needs)
        // a Screen Recording change waiting for a restart: its row (with Restart Blurt) comes right after the missing
        let restart = SystemAccess.screenAskedThisRun && !missing.contains(.screen)
        let open = shown ?? (!missing.isEmpty || restart)
        let sep = T("settings.perm.list_sep")
        let first = missing + (restart ? [.screen] : [])
        let ordered = first + Self.kinds.filter { !first.contains($0) }

        SettingsLine {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.kinds.map(PermissionGuide.name).joined(separator: sep)).font(.system(size: SettingsMetrics.titleSize))
                        .gridProbe(.text, "permissions")
                    Text(missing.isEmpty ? T("settings.privacy.perms.why")
                         : T("settings.privacy.perms.missing", missing.map(PermissionGuide.name).joined(separator: sep)))
                        .font(.system(size: SettingsMetrics.detailSize))
                        .foregroundStyle(missing.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.brandAttnInk))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if missing.isEmpty {
                    PermissionMark(ok: true)
                    Text(T("settings.privacy.perms.all_allowed")).font(.system(size: SettingsMetrics.titleSize)).foregroundStyle(.secondary)
                } else {
                    // the walk through everything still missing
                    Button(guide.running ? T("settings.perm.setup_running") : T("settings.perm.setup")) { guide.start(.all, source: .privacy) }.buttonStyle(SettingsOutlinedButtonStyle())
                }
                Button { toggle(open) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(T(open ? "settings.privacy.perms.hide" : "settings.privacy.perms.show"))
                .accessibilityLabel(T(open ? "settings.privacy.perms.hide" : "settings.privacy.perms.show"))
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(open) }
        }
        // the check-mark line after a walk ("Done — Blurt has every permission it needs.")
        if guide.finished != nil { SettingsLine { PermissionDoneBanner() } }
        if open {
            ForEach(ordered, id: \.self) { k in SettingsLine { row(k) } }
        }
    }

    private func toggle(_ open: Bool) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduce ? nil : .easeOut(duration: 0.15)) { shown = !open }
        emit(["event": "privacy_permissions", "shown": !open])
    }

    /// One permission: its name and what it is for in one line (the longer reason as the tooltip), then its state at
    /// the right — the check alone when allowed, or the attention mark and the one button that fixes it.
    func row(_ k: PermissionKind) -> some View {
        let st = p.state(k)
        let now = guide.running && guide.current == k
        let notNeeded = st != .granted && guide.satisfied(k)
        let off = st == .denied && !notNeeded
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(PermissionGuide.name(k)).font(.system(size: SettingsMetrics.titleSize))
                Text(off ? T("settings.privacy.perm.turned_off") : Self.short(k))
                    .font(.system(size: SettingsMetrics.detailSize))
                    .foregroundStyle(off ? AnyShapeStyle(Color.brandAttnInk) : AnyShapeStyle(.secondary))
                // Screen Recording asked for while Blurt runs: some macOS versions apply it only after a relaunch
                if k == .screen && SystemAccess.screenAskedThisRun {
                    HStack(spacing: 6) {
                        Text(T("settings.privacy.macos_applies_screen_recording")).font(.system(size: SettingsMetrics.detailSize))
                            .foregroundStyle(.secondary)
                        InkTextButton(T("settings.perm.restart")) { SystemAccess.relaunch() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(PermissionGuide.why(k))
            if now {
                Text(T("settings.perm.now")).font(.system(size: SettingsMetrics.titleSize)).foregroundStyle(.secondary)
            } else if st == .granted {
                PermissionMark(ok: true).help(T("settings.kit.allowed"))
            } else if notNeeded {
                Text(T("settings.perm.not_needed")).font(.system(size: SettingsMetrics.titleSize)).foregroundStyle(.secondary)
            } else {
                PermissionMark(ok: false)
                // turned off: macOS won't ask again, so the button says where it goes (the guide opens the exact
                // pane, with its helper panel beside it); never asked: Allow… (System Settings' pane in its menu)
                Button(T(off ? "settings.kit.system_settings" : "settings.kit.allow")) { guide.start(.all, only: [k], source: .privacy) }
                    .buttonStyle(SettingsOutlinedButtonStyle())
                    .contextMenu { if !off { Button(T("settings.kit.system_settings")) { Permissions.openPane(k) } } }
                    .help(off ? "" : T("settings.kit.allow_help"))
                    .accessibilityIdentifier(off ? "perm.\(k).open_settings" : "perm.\(k).allow")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What it is for, in one line.
    static func short(_ k: PermissionKind) -> String {
        k == .inputMonitoring ? T("settings.privacy.perm.input_monitoring", Dictation.keyInline) : T("settings.privacy.perm.\(k.rawValue)")
    }
}

/// Allowed: the ok disc with its check; missing: the attention disc with "!" (§2.3: a state has a shape twin). Said
/// once, at the row's right, at the size of the text beside it.
private struct PermissionMark: View {
    var ok: Bool
    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(ok ? Color.brandOnOk : Color(nsColor: BrandColor.onAttn), ok ? Color.brandOk : Color.brandAttn)
            .font(.system(size: 14))
            .accessibilityLabel(T(ok ? "settings.kit.allowed" : "settings.privacy.perm.not_allowed"))
    }
}

/// A plain text button in brand ink (§3.4: "Change in Dictation…"), not the system's link blue.
private struct InkTextButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Text(title).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandInk) }
            .buttonStyle(.plain)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

// MARK: - Storage

/// Everything big that Blurt keeps, the way macOS's own Storage pane shows a disk: first the total and a bar split by
/// kind, then one list per kind — Recordings (all recordings and snaps; inside them the videos of organized recordings
/// and kept live-caption audio, which can go; deleting videos automatically), Models (one row per model, saying which
/// pane uses it) and App data (dictation history, the index, caches, logs). Every row has one anatomy: an icon, a name,
/// one plain line, the size in the one size column; what can be done with it (Show in Finder, Move to Trash) is in its
/// ⋯ menu — shown on hover or focus, never at rest — and its right-click menu. Rows come from the file system at once;
/// which model is which and what uses it comes from the scripts (transcribe.py models and dictation-models, polish.py
/// models) a moment later. Nothing is deleted without the user asking, and what is deleted goes to the Trash.
@MainActor
final class StorageModel: ObservableObject {
    struct Row: Identifiable {
        var id: String { path.path }
        var name: String
        var path: URL
        var bytes: Int64
        /// what it is, in a few plain words ("" = nothing to say)
        var detail: String = ""
        var icon: String = "doc"
        /// what Show in Finder selects and Move to Trash moves (default: the row's path)
        var urls: [URL] = []
        /// A model: what it is for (nil = not a model the catalogues know), whether something uses it and which pane.
        var family: String?
        var vad = false
        var inUse = false
        var usedBy: [ModelUsage.Feature] = []
        /// may go to the Trash from here
        var removable = false
        var items: [URL] { urls.isEmpty ? [path] : urls }
    }
    /// The places recordings and snaps are kept (a store's sessions/ folder each) and how many there are.
    @Published var folders: [Row] = []
    @Published var sessions = 0
    @Published var videos: [VideoRetention.Candidate] = []
    @Published var liveAudio: [URL] = []
    @Published var liveAudioBytes: Int64 = 0
    @Published var models: [Row] = []
    /// App data: dictation's files, the index, caches, logs — the ones that exist.
    @Published var files: [Row] = []
    /// Free space on the volume Blurt keeps its files on.
    @Published var available: Int64?
    @Published var autoDelete: Int? = VideoRetention.autoDays
    /// the first scan is in (until then the page says "Adding up…" instead of showing empty rows)
    @Published var loaded = false
    @Published var busy = false
    @Published var checkingModels = false
    /// the scripts have said which model is used by what (until then no model says "Not used")
    @Published var annotated = false

    /// App data as the page lists it: the search index and the build files are one "Caches" row (both rebuilt when
    /// needed; Move to Trash takes the build files, never the index the app has open).
    var groupedFiles: [Row] {
        let cacheIDs = ["index.db", "build"].map { BlurtPaths.home.appendingPathComponent($0).path }
        let caches = files.filter { cacheIDs.contains($0.path.path) }
        guard !caches.isEmpty else { return files }
        let build = caches.first { $0.path.lastPathComponent == "build" }
        let row = Row(name: T("settings.storage.caches"), path: build?.path ?? caches[0].path, bytes: caches.reduce(0) { $0 + $1.bytes },
                      detail: T("settings.storage.rebuilt"), icon: "arrow.triangle.2.circlepath", urls: build.map { [$0.path] } ?? [],
                      removable: build != nil)
        var out = files.filter { !cacheIDs.contains($0.path.path) }
        out.insert(row, at: min(1, out.count))
        return out
    }

    var videoBytes: Int64 { videos.reduce(0) { $0 + $1.bytes } }
    var recordingBytes: Int64 { folders.reduce(0) { $0 + $1.bytes } }
    var modelBytes: Int64 { models.reduce(0) { $0 + $1.bytes } }
    var fileBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    /// Videos and live-caption audio are inside the recordings' folders: counted there, not again.
    var total: Int64 { recordingBytes + modelBytes + fileBytes }

    func videos(olderThan days: Int?) -> [VideoRetention.Candidate] {
        guard let d = days else { return videos }
        return videos.filter { Date().timeIntervalSince($0.date) >= Double(d) * 86400 }
    }

    func load() async {
        busy = true
        defer { busy = false }
        let current = (NSApp.delegate as? App)?.lastSession.map { Set([$0.standardizedFileURL.path]) } ?? []
        let r = await Task.detached { () -> ([Row], Int, [VideoRetention.Candidate], [Row], [Row], [URL], Int64, Int64?) in
            let fm = FileManager.default
            let roots = StorageModel.roots()
            var folders: [Row] = []
            var sessions = 0
            for root in roots where fm.fileExists(atPath: root.path) {
                sessions += ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.count
                let ws = root.lastPathComponent == "recordings" ? root.deletingLastPathComponent() : root.deletingLastPathComponent().deletingLastPathComponent()
                // ~/Blurt holds two: its Unassigned store (inbox/sessions) and v0.6's recordings/ — name them apart
                let name = isDefaultWorkspace(ws) ? "~/Blurt/" + (root.path.dropFirst(ws.path.count + 1).split(separator: "/").first.map(String.init) ?? "") : ws.lastPathComponent
                folders.append(Row(name: name, path: root, bytes: diskSize(root), icon: "folder"))
            }
            let videos = VideoRetention.candidates(roots: roots, olderThan: nil, excluding: current)
            let h = BlurtPaths.home
            func row(_ name: String, _ rel: String, _ icon: String, _ detail: String, removable: Bool = false) -> Row? {
                let u = h.appendingPathComponent(rel)
                guard fm.fileExists(atPath: u.path) else { return nil }
                var b = diskSize(u)
                if rel == "index.db" { b += diskSize(h.appendingPathComponent("index.db-wal")) + diskSize(h.appendingPathComponent("index.db-shm")) }
                return Row(name: name, path: u, bytes: b, detail: detail, icon: icon, removable: removable)
            }
            let managed = T("settings.storage.managed_in_dictation"), rebuilt = T("settings.storage.rebuilt")
            let files = [
                row(T("settings.storage.dictation_history"), "dictation/history.jsonl", "character.cursor.ibeam", managed),
                row(T("settings.storage.dictation_audio"), "dictation/audio", "waveform", managed),
                row(T("settings.storage.dictation_lab"), "dictation/lab", "testtube.2", T("settings.storage.detail.lab")),
                row(T("settings.privacy.search_index"), "index.db", "magnifyingglass", rebuilt),
                row(T("settings.privacy.build_cache"), "build", "hammer", rebuilt, removable: true),
                row(T("settings.privacy.agent_runs"), "runs", "paperplane", T("settings.storage.detail.runs")),
                row(T("settings.storage.jobs"), "jobs", "list.bullet.rectangle", T("settings.storage.detail.jobs")),
                row(T("settings.storage.handoff"), "handoff", "doc.text", T("settings.storage.detail.handoff")),
                row(T("settings.privacy.prompts"), "prompts", "text.quote", T("settings.storage.detail.prompts"), removable: true),
                row(T("settings.privacy.benchmark_samples"), "bench", "timer", T("settings.storage.detail.bench"), removable: true),
                row(T("settings.storage.tmp"), "tmp", "tray", T("settings.storage.detail.tmp"), removable: true),
            ].compactMap { $0 }.filter { $0.bytes > 0 }
            let live = Retention.liveAudioFiles()
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
            let v = try? h.resourceValues(forKeys: keys)
            let free = v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
            return (folders, sessions, videos, StorageModel.scanModels(), files, live, live.reduce(0) { $0 + diskSize($1) }, free)
        }.value
        folders = r.0; sessions = r.1; videos = r.2; files = r.4; liveAudio = r.5; liveAudioBytes = r.6; available = r.7
        // fresh sizes; what the scripts said last time (names, use, the shared-cache rows) until they say it again
        let before = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        models = r.3.map { fresh in
            guard var row = before[fresh.id] else { return fresh }
            row.bytes = fresh.bytes
            return row
        } + models.filter { $0.family != nil && !r.3.map(\.id).contains($0.id) && !$0.path.path.hasPrefix(BlurtPaths.home.path) }
        models.sort { $0.bytes > $1.bytes }
        autoDelete = VideoRetention.autoDays
        loaded = true
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
        func model(_ u: URL) -> Row {
            let f = u.lastPathComponent
            return Row(name: displayName(f), path: u, bytes: diskSize(u), icon: icon(f), family: family(f), vad: f == "silero_vad.onnx")
        }
        for e in ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
            where !e.lastPathComponent.hasPrefix(".") {
            if ["asr", "polish"].contains(e.lastPathComponent) {
                for m in ((try? fm.contentsOfDirectory(at: e, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
                    where !m.lastPathComponent.hasPrefix(".") {
                    out.append(model(m))
                }
            } else {
                out.append(model(e))
            }
        }
        return out
    }

    /// A model's glyph by what it does, as the Models pane draws it: speech recognition the waveform, polish the wand
    /// (an unknown folder: the generic chip).
    nonisolated static func icon(_ folder: String) -> String {
        if folder == "silero_vad.onnx" { return "waveform" }
        guard let e = ModelCatalog.entry(folder: folder) else { return "cpu" }
        return e.polish ? "wand.and.stars" : "waveform"
    }
    nonisolated static func icon(_ k: ModelUsage.Kind) -> String { k == .polish ? "wand.and.stars" : "waveform" }

    /// What a model folder is for, from the catalogues (nil: not known — annotateModels says it).
    nonisolated static func family(_ folder: String) -> String? {
        if folder == "silero_vad.onnx" { return T("settings.storage.model.vad") }
        return ModelCatalog.entry(folder: folder).map { T($0.polish ? "settings.storage.model.polish" : "settings.storage.model.asr") }
    }

    /// A model folder's name for people: the catalogue's name, the voice detector by what it is, anything else as a
    /// model this version doesn't use (the folder is in the row's tooltip, with its path).
    nonisolated static func displayName(_ folder: String) -> String {
        if folder == "silero_vad.onnx" { return T("settings.storage.model.vad_name") }
        return ModelCatalog.entry(folder: folder)?.name ?? T("settings.storage.model.unknown")
    }

    /// Which model is which and what uses it (BlurtCore ModelUsage): transcribe.py models and dictation-models (speech
    /// recognition: recordings, live captions, voice notes, dictation) and polish.py models (dictation's clean-up).
    /// Models of theirs in the shared Hugging Face cache are listed too, with their size, but never removed here: other
    /// apps may use that cache.
    func annotateModels() async {
        checkingModels = true
        defer { checkingModels = false }
        async let asrRun = try? SkillCLI.shared.run("transcribe.py", ["models"], timeout: 180)
        async let dictationRun = try? SkillCLI.shared.run("transcribe.py", ["dictation-models"], timeout: 180)
        async let polishRun = try? SkillCLI.shared.run("polish.py", ["models"], timeout: 60)
        let (asr, dictation, polish) = await (asrRun?.json, dictationRun?.json, polishRun?.json)
        let known = ModelUsage.merge(asr: asr, dictation: dictation, polish: polish)
        guard !known.isEmpty else { return }
        let users = ModelUsage.users(asr: asr, dictation: dictation, polish: polish)
        func family(_ k: ModelUsage.Kind) -> String {
            T(k == .vad ? "settings.storage.model.vad" : k == .polish ? "settings.storage.model.polish" : "settings.storage.model.asr")
        }
        let own = BlurtPaths.home.appendingPathComponent("models").standardizedFileURL.path
        var rows = models.filter { $0.path.standardizedFileURL.path.hasPrefix(own) }
        // the scripts and the folder listing may name one model by two paths (a models folder that is a link, a model
        // linked in): matched on where the links lead too, so a model in use is never taken for one nothing uses
        func resolved(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path }
        let knownResolved = Dictionary(known.map { (resolved($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        let usersResolved = Dictionary(users.map { (resolved($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        for i in rows.indices {
            let p = rows[i].path.standardizedFileURL.path
            let r = resolved(p)
            guard let k = known[p] ?? knownResolved[r] else {
                // a folder no script knows (a model an older version used): nothing uses it, it may go
                let folder = rows[i].path.lastPathComponent
                if folder != "silero_vad.onnx", ModelCatalog.entry(folder: folder) == nil {
                    rows[i].family = nil
                    rows[i].detail = T("settings.storage.model.unused")
                    rows[i].removable = true
                }
                continue
            }
            rows[i].name = k.name
            rows[i].family = family(k.kind)
            rows[i].vad = k.kind == .vad
            rows[i].icon = StorageModel.icon(k.kind)
            rows[i].inUse = k.inUse
            rows[i].usedBy = users[p] ?? usersResolved[r] ?? []
            rows[i].removable = k.removable
        }
        // the shared Hugging Face cache: its repo folders (the snapshots are links into them)
        for (p, k) in known.sorted(by: { $0.key < $1.key }) where !p.hasPrefix(own) {
            let u = URL(fileURLWithPath: p)
            let bytes = await Task.detached { diskSize(u) }.value
            rows.append(Row(name: k.name, path: u, bytes: bytes, icon: StorageModel.icon(k.kind), family: family(k.kind), vad: k.kind == .vad,
                            inUse: k.inUse, usedBy: users[p] ?? [], removable: false))
        }
        models = rows.sorted { $0.bytes > $1.bytes }          // biggest first, as macOS lists what takes space
        annotated = true
    }

    /// Models in the shared Hugging Face cache are listed, never removed here.
    var hasShared: Bool { models.contains { !$0.path.standardizedFileURL.path.hasPrefix(BlurtPaths.home.standardizedFileURL.path) } }

    /// Move to Trash at once — like Finder, no question — with Undo: the island's button and ⌘Z (the Settings window's
    /// undo) put it back where it was.
    func trash(_ urls: [URL], name: String, window: NSWindow?) {
        NSWorkspace.shared.recycle(urls) { done, _ in
            Task { @MainActor in
                emit(["event": "storage_trash", "files": done.count])
                await self.load()
                await DictationModels.shared.load()          // a model gone: the dictation key knows
                self.offerUndo(done, text: T("settings.storage.trashed", name), name: name, window: window) { _ in }
            }
        }
    }

    /// The videos of organized recordings older than `days` (nil = all) go to the Trash, with Undo.
    func deleteVideos(olderThan days: Int?, window: NSWindow?) {
        let c = videos(olderThan: days)
        guard !c.isEmpty else { return }
        let bytes = byteString(c.reduce(0) { $0 + $1.bytes })
        Housekeeping.trashVideos(c, auto: false) { done in
            Task { @MainActor in
                await self.load()
                self.offerUndo(done, text: T("settings.storage.videos.trashed", TP("settings.storage.videos.count", c.count), bytes), window: window) { back in
                    // only the sessions whose video came back stop saying it was removed
                    for s in c where back.contains(where: { $0.standardizedFileURL.path.hasPrefix(s.session.standardizedFileURL.path + "/") }) {
                        VideoRetention.unstampRemoved(s.session)
                    }
                }
            }
        }
    }

    /// "Moved to the Trash · Undo" in the island, and the same step on the window's ⌘Z. `name`: the row's name, said
    /// when it can't come back (never the folder's name on disk).
    private func offerUndo(_ moved: [URL: URL], text: String, name: String? = nil, window: NSWindow?, restored: @escaping ([URL]) -> Void) {
        guard !moved.isEmpty else { return }
        var undone = false
        let undo: () -> Void = { [weak self] in
            guard !undone else { return }
            undone = true
            // back where it was (a folder made again meanwhile takes its old contents back); what can't come back
            // — the Trash emptied, the name taken again — is said, not silently skipped
            let (back, missing) = TrashRestore.restore(moved)
            restored(back)
            emit(["event": "storage_trash_undo", "files": back.count, "missing": missing.map(\.lastPathComponent)])
            if !missing.isEmpty {
                var t = Island.Toast(text: missing.count == 1 && name != nil ? T("settings.storage.undo_failed", name ?? "")
                                                              : T("settings.storage.undo_failed_many", missing.count),
                                     actionTitle: nil, action: nil)
                t.seconds = 6
                island.toast(t)
            }
            Task { @MainActor in
                await self?.load()
                await DictationModels.shared.load()
            }
        }
        if let um = window?.undoManager {
            um.registerUndo(withTarget: self) { _ in undo() }
            um.setActionName(T("settings.privacy.move_trash"))
        }
        var t = Island.Toast(text: text, actionTitle: T("settings.storage.undo")) { undo() }
        t.seconds = 8
        island.toast(t)
        lastTrash = undo
    }

    /// Tests: the last Move to Trash's Undo.
    var lastTrash: (() -> Void)?

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

/// A size as every row and heading says it: one formatter (ByteCountFormatter, file style) in every language — "0 KB"
/// for nothing, a number like every other in the column.
func storageSize(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]     // nothing is "0 KB", like the rows beside it, never "0 bytes"
    return f.string(fromByteCount: max(0, n))
}

/// Free space, rounded as people say it: "438 GB", "42.5 GB" (no hundredths on a number this size).
func roundedSize(_ n: Int64) -> String {
    let gb = Double(n) / 1_000_000_000
    guard gb >= 1 else { return byteString(n) }
    let f = NumberFormatter()
    f.locale = Loc.locale
    f.maximumFractionDigits = gb >= 100 ? 0 : 1
    return T("settings.storage.gb", f.string(from: gb as NSNumber) ?? "\(Int(gb))")
}

enum StorageMetrics {
    /// the one size column every row shares, flush with the page's trailing edge
    static let sizeWidth: CGFloat = 76
    /// the ⋯ menu's slot before it, kept when the menu isn't shown so nothing moves
    static let menuWidth: CGFloat = 24
}

/// Tests: the row whose ⋯ shows as if the pointer were on it (SelfTests "storagehover NAME"), for screenshots.
final class StorageHover: ObservableObject {
    static let shared = StorageHover()
    @Published var forced: String?
}

/// One thing a row's ⋯ menu (and its right-click menu) can do; with children, a submenu.
struct StorageAction: Identifiable {
    let id = UUID()
    var title: String
    var disabled = false
    var dividerBefore = false
    var children: [StorageAction] = []
    var run: () -> Void = {}
}

struct StorageMenuItems: View {
    var actions: [StorageAction]
    var body: some View {
        ForEach(actions) { a in
            if a.dividerBefore { Divider() }
            if a.children.isEmpty {
                Button(a.title, action: a.run).disabled(a.disabled)
            } else {
                Menu(a.title) {
                    ForEach(a.children) { c in
                        if c.dividerBefore { Divider() }
                        Button(c.title, action: c.run).disabled(c.disabled)
                    }
                }
            }
        }
    }
}

/// One storage row: its glyph in the page's one icon gutter, name and one plain line on the left; the size flush with
/// the trailing edge (where every page's controls end); the ⋯ menu's slot just before the size, empty at rest and filled
/// on hover or keyboard focus. The path is the tooltip, never a line of the row.
struct StorageRow: View {
    var icon: String
    var title: String
    var detail: AttributedString?
    var size: String
    var tip: String?
    var actions: [StorageAction] = []
    @State private var hover = false
    @FocusState private var menuFocused: Bool
    @ObservedObject private var forced = StorageHover.shared

    var body: some View {
        if actions.isEmpty { line } else { line.contextMenu { StorageMenuItems(actions: actions) } }
    }

    private var showMenu: Bool { hover || menuFocused || forced.forced == title }

    private var line: some View {
        SettingsLine {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                    SettingsIcon(icon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: SettingsMetrics.titleSize)).fixedSize(horizontal: false, vertical: true)
                            .gridProbe(.iconText, title)
                        if let d = detail, !d.characters.isEmpty {
                            Text(d).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary).tint(Color.brandInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    // the slot stays when a row offers nothing, so every size ends at the same edge
                    ZStack { Color.clear.frame(height: 1); menu }.frame(width: StorageMetrics.menuWidth)
                    Text(size).font(.system(size: SettingsMetrics.titleSize).monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).frame(width: StorageMetrics.sizeWidth, alignment: .trailing)
                        .gridProbe(.trailing, title)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(tip ?? "")
        .accessibilityElement(children: .contain)
        .environment(\.openURL, OpenURLAction { StoragePane.open($0) })
    }

    @ViewBuilder private var menu: some View {
        if !actions.isEmpty {
            Menu { StorageMenuItems(actions: actions) } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 20).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .focused($menuFocused)
            .opacity(showMenu ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: showMenu)
            .help(T("settings.storage.more"))
            .accessibilityLabel(T("settings.storage.more") + ": " + title)
        }
    }
}

struct StoragePane: View {
    @StateObject var m = StorageModel()
    /// what each model is used for (its rows say it in Speech's words)
    @ObservedObject private var speech = SpeechModel.shared
    @ObservedObject private var dictationModels = DictationModels.shared
    /// What the confirmation is about: only turning on automatic deletion asks (it deletes on its own from then on).
    enum Ask: Identifiable {
        case auto(Int)
        var id: String { switch self { case .auto(let d): return "a\(d)" } }
    }
    @State var ask: Ask?

    var body: some View {
        SettingsPage(.storage, lead: summary) {
            SettingsGroup("storage.recordings", content: {
                if m.loaded { recordings }
                SettingRow("storage.auto_delete", icon: "clock.arrow.circlepath") {
                    ChoicePopup(label: T("settings.storage.videos.auto"),
                                choices: [(0, T("settings.storage.videos.never"))] + VideoRetention.choices.map { ($0, T("settings.storage.videos.after", $0)) },
                                selection: Binding(get: { m.autoDelete ?? 0 }, set: { setAuto($0) }), dividers: [1])
                }
            }, accessory: { headingSize(m.recordingBytes) })

            SettingsGroup("storage.models", note: AnyView(modelsFootnote), content: {
                if m.loaded {
                    if m.models.isEmpty {
                        StorageRow(icon: "cpu", title: T("settings.storage.model.none"), size: storageSize(0))
                    }
                    // the voice detector is part of local speech recognition, not a model to choose: said on the
                    // recognition rows, never a row of its own
                    ForEach(m.models.filter { !$0.vad }) { r in modelRow(r) }
                }
            }, accessory: {
                HStack(spacing: 8) {
                    if m.checkingModels { BrandSpinnerView(size: 10) }
                    headingSize(m.modelBytes)
                }
            })

            if !m.files.isEmpty {
                SettingsGroup("storage.files", content: {
                    ForEach(m.groupedFiles) { r in fileRow(r) }
                }, accessory: { headingSize(m.fileBytes) })
            }
        }
        .task { await m.load() }
        .task { if speech.state == nil { await speech.load() } }
        .task { dictationModels.loadIfNeeded() }
        // the one question left: a policy that deletes on its own from now on (a Move to Trash has Undo instead)
        .alert(alertTitle, isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }), presenting: ask) { a in
            Button(T("settings.storage.videos.auto_on"), role: .destructive) {
                if case .auto(let d) = a { m.setAutoDelete(d) }
                ask = nil
            }
            Button(T("settings.privacy.cancel"), role: .cancel) { ask = nil }
        } message: { a in
            if case .auto(let d) = a {
                let c = m.videos(olderThan: d)
                Text(T("settings.storage.videos.auto_confirm") + " " + TP("settings.storage.videos.count", c.count) + " (" + byteString(c.reduce(0) { $0 + $1.bytes }) + "). " + T("settings.storage.videos.confirm"))
            }
        }
    }

    var alertTitle: String {
        if case .auto(let d) = ask { return T("settings.storage.videos.auto_confirm_title", d) }
        return ""
    }

    /// Never applies at once; an age does too when no video is that old yet, else it asks first — choosing it moves
    /// those videos to the Trash right away.
    func setAuto(_ d: Int) {
        if d == 0 { m.setAutoDelete(nil) } else if m.videos(olderThan: d).isEmpty { m.setAutoDelete(d) } else { ask = .auto(d) }
    }

    // MARK: summary

    /// The page's one focus, as its lead: how much Blurt takes, and how much the Mac has left; each section's heading
    /// carries its own total (the same size column as its rows), so no bar has to be decoded.
    var summary: SettingsLead {
        SettingsLead(text: m.loaded ? Text(totalLine) : Text(T("settings.storage.counting")),
                     accessory: m.available.map { a in
                         AnyView(Text(T("settings.storage.available", roundedSize(a))).monospacedDigit().foregroundStyle(.secondary))
                     })
    }

    /// "Blurt uses 3.9 GB", the size in semibold tabular figures.
    var totalLine: AttributedString {
        let size = byteString(m.total)
        var a = AttributedString(T("settings.storage.uses", size))
        if let r = a.range(of: size) { a[r].font = .system(size: SettingsMetrics.detailSize, weight: .semibold).monospacedDigit() }
        return a
    }

    /// A section's total on its heading's line, over its rows' size column.
    func headingSize(_ n: Int64) -> some View {
        Text(m.loaded ? storageSize(n) : "").font(.system(size: SettingsMetrics.detailSize, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    // MARK: rows

    /// All recordings and snaps as one row (its folders behind Show in Finder); inside it, the videos of organized
    /// recordings and any kept live-caption audio — the parts that can go.
    @ViewBuilder var recordings: some View {
        let detail: String = m.sessions == 0 ? T("settings.storage.none_yet")
            : TP("settings.storage.recordings.count", m.sessions) + (m.folders.count > 1 ? " · " + TP("settings.privacy.sessions", m.folders.count) : "")
        StorageRow(icon: "record.circle", title: T("settings.privacy.recordings_screenshots"), detail: AttributedString(detail),
                   size: storageSize(m.recordingBytes), tip: m.folders.map { tilde($0.path) }.joined(separator: "\n"),
                   actions: m.sessions == 0 ? [] : [reveal(m.folders)])
        if !m.videos.isEmpty {
            StorageRow(icon: "film", title: T("settings.storage.videos"),
                       detail: AttributedString(T("settings.storage.videos.detail", TP("settings.storage.videos.count", m.videos.count))),
                       size: storageSize(m.videoBytes), tip: T("settings.storage.videos.footer"), actions: [videoActions])
        }
        if !m.liveAudio.isEmpty {
            let detail = TP("settings.privacy.live_audio", m.liveAudio.count) + " · " + T("settings.storage.live_audio.kept")
            StorageRow(icon: "captions.bubble", title: T("settings.storage.live_audio"),
                       detail: linked(detail, [(T("settings.kit.privacy"), "privacy/privacy.keep_live")]),
                       size: storageSize(m.liveAudioBytes),
                       actions: [StorageAction(title: T("action.reveal_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting(m.liveAudio) },
                                 trashAction(m.liveAudio, name: T("settings.storage.live_audio"))])
        }
    }

    /// Move to Trash ▸ Older Than 30 Days (1.2 GB) … / All Videos (2.3 GB), each with Undo.
    var videoActions: StorageAction {
        var older = VideoRetention.choices.map { d -> StorageAction in
            let c = m.videos(olderThan: d)
            return StorageAction(title: T("settings.storage.videos.older", d) + (c.isEmpty ? "" : " (" + byteString(c.reduce(0) { $0 + $1.bytes }) + ")"),
                                 disabled: c.isEmpty) { m.deleteVideos(olderThan: d, window: NSApp.keyWindow) }
        }
        older.append(StorageAction(title: T("settings.storage.videos.all") + " (" + byteString(m.videoBytes) + ")", dividerBefore: true) {
            m.deleteVideos(olderThan: nil, window: NSApp.keyWindow)
        })
        return StorageAction(title: T("settings.privacy.move_trash"), children: older)
    }

    /// A model: the jobs it does now, in the words of Speech's rows ("Used for live captions and voice notes"); only a
    /// model nothing uses says so, and one Blurt downloaded can then go to the Trash. What kind of model it is (speech
    /// recognition, polish) is the tooltip, with its path.
    func modelRow(_ r: StorageModel.Row) -> some View {
        var line = ""
        if r.family == nil, !r.detail.isEmpty { line = r.detail }
        else if r.vad { line = T("settings.storage.model.vad_use") }
        else {
            let jobs = StoragePane.jobs(for: r)
            if !jobs.isEmpty { line = T("settings.storage.model.used_for", Loc.list(jobs.map { $0.lowercased(with: Loc.locale) })) }
            else if m.annotated && !r.inUse { line = T("settings.storage.model.not_used") }
            // a local recogniser in use runs with the voice detector (its own file, shared by them all)
            if r.icon == "waveform", r.inUse || !jobs.isEmpty, m.models.contains(where: \.vad) {
                line += (line.isEmpty ? "" : " · ") + T("settings.storage.model.with_vad")
            }
        }
        var actions = [reveal([r])]
        if r.removable { actions.append(trashAction(r.items, name: r.name)) }
        return StorageRow(icon: r.icon, title: r.name, detail: AttributedString(line), size: storageSize(r.bytes),
                          tip: [r.family, tilde(r.path)].compactMap { $0 }.joined(separator: "\n"), actions: actions)
    }

    /// The jobs a model on disk does now, as Speech's rows name them: its recognition purposes (Speech's state, by the
    /// model's folder), Dictation when it is dictation's recogniser, Dictation polish when it is the polish model.
    @MainActor static func jobs(for r: StorageModel.Row) -> [String] {
        let path = r.path.standardizedFileURL.path
        var out: [String] = []
        let sm = SpeechModel.shared, dm = DictationModels.shared
        if let x = sm.models.first(where: { $0.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path || $0.title == r.name }) {
            for p in ASRPurpose.allCases where sm.state?.selected[p.rawValue] == x.id { out.append(p.title) }
        }
        if let a = dm.selectedASR, (a.name ?? dm.asrName(a.id)) == r.name || dm.asrName(a.id) == r.name,
           dm.asr?.selectedInstalled ?? a.installed { out.append(Loc.string("speech.purpose.dictation", table: "Speech")) }
        if let p = dm.selectedPolish, p.name == r.name, p.installed { out.append(Loc.string("speech.purpose.polish", table: "Speech")) }
        return out
    }

    /// Under the models, outside their box: where they are chosen (Speech, a link), and — when the list has any — why
    /// the shared cache's models stay.
    var modelsFootnote: some View {
        let s = T(m.hasShared ? "settings.storage.model.footer_shared" : "settings.storage.model.footer")
        return Text(linked(s, [(T("settings.kit.speech"), "speech/speech.jobs")]))
            .environment(\.openURL, OpenURLAction { StoragePane.open($0) })
    }

    func fileRow(_ r: StorageModel.Row) -> some View {
        var actions = [reveal([r])]
        if r.removable { actions.append(trashAction(r.items, name: r.name)) }
        let detail = r.detail == T("settings.storage.managed_in_dictation")
            ? linked(r.detail, [(T("dictation.settings.tab"), "dictation/dictation.history")]) : AttributedString(r.detail)
        return StorageRow(icon: r.icon, title: r.name, detail: detail, size: storageSize(r.bytes), tip: tilde(r.path), actions: actions)
    }

    // MARK: actions

    /// Show in Finder: one place selects it; several (recordings in more than one store) are a submenu by name.
    func reveal(_ rows: [StorageModel.Row]) -> StorageAction {
        let title = T("action.reveal_in_finder")
        if rows.count == 1, let r = rows.first { return StorageAction(title: title) { NSWorkspace.shared.activateFileViewerSelecting(r.items) } }
        return StorageAction(title: title, children: rows.map { r in
            StorageAction(title: r.name) { NSWorkspace.shared.activateFileViewerSelecting(r.items) }
        })
    }

    /// The one destructive verb on the page: Move to Trash, at once, with Undo.
    func trashAction(_ urls: [URL], name: String) -> StorageAction {
        StorageAction(title: T("settings.privacy.move_trash"), dividerBefore: true) { m.trash(urls, name: name, window: NSApp.keyWindow) }
    }

    func tilde(_ u: URL) -> String { (u.path as NSString).abbreviatingWithTildeInPath }

    /// Text with the named panes as links (brand ink, §3.4), each to its pane; the first time each name appears.
    func linked(_ s: String, _ links: [(String, String)]) -> AttributedString {
        var a = AttributedString(s)
        for (word, pane) in links {
            if let r = a.range(of: word) { a[r].link = URL(string: "blurt-settings:" + pane) }
        }
        return a
    }

    /// A pane link inside this page's text: Settings goes there itself (never handed to the system as a URL).
    static func open(_ u: URL) -> OpenURLAction.Result {
        guard u.scheme == "blurt-settings" else { return .systemAction }
        AppEnvironment.settings?.show(pane: String(u.absoluteString.dropFirst("blurt-settings:".count)))
        return .handled
    }
}
