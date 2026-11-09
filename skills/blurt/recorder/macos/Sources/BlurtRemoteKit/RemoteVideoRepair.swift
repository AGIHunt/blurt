// Repairing the picture instead of starting it over (docs/design/remote-realtime.md). Before this, one piece lost on the way cost the whole
// frame, every frame after it, and a keyframe of 50–100 KB that took a round trip to ask for. Three repairs, each offered by the phone in its
// screen request and answered by the host in screenView, so an older phone or host goes on as before:
//
//  • nack: the phone says which pieces are missing, the host sends them again from what it kept. On a home network that's back in a few ms,
//    well before the frame is due; the phone holds the frames behind it meanwhile, since they can't be decoded without it.
//  • ltr: the phone acknowledges the frames the host marks; a frame that's gone for good costs one small frame made from an acknowledged
//    one (a refresh), not a keyframe.
//  • fec: one parity piece per group of pieces, so a single loss in a group is mended without asking. Only where a round trip is long.
import Foundation

public enum RemoteVideoFeature {
    public static let nack = "nack"
    public static let ltr = "ltr"
    public static let fec = "fec"
    /// what an Apple phone asks for
    public static let all = [nack, ltr, fec]
}

/// What the phone tells the host about the picture: datagrams of kind `videoFeedback`, first byte the type, numbers big-endian.
public enum RemoteVideoFeedback: Equatable, Sendable {
    public struct Missing: Equatable, Sendable {
        public var frame: UInt32
        /// pieces by index; empty: the whole frame (nothing of it arrived, so its size isn't known)
        public var pieces: [UInt16]
        public init(frame: UInt32, pieces: [UInt16]) { self.frame = frame; self.pieces = pieces }
    }
    /// 1: send these again. Repeated: u32 frame, u16 n (0xFFFF = the whole frame), n × u16 index
    case nack([Missing])
    /// 2: decoded, of the frames that asked for it: u32 the newest, u32 a bit for each of the 32 before it (bit 0 = newest − 1)
    case ack(newest: UInt32, earlier: UInt32)
    /// 3: the frame after this one is gone for good: a refresh (or a keyframe if nothing is acknowledged). u32 the last frame decoded
    case lost(after: UInt32)

    public static let maxSize = 1100

