// The Mac coming back online (NWPathMonitor): what waited for the network carries on by itself — a model download a
// launch kept for it (ModelDownloads.backOnline), the setup assistant's speech setup that couldn't download its tools
// (OnboardingModel.backOnline), and the speech models' list dictation couldn't read (Dictation's "isn't set up yet").
// Only on the change from offline to online (BlurtCore NetworkRetry), so a failure that isn't the network's never
// loops. `online` is the last state macOS reported (nil until its first answer): what a failure is put down to — the
// network only when the Mac really is offline (ModelDownloadQueue.waitsForNetwork, SpeechSetup.Cause). Started at
// launch; it costs nothing while nothing changes. Tests: `network [online|offline|real]`, BLURT_TEST_NETWORK=offline.
import AppKit
import BlurtCore
import Network

final class NetworkWatch {
    static let shared = NetworkWatch()
    private var monitor: NWPathMonitor?
    private var retry = NetworkRetry()
    /// Called on the main thread each time the Mac comes back online.
    private var handlers: [() -> Void] = []
    /// The Mac's network as macOS last reported it (nil: no answer yet); a test may stand in for it.
    private(set) var online: Bool?
    /// tests: `network offline` / BLURT_TEST_NETWORK=offline at launch (test builds only)
    private var testOnline: Bool? = {
        let env = ProcessInfo.processInfo.environment
        guard env["BLURT_TEST_COMMANDS"] == "1", let v = env["BLURT_TEST_NETWORK"] else { return nil }
        return v != "offline"
    }()
    var isOnline: Bool? { testOnline ?? online }

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.changed(online: path.status == .satisfied) }
        }
        m.start(queue: DispatchQueue(label: "blurt.network"))
        monitor = m
    }

    func onBackOnline(_ f: @escaping () -> Void) { handlers.append(f) }

    private func changed(online now: Bool) {
        online = now
        guard retry.update(online: now) else { return }
        emit(["event": "network_online"])
        handlers.forEach { $0() }
    }

    /// Tests: `network` / `network online` — as if the Mac just came back online (it then reads online); `network
    /// offline` — it reads offline until the next; `network real` — what macOS says again.
    func testCommand(_ arg: String) {
        switch arg {
        case "offline": testOnline = false
        case "real": testOnline = nil
        default:
            testOnline = true
            emit(["event": "network_online", "test": true])
            handlers.forEach { $0() }
        }
        emit(["event": "network_state", "online": isOnline ?? NSNull(), "test": testOnline != nil])
    }
}
