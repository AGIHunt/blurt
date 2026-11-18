// This Mac's displays, for the phone (docs/design/remote.md §Several displays). CoreGraphics' own coordinates are already the
// arrangement's: points, top-left origin at the main display, y down. Ids are CGDirectDisplayIDs, stable while a display stays connected.
// Names come from NSScreen, which belongs to the main thread: they're kept here, refreshed there, so the remote's queues never wait on it.
import AppKit
import BlurtRemoteKit

enum RemoteDisplayList {
    private static let lock = NSLock()
    private static var names: [CGDirectDisplayID: String] = [:]
    private static var watchers: [() -> Void] = []
    private static var registered = false
    private static var pending: DispatchWorkItem?

    static func ids() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        // a display that mirrors another isn't a place of its own
        return ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    static func all() -> [RemoteDisplay] {
        lock.lock()
        let n = names
        lock.unlock()
        let main = CGMainDisplayID()
        return ids().map { id in
            let b = CGDisplayBounds(id)
            return RemoteDisplay(id: String(id), name: n[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"),
                                 x: b.minX, y: b.minY, width: b.width, height: b.height, main: id == main)
        }
    }

    /// The display a point of the desktop is on, or the nearest one.
    static func at(_ p: CGPoint) -> CGDirectDisplayID? {
        let list = ids()
        if let d = list.first(where: { CGDisplayBounds($0).contains(p) }) { return d }
        return list.min { dist(p, CGDisplayBounds($0)) < dist(p, CGDisplayBounds($1)) }
    }

    private static func dist(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    static func id(_ s: String?) -> CGDirectDisplayID? {
        guard let s, let n = UInt32(s), ids().contains(n) else { return nil }
        return n
    }

    static func name(_ id: CGDirectDisplayID) -> String { all().first { $0.id == String(id) }?.name ?? "" }

    /// Pixels per point: what the stream can ask of it at most.
    static func scale(_ id: CGDirectDisplayID) -> CGFloat {
        guard let m = CGDisplayCopyDisplayMode(id), m.width > 0 else { return 2 }
        return CGFloat(m.pixelWidth) / CGFloat(m.width)
    }

    /// On the main thread.
    private static func readNames() {
        var n: [CGDirectDisplayID: String] = [:]
        for s in NSScreen.screens {
            guard let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            n[id] = s.localizedName
        }
        lock.lock()
        names = n
        lock.unlock()
    }

    /// `changed` runs (on the main thread) once a burst of reconfiguration is over: plugged in, unplugged, rearranged, another resolution.
    static func watch(_ changed: @escaping () -> Void) {
        let start = {
            readNames()
            watchers.append(changed)
            guard !registered else { return }
            registered = true
            CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
                guard !flags.contains(.beginConfigurationFlag) else { return }
                DispatchQueue.main.async { RemoteDisplayList.reconfigured() }
            }, nil)
        }
        if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
    }

    private static func reconfigured() {
        pending?.cancel()
        // one change comes as several callbacks, one per display, and NSScreen catches up a moment later
        let w = DispatchWorkItem {
            readNames()
            watchers.forEach { $0() }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
}
