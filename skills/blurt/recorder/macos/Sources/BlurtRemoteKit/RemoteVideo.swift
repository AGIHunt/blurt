// The screen, as a stream of small datagrams (docs/design/remote.md §Screen). A frame is cut into pieces that each fit a Wi-Fi
// packet. UDP, not TCP: a late frame is worth nothing, and nothing must wait behind one. A frame missing a piece is dropped;
// the frames after it can't be decoded either, so the phone asks for a keyframe and waits for it.
import Foundation

/// A part of the source, 0…1. The phone decides what's in view; the Mac sends that part, and says with each frame which part it is.
public struct RemoteCrop: Codable, Hashable, Sendable {
    public var x: Float, y: Float, w: Float, h: Float
    public init(x: Float, y: Float, w: Float, h: Float) { self.x = x; self.y = y; self.w = w; self.h = h }
    public static let whole = RemoteCrop(x: 0, y: 0, w: 1, h: 1)

    public static func centered(zoom: Float) -> RemoteCrop {
        let s = 1 / max(1, zoom)
        return RemoteCrop(x: (1 - s) / 2, y: (1 - s) / 2, w: s, h: s)
    }

    /// Inside the source and not absurdly small, whatever arrived.
    public var valid: RemoteCrop {
        guard [x, y, w, h].allSatisfy(\.isFinite) else { return .whole }
        let w = min(1, max(0.1, self.w)), h = min(1, max(0.1, self.h))
        return RemoteCrop(x: min(1 - w, max(0, x)), y: min(1 - h, max(0, y)), w: w, h: h)
    }
}

public struct RemoteScreenRequest: Codable, Hashable, Sendable {
    /// "display": the screen with the pointer. "window": the window titled "Blurt Screen Test".
    public var target: String
    public var crop: RemoteCrop
    public var width: Int
    public var height: Int
    public var bitrate: Int
    public var fps: Int
    public init(target: String, crop: RemoteCrop = .whole, width: Int, height: Int, bitrate: Int, fps: Int = 60) {
        self.target = target; self.crop = crop; self.width = width; self.height = height; self.bitrate = bitrate; self.fps = fps
    }
}

/// What the phone got since its last report.
public struct RemoteScreenReport: Codable, Hashable, Sendable {
    public var frames: Int
    /// frames that never arrived whole
    public var lost: Int
    /// seconds, the last ping's round trip
    public var rtt: Double?
    /// bytes of picture since this stream began
    public var received: Int
    public init(frames: Int, lost: Int, rtt: Double?, received: Int) { self.frames = frames; self.lost = lost; self.rtt = rtt; self.received = received }
}

/// How much to send, from what the network lets through. The phone's request is the ceiling, set by what it's on and what the user chose.
/// Away from home it starts at half and climbs. Down fast when frames pile up on the way or are lost in numbers; then to a little under what's
/// really getting through, and no further while the queue drains. One lost frame on Wi-Fi says nothing: it's counted over a few seconds. Back up
/// slowly, and only while the picture actually uses what it has: a still screen proves nothing about the network. Each frame must be worth
/// sending: with little to spend there are fewer of them, because on a screen text that can be read matters more than motion.
public struct RemoteRate: Equatable, Sendable {
    public let cap: Int
    public let fpsCap: Int
    public private(set) var bitrate: Int
    public private(set) var fps: Int
    private var calm = 0
    private var bestRTT = Double.infinity
    /// reports to let a cut take effect before judging it
    private var wait = 0
    /// where trouble last began, and how long ago: no use climbing straight back into it
    private var troubleAt = Int.max, sinceTrouble = 0
    /// the last few reports: frames, lost
    private var recent: [(Int, Int)] = []

    private static let window = 5
    /// reports before trying past where trouble began
    private static let patience = 30
    private static let bitsPerFrame = 30_000

    public init(bitrate: Int, fps: Int, away: Bool = false) {
        cap = bitrate; fpsCap = fps
        self.bitrate = away ? bitrate / 2 : bitrate
        self.fps = Self.frames(self.bitrate, cap: fps)
    }

