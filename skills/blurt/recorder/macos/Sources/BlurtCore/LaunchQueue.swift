// The rule behind the app's one message at launch (BlurtApp LaunchMessages): from start() messages are held for
// `hold` seconds; flush() then shows the highest-ranked one (between equals, the first posted) and drops the rest.
// Until `window` seconds after start, a message posted once one has been shown is dropped too; after that, post() just
// shows it. A message that is no longer true when the hold ends (`stale`: "the downloads carry on" after they
// stopped) is dropped before the pick. The clock is passed in, and showing and dropping are the caller's (the island,
// the event log).
import Foundation

public final class LaunchQueue<Message> {
    public enum Outcome: Equatable { case held, shown, dropped }

    public let hold: TimeInterval
    public let window: TimeInterval
    private let show: (Message) -> Void
    private let drop: (Message, Int) -> Void
    private let stale: (Message) -> Bool
    private var held: [(rank: Int, message: Message)] = []
    /// The launch's messages are still held (the first seconds after start()).
    public private(set) var collecting = false
    private var oneShown = false
    private var started: Date?

    public init(hold: TimeInterval = 3, window: TimeInterval = 90, show: @escaping (Message) -> Void,
                dropped: @escaping (Message, Int) -> Void = { _, _ in }, stale: @escaping (Message) -> Bool = { _ in false }) {
        self.hold = hold
        self.window = window
        self.show = show
        self.drop = dropped
        self.stale = stale
    }

    /// At launch, before anything posts; the caller calls flush() `hold` seconds later.
    public func start(now: Date = Date()) {
        started = now
        collecting = true
    }

    @discardableResult
    public func post(_ rank: Int, _ m: Message, now: Date = Date()) -> Outcome {
        if collecting {
            held.append((rank, m))
            return .held
        }
        if let s = started, now.timeIntervalSince(s) < window {
            if oneShown { drop(m, rank); return .dropped }
            oneShown = true
        }
        show(m)
        return .shown
    }

    /// The end of the hold: the highest-ranked held message goes up, the others are dropped.
    public func flush() {
        collecting = false
        held.removeAll { h in
            guard stale(h.message) else { return false }
            drop(h.message, h.rank)
            return true
        }
        guard let best = held.indices.max(by: { held[$0].rank < held[$1].rank || (held[$0].rank == held[$1].rank && $0 > $1) }) else { return }
        let all = held
        held = []
        for (i, h) in all.enumerated() where i != best { drop(h.message, h.rank) }
        oneShown = true
        show(all[best].message)
    }
}
