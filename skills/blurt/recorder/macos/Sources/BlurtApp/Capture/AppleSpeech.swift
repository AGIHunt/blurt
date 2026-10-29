// macOS's own speech recognition (docs/design/first-minute-speech.md): the recogniser dictation, voice notes and
// recordings run on until a local model is on this Mac — nothing to download from Blurt, no uv, no Python.
// SpeechAnalyzer + SpeechTranscriber (macOS 26): measured on 270 kept takes 10.1 % (zh) / 4.0 % (en, LibriSpeech),
// 58 ms from key-up to text, no Speech Recognition permission; the recognition runs in the system's
// localspeechrecognition process (~0.45 GB while in use). DictationTranscriber was worse everywhere (it drops the ends
// of sentences): not used. One locale a recogniser, no language detection — the Chinese one hears the English words
// inside Chinese speech, so `locale` follows the user's first language that it supports.
//
// The model id is "apple-speech" (asr_models.json): `transcribe.py dictation-models` / `models` select it when no local
// model is installed, and the app runs it in-process (Dictation.transcribe, VoiceInput.transcribePiece) rather than
// through the warm Python server. Recordings (`transcribe.py run`) reach it through this executable:
//   blurt-recorder --speech WAV [--locale zh-CN] [--language zh] [--words "a\nb"]
//       → {"ok", "text", "segments": [{"start", "end", "text"}], "locale", "ms"} | {"ok": false, "code", "error"}
//   blurt-recorder --speech-status [--language zh]  → {"ok", "available", "locale", "assets": installed|supported|…}
// The language's files are macOS's (~390 MB a language, in the system's own folder; often already there for macOS
// dictation): `prepare` asks macOS for them once (AssetInventory), in the background.
import AVFAudio
import Foundation
import BlurtCore
#if compiler(>=6.2)
import Speech
#endif

enum AppleSpeech {
    static let modelID = "apple-speech"
    /// SpeechTranscriber's languages (macOS 26.5's supportedLocales), by Blurt's language codes
    static let locales: [String: String] = ["zh": "zh-CN", "zh-hant": "zh-TW", "yue": "yue-CN", "en": "en-US", "ja": "ja-JP",
                                            "ko": "ko-KR", "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "it": "it-IT",
                                            "pt": "pt-BR"]

