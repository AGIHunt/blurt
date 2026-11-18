import AVFoundation
import AppKit
import SwiftUI

// One long take: camera and microphone run from the first Space to Esc. Space only writes a time mark,
// so a sentence costs its own length and nothing else. Marks are appended as they happen; rapid_cut.py
// cuts the take afterwards. Everything stays on this Mac.

struct Line: Codable { let id: String; let text: String; let app: String? }

enum Mode: String, CaseIterable, Identifiable {
    case pairs = "先出声，再不出声", silent = "只不出声", voiced = "只出声", free = "随便说"
    var id: String { rawValue }
}

@MainActor final class Rapid: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let root: URL, dry: Bool
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) let movie = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "rapid.capture")
    @Published var lines: [Line] = []
    @Published var index = 0
    @Published var mode = Mode.pairs
    @Published var voicedStep = true
    @Published var recording = false
    @Published var ready = false
    @Published var starting = false
    @Published var message = "空格开始"
    @Published var clips = 0
    @Published var seconds = 0.0
    private var folder: URL?, marks: FileHandle?, t0 = 0.0, segmentStart = 0.0, history: [(Int, Bool, Bool)] = []
    private var timer: Timer?
    private let script: URL?
    @Published var topic = 0
    private let topics = ["今天手上在忙什么，卡在哪", "最近用过最顺手的一个工具，好在哪", "最近踩的一个坑，后来怎么解决的", "给同事解释一下你现在做的项目",
                          "说说下周打算做什么", "最近看到的一条 AI 新闻，你怎么看", "怎么给新人讲清楚一个技术概念", "一个产品哪里做得不好，你会怎么改",
                          "最近一次开会讨论了什么", "写一条消息，安排一件事", "说说今天吃了什么，好不好吃", "最近去过的地方，推荐给朋友",
                          "最近在看的书、剧或者视频", "家里最近的事", "如果有一周假期想怎么过", "说一件最近让你开心的事", "说一件最近让你烦的事", "你怎么安排一天的工作"]

    init(root: URL, dry: Bool, script: URL?) {
        self.root = root; self.dry = dry; self.script = script; super.init()
        if script != nil { mode = .silent }
        lines = (try? JSONDecoder().decode([Line].self, from: Data(contentsOf: script ?? root.appendingPathComponent("script.json")))) ?? []
        index = (try? Int(String(contentsOf: progressURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))) ?? 0
        if lines.isEmpty { message = "找不到 script.json，先运行 rapid_script.py" }
    }
    private var progressURL: URL { script.map { $0.appendingPathExtension("progress") } ?? root.appendingPathComponent("progress.txt") }
    var current: String { mode == .free ? topics[topic % topics.count] : index < lines.count ? lines[index].text : "稿子读完了" }
    var hint: String {
        if !recording { return mode == .free ? "空格 开始，话题只是提示，想说别的就说别的" : "空格 开始　先对准脸，光线要亮" }
        if mode == .free { return "一直说，句子之间停一下　空格 换话题　Esc 结束" }
        return speakAloud ? "空格 下一段　⌫ 这段重来　Esc 结束" : "嘴唇分开，下巴放下，放慢一点　空格 下一段　⌫ 重来　Esc 结束"
    }
    var upcoming: String { mode != .free && index+1 < lines.count ? lines[index+1].text : "" }
    var speakAloud: Bool { switch mode { case .pairs: return voicedStep; case .silent: return false; default: return true } }

    func enable() {
        if dry { ready = true; return }
        AVCaptureDevice.requestAccess(for: .video) { video in
            AVCaptureDevice.requestAccess(for: .audio) { audio in
                guard video, audio else { Task { @MainActor in self.message = "需要摄像头和麦克风权限" }; return }
                self.queue.async {
                    self.session.beginConfiguration()
                    if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) ?? AVCaptureDevice.default(for: .video),
                       let vi = try? AVCaptureDeviceInput(device: cam), self.session.canAddInput(vi) { self.session.addInput(vi) }
                    let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
                    if let mic = mics.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn }) ?? AVCaptureDevice.default(for: .audio),
                       let ai = try? AVCaptureDeviceInput(device: mic), self.session.canAddInput(ai) { self.session.addInput(ai) }
                    if self.session.canAddOutput(self.movie) { self.session.addOutput(self.movie) }
                    if self.session.canSetSessionPreset(.hd1920x1080) { self.session.sessionPreset = .hd1920x1080 }
                    self.movie.maxRecordedDuration = .invalid
                    self.session.commitConfiguration()
                    self.session.startRunning()
                    Task { @MainActor in self.ready = true }
                }
            }
        }
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func begin() {
        guard ready, !recording, !starting else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = root.appendingPathComponent("sessions/\(stamp)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("marks.jsonl").path, contents: nil)
        marks = try? FileHandle(forWritingTo: dir.appendingPathComponent("marks.jsonl"))
        folder = dir; starting = true; message = "启动中，等绿色提示"
        if dry { didStart(); return }
        let url = dir.appendingPathComponent("take.mov")
        queue.async { self.movie.startRecording(to: url, recordingDelegate: self) }
    }

    private func didStart() {
        t0 = now(); segmentStart = 0; starting = false; recording = true; voicedStep = true; message = "开始"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in self.seconds = self.now()-self.t0 } }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Task { @MainActor in self.didStart() }
    }
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let text = error.map { "已保存（\($0.localizedDescription)）" } ?? "已保存，可以继续下一段"
        Task { @MainActor in self.message = text }
    }

    private func write(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row) else { return }
        marks?.write(data); marks?.write(Data("\n".utf8))
    }

    func advance() {
        guard recording else { begin(); return }
        if mode == .free { topic += 1; return }  // The whole take is one recording; free_label.py finds the sentences.
        guard index < lines.count else { finish(); return }
        let t = now()-t0, wrote = t-segmentStart > 0.6
        if wrote {
            write(["kind": "segment", "start": segmentStart, "end": t, "line": lines[index].id,
                   "text": lines[index].text, "spoken": speakAloud, "mode": speakAloud ? "voiced" : "silent"])
            clips += 1
        }
        history.append((index, voicedStep, wrote))
        segmentStart = t
        if mode == .pairs && voicedStep { voicedStep = false }
        else { voicedStep = true; index += 1; try? String(index).write(to: progressURL, atomically: true, encoding: .utf8) }
    }

    // Wrong take: void the last segment and say it again.
    func undo() {
        guard recording, let last = history.popLast() else { return }
        if last.2 { write(["kind": "void_last", "at": now()-t0]); clips = max(0, clips-1) }
        index = last.0; voicedStep = last.1; segmentStart = now()-t0
        try? String(index).write(to: progressURL, atomically: true, encoding: .utf8)
        message = "上一段作废，重来"
    }

    func finish() {
        guard recording else { return }
        recording = false; timer?.invalidate(); try? marks?.close(); marks = nil; message = "正在保存"
        if dry { message = "已保存" } else { queue.async { self.movie.stopRecording() } }
    }
}

