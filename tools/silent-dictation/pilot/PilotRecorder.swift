// Standalone local research recorder. No capture occurs until the user enables it.
import SwiftUI
import AVFoundation
import AVKit
import CoreAudio

struct Take: Codable, Identifiable {
    let id: String
    let speaker_id: String
    let session_id: String
    let split: String
    let phrase_family: String
    let language: String
    let mode: String
    let prompt: String
    let language_profile: String?
    let domain: String?
    let target_terms: [String]?
}
struct Plan: Codable { let takes: [Take] }

final class Recorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let queue = DispatchQueue(label: "blurt.vsr.pilot.capture")
    private let movie = AVCaptureMovieFileOutput()
    private var videoDevice: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private var startDate = Date()
    private var captureStartedAt: TimeInterval?
    private var captureWallSeconds: Double?
    private var startPressedAt: Double?
    private var startLatencySeconds: Double?
    private var audioInfo: [String: Any] = [:]
    private var activeTake: Take?
    private var activeAudio = false
    private var cameraInfo: [String: Any] = [:]
    private var draftContextSource = "capture"
    let root: URL
    let allTakes: [Take]
    @Published var takes: [Take]
    @Published var sessionID: String
    @Published var index = 0
    @Published var ready = false
    @Published var busy = false
    @Published var recording = false
    @Published var status = UIMessage("status.off")
    @Published var draft: URL?
    @Published var player: AVPlayer?
    @Published var reference = ""
    @Published var verified = false
    @Published var includeAudio = UserDefaults.standard.bool(forKey: "pilot.includeAudio") {
        didSet { UserDefaults.standard.set(includeAudio, forKey: "pilot.includeAudio") }
    }
    @Published var microphoneName = ""
    @Published var saved = 0
    private var duration = 0.0
    var take: Take? { index < takes.count ? takes[index] : nil }
    var isSilent: Bool { take?.mode.contains("silent") ?? true }

    init(root: URL, sessionID: String?, recoveryURL: URL? = nil) throws {
        self.root = root
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: root.appendingPathComponent("plan.json")))
        allTakes = plan.takes
        let selectedSession = sessionID ?? plan.takes.first(where: { $0.split == "train" })?.session_id ?? "train-01"
        self.sessionID = selectedSession
        let all = plan.takes.filter { $0.session_id == selectedSession }
        guard !all.isEmpty else { throw PilotError("error.session", selectedSession) }
        takes = all.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent("clips/\($0.id).json").path) }
        super.init()
        // Attach once before the capture queue starts. Attaching a new preview layer
        // during SwiftUI rendering can deadlock against commitConfiguration().
        previewLayer.session = session
        status = takes.isEmpty ? UIMessage("status.complete") : UIMessage("status.remaining", takes.count)
        // Only drafts with durable take metadata are recovered automatically.
        // --recover-draft is also available for explicit recovery of older, unjournaled files.
        let pending = root.appendingPathComponent("pending")
        let candidates = (try? FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let recoverable = candidates.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }.compactMap { url -> URL? in
            guard let bytes = try? Data(contentsOf: url),
                  let record = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let takeID = record["take_id"] as? String,
                  takes.contains(where: { $0.id == takeID }),
                  let name = record["filename"] as? String, name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
            let video = root.appendingPathComponent("clips/\(name)")
            return FileManager.default.fileExists(atPath: video.path) ? video : nil
        }
        if let video = recoveryURL ?? recoverable.first {
            busy = true
            Task { await recover(video) }
        }
    }

    private func journalURL(for video: URL) -> URL {
        root.appendingPathComponent("pending/\(video.deletingPathExtension().lastPathComponent).json")
    }

    private func journal(_ video: URL) throws {
        guard let take = activeTake else { throw PilotError("error.noRecoveryTake") }
        let data: [String: Any] = ["take_id": take.id, "filename": video.lastPathComponent,
                                  "captured_at": ISO8601DateFormatter().string(from: startDate),
                                  "audio_recorded": activeAudio, "camera": cameraInfo,
                                  "context_source": draftContextSource, "audio_device": audioInfo,
                                  "capture_wall_seconds": captureWallSeconds as Any? ?? NSNull(),
                                  "start_latency_seconds": startLatencySeconds as Any? ?? NSNull()]
        let url = journalURL(for: video)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private func recover(_ video: URL) async {
        do {
            guard video.resolvingSymlinksInPath().deletingLastPathComponent() == root.appendingPathComponent("clips").resolvingSymlinksInPath() else {
                throw PilotError("error.recoveryPath")
            }
            let metadataURL = journalURL(for: video)
            let metadata = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let selected = metadata?["take_id"] as? String
            guard let take = selected.flatMap({ id in takes.first(where: { $0.id == id }) }) ?? (selected == nil ? self.take : nil) else {
                throw PilotError("error.noRecoveryTake")
            }
            let asset = AVURLAsset(url: video)
            let audio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
            guard !(take.mode.contains("silent") && audio) else { throw PilotError("error.audioMismatch") }
            let created = try video.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()
            await MainActor.run {
                self.activeTake = take
                self.index = self.takes.firstIndex(where: { $0.id == take.id })!
                self.startDate = (metadata?["captured_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? created
                self.activeAudio = audio
                self.cameraInfo = metadata?["camera"] as? [String: Any] ?? [:]
                self.audioInfo = metadata?["audio_device"] as? [String: Any] ?? [:]
                self.captureWallSeconds = metadata?["capture_wall_seconds"] as? Double
                self.startLatencySeconds = metadata?["start_latency_seconds"] as? Double
                self.draftContextSource = metadata?["context_source"] as? String ?? "legacy_recovery_current_take_requires_participant_verification"
            }
            try journal(video)
            try await presentReview(video, recovered: true)
        } catch { fail(error) }
    }

    private func presentReview(_ video: URL, recovered: Bool = false) async throws {
        let asset = AVURLAsset(url: video)
        let seconds = try await asset.load(.duration).seconds
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        guard seconds.isFinite, seconds > 0, seconds <= 32 else { throw PilotError("error.videoDuration") }
        guard hasAudio == activeAudio else { throw PilotError("error.audioMismatch") }
        await MainActor.run {
            self.recording = false; self.busy = false; self.duration = seconds
            self.draft = video
            let player = AVPlayer(url: video)
            player.defaultRate = 1
            player.currentItem?.audioTimePitchAlgorithm = .timeDomain
            self.player = player
            self.reference = self.activeTake?.prompt ?? ""; self.verified = false
            self.status = UIMessage(recovered ? "status.recovered" : "status.review")
        }
    }

    func switchSession(_ value: String) {
        guard !ready, !busy, !recording, draft == nil else { return }
        sessionID = value; index = 0
        takes = allTakes.filter { $0.session_id == value && !FileManager.default.fileExists(atPath: root.appendingPathComponent("clips/\($0.id).json").path) }
        verified = false
        status = takes.isEmpty ? UIMessage("status.complete") : UIMessage("status.remaining", takes.count)
    }

    func enableCamera(startAfterEnable: Bool = false) {
        guard !busy, !ready else { return }
        busy = true
        AVCaptureDevice.requestAccess(for: .video) { allowed in
            guard allowed else { self.fail(UIMessage("error.cameraPermission")); return }
            self.queue.async {
                do {
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    if self.videoDevice == nil {
                        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                            ?? AVCaptureDevice.default(.external, for: .video, position: .unspecified) else {
                            throw PilotError("error.cameraMissing")
                        }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard self.session.canAddInput(input), self.session.canAddOutput(self.movie) else {
                            throw PilotError("error.cameraConfiguration")
                        }
                        self.session.addInput(input)
                        self.session.addOutput(self.movie)
                        if self.session.canSetSessionPreset(.hd1920x1080) { self.session.sessionPreset = .hd1920x1080 }
                        self.videoDevice = device
                        self.movie.maxRecordedDuration = CMTime(seconds: 30, preferredTimescale: 600)
                        if let c = self.movie.connection(with: .video), c.isVideoMirroringSupported {
                            c.automaticallyAdjustsVideoMirroring = false
                            c.isVideoMirrored = false
                        }
                    }
                } catch { self.fail(error); return }
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.ready = true; self.busy = false; self.status = UIMessage("status.preview")
                    self.microphoneName = Self.preferredMicrophone()?.localizedName ?? ""
                    if startAfterEnable { self.start() }
                }
            }
        }
    }

    func stopCamera() {
        guard !recording, !busy else { return }
        busy = true
        queue.async {
            self.session.stopRunning()
            DispatchQueue.main.async { self.ready = false; self.busy = false; self.status = UIMessage("status.off") }
        }
    }

    static func preferredMicrophone() -> AVCaptureDevice? {
        // Avoid Bluetooth call-profile/sample-rate changes during capture and review.
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn })
            ?? AVCaptureDevice.default(for: .audio)
    }

    func start() {
        guard ready, !busy, !recording, draft == nil, let take else { return }
        busy = true
        activeTake = take
        activeAudio = includeAudio && !isSilent
        draftContextSource = "capture"
        captureStartedAt = nil; captureWallSeconds = nil; audioInfo = [:]
        // Adding the microphone can hold back capture for over a second; speech before
        // the go signal is not in the clip, so show a wait state and record the delay.
        startPressedAt = ProcessInfo.processInfo.systemUptime; startLatencySeconds = nil
        status = UIMessage("status.starting")
        let proceed = {
            self.queue.async {
                do {
                    self.session.beginConfiguration()
                    do {
                        if let old = self.audioInput { self.session.removeInput(old); self.audioInput = nil }
                        if self.activeAudio {
                            guard let mic = Self.preferredMicrophone() else {
                                throw PilotError("error.micMissing")
                            }
                            let input = try AVCaptureDeviceInput(device: mic)
                            guard self.session.canAddInput(input) else {
                                throw PilotError("error.micUnavailable")
                            }
                            self.session.addInput(input); self.audioInput = input
                            let format = mic.activeFormat.formatDescription
                            let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate ?? 0
                            self.audioInfo = ["name": mic.localizedName, "transport": mic.transportType, "sample_rate": rate]
                            DispatchQueue.main.async { self.microphoneName = mic.localizedName }
                        }
                    } catch { self.session.commitConfiguration(); throw error }
                    self.session.commitConfiguration()
                    let url = self.root.appendingPathComponent("clips/draft-\(UUID().uuidString).mov")
                    if let device = self.videoDevice {
                        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                        self.cameraInfo = ["type": device.deviceType.rawValue, "width": size.width, "height": size.height,
                                           "nominal_fps": 1 / device.activeVideoMinFrameDuration.seconds]
                    }
                    self.startDate = Date()
                    try self.journal(url)
                    self.movie.startRecording(to: url, recordingDelegate: self)
                } catch { self.fail(error) }
            }
        }
        if activeAudio {
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                if allowed { proceed() } else { self.fail(UIMessage("error.micPermission")) }
            }
        } else { proceed() }
    }

    func stop() {
        guard recording, !busy else { return }
        busy = true
        if let began = captureStartedAt { captureWallSeconds = ProcessInfo.processInfo.systemUptime - began }
        queue.async { self.movie.stopRecording() }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        startDate = Date()
        captureStartedAt = ProcessInfo.processInfo.systemUptime
        if let pressed = startPressedAt { startLatencySeconds = captureStartedAt! - pressed }
        // The pre-capture journal already exists if a crash interrupts this update.
        try? journal(fileURL)
        DispatchQueue.main.async {
            self.busy = false; self.recording = true
            self.status = UIMessage(self.activeAudio ? "status.recordingAudio" : "status.recordingVideo")
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            self.session.beginConfiguration()
            if let input = self.audioInput { self.session.removeInput(input); self.audioInput = nil }
            self.session.commitConfiguration()
        }
        if let error = error as NSError?, error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
            fail(UIMessage("error.recording", error.localizedDescription, fileURL.lastPathComponent))
            return
        }
        if captureWallSeconds == nil, let began = captureStartedAt {
            captureWallSeconds = ProcessInfo.processInfo.systemUptime - began
        }
        try? journal(fileURL)
        Task {
            do { try await presentReview(fileURL) } catch { fail(error) }
        }
    }

    func discard() {
        guard let draft else { return }
        player?.pause(); player = nil
        do {
            try FileManager.default.removeItem(at: draft)
            try? FileManager.default.removeItem(at: journalURL(for: draft))
            self.draft = nil; verified = false; status = UIMessage("status.discarded")
        } catch { fail(error) }
    }

    func replay() {
        guard !busy, let player else { return }
        player.pause()
        player.defaultRate = 1
        player.seek(to: .zero) { finished in
            if finished { player.playImmediately(atRate: 1) }
        }
    }

    func toggleRecording() {
        guard !busy, draft == nil, take != nil else { return }
        if recording { stop() }
        else if ready { start() }
        else { enableCamera(startAfterEnable: true) }
    }

    func retry() {
        guard !busy, !recording, draft != nil else { return }
        discard()
        guard draft == nil else { return }
        toggleRecording()
    }

    func submit() {
        guard !busy, !recording, draft != nil, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The explicitly labeled submit action is the participant's confirmation.
        verified = true
        save()
    }

    func shortcut(_ keyCode: UInt16) {
        switch keyCode {
        case 49: toggleRecording()
        case 15: retry()
        case 35: replay()
        case 36, 76: submit()
        default: break
        }
    }

    func save() {
        guard verified, let draft, let take = activeTake, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let destination = root.appendingPathComponent("clips/\(take.id).mov")
        let manifest = root.appendingPathComponent("clips/\(take.id).json")
        do {
            var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(take)) as! [String: Any]
            data.merge(["schema_version": 1, "video": "clips/\(take.id).mov", "reference_text": reference,
                        "reference_verified": true, "reference_provenance": "participant_reviewed_prompt_or_correction",
                        "captured_at": ISO8601DateFormatter().string(from: startDate), "duration_seconds": duration,
                        "audio_recorded": activeAudio, "camera": cameraInfo, "consent_scope": "local_research",
                        "recording_context_source": draftContextSource, "audio_device": audioInfo,
                        "capture_wall_seconds": captureWallSeconds as Any? ?? NSNull(),
                        "start_latency_seconds": startLatencySeconds as Any? ?? NSNull()]) { _, new in new }
            let bytes = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            // Refuse to overwrite a previous clip. Drafts remain recoverable on errors.
            guard !FileManager.default.fileExists(atPath: manifest.path) else {
                throw PilotError("error.manifestExists")
            }
            try FileManager.default.moveItem(at: draft, to: destination)
            do { try bytes.write(to: manifest, options: .atomic) }
            catch { try? FileManager.default.moveItem(at: destination, to: draft); throw error }
            try? FileManager.default.removeItem(at: journalURL(for: draft))
            player?.pause(); player = nil; self.draft = nil; verified = false; saved += 1; index += 1
            status = UIMessage("status.saved", takes.count - index)
            if index == takes.count { stopCamera() }
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        fail((error as? PilotError)?.message ?? UIMessage("error.detail", error.localizedDescription))
    }

    private func fail(_ message: UIMessage) {
        DispatchQueue.main.async { self.status = message; self.busy = false; self.recording = false }
    }
}

