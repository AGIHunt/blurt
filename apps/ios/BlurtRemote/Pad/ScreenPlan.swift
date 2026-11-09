// How much of the screen to ask for. One choice for the user, not a frame rate and a resolution and a bitrate to work out: what they want from it.
// Auto knows what the phone is on. Whatever this says is a ceiling: below it the Mac follows the network by itself, and when the picture stops
// it sharpens what's there, so saving data costs motion before it costs text (RemoteRate, RemoteScreen).
import Foundation
import SwiftUI

enum ScreenQuality: String, CaseIterable, Identifiable {
    case auto, sharp, balanced, saver
    var id: String { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .auto: "Auto"
        case .sharp: "Sharp"
        case .balanced: "Balanced"
        case .saver: "Data Saver"
        }
    }

    /// The most it can cost, worked out from the ceilings below: a still screen costs next to nothing.
    var detail: LocalizedStringKey {
        switch self {
        case .auto: "Sharpest on your own network, lighter on mobile data"
        case .sharp: "At most about 90 MB a minute, 60 frames at home"
        case .balanced: "At most about 30 MB a minute, 30 frames"
        case .saver: "At most about 8 MB a minute, 15 frames"
        }
    }
}

struct ScreenPlan: Equatable {
    var width: Int
    var height: Int
    var bitrate: Int
    var fps: Int

    /// `panel`: the display's top rate. At home the picture comes at up to that (120 on ProMotion): a frame waits half as long for its turn, and
    /// scrolling moves as the phone's own does. The bitrate ceiling stays, so it costs no more data, only motion's share of it.
    init(_ q: ScreenQuality, route: Link.Route, cellular: Bool, lowData: Bool, native: CGSize, panel: Int = 60) {
        let long = Int(max(native.width, native.height)), short = Int(min(native.width, native.height))
        func size(_ w: Int, _ h: Int) -> (Int, Int) { (min(long, w), min(short, h)) }
        var tier = q
        if q == .auto {
            tier = lowData ? .saver : route == .local && !cellular ? .sharp : .balanced
        }
        switch tier {
        case .saver:
            (width, height) = size(1280, 800)
            bitrate = 1_000_000
            fps = 15
        case .sharp where route == .local:
            (width, height) = (long, short)
            bitrate = 12_000_000
            fps = min(120, max(60, panel))
        case .sharp:
            (width, height) = (long, short)
            bitrate = 8_000_000
            fps = 30
        default:
            if q == .auto, cellular {   // data the user pays for, and nobody asked for less: most of the picture for less than half
                (width, height) = size(1440, 900)
                bitrate = 2_000_000
                fps = 24
            } else {
                (width, height) = size(1800, 1100)
                bitrate = 4_000_000
                fps = 30
            }
        }
    }
}

/// What the picture is costing, for Settings. Published on the main thread.
final class ScreenUse: ObservableObject {
    @Published private(set) var total = 0
    @Published private(set) var kbps = 0
    @Published private(set) var fps = 0
    @Published private(set) var running = false

    func add(bytes: Int, seconds: Double, frames: Int) {
        DispatchQueue.main.async {
            self.running = true
            self.total += bytes
            self.kbps = Int(Double(bytes) * 8 / seconds / 1000)
            self.fps = Int((Double(frames) / seconds).rounded())
        }
    }

    func stopped() { DispatchQueue.main.async { self.running = false } }
}
