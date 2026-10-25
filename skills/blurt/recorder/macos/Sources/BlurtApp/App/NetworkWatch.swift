// The Mac coming back online (NWPathMonitor): what waited for the network carries on by itself — a model download a
// launch kept for it (ModelDownloads.backOnline), the setup assistant's speech setup that couldn't download its tools
// (OnboardingModel.backOnline), and the speech models' list dictation couldn't read (Dictation's "isn't set up yet").
// Only on the change from offline to online (BlurtCore NetworkRetry), so a failure that isn't the network's never
// loops. Started at launch; it costs nothing while nothing changes.
import AppKit
import BlurtCore
import Network

final class NetworkWatch {
    static let shared = NetworkWatch()
    private var monitor: NWPathMonitor?
    private var retry = NetworkRetry()
    /// Called on the main thread each time the Mac comes back online.
    private var handlers: [() -> Void] = []

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

    private func changed(online: Bool) {
        guard retry.update(online: online) else { return }
        emit(["event": "network_online"])
        handlers.forEach { $0() }
    }

    /// Tests (`network online`): as if the Mac just came back online.
    func testBackOnline() {
        emit(["event": "network_online", "test": true])
        handlers.forEach { $0() }
    }
}