final class PreviewView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    init(preview: AVCaptureVideoPreviewLayer) {
        self.preview = preview
        super.init(frame: .zero)
        wantsLayer = true; layer = preview; preview.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
}
struct CameraPreview: NSViewRepresentable {
    let preview: AVCaptureVideoPreviewLayer
    func makeNSView(context: Context) -> PreviewView { PreviewView(preview: preview) }
    func updateNSView(_ view: PreviewView, context: Context) {}
}

// Avoid the _AVKit_SwiftUI VideoPlayer overlay: it aborts during generic superclass
// metadata initialization on the user's macOS runtime when the review view appears.
struct RecordedVideoPreview: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none // Explicit controls keep playback at 1× and avoid native key interception.
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

// SwiftUI's scene title can lag behind an in-place language change on macOS.
private final class TitleView: NSView {
    var localizedTitle = "" { didSet { window?.title = localizedTitle } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.title = localizedTitle
    }
}
private struct LocalizedWindowTitle: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.localizedTitle = title }
}

// Local to this window; never intercept typing or IME composition in the reference field.
struct RecorderKeyboardHandler: NSViewRepresentable {
    let action: (UInt16) -> Void
    final class KeyView: NSView {
        var action: ((UInt16) -> Void)?
        var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                    if event.keyCode == 53, !editor.hasMarkedText() { window.makeFirstResponder(nil); return nil }
                    return event
                }
                guard [UInt16(49), 15, 35, 36, 76].contains(event.keyCode) else { return event }
                if !event.isARepeat { self.action?(event.keyCode) }
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> KeyView { let view = KeyView(); view.action = action; return view }
    func updateNSView(_ view: KeyView, context: Context) { view.action = action }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor); view.monitor = nil }
    }
}

