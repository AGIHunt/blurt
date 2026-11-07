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
            if current != nil { dropped += 1; waitingForKey = true }   // the frame before never finished
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
        if let previous = lastComplete, p.frame != previous &+ 1 { waitingForKey = true; dropped += 1 }
        lastComplete = p.frame
        if key { waitingForKey = false }
        return waitingForKey ? nil : Frame(data: data, keyframe: key, captured: captured, id: p.frame)
    }
    private var lastComplete: UInt32?
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