    /// macOS has the engine (26 or later, and an SDK that knows it)
    static var available: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        #endif
        return false
    }

    /// The locale for `language` ("zh", "en", "auto"…): an explicit one, else the user's languages (asr.languages,
    /// else the system's), the first one SpeechTranscriber speaks; nil when it speaks none of them.
    static func locale(for language: String? = nil) -> String? {
        if let l = language?.lowercased(), l != "auto", !l.isEmpty { return locales[l] ?? locales[String(l.prefix(2))] }
        let configured = Config.shared["asr.languages"] as? [String] ?? []
        let system = Locale.preferredLanguages.map { tag -> String in
            let t = tag.lowercased()
            if t.hasPrefix("zh-hant") || t.hasPrefix("zh-tw") || t.hasPrefix("zh-hk") { return "zh-hant" }
            return String(t.prefix(while: { $0 != "-" && $0 != "_" }))
        }
        for l in (configured.isEmpty ? system : configured) + ["en"] { if let loc = locales[l] { return loc } }
        return nil
    }

    /// Dictation runs on it: `transcribe.py dictation-models` selected it (no local model is installed), or — before
    /// that list can be read (no speech tools yet) — the app put it in (`dictationModels`).
    static var forDictation: Bool { Dictation.shared.speechModels?.selected == modelID }
    /// Voice notes too: dictation falls back to the voice-note model, so dictation on macOS's recogniser means the
    /// voice-note pick is it as well.
    static var forNotes: Bool { forDictation }
    /// Recognition goes to a cloud service (a key the user set, every job on it): the live text while talking comes
    /// from macOS's recogniser instead — free and local — and only the finished pieces are sent (each pass is billed).
    static var cloudSelected: Bool { Dictation.shared.speechModels?.selectedCloud == true }
    static var forLiveText: Bool { forDictation || (cloudSelected && ready()) }

    /// `dictation-models`' answer while the list can't be read and macOS's recogniser is ready: nothing to offer
    /// (no sizes without the list), nothing missing.
    static var dictationModels: [String: Any] {
        ["selected": modelID, "ready": true, "selected_installed": true, "recommended": modelID, "missing": [String](),
         "models": [["id": modelID, "installed": true]]]
    }

    // MARK: the language's files (macOS's)

    enum Assets: String { case unsupported, supported, downloading, installed }

    static func assets(_ locale: String) async -> Assets {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let t = SpeechTranscriber(locale: Locale(identifier: locale), preset: .transcription)
            switch await AssetInventory.status(forModules: [t]) {
            case .installed: return .installed
            case .downloading: return .downloading
            case .supported: return .supported
            default: return .unsupported
            }
        }
        #endif
        return .unsupported
    }

    /// The last answer of `assets` for the current locale (nil: not asked yet), for checks that can't wait.
    private static let lock = NSLock()
    private static var known: [String: Assets] = [:]
    static func knownAssets(_ locale: String) -> Assets? { lock.withLock { known[locale] } }
    private static func remember(_ locale: String, _ a: Assets) { lock.withLock { known[locale] = a } }

    /// Ready to recognise now in this locale: the engine, and the language's files on this Mac.
    static func ready(_ locale: String? = locale()) -> Bool {
        guard available, let l = locale else { return false }
        return knownAssets(l) == .installed
    }

    /// The language's files, made usable by this app: macOS answers "supported" for files already on disk until an
    /// app asks for them (then the install takes ~50 ms); otherwise it is a real download (~390 MB, 25 s here). One
    /// request a locale at a time; later callers wait for the same one.
    private static var installing: [String: Task<Assets, Never>] = [:]
    static func ensure(_ l: String, via: String) async -> Assets {
        let a = await assets(l)
        remember(l, a)
        guard a == .supported || a == .downloading else { return a }
        let task: Task<Assets, Never> = lock.withLock {
            if let t = installing[l] { return t }
            let t = Task.detached(priority: .utility) {
                let t0 = Date()
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    do {
                        let t = SpeechTranscriber(locale: Locale(identifier: l), preset: .transcription)
                        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                            try await req.downloadAndInstall()
                        }
                    } catch {
                        emit(["event": "apple_speech_assets", "locale": l, "result": "failed", "error": "\(error)"])
                    }
                }
                #endif
                let after = await assets(l)
                remember(l, after)
                emit(["event": "apple_speech_assets", "locale": l, "result": after.rawValue, "via": via,
                      "ms": Int(Date().timeIntervalSince(t0) * 1000)])
                lock.withLock { installing[l] = nil }
                return after
            }
            installing[l] = t
            return t
        }
        return await task.value
    }

    /// Asks macOS for the language's files in the background (nothing to fetch when they are here). `done` on the
    /// main thread with what is true afterwards.
    static func prepare(language: String? = nil, via: String, done: ((Assets) -> Void)? = nil) {
        guard available, let l = locale(for: language) else { done?(.unsupported); return }
        Task.detached(priority: .utility) {
            let a = await ensure(l, via: via)
            DispatchQueue.main.async { done?(a) }
        }
    }

    // MARK: recognition

    struct Segment { var start: Double; var end: Double; var text: String }

    enum Failure: Error { case unsupported, assets, failed(String) }

    /// One audio file → its words, in `locale`, biased toward `words` (macOS's contextual strings: they help little,
    /// 5 of 35 terms against 3 without — polish fixes names). Spaces macOS puts around full-width punctuation are taken
    /// out (formatting, not words).
    static func recognize(_ url: URL, locale: String, words: [String] = [], wait: Double = 4) async throws -> [Segment] {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            guard available else { throw Failure.unsupported }
            let t = SpeechTranscriber(locale: Locale(identifier: locale), preset: .transcription)
            if knownAssets(locale) != .installed {
                // files on disk become usable at once; a real download is waited for only up to `wait` seconds (it
                // carries on, and the next take uses it)
                let pending = Task { await ensure(locale, via: "recognize") }
                let got = await withTaskGroup(of: Assets?.self) { g -> Assets? in
                    g.addTask { await pending.value }
                    g.addTask { _ = try? await Task.sleep(for: .seconds(wait)); return nil }   // the time limit: nothing to report
                    let first = await g.next() ?? nil
                    g.cancelAll()
                    return first
                }
                guard got == .installed else { throw Failure.assets }
            }
            let ctx = AnalysisContext()
            let terms = Array(words.filter { !$0.isEmpty }.prefix(100))
            if !terms.isEmpty { ctx.contextualStrings[.general] = terms }
            let file: AVAudioFile
            do { file = try AVAudioFile(forReading: url) } catch { throw Failure.failed("\(error)") }
            let collect = Task { () throws -> [Segment] in
                var out: [Segment] = []
                for try await r in t.results {
                    let text = tidy(String(r.text.characters))
                    if text.isEmpty { continue }
                    out.append(Segment(start: r.range.start.seconds, end: r.range.end.seconds, text: text))
                }
                return out
            }
            do {
                _ = try await SpeechAnalyzer(inputAudioFile: file, modules: [t], analysisContext: ctx, finishAfterFile: true)
                return try await collect.value
            } catch {
                collect.cancel()
                throw Failure.failed("\(error)")
            }
        }
        #endif
        throw Failure.unsupported
    }

    /// Full-width punctuation takes no space on either side ("在转 ，看看" → "在转，看看").
    static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"\s+([，。？！：；、）」』”])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([，。？！：；、（「『“])\s+"#, with: "$1", options: .regularExpression)
        return t
    }

    /// Joins segments as one text: Chinese and Japanese without a space, other languages with one.
    static func join(_ segs: [Segment], locale: String) -> String {
        let cjk = locale.hasPrefix("zh") || locale.hasPrefix("yue") || locale.hasPrefix("ja")
        return segs.map(\.text).joined(separator: cjk ? "" : " ")
    }

    /// The warm server's answer shape (`transcribe.py serve`'s `note`), for the callers that went there: blocking, off
    /// the main thread. `language` "auto" or a code; `vocab` the dictation's word list (term dicts).
    static func transcribe(_ wav: URL, language: String, vocab: [[String: Any]] = [], purpose: String) -> [String: Any] {
        guard let loc = locale(for: language) else { return ["ok": false, "code": "unsupported_language", "model": modelID] }
        let words = vocab.compactMap { $0["term"] as? String }
        let t0 = Date()
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = ["ok": false, "code": "error", "model": modelID]
        Task.detached(priority: .userInitiated) {
            do {
                let segs = try await recognize(wav, locale: loc, words: words)
                let text = join(segs, locale: loc)
                let secs = (try? AVAudioFile(forReading: wav)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
                out = ["ok": true, "text": text, "asr_text": text, "language": String(loc.prefix(while: { $0 != "-" })),
                       "ms": Int(Date().timeIntervalSince(t0) * 1000), "model": modelID, "load_ms": 0,
                       "audio_seconds": (secs * 100).rounded() / 100, "biased": !words.isEmpty]
                remember(loc, .installed)
            } catch Failure.assets {
                out = ["ok": false, "code": "model_missing", "error": "macOS's speech files for \(loc) aren't here yet", "model": modelID]
                remember(loc, .supported)
            } catch Failure.unsupported {
                out = ["ok": false, "code": "unsupported", "model": modelID]
            } catch {
                out = ["ok": false, "code": "error", "error": "\(error)", "model": modelID]
            }
            sem.signal()
        }
        sem.wait()
        emit(["event": "apple_speech", "purpose": purpose, "locale": loc, "ok": out["ok"] ?? false,
              "code": out["code"] ?? NSNull(), "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        return out
    }

    // MARK: the command line (transcribe.py's `apple` backend)

    static func runCLI(_ args: [String]) -> Never {
        func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        func out(_ o: [String: Any]) -> Never {
            let d = (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
            FileHandle.standardOutput.write(d + Data("\n".utf8))
            exit(o["ok"] as? Bool == false ? 1 : 0)
        }
        let status = args.first == "--status"
        let loc = arg("--locale") ?? locale(for: arg("--language"))
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task.detached {
            if status {
                let a = loc != nil && available ? await assets(loc!) : .unsupported
                result = ["ok": true, "available": available, "locale": loc ?? NSNull(), "assets": a.rawValue]
            } else if let path = args.first, let loc {
                let t0 = Date()
                do {
                    let segs = try await recognize(URL(fileURLWithPath: path), locale: loc,
                                                   words: (arg("--words") ?? "").components(separatedBy: "\n"), wait: 600)
                    result = ["ok": true, "text": join(segs, locale: loc), "locale": loc,
                              "ms": Int(Date().timeIntervalSince(t0) * 1000),
                              "segments": segs.map { ["start": ($0.start * 100).rounded() / 100,
                                                      "end": ($0.end * 100).rounded() / 100, "text": $0.text] }]
                } catch Failure.assets {
                    result = ["ok": false, "code": "model_missing", "error": "macOS's speech files for \(loc) aren't here yet"]
                } catch Failure.unsupported {
                    result = ["ok": false, "code": "unsupported", "error": "macOS speech recognition needs macOS 26"]
                } catch {
                    result = ["ok": false, "code": "error", "error": "\(error)"]
                }
            } else {
                result = ["ok": false, "code": loc == nil ? "unsupported_language" : "usage",
                          "error": loc == nil ? "no supported language" : "usage: --speech WAV [--locale L] [--words W]"]
            }
            sem.signal()
        }
        sem.wait()
        out(result)
    }
}
