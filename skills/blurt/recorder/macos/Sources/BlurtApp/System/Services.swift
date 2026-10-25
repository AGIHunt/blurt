// Services → "Add to Blurt" (Info.plist NSServices, NSMessage addToBlurt): the selected text or image becomes a note
// in the inbox. Notes of one day go into one session of the current workspace, "<ts>-shots" with meta.json
// {"mode": "shots", "source": "service"} — a processed, not yet reviewed batch, i.e. the inbox. The session's
// items.json is written once, empty (items.py needs it to exist, SKILL §3); every note goes in with `items.py add`
// (C2), images are copied to frames/ and attached with `items.py set-frames`.
import AppKit
import BlurtCore
import UniformTypeIdentifiers

final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()

    @objc func addToBlurt(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let from = NSWorkspace.shared.frontmostApplication?.localizedName
        let note = Note(pboard: pboard, from: from)
        guard !note.isEmpty else {
            error.pointee = Loc.t("capture.service.empty", table: "Capture") as NSString
            return
        }
        Task { @MainActor in
            do {
                let r = try await ServiceProvider.add(note)
                emit(["event": "service_note", "session": r.session.path, "uid": r.uid])
                island.toast(Loc.t("capture.service.added", table: "Capture", note.title), actionTitle: nil, action: nil)
                Spotlight.shared.refreshSoon()
            } catch {
                emit(["event": "service_note", "error": "\(error)"])
                NSLog("blurt services: couldn't add the note: %@", "\(error)")
                island.toast(Loc.t("capture.service.failed", table: "Capture"), actionTitle: nil, action: nil)
            }
        }
    }

    struct Note {
        var text: String = ""
        var images: [Data] = []        // PNG
        var files: [URL] = []          // image files dropped as file URLs
        var from: String?

        init(pboard: NSPasteboard, from: String?) {
            self.from = from
            if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                files = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
                if files.isEmpty, !urls.isEmpty { text = urls.map(\.path).joined(separator: "\n") }
            }
            if text.isEmpty, let s = pboard.string(forType: .string) { text = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if files.isEmpty, let imgs = pboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
                images = imgs.compactMap { img in
                    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
                    return rep.representation(using: .png, properties: [:])
                }
            }
        }
        init(text: String, images: [Data] = [], from: String? = nil) { self.text = text; self.images = images; self.from = from }

        var isEmpty: Bool { text.isEmpty && images.isEmpty && files.isEmpty }
        var title: String {
            let first = text.split(separator: "\n").first.map(String.init) ?? ""
            if !first.isEmpty { return first.count > 60 ? String(first.prefix(59)) + "…" : first }
            return from.map { Loc.t("capture.service.image_from", table: "Capture", $0) } ?? Loc.t("capture.service.image", table: "Capture")
        }
    }

    /// Today's service-notes session in the current workspace (created on first use).
    static func inboxSession() throws -> URL {
        let root = sessionsRoot(for: currentWorkspace())
        let day = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date()) }()
        let fm = FileManager.default
        let existing = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(day) && $0.lastPathComponent.hasSuffix("-shots") }
            .filter { d in
                let m = (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent("meta.json")))) as? [String: Any]
                return m?["source"] as? String == "service"
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if let d = existing.first { return d }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = root.appendingPathComponent(f.string(from: Date()) + "-shots")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = ["mode": "shots", "source": "service", "engine": "services",
                                   "title": Loc.t("capture.service.title", table: "Capture"),
                                   "started_at": ISO8601DateFormatter().string(from: Date()),
                                   "author": recordConfig()["author"] as? String ?? NSFullUserName(),
                                   "workspace": currentWorkspace().path]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("meta.json"))
        // the session header items.py keeps (C1); items.py add fills in the rest
        let head: [String: Any] = ["session": dir.lastPathComponent, "title": Loc.t("capture.service.title", table: "Capture"), "items": []]
        try JSONSerialization.data(withJSONObject: head, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("items.json"))
        return dir
    }

    static func add(_ note: Note) async throws -> (session: URL, uid: String) {
        let dir = try inboxSession()
        var item: [String: Any] = ["kind": "note", "title": note.title]       // state: new (K3's default)
        if !note.text.isEmpty { item["quote"] = note.text }
        item["source"] = ["type": "service"].merging(note.from.map { ["app": $0] } ?? [:]) { a, _ in a }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: item), as: UTF8.self)
        let r = try await SkillCLI.shared.run("items.py", ["add", dir.path, "--json", json], timeout: 60)
        guard r.ok, let o = r.json, let id = o["id"] as? String, let uid = o["uid"] as? String else {
            throw AgentError.script(r.errorText)
        }
        // images → frames/<id>-<n>.png, attached with set-frames
        var frames: [String] = []
        let fdir = dir.appendingPathComponent("frames")
        try? FileManager.default.createDirectory(at: fdir, withIntermediateDirectories: true)
        for (i, d) in note.images.enumerated() {
            let rel = "frames/\(id)-\(i + 1).png"
            try d.write(to: dir.appendingPathComponent(rel))
            frames.append(rel)
        }
        for (i, u) in note.files.enumerated() {
            let rel = "frames/\(id)-\(note.images.count + i + 1).\(u.pathExtension.lowercased())"
            try? FileManager.default.copyItem(at: u, to: dir.appendingPathComponent(rel))
            frames.append(rel)
        }
        if !frames.isEmpty {
            let s = try await SkillCLI.shared.run("items.py", ["set-frames", dir.path, id] + frames, timeout: 60)
            if !s.ok { throw AgentError.script(s.errorText) }
        }
        return (dir, uid)
    }

    func register() {
        NSApp.servicesProvider = self
        NSRegisterServicesProvider(self, "Blurt")     // = Info.plist NSPortName (the executable is "blurt-recorder")
    }
}