struct Preview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        let l = AVCaptureVideoPreviewLayer(session: session); l.videoGravity = .resizeAspectFill
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]; v.layer = l
        return v
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct Content: View {
    @ObservedObject var r: Rapid
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Picker("", selection: $r.mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().disabled(r.recording).frame(maxWidth: 420)
                Spacer()
                Text(r.mode == .free ? "\(Int(r.seconds)/60):\(String(format: "%02d", Int(r.seconds)%60))" : "\(r.clips) 段 · \(Int(r.seconds)/60):\(String(format: "%02d", Int(r.seconds)%60)) · 第 \(min(r.index+1, r.lines.count))/\(r.lines.count) 句")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            Text(r.recording ? (r.speakAloud ? "出声说" : "不出声") : r.message)
                .font(.title2.bold()).padding(.horizontal, 16).padding(.vertical, 6)
                .background(r.recording ? (r.speakAloud ? Color.green : Color.orange).opacity(0.25) : Color.gray.opacity(0.15), in: Capsule())
            Text(r.current).font(.system(size: 40, weight: .semibold)).multilineTextAlignment(.center).lineLimit(4).minimumScaleFactor(0.5)
            Text(r.upcoming).font(.title3).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            HStack(alignment: .bottom) {
                Text(r.hint).foregroundStyle(.secondary)
                Spacer()
                if !r.dry { Preview(session: r.session).frame(width: 240, height: 135).clipShape(RoundedRectangle(cornerRadius: 8)) }
            }
        }.padding(24).frame(minWidth: 860, minHeight: 560).onAppear { r.enable() }
    }
}

@main struct RapidApp: App {
    @StateObject private var r: Rapid
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    init() {
        let args = CommandLine.arguments
        let root = args.drop(while: { $0 != "--root" }).dropFirst().first.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Blurt VSR Pilot/rapid")
        let script = args.drop(while: { $0 != "--script" }).dropFirst().first.map { URL(fileURLWithPath: $0) }
        let model = Rapid(root: root, dry: args.contains("--dry"), script: script)
        _r = StateObject(wrappedValue: model)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.isARepeat { return nil }
            switch e.keyCode {
            case 49: Task { @MainActor in model.advance() }; return nil
            case 51, 123: Task { @MainActor in model.undo() }; return nil
            case 53: Task { @MainActor in model.finish() }; return nil
            default: return e
            }
        }
    }
    var body: some Scene { WindowGroup("连续录制") { Content(r: r) } }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