    public func encoded() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        switch self {
        case let .nack(m):
            d.append(1)
            for f in m {
                u32(f.frame)
                u16(f.pieces.isEmpty ? 0xFFFF : UInt16(f.pieces.count))
                f.pieces.forEach(u16)
            }
        case let .ack(n, e): d.append(2); u32(n); u32(e)
        case let .lost(a): d.append(3); u32(a)
        }
        return d
    }

    public init?(_ data: Data) {
        let b = [UInt8](data)
        var at = 1
        func u32() -> UInt32? {
            guard at + 4 <= b.count else { return nil }
            defer { at += 4 }
            return b[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func u16() -> UInt16? {
            guard at + 2 <= b.count else { return nil }
            defer { at += 2 }
            return UInt16(b[at]) << 8 | UInt16(b[at + 1])
        }
        guard let t = b.first else { return nil }
        switch t {
        case 1:
            var m: [Missing] = []
            while at < b.count {
                guard let f = u32(), let n = u16() else { return nil }
                if n == 0xFFFF { m.append(Missing(frame: f, pieces: [])); continue }
                var p: [UInt16] = []
                for _ in 0..<n { guard let i = u16() else { return nil }; p.append(i) }
                m.append(Missing(frame: f, pieces: p))
            }
            guard !m.isEmpty else { return nil }
            self = .nack(m)
        case 2:
            guard let n = u32(), let e = u32() else { return nil }
            self = .ack(newest: n, earlier: e)
        case 3:
            guard let a = u32() else { return nil }
            self = .lost(after: a)
        default: return nil
        }
    }

    /// Several frames' worth, in datagrams that fit.
    public static func nacks(_ m: [Missing]) -> [RemoteVideoFeedback] {
        var out: [RemoteVideoFeedback] = [], cur: [Missing] = [], size = 1
        for var f in m {
            f.pieces = Array(f.pieces.prefix(400))
            let n = 6 + 2 * f.pieces.count
            if size + n > maxSize, !cur.isEmpty { out.append(.nack(cur)); cur = []; size = 1 }
            cur.append(f)
            size += n
        }
        if !cur.isEmpty { out.append(.nack(cur)) }
        return out
    }
}

/// Parity pieces, about one for every `group` pieces: the frame's n groups are interleaved (piece i is in group i mod n), so a burst of up to n
/// pieces lost in a row, as Wi-Fi loses them, costs each group at most one. Parity piece k (index count + k) is one byte n, then the XOR of
/// each member's length (2 bytes) and payload, zero-padded to the longest. Any one piece missing from a group is rebuilt from the rest.
public enum RemoteVideoFEC {
    /// parity pieces a frame may carry: an index at count + maxParity or beyond is not a piece
    public static let maxParity = 64

    public static func parity(for pieces: [RemoteVideoPacket], group: Int) -> [RemoteVideoPacket] {
        guard let first = pieces.first, group >= 2, pieces.count >= 2 else { return [] }
        let n = min(maxParity, (pieces.count + group - 1) / group)
        return (0..<n).compactMap { k in
            let members = stride(from: k, to: pieces.count, by: n).map { pieces[$0] }
            guard members.count >= 2 else { return nil }    // a group of one gains nothing over sending it twice
            let len = members.map(\.payload.count).max() ?? 0
            var x = [UInt8](repeating: 0, count: 2 + len)
            for m in members { xor(&x, m.payload) }
            var p = first
            p.index = first.count + UInt16(k)
            p.payload = Data([UInt8(n)]) + Data(x)
            return p
        }
    }

    static func xor(_ x: inout [UInt8], _ payload: Data) {
        let n = payload.count
        x[0] ^= UInt8(n >> 8)
        x[1] ^= UInt8(n & 255)
        var i = 2
        for b in payload { x[i] ^= b; i += 1 }
    }

    /// The one piece missing from a parity piece's group, if exactly one is: (index, payload).
    static func recover(parity: Data, slot: Int, count: Int, have: [UInt16: Data]) -> (UInt16, Data)? {
        guard parity.count >= 3 else { return nil }
        let n = Int(parity[parity.startIndex])
        guard n >= 1, slot < n else { return nil }
        let members = Array(stride(from: slot, to: count, by: n))
        let missing = members.filter { have[UInt16($0)] == nil }
        guard missing.count == 1 else { return nil }
        var x = [UInt8](parity.dropFirst())
        for i in members where i != missing[0] {
            guard let p = have[UInt16(i)], p.count + 2 <= x.count else { return nil }
            xor(&x, p)
        }
        let len = Int(x[0]) << 8 | Int(x[1])
        guard len + 2 <= x.count else { return nil }
        return (UInt16(missing[0]), Data(x[2..<2 + len]))
    }
}

/// The host's recent pieces, to send again when the phone says they're missing. A second at most, and only what fits.
public struct RemoteVideoHistory {
    private var frames: [(id: UInt32, at: Double, packets: [Data])] = []
    private var bytes = 0
    public let maxAge: Double, maxBytes: Int

    public init(maxAge: Double = 1, maxBytes: Int = 6_000_000) { self.maxAge = maxAge; self.maxBytes = maxBytes }

    /// One frame's pieces, encoded (RemoteVideoPacket.encoded), parity pieces left out.
    public mutating func add(_ id: UInt32, _ packets: [Data], now: Double) {
        frames.append((id, now, packets))
        bytes += packets.reduce(0) { $0 + $1.count }
        while let f = frames.first, frames.count > 1, now - f.at > maxAge || bytes > maxBytes {
            bytes -= f.packets.reduce(0) { $0 + $1.count }
            frames.removeFirst()
        }
    }

    /// The pieces asked for (empty: all of them), if the frame is still here.
    public func pieces(_ id: UInt32, _ indices: [UInt16]) -> [Data] {
        guard let f = frames.last(where: { $0.id == id }) else { return [] }
        if indices.isEmpty { return f.packets }
        return indices.compactMap { Int($0) < f.packets.count ? f.packets[Int($0)] : nil }
    }

    public mutating func clear() { frames = []; bytes = 0 }
}

/// The phone's side: pieces in, frames out in order, and what to tell the host. Frames behind a missing piece wait for it to be sent again,
/// up to a limit set by the round trip; then the frame is given up and the host asked for a refresh (or a keyframe). Time is passed in, so
/// this is a pure state machine and its tests run without a clock.
public struct RemoteVideoReceiver {
    public enum Output: Equatable {
        case frame(RemoteVideoAssembler.Frame)
        case feedback(RemoteVideoFeedback)
        /// ask for a keyframe the old way (ToMac.requestKeyframe): nothing can be decoded until one comes
        case keyframe
    }

    struct Partial {
        var count: UInt16
        var pieces: [UInt16: Data] = [:]
        var parity: [UInt16: Data] = [:]
        var key: Bool, refresh: Bool, ack: Bool
        var captured: Double
        var firstAt: Double, lastAt: Double
        /// when each missing piece was last asked for, and how often
        var asked: [UInt16: (at: Double, times: Int)] = [:]
        var complete: Bool { pieces.count == Int(count) }
        var highest: UInt16 = 0
    }

    /// what the host said it does (screenView.features): with neither, nothing waits and a loss asks for a keyframe, as before them
    public var nack: Bool, ltr: Bool
    /// the last measured round trip, seconds
    public var rtt = 0.01
    private var partials: [UInt32: Partial] = [:]
    /// frames known only from a gap in the numbers: when each was last asked for, and how often
    private var whole: [UInt32: (at: Double, times: Int)] = [:]
    /// the frame that decodes next; nil until the first keyframe
    private var next: UInt32?
    private var newest: UInt32?
    /// nothing can be decoded until a keyframe, or with ltr a refresh, arrives
    public private(set) var broken = true
    /// the decoder lost its references: only a keyframe will do
    private var needsKey = true
    private var brokenAt = 0.0, askedAt = -1.0
    /// when frame `next` was first seen to be late
    private var lateSince: Double?
    /// how long it has been late while pieces were arriving and the phone was running: what the patience is measured against
    private var lateFor = 0.0
    /// when frame `next` was first seen to be late, never moved by the phone's own hitches: a phone that stays busy still gives up
    private var lateAt = 0.0
    /// when any piece last arrived. Nothing at all for a while is a stall (a radio dozing, a busy channel), not a loss: everything held up
    /// arrives together afterwards, so nothing is given up and nothing asked for twice meanwhile
    private var heardAt = -1.0
    /// when `tick` last ran: one much later than the last means the phone itself wasn't running (a hitch), not that the network lost
    /// anything; what arrived meanwhile hasn't been read yet
    private var tickedAt: Double?
    private static let quiet = 0.02
    /// a stall this long is given up on regardless
    private static let longest = 0.35
    /// ticks further apart than this: the phone was busy (a frame at 60 Hz without one)
    private static let away = 0.015
    /// late this long in real time is given up on regardless, the phone busy or not
    private static let stuck = 1.0
    private var acks: [UInt32] = [], ackedAt = -1.0
    public private(set) var dropped = 0, repaired = 0, nacked = 0, refreshes = 0

    public init(nack: Bool, ltr: Bool, now: Double = 0) {
        self.nack = nack; self.ltr = ltr; brokenAt = now
    }

    /// How long frames wait behind a missing one before it's given up: a few round trips, within reason. Without nack, not at all.
    public var patience: Double { nack ? min(0.15, max(0.04, rtt * 3 + 0.02)) : 0 }
    private var retry: Double { max(0.012, rtt * 1.5) }
    /// pieces of a frame still arriving: the end of a frame is asked for only after this quiet (keyframes on a direct path come in paced batches)
    private var tailWait: Double { max(0.03, rtt * 2) }

    public mutating func add(_ p: RemoteVideoPacket, now: Double) -> [Output] {
        if let n = next, p.frame < n { return [] }         // decoded already, or given up: a second copy, or late
        // waiting to start over: only what can end the wait is worth keeping
        if broken, !p.keyframe, !(p.refresh && ltr && !needsKey) { return [] }
        if partials[p.frame] == nil {
            if partials.count > 120, let oldest = partials.keys.min() { partials[oldest] = nil }
            partials[p.frame] = Partial(count: p.count, key: p.keyframe, refresh: p.refresh, ack: p.ackRequested, captured: p.captured, firstAt: now, lastAt: now)
            whole[p.frame] = nil
        }
        guard var f = partials[p.frame], f.count == p.count else { return [] }
        f.lastAt = now
        heardAt = now
        if p.isParity {
            f.parity[p.index - p.count] = p.payload
        } else if f.pieces[p.index] == nil {
            f.pieces[p.index] = p.payload
            f.asked[p.index] = nil
            f.highest = max(f.highest, p.index)
        }
        if !f.complete, !f.parity.isEmpty {
            for (slot, par) in f.parity {
                if let (i, d) = RemoteVideoFEC.recover(parity: par, slot: Int(slot), count: Int(f.count), have: f.pieces) {
                    f.pieces[i] = d
                    f.asked[i] = nil
                    repaired += 1
                }
            }
        }
        partials[p.frame] = f
        if newest.map({ p.frame > $0 }) ?? true {
            if nack, let n = newest, p.frame > n &+ 1 {
                for g in (n &+ 1)..<p.frame where partials[g] == nil && whole[g] == nil && next.map({ g >= $0 }) ?? false { whole[g] = (0, 0) }
            }
            newest = p.frame
        }
        return drain(now)
    }

    /// Frames ready to decode, in order.
    private mutating func drain(_ now: Double) -> [Output] {
        var out: [Output] = []
        while true {
            // a whole keyframe jumps over anything before it
            let floor = next ?? 0
            if let k = partials.filter({ $0.value.complete && $0.value.key && $0.key >= floor }).keys.min(),
               broken || k != next {
                out.append(.frame(release(k)))
                continue
            }
            if broken {
                // with references acknowledged, a refresh will do
                if ltr, !needsKey, let n = next,
                   let r = partials.filter({ $0.value.complete && $0.value.refresh && $0.key >= n }).keys.min() {
                    refreshes += 1
                    out.append(.frame(release(r)))
                    continue
                }
                break
            }
            guard let n = next, partials[n]?.complete == true else { break }
            out.append(.frame(release(n)))
        }
        return out
    }

    private mutating func release(_ id: UInt32) -> RemoteVideoAssembler.Frame {
        let f = partials[id]!
        var data = Data()
        for i in 0..<f.count { data.append(f.pieces[i] ?? Data()) }
        if let n = next, id > n { dropped += Int(id - n) }
        for k in partials.keys where k < id { partials[k] = nil }
        for k in whole.keys where k <= id { whole[k] = nil }
        partials[id] = nil
        next = id &+ 1
        if f.key { needsKey = false }
        broken = false
        lateSince = nil
        var out = RemoteVideoAssembler.Frame(data: data, keyframe: f.key, captured: f.captured, id: id, refresh: f.refresh, ackRequested: f.ack)
        out.firstAt = f.firstAt
        out.lastAt = f.lastAt
        return out
    }

    /// Timers: missing pieces asked for, frames given up, the host asked to start over. Call every few ms while the picture is on.
    /// The patience counts only while pieces arrive and the phone is running. In a stall nothing can be asked again, and when it ends
    /// the piece asked for gets its retry before the frame is given up. A tick long after the last one gives nothing up: the phone was
    /// busy, and the pieces that came meanwhile (the one asked for among them) are still to be read. A frame late for a second of real
    /// time is given up regardless, so a phone that stays busy doesn't freeze the picture with nothing asked.
    public mutating func tick(now: Double) -> [Output] {
        var out: [Output] = []
        let sinceTick = tickedAt.map { now - $0 } ?? 0
        let away = sinceTick > Self.away
        if away, let s = lateSince { lateSince = s + sinceTick }
        tickedAt = now
        // a frame that can't come: give up on it, and everything behind it waits for a refresh
        if !broken, let n = next {
            let f = partials[n]
            let late = f.map { !$0.complete && (newest.map { $0 > n } ?? false || now - $0.lastAt > tailWait) } ?? (newest.map { $0 >= n } ?? false)
            if late {
                let stalled = now - heardAt > Self.quiet
                let since: Double
                if let s = lateSince {
                    if !away, !stalled { lateFor += sinceTick }
                    since = s
                } else {
                    lateFor = 0
                    lateAt = now
                    lateSince = now
                    since = now
                }
                let stuck = now - lateAt >= Self.stuck
                if stuck || (!away && ((lateFor >= patience && !stalled) || now - since >= Self.longest)) {
                    broken = true
                    brokenAt = now
                    askedAt = -1
                    lateSince = nil
                    // what's behind it is no use now, except what could end the wait
                    for (k, p) in partials where !p.key && !p.refresh { partials[k] = nil }
                    whole = [:]
                }
            } else {
                lateSince = nil
            }
        }
        if broken {
            // at the start the first keyframe is on its way: ask only if it doesn't come
            let started = next == nil && askedAt < 0
            if now - askedAt >= 0.25, !started || now - brokenAt > 0.3 {
                askedAt = now
                if ltr, !needsKey, let n = next { out.append(.feedback(.lost(after: n &- 1))) } else { out.append(.keyframe) }
            }
        }
        if nack { out += missing(now) }
        if !acks.isEmpty, now - ackedAt >= 0.02 { out.append(.feedback(takeAck(now))) }
        return out
    }

    /// What to ask for again, now.
    private mutating func missing(_ now: Double) -> [Output] {
        var want: [RemoteVideoFeedback.Missing] = []
        let floor = next ?? 0
        for (id, f) in partials.sorted(by: { $0.key < $1.key }) where !f.complete && id >= floor {
            // while broken only what could end it is worth having
            if broken, !(f.key || (f.refresh && ltr && !needsKey)) { continue }
            let later = newest.map { $0 > id } ?? false
            var ask: [UInt16] = []
            var g = f
            for i in 0..<f.count where f.pieces[i] == nil {
                // a hole before the newest piece of the frame, or the end once it's been quiet (or a later frame has begun)
                guard i < f.highest || later || now - f.lastAt > tailWait else { continue }
                // asked already: again after a round trip and a half, but not into a stall
                if let a = f.asked[i] { guard a.times < 4, now - a.at >= retry, now - heardAt <= Self.quiet else { continue } }
                ask.append(i)
                g.asked[i] = (now, (f.asked[i]?.times ?? 0) + 1)
            }
            guard !ask.isEmpty else { continue }
            partials[id] = g
            want.append(.init(frame: id, pieces: ask))
            nacked += ask.count
        }
        if !broken {
            for (id, a) in whole.sorted(by: { $0.key < $1.key }) where id >= floor && a.times < 4 && now - a.at >= retry {
                whole[id] = (now, a.times + 1)
                want.append(.init(frame: id, pieces: []))
                nacked += 1
            }
        }
        return RemoteVideoFeedback.nacks(want).map { .feedback($0) }
    }

    /// The decoder took this frame: if the host asked, it hears so (in a batch, every 20 ms at most).
    public mutating func decoded(_ f: RemoteVideoAssembler.Frame, now: Double) -> [Output] {
        guard ltr, f.ackRequested else { return [] }
        acks.append(f.id)
        guard now - ackedAt >= 0.02 else { return [] }
        return [.feedback(takeAck(now))]
    }

    private mutating func takeAck(_ now: Double) -> RemoteVideoFeedback {
        let n = acks.max() ?? 0
        var bits: UInt32 = 0
        for a in acks where a < n && n - a <= 32 { bits |= 1 << (n - a - 1) }
        acks = []
        ackedAt = now
        return .ack(newest: n, earlier: bits)
    }

    /// The decoder failed: its references are gone, only a keyframe helps.
    public mutating func decoderFailed(now: Double) {
        broken = true
        needsKey = true
        brokenAt = now
        askedAt = -1
        acks = []
    }
}
