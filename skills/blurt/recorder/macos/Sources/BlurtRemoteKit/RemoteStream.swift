// The stream over UDP (docs/design/remote-go-between.md, "Rules for the stream over UDP"). On the go-between, once the direct path is open,
// each end moves the bytes it would have written to TCP or the WebSocket into datagrams: frame kind 7 carries a piece of the stream at its
// offset, kind 8 says how far the other end has read. These two types are the whole of it, with the clock passed in, so every rule can be
// tested without a network: RemoteChannel feeds them packets and its timer, and sends what they hand back.
import Foundation

/// The bodies of frame kinds 7 and 8, after the kind byte.
public enum RemoteStreamPacket: Equatable, Sendable {
    /// kind 7: u64 BE offset ∥ bytes, at most `RemoteStream.chunk` of them
    case data(offset: UInt64, bytes: Data)
    /// kind 8: u64 BE, the next offset the receiver expects (everything before it arrived)
    case ack(next: UInt64)

    public var kind: RemoteFrameKind {
        switch self {
        case .data: .stream
        case .ack: .streamAck
        }
    }

    public func encoded() -> Data {
        var d = Data(capacity: 8 + (self.bytes?.count ?? 0))
        let n: UInt64
        switch self {
        case let .data(offset, _): n = offset
        case let .ack(next): n = next
        }
        withUnsafeBytes(of: n.bigEndian) { d.append(contentsOf: $0) }
        if let b = bytes { d.append(b) }
        return d
    }

    private var bytes: Data? { if case let .data(_, b) = self { b } else { nil } }

    /// `body`: what follows the kind byte. nil for a body that can't be one.
    public init?(kind: RemoteFrameKind, body: Data) {
        let b = [UInt8](body)
        guard b.count >= 8 else { return nil }
        let n = b[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        switch kind {
        case .stream:
            guard b.count - 8 <= RemoteStream.chunk else { return nil }
            self = .data(offset: n, bytes: Data(b[8...]))
        case .streamAck:
            guard b.count == 8 else { return nil }
            self = .ack(next: n)
        default: return nil
        }
    }
}

public enum RemoteStream {
    /// bytes of the stream in one kind-7 datagram: with the offset, the seal and the packet's header it stays under 1,200
    public static let chunk = 1100
    /// unacknowledged bytes a sender keeps in flight, and out-of-order bytes a receiver keeps past `next`
    public static let window = 256 * 1024
    /// the retransmission timeout's floor and ceiling
    public static let minRTO = 0.2
    public static let maxRTO = 2.0
    /// chunks sent again on a timeout
    public static let resendBurst = 8
    /// a receiver acks at most this often, unless a packet filled a gap
    public static let ackGap = 0.02
}

/// One end's outgoing stream. Keeps every byte until it's acknowledged; sends new bytes while fewer than `window` are in flight and queues
/// the rest. With no progress for an RTO (max(200 ms, 2 × smoothed RTT), doubling on each such timeout up to 2 s) it sends again from the
/// acknowledged offset, up to 8 chunks; three acks in a row with the same `next` send one chunk again at once.
public final class RemoteStreamSender {
    /// everything before this has arrived
    public private(set) var acked: UInt64 = 0
    /// bytes from `acked` on, sent or not
    private var buffer = Data()
    /// the first offset never sent
    public private(set) var sent: UInt64 = 0
    /// when each run of new bytes went, by its end: the round trip's samples. Bytes sent again give none (which copy was acked?)
    private var sendTimes: [(end: UInt64, at: Double)] = []
    public private(set) var srtt: Double?
    private var backoff = 1.0
    /// when the timeout runs from: the last progress, the first send after none in flight, or the last timeout
    private var since = 0.0
    private var lastAck: UInt64?
    private var sameAcks = 0
    /// for the log and the tests
    public private(set) var resent = 0

    /// `rtt`: a first guess at the round trip (the session's pings), until the stream has measured its own
    public init(rtt: Double? = nil) { srtt = rtt }

    public var inFlight: Int { Int(sent - acked) }
    /// bytes written and not yet sent
    public var queued: Int { buffer.count - inFlight }
    public var written: UInt64 { acked + UInt64(buffer.count) }

    public var rto: Double {
        let base = max(RemoteStream.minRTO, 2 * (srtt ?? RemoteStream.minRTO / 2))
        return min(base * backoff, max(RemoteStream.maxRTO, base))
    }

    /// When `tick` next has something to do; nil with nothing in flight.
    public var deadline: Double? { inFlight > 0 ? since + rto : nil }

    /// More bytes of the stream: what can go now.
    public func write(_ d: Data, now: Double) -> [RemoteStreamPacket] {
        buffer.append(d)
        return pump(now)
    }

