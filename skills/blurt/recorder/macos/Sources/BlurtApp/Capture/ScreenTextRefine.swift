// The optional second pass of Copy Text from Screen (ScreenTextCopy.swift; docs/design/screen-text.md §Second pass):
// the same picture read again by a model, merged into the draft by scripts/screen_text.py (the draft keeps its lines
// and layout; the model's characters fix what Vision misread inside a line — l / I / /, 0 / @, a missing →).
// ScreenTextCopy decides where the merge goes (the clipboard, still holding the draft; or the field it types into).
//
// record.screen_text.refine = off (unset) | local | cloud — Settings → Copy Text from Screen:
//   local   PaddleOCR-VL 1.6 (720 MB, through the one download manager), kept warm by `screen_text.py serve` (~1.1 GB
//           while warm, ended after 10 idle minutes and with Blurt, like the speech and polish servers); ~0.2 s a
//           capture on an M5 Max. Offered from 16 GB; an 8 GB Mac gets the choice with its cost said.
//   cloud   the provider and key the user set up for cloud polish (DictationCloud: DeepSeek, or any OpenAI- or
//           Anthropic-compatible API with images): `screen_text.py read --stdin`, the key on stdin, never in a file,
//           an argument or the environment. 1–6 s; ≈ ¥0.001 a capture. Nothing to download.
// A capture over 4 MP or 3000 characters (a whole screen) keeps the draft: seconds, not a moment.
import AppKit
import BlurtCore

final class ScreenTextRefine {
    static let shared = ScreenTextRefine()
    static let server = "screen-text-serve"
    static let modelID = "paddleocr-vl-1.6"
    static let modelSizeMB = 720.0

    enum Mode: String, CaseIterable { case off, local, cloud }

    static var mode: Mode {
        let o = recordConfig()["screen_text"] as? [String: Any] ?? [:]
        return Mode(rawValue: o["refine"] as? String ?? "off") ?? .off
    }

    static func setMode(_ m: Mode) {
        var o = recordConfig()["screen_text"] as? [String: Any] ?? [:]
        o["refine"] = m == .off ? nil : m.rawValue
        setRecordConfig("screen_text", o.isEmpty ? nil : o)
        if m == .local, installed == true { shared.warm() }
        if m != .local, WarmServer.running(server) { DispatchQueue.global(qos: .utility).async { _ = WarmServer.call(server, ["cmd": "exit"], timeout: 2) } }
    }

    /// Whether the local model is on disk (nil: not asked yet — `screen_text.py models`, once, then after a download).
    static var installed: Bool?
    static func refreshInstalled(_ done: (() -> Void)? = nil) {
        Task {
            let r = try? await ScriptRunner.shared.json("screen_text.py", ["models"], timeout: 60)
            await MainActor.run {
                installed = r?["installed"] as? Bool ?? false
                done?()
            }
        }
    }

    /// The cloud model's settings with the key, when the user set a provider up with a key (cloud polish itself may be
    /// off: this is its own choice); nil otherwise.
    static var cloudPayload: [String: Any]? {
        let s = DictationCloud.setup
        guard !s.effectiveModel.isEmpty, let key = DictationCloud.Key.read(s.provider), !key.isEmpty else { return nil }
        return DictationCloud.payload(s, key: key)
    }

    /// The local model's server, started ahead (Settings turned it on, or the first capture): the next capture finds it warm.
    func warm() {
        guard !WarmServer.running(Self.server) else { return }
        _ = WarmSpawn.start("screen_text.py", ["serve", "--preload"], server: Self.server)
    }

    /// The second pass can answer within a moment: this Mac's model, installed, its server up (what the copy waits
    /// for before typing into a field; the cloud and a cold model are never waited for).
    static var quick: Bool { mode == .local && installed == true && WarmServer.running(server) }

    /// The second reading of `image` merged into `draft` → `done` (main queue) with screen_text.py's answer
    /// ({"ok", "text", "changed", "ms", …}), or nil: off, skipped (too big, no model, no key) or failed. Every outcome
    /// is one `screen_text_refine` event.
    func read(image: CGImage, draft: String, done: @escaping ([String: Any]?) -> Void) {
        let mode = Self.mode
        guard mode != .off else { return done(nil) }
        func skip(_ why: String) { emit(["event": "screen_text_refine", "mode": mode.rawValue, "skipped": why]); done(nil) }
        guard image.width * image.height <= 4_000_000, draft.count <= 3000 else { return skip("large") }
        let cloud = mode == .cloud ? Self.cloudPayload : nil
        if mode == .cloud, cloud == nil { return skip("no_key") }
        if mode == .local {
            // the model not on disk (yet): no server that could only fail — the draft stays (Settings says Download)
            guard Self.installed == true else { return skip("no_model") }
            warm()
        }
        // the picture goes to the script as a file in Blurt's own tmp (owner-only), removed as soon as it was read
        let dir = BlurtPaths.home.appendingPathComponent("tmp/screen-text", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent(UUID().uuidString + ".png")
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: file, options: .atomic)) != nil else { return done(nil) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let t0 = CACurrentMediaTime()
        DispatchQueue.global(qos: .userInitiated).async {
            var r: [String: Any]?
            if let cloud = cloud {
                let body = try? JSONSerialization.data(withJSONObject: ["draft": draft, "cloud": cloud])
                let sem = DispatchSemaphore(value: 0)
                Task {
                    r = try? await ScriptRunner.shared.json("screen_text.py", ["read", "--image", file.path, "--stdin"], stdin: body, timeout: 30)
                    sem.signal()
                }
                sem.wait()
            } else {
                // a server still starting (its first use loads the model, ~2 s): wait for it, never for long
                let until = Date().addingTimeInterval(25)
                while !WarmServer.running(Self.server) && Date() < until { usleep(100_000) }
                r = WarmServer.call(Self.server, ["cmd": "read", "image": file.path, "draft": draft], timeout: 20)
            }
            try? FileManager.default.removeItem(at: file)
            let ms = Int((CACurrentMediaTime() - t0) * 1000)
            DispatchQueue.main.async {
                var ev: [String: Any] = ["event": "screen_text_refine", "mode": mode.rawValue, "ms": ms, "ok": r?["ok"] as? Bool ?? false,
                                         "model_ms": r?["ms"] ?? NSNull(), "load_ms": r?["load_ms"] ?? NSNull(), "changed": r?["changed"] ?? 0]
                if let c = r?["code"] { ev["code"] = c }
                emit(ev)
                done(r?["ok"] as? Bool == true ? r : nil)
            }
        }
    }
}
