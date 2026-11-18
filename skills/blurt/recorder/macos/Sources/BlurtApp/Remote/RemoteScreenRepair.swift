// The host's half of repairing the picture (docs/design/remote-realtime.md), on RemoteScreen's queue. What the phone offered in its request
// and this Mac can do is used, and named in screenView:
//
//  • nack: the last second of pieces is kept; the phone names what's missing and it goes again at once. Within a budget: pieces lost by
//    the hundred mean a network that can't carry them, and the rate comes down instead.
//  • ltr: VideoToolbox marks frames it may later refer back to (kVTCompressionPropertyKey_EnableLTR, HEVC and H.264, low-latency mode
//    included); the phone acknowledges them, and a frame lost for good is answered with a refresh from an acknowledged one
//    (kVTEncodeFrameOptionKey_ForceLTRRefresh): 5–10 KB where a keyframe was 50–100 KB or more, and no round trip of waiting first.
//  • fec: a parity piece per group, only when a round trip is long enough that asking costs more than the parity (away from home).
import BlurtCore
import BlurtRemoteKit
import CoreMedia
import Foundation
import QuartzCore
import VideoToolbox

final class ScreenRepair {
    private(set) var features: Set<String> = []
    var nack: Bool { features.contains(RemoteVideoFeature.nack) }
    var ltr: Bool { features.contains(RemoteVideoFeature.ltr) }
    var fec: Bool { features.contains(RemoteVideoFeature.fec) }

    private var history = RemoteVideoHistory()
    /// frames VideoToolbox may refer back to once the phone has them, and their tokens
    private var tokens: [UInt32: Int] = [:]
    /// acknowledged since the last frame: the encoder hears with the next one
    private var acked: [Int] = []
    private var refreshWanted = false
    /// pieces per parity piece; 0: none
    private(set) var group = 0
    /// over the last few seconds: pieces sent and asked for again
    private var window: [(sent: Int, asked: Int)] = []
    private var sentNow = 0, askedNow = 0
    private var budget = (at: 0.0, bytes: 0)

    // for the log, since the last stats line
    var resent = 0, refreshes = 0, parity = 0, lostAsked = 0, ignored = 0

    /// A new stream: what the phone offered, of what this host does.
    func negotiate(_ offered: [String]?) {
        features = Set(offered ?? []).intersection([RemoteVideoFeature.nack, RemoteVideoFeature.ltr, RemoteVideoFeature.fec])
        if ProcessInfo.processInfo.environment["BLURT_SCREEN_REPAIR"] == "0" { features = [] }      // for measuring before / after
        history.clear()
        tokens = [:]
        acked = []
        refreshWanted = false
        group = 0
        window = []
    }