struct RecorderView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var strings = Localizer.shared
    @FocusState private var editingReference: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(strings.text("app.title")).font(.title.bold())
                Spacer()
                Text(strings.text("app.badge")).font(.caption).foregroundStyle(.secondary)
            }
            Text(strings.text("app.intro"))
                .foregroundStyle(.secondary)
            HStack {
                Picker(strings.text("language.label"), selection: $strings.selection) {
                    ForEach(InterfaceLanguage.allCases) { language in Text(strings.label(language)).tag(language) }
                }.frame(maxWidth: 350)
                Spacer()
            }
            Picker(strings.text("session.label"), selection: Binding(get: { recorder.sessionID }, set: { recorder.switchSession($0) })) {
                ForEach(Array(Set(recorder.allTakes.map(\.session_id))).sorted(), id: \.self) { Text($0).tag($0) }
            }.disabled(recorder.ready || recorder.busy || recorder.recording || recorder.draft != nil)
            if let take = recorder.take {
                HStack {
                    Text("\(strings.text("split.\(take.split)")) · \(take.session_id) · \(strings.text("lang.\(take.language_profile ?? take.language)")) · \(strings.text("domain.\(take.domain ?? "general")"))")
                    Spacer()
                    Text("\(recorder.index + 1) / \(recorder.takes.count)")
                }.font(.caption.monospaced())
                Text(strings.text("mode.\(take.mode)")).font(.headline)
                Text(take.prompt).font(.title2).textSelection(.enabled).frame(minHeight: 54, alignment: .leading)
                Text(strings.text("instruction.\(take.mode)")).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(strings.text("session.done")).font(.headline)
            }
            ZStack {
                Color.black
                if let player = recorder.player {
                    RecordedVideoPreview(player: player)
                } else if recorder.ready {
                    CameraPreview(preview: recorder.previewLayer)
                } else { Text(strings.text("camera.off")).foregroundStyle(.white) }
            }.frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 10))
            if recorder.draft != nil {
                HStack {
                    Button(strings.text("review.replay") + "  P", action: recorder.replay)
                    Text("1×").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Button(strings.text("review.pause")) { recorder.player?.pause() }
                }
                TextField(strings.text("reference.label"), text: $recorder.reference).textFieldStyle(.roundedBorder)
                    .focused($editingReference)
                    .onChange(of: recorder.reference) { recorder.verified = false }
                    .onSubmit { editingReference = false }
                Text(strings.text("reference.submitConsent")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(strings.text("take.discard") + "  R", action: recorder.retry)
                    if recorder.ready { Button(strings.text("camera.disable"), action: recorder.stopCamera).disabled(recorder.busy) }
                    Spacer()
                    Button(strings.text("take.save") + "  ↵", action: recorder.submit)
                        .disabled(recorder.busy || recorder.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                if !recorder.isSilent {
                    Toggle(strings.text("audio.optional"), isOn: $recorder.includeAudio)
                        .disabled(recorder.recording || recorder.busy)
                    if !recorder.microphoneName.isEmpty {
                        Text(strings.render(UIMessage("audio.source", recorder.microphoneName))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(strings.text(recorder.ready ? "camera.disable" : "camera.enable")) {
                        if recorder.ready { recorder.stopCamera() } else { recorder.enableCamera() }
                    }.disabled(recorder.busy || recorder.recording || recorder.take == nil)
                    Spacer()
                    Button(strings.text(recorder.recording ? "record.stop" : "record.start") + "  ␣", action: recorder.toggleRecording)
                        .disabled(recorder.busy || recorder.take == nil)
                }
            }
            Text(strings.text("shortcuts.hint")).font(.caption).foregroundStyle(.secondary)
            Text(strings.render(recorder.status))
                .font(recorder.recording || recorder.busy ? .title3.bold() : .callout)
                .foregroundStyle(recorder.recording ? .red : .secondary)
            HStack {
                Text(recorder.root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(strings.text("folder.show")) { NSWorkspace.shared.open(recorder.root) }
            }
        }.padding(24).frame(width: 800, height: 750)
            .background(RecorderKeyboardHandler(action: recorder.shortcut).frame(width: 0, height: 0))
            .onChange(of: recorder.draft) {
                editingReference = false
                DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
            .background(LocalizedWindowTitle(title: strings.text("app.title")).frame(width: 0, height: 0))
            .environment(\.locale, strings.locale)
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in strings.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in strings.refresh() }
    }
}

final class PilotDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !PILOT_CHECKS
@main struct PilotApp: App {
    @NSApplicationDelegateAdaptor(PilotDelegate.self) var delegate
    @StateObject private var recorder: Recorder
    @StateObject private var strings = Localizer.shared
    init() {
        let args = CommandLine.arguments
        var dataset = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Blurt VSR Pilot/datasets/speaker-01-tech-zh90-v1").path
        var sessionID: String? = nil
        var recoveryURL: URL? = nil
        if let di = args.firstIndex(of: "--dataset") {
            guard di + 1 < args.count else { fputs("--dataset requires a path\n", stderr); exit(2) }
            dataset = args[di + 1]
        }
        if let si = args.firstIndex(of: "--session") {
            guard si + 1 < args.count else { fputs("--session requires a session ID\n", stderr); exit(2) }
            sessionID = args[si + 1]
        }
        if let ri = args.firstIndex(of: "--recover-draft") {
            guard ri + 1 < args.count else { fputs("--recover-draft requires a path\n", stderr); exit(2) }
            recoveryURL = URL(fileURLWithPath: args[ri + 1])
        }
        do {
            let value = try Recorder(root: URL(fileURLWithPath: dataset), sessionID: sessionID, recoveryURL: recoveryURL)
            _recorder = StateObject(wrappedValue: value)
        }
        catch { fputs("\(error)\n", stderr); exit(1) }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var body: some Scene {
        WindowGroup(strings.text("app.title")) { RecorderView(recorder: recorder) }
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
#endif
