// The warm model servers (transcribe.py / polish.py serve) hand their memory back when macOS runs short. They hold
// 1–4 GB each between takes so the next dictation starts at once; on a Mac that is already compressing and swapping
// that warmth costs more than it saves (a 24 GB Mac with 17 GB of swap stuttered everywhere, the notch included). On a
// warning or critical pressure event each idle server is asked to "exit" — ending the process is what returns MLX's
// memory — and the next key-down starts it again. A take in progress keeps its servers; the check runs again on the
// next event.
import BlurtCore
import Foundation

final class MemoryPressure {
    static let shared = MemoryPressure()
    private var source: DispatchSourceMemoryPressure?
    static let servers = ["polish-serve", "asr-serve"]
    private let lock = NSLock()
    private var last: Date?

    /// macOS said memory was short in the last 10 minutes: no warming ahead of need (the launch prewarm skips).
    var recent: Bool { lock.lock(); defer { lock.unlock() }; return last.map { Date().timeIntervalSince($0) < 600 } ?? false }

    func start() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        s.setEventHandler { [weak self, weak s] in
            guard let ev = s?.data else { return }
            self?.lock.lock(); self?.last = Date(); self?.lock.unlock()
            self?.relieve(critical: ev.contains(.critical))
        }
        s.resume()
        source = s
    }

    /// Ends the servers no take is using. Returns their names.
    @discardableResult
    func relieve(critical: Bool) -> [String] {
        let busy = VoiceInput.onMain { VoiceInput.shared.active || Dictation.shared.busy } || VoiceInput.notesWaiting > 0
        guard !busy else {
            emit(["event": "memory_pressure", "level": critical ? "critical" : "warning", "ended": [], "kept": "take"])
            return []
        }
        let ended = Self.servers.filter { WarmServer.running($0) && WarmServer.call($0, ["cmd": "exit"], timeout: 2) != nil }
        emit(["event": "memory_pressure", "level": critical ? "critical" : "warning", "ended": ended])
        return ended
    }
}