    public static func == (a: RemoteRate, b: RemoteRate) -> Bool { a.cap == b.cap && a.bitrate == b.bitrate && a.fps == b.fps }

    public var floor: Int { min(cap, 200_000) }

    private static func frames(_ bitrate: Int, cap: Int) -> Int { min(cap, max(10, bitrate / bitsPerFrame)) }

    /// One report's worth. `busy`: frames skipped because the way out was full. `backedUp`: more on its way than should be. `sent`, `delivered`:
    /// bits a second out of here and into the phone. True if anything changed.
    public mutating func update(frames: Int, lost: Int, busy: Int, backedUp: Bool = false, rtt: Double?, sent: Int, delivered: Int = 0) -> Bool {
        let before = (bitrate, fps)
        if let rtt, rtt > 0 { bestRTT = min(bestRTT, rtt) }
        recent.append((frames, lost))
        if recent.count > Self.window { recent.removeFirst() }
        let seen = recent.reduce(0) { $0 + $1.0 }, missing = recent.reduce(0) { $0 + $1.1 }
        let queued = rtt.map { $0 > bestRTT * 3 + 0.1 } ?? false
        let lossy = missing >= 2 && missing * 20 >= seen + missing
        sinceTrouble += 1
        if sinceTrouble > Self.patience { troubleAt = Int.max }
        if wait > 0 { wait -= 1 }
        if busy >= 3 || backedUp || lossy || queued {
            calm = 0
            if lossy { recent = [] }        // each loss is answered once
            // already under what's arriving: what's queued is draining
            if wait == 0, delivered == 0 || bitrate * 100 > delivered * 85 {
                troubleAt = bitrate
                sinceTrouble = 0
                var next = bitrate * 7 / 10
                if delivered > 0 { next = min(next, Swift.max(delivered * 85 / 100, bitrate / 2)) }
                bitrate = Swift.max(floor, next)
                wait = 2
            }
        } else {
            calm += 1
            let ceiling = min(cap, troubleAt == Int.max ? cap : troubleAt * 9 / 10)
            if calm >= 3, bitrate < ceiling, sent * 10 >= bitrate * 6 {
                calm = 0
                bitrate = min(ceiling, bitrate * 5 / 4)
            }
        }
        fps = Self.frames(bitrate, cap: fpsCap)
        return before != (bitrate, fps)
    }
}

public struct RemoteVideoPacket: Equatable, Sendable {
    public static let headerSize = 17
    public static let payloadSize = 1180

    public var frame: UInt32
    public var index: UInt16
    public var count: UInt16
    public var keyframe: Bool
    /// when the Mac composed it, on the Mac's clock
    public var captured: Double
    public var payload: Data

    public init(frame: UInt32, index: UInt16, count: UInt16, keyframe: Bool, captured: Double, payload: Data) {
        self.frame = frame; self.index = index; self.count = count; self.keyframe = keyframe; self.captured = captured; self.payload = payload
    }