    /// A new encoder: references from the last one mean nothing to it.
    func configure(_ s: VTCompressionSession) {
        tokens = [:]
        acked = []
        refreshWanted = false
        // a keyframe every 600 frames was a safety net for a phone that can only start over: every 10–12 s of scrolling, 100–170 KB at once,
        // and the frames around it starved to pay for it. A phone that repairs has no use for it
        if nack || ltr { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 0 as CFNumber) }
        guard ltr else { return }
        let st = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue)
        if st != noErr {
            features.remove(RemoteVideoFeature.ltr)
            emit(["event": "remote_screen_repair", "ltr": "unsupported", "status": Int(st)])
        }
    }

    /// What goes with the next frame: a keyframe, a refresh, references the phone has acknowledged. `refresh`: this frame answers a loss.
    func options(key: Bool) -> (props: CFDictionary?, refresh: Bool) {
        var p: [CFString: Any] = [:]
        if key { p[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        var refresh = false
        if ltr {
            if !acked.isEmpty {
                p[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acked
                acked = []
            }
            if refreshWanted, !key {
                p[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true
                refresh = true
            }
            refreshWanted = false
        }
        return (p.isEmpty ? nil : p as CFDictionary, refresh)
    }

    /// The encoder's mark on a frame it may refer back to.
    static func token(_ b: CMSampleBuffer) -> Int? {
        (CMSampleBufferGetSampleAttachmentsArray(b, createIfNecessary: false) as? [[CFString: Any]])?.first?[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? Int
    }

    /// A frame went out: kept for sending again, its token remembered. Parity pieces for it, if they're worth it now.
    func sent(_ frame: UInt32, token: Int?, pieces: [RemoteVideoPacket], encoded: [Data], datagrams: Bool, now: Double) -> [RemoteVideoPacket] {
        if let token, ltr {
            tokens[frame] = token
            if tokens.count > 600, let old = tokens.keys.min() { tokens[old] = nil }
        }
        guard datagrams else { return [] }
        sentNow += pieces.count
        if nack { history.add(frame, encoded, now: now) }
        guard fec, group > 0 else { return [] }
        let p = RemoteVideoFEC.parity(for: pieces, group: group)
        parity += p.count
        return p
    }

    enum Answer { case resend([Data]), refresh, keyframe }

    /// What the phone said. Pieces to send again, or a frame to make now.
    func feedback(_ d: Data, rate: Int, now: Double) -> Answer? {
        guard let f = RemoteVideoFeedback(d) else { return nil }
        switch f {
        case let .nack(missing):
            guard nack else { return nil }
            var out: [Data] = []
            for m in missing {
                askedNow += max(1, m.pieces.count)
                out += history.pieces(m.frame, m.pieces)
            }
            // a second's budget: half the picture's rate again, at least 300 KB. Past it the network is the trouble, not chance
            if now - budget.at > 1 { budget = (now, 0) }
            let n = out.reduce(0) { $0 + $1.count }
            guard budget.bytes + n <= max(300_000, rate / 8 / 2) else { ignored += out.count; return nil }
            budget.bytes += n
            resent += out.count
            return out.isEmpty ? nil : .resend(out)
        case let .ack(newest, earlier):
            guard ltr else { return nil }
            var ids = [newest]
            for i in 0..<32 where earlier & (1 << UInt32(i)) != 0 { ids.append(newest &- UInt32(i) &- 1) }
            for id in ids { if let t = tokens.removeValue(forKey: id) { acked.append(t) } }
            return nil
        case .lost:
            lostAsked += 1
            guard ltr else { return .keyframe }
            refreshWanted = true
            refreshes += 1
            return .refresh
        }
    }

    /// Each report from the phone (about once a second): parity follows the loss seen and the round trip. At home a piece asked for is back
    /// in a few ms, so parity would only cost; away, asking costs a round trip the frame can't wait for.
    func adapt(rtt: Double?) {
        window.append((sentNow, askedNow))
        sentNow = 0
        askedNow = 0
        if window.count > 5 { window.removeFirst() }
        guard fec else { return }
        #if DEBUG || BLURT_TEST_HOOKS
        // measured runs: parity at a fixed group size, whatever the round trip
        if let g = Int(ProcessInfo.processInfo.environment["BLURT_SCREEN_FEC"] ?? "") { group = g; return }
        #endif
        let sent = window.reduce(0) { $0 + $1.sent }, asked = window.reduce(0) { $0 + $1.asked }
        let loss = sent > 0 ? Double(asked) / Double(sent) : 0
        let far = (rtt ?? 0) >= 0.03
        let before = group
        if far {
            group = loss > 0.05 ? 4 : loss > 0.01 ? 8 : loss > 0.002 ? 16 : 0
        } else {
            group = loss > 0.1 ? 8 : 0
        }
        if group != before { emit(["event": "remote_screen_repair", "fec_group": group, "loss": (loss * 1000).rounded() / 1000, "rtt": rtt ?? -1]) }
    }

    /// For the stats line.
    func take() -> [String: Any] {
        defer { resent = 0; refreshes = 0; parity = 0; lostAsked = 0; ignored = 0 }
        return ["resent": resent, "refreshes": refreshes, "parity": parity, "lost_asked": lostAsked, "resend_ignored": ignored]
    }
}

/// Where a frame's time goes on the Mac, for the stats line: composed → handed over by ScreenCaptureKit → encoded → its pieces sent.
struct ScreenTiming {
    private var capture: [Double] = [], encode: [Double] = [], total: [Double] = []
    /// how long each crop change kept frames waiting (ScreenCaptureKit doesn't say which frame has the new crop)
    private var holds: [Double] = []

    mutating func held(_ ms: Double) { if holds.count < 500 { holds.append(ms) } }
    /// the GPU's crop and scale of a zoomed frame
    private var crops: [Double] = []
    mutating func cropped(_ ms: Double) { if crops.count < 2000 { crops.append(ms) } }

    mutating func add(captured: Double, encodeStart: Double, encoded: Double, sent: Double) {
        guard capture.count < 2000 else { return }
        capture.append((encodeStart - captured) * 1000)
        encode.append((encoded - encodeStart) * 1000)
        total.append((sent - captured) * 1000)
    }

    /// the whole app's CPU time since the last line, for what the picture costs the Mac
    private var cpuAt = (wall: 0.0, cpu: 0.0)
    private static func cpu() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    mutating func take() -> [String: Any] {
        let wall = CACurrentMediaTime(), cpu = Self.cpu()
        let pct = cpuAt.wall > 0 ? ((cpu - cpuAt.cpu) / max(0.001, wall - cpuAt.wall) * 1000).rounded() / 10 : -1
        cpuAt = (wall, cpu)
        defer { capture = []; encode = []; total = []; holds = []; crops = [] }
        func p(_ a: [Double], _ q: Double) -> Double {
            guard !a.isEmpty else { return -1 }
            let s = a.sorted()
            return (s[min(s.count - 1, Int(Double(s.count) * q))] * 10).rounded() / 10
        }
        return ["capture_p50": p(capture, 0.5), "capture_p95": p(capture, 0.95), "encode_p50": p(encode, 0.5), "encode_p95": p(encode, 0.95),
                "mac_p50": p(total, 0.5), "mac_p95": p(total, 0.95), "mac_max": p(total, 1), "crops": holds.count, "crop_hold_p50": p(holds, 0.5),
                "crop_hold_max": p(holds, 1), "gpu_crops": crops.count, "gpu_crop_p50": p(crops, 0.5), "gpu_crop_p95": p(crops, 0.95), "cpu_pct": pct]
    }
}