    private func pump(_ now: Double) -> [RemoteStreamPacket] {
        var out: [RemoteStreamPacket] = []
        while queued > 0, inFlight < RemoteStream.window {
            let n = min(RemoteStream.chunk, queued, RemoteStream.window - inFlight)
            if inFlight == 0 { since = now }
            let from = Int(sent - acked)
            out.append(.data(offset: sent, bytes: slice(from, n)))
            sent += UInt64(n)
            sendTimes.append((sent, now))
        }
        return out
    }

    private func slice(_ from: Int, _ n: Int) -> Data {
        let s = buffer.startIndex + from
        return Data(buffer[s..<s + n])
    }

    /// The other end has everything before `next`.
    public func ack(_ next: UInt64, now: Double) -> [RemoteStreamPacket] {
        guard next <= sent else { return [] }      // more than was ever sent: not an ack of this stream
        if next == lastAck { sameAcks += 1 } else { lastAck = next; sameAcks = 1 }
        if next > acked {
            let n = Int(next - acked)
            buffer.removeFirst(n)
            buffer = Data(buffer)       // a fresh start index, so slicing stays cheap
            acked = next
            // the newest run this ack covers says how long the round trip is
            if let i = sendTimes.lastIndex(where: { $0.end <= next }) {
                let sample = max(0, now - sendTimes[i].at)
                srtt = srtt.map { $0 * 7 / 8 + sample / 8 } ?? sample
                sendTimes.removeFirst(i + 1)
            }
            backoff = 1
            since = now
        }
        var out: [RemoteStreamPacket] = []
        if sameAcks >= 3, inFlight > 0, next == acked {
            // the receiver keeps saying the same: what it's missing goes again now, not at the timeout
            sameAcks = 0
            out += resend(1)
        }
        return out + pump(now)
    }

    /// The timer: with no progress for an RTO, send again from the acknowledged offset.
    public func tick(now: Double) -> [RemoteStreamPacket] {
        guard let d = deadline, now >= d else { return [] }
        let out = resend(RemoteStream.resendBurst)
        backoff = min(backoff * 2, 64)
        since = now
        return out
    }

    private func resend(_ chunks: Int) -> [RemoteStreamPacket] {
        sendTimes.removeAll()
        var out: [RemoteStreamPacket] = []
        var at = 0
        while out.count < chunks, at < inFlight {
            let n = min(RemoteStream.chunk, inFlight - at)
            out.append(.data(offset: acked + UInt64(at), bytes: slice(at, n)))
            at += n
        }
        resent += out.count
        return out
    }
}

/// One end's incoming stream. Hands on bytes in offset order, keeps what comes early up to `window` past `next` (a chunk that overlaps
/// what it has is fine), and acks every packet, at most once every 20 ms unless the packet filled a gap.
public final class RemoteStreamReceiver {
    /// everything before this has been handed on
    public private(set) var next: UInt64 = 0
    /// bytes that came early, by their offset
    private var early: [UInt64: Data] = [:]
    private var lastAckAt = -Double.infinity
    private var owed = false
    /// bytes held out of order, for the tests
    public var held: Int { early.values.reduce(0) { $0 + $1.count } }

    public init() {}

    /// When `tick` owes an ack; nil if it owes none.
    public var deadline: Double? { owed ? lastAckAt + RemoteStream.ackGap : nil }

    /// A kind-7 packet: the bytes now readable in order (often none), and an ack to send now, if one is due.
    public func receive(offset: UInt64, bytes: Data, now: Double) -> (data: Data, ack: UInt64?) {
        var out = Data()
        var filled = false
        let end = offset + UInt64(bytes.count)
        let limit = next + UInt64(RemoteStream.window)
        if end > next, offset < limit {
            // the part that's new and inside the window
            let from = max(offset, next), to = min(end, limit)
            let part = Data(bytes[bytes.startIndex + Int(from - offset)..<bytes.startIndex + Int(to - offset)])
            if from == next {
                let gap = !early.isEmpty
                out.append(part)
                next = to
                // what came early and now follows on
                while let (start, d) = early.first(where: { $0.key <= next && $0.key + UInt64($0.value.count) > next }) {
                    early[start] = nil
                    out.append(Data(d[(d.startIndex + Int(next - start))...]))
                    next = start + UInt64(d.count)
                }
                for (start, d) in early where start + UInt64(d.count) <= next { early[start] = nil }
                filled = gap
            } else if (early[from]?.count ?? 0) < part.count {
                early[from] = part
            }
        }
        if filled || now - lastAckAt >= RemoteStream.ackGap {
            lastAckAt = now
            owed = false
            return (out, next)
        }
        owed = true
        return (out, nil)
    }

    /// The timer: an ack held back by the 20 ms gap.
    public func tick(now: Double) -> UInt64? {
        guard owed, now >= lastAckAt + RemoteStream.ackGap else { return nil }
        owed = false
        lastAckAt = now
        return next
    }
}