    public func encoded() -> Data {
        var d = Data(capacity: Self.headerSize + payload.count)
        withUnsafeBytes(of: frame.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: index.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: count.bigEndian) { d.append(contentsOf: $0) }
        d.append(keyframe ? 1 : 0)
        withUnsafeBytes(of: captured.bitPattern.bigEndian) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    public init?(_ d: Data) {
        guard d.count >= Self.headerSize else { return nil }
        let b = [UInt8](d.prefix(Self.headerSize))
        frame = b[0..<4].reduce(0) { $0 << 8 | UInt32($1) }
        index = b[4..<6].reduce(0) { $0 << 8 | UInt16($1) }
        count = b[6..<8].reduce(0) { $0 << 8 | UInt16($1) }
        keyframe = b[8] == 1
        captured = Double(bitPattern: b[9..<17].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        payload = Data(d.dropFirst(Self.headerSize))
        guard count > 0, index < count else { return nil }
    }

    /// One encoded frame, in pieces.
    public static func split(_ data: Data, frame: UInt32, keyframe: Bool, captured: Double, payload size: Int = payloadSize) -> [RemoteVideoPacket] {
        let count = max(1, (data.count + size - 1) / size)
        return (0..<count).map { i in
            let start = data.startIndex + i * size
            let end = min(start + size, data.endIndex)
            return RemoteVideoPacket(frame: frame, index: UInt16(i), count: UInt16(count), keyframe: keyframe, captured: captured,
                                     payload: Data(data[start..<end]))
        }
    }
}

/// Pieces in, whole frames out, in order, and never a frame the decoder couldn't use.
public struct RemoteVideoAssembler {
    public struct Frame: Equatable {
        public let data: Data
        public let keyframe: Bool
        public let captured: Double
        public let id: UInt32
    }

    private var current: UInt32?
    private var pieces: [UInt16: Data] = [:]
    private var total: UInt16 = 0
    private var key = false
    private var captured = 0.0
    private var lastDone: UInt32?
    /// a frame was lost: nothing can be decoded until the next keyframe
    public private(set) var waitingForKey = true
    public private(set) var dropped = 0
    public init() {}

    /// A frame, if this piece finished one.
    public mutating func add(_ p: RemoteVideoPacket) -> Frame? {
        if let l = lastDone, p.frame <= l { return nil }        // late
        if current != p.frame {
            if let c = current, p.frame < c { return nil }      // late, and a newer one has begun
            if current != nil { dropped += 1; waitingForKey = true; noted = true }   // the frame before never finished
            current = p.frame
            pieces = [:]
            total = p.count
            key = p.keyframe
            captured = p.captured
        }
        pieces[p.index] = p.payload
        guard pieces.count == Int(total) else { return nil }
        var data = Data()
        for i in 0..<total { data.append(pieces[i] ?? Data()) }
        lastDone = p.frame
        current = nil
        pieces = [:]
        if let previous = lastComplete, p.frame != previous &+ 1 {
            waitingForKey = true
            if !noted { dropped += 1 }
        }
        noted = false
        lastComplete = p.frame
        if key { waitingForKey = false }
        return waitingForKey ? nil : Frame(data: data, keyframe: key, captured: captured, id: p.frame)
    }
    private var lastComplete: UInt32?
    /// the gap ahead of this frame has been counted
    private var noted = false
}

/// The part of the source this frame shows, then the keyframe's parameter sets (count, then each with a 2-byte length), then its picture.
public enum RemoteVideoPayload {
    public static func pack(crop: RemoteCrop, parameterSets: [Data], picture: Data) -> Data {
        var d = Data()
        for v in [crop.x, crop.y, crop.w, crop.h] { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        d.append(UInt8(parameterSets.count))
        for p in parameterSets {
            d.append(UInt8(p.count >> 8)); d.append(UInt8(p.count & 255))
            d.append(p)
        }
        d.append(picture)
        return d
    }

    public static func unpack(_ d: Data) -> (crop: RemoteCrop, parameterSets: [Data], picture: Data)? {
        guard d.count >= 17 else { return nil }
        let head = [UInt8](d.prefix(16))
        func f(_ i: Int) -> Float {
            Float(bitPattern: UInt32(head[i]) | UInt32(head[i + 1]) << 8 | UInt32(head[i + 2]) << 16 | UInt32(head[i + 3]) << 24)
        }
        let crop = RemoteCrop(x: f(0), y: f(4), w: f(8), h: f(12)).valid
        let n = d[d.startIndex + 16]
        var at = d.startIndex + 17
        var sets: [Data] = []
        for _ in 0..<n {
            guard at + 2 <= d.endIndex else { return nil }
            let len = Int(d[at]) << 8 | Int(d[at + 1])
            at += 2
            guard at + len <= d.endIndex else { return nil }
            sets.append(Data(d[at..<at + len]))
            at += len
        }
        return (crop, sets, Data(d[at...]))
    }
}
