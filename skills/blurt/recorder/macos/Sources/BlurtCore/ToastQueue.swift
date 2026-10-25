// The island's one-line toasts, as a rule (BlurtApp Capture/Island/Island.swift shows them). The island has one slot;
// the dogfood run found it a FIFO queue, so a second ⌥⇧L's "Reformatted as …" waited behind the first one's (with
// that one's Undo), and "nothing to reformat" waited behind the launch welcome: the island described the past.
//
//  • newest first: what the user just did (`.reply`, the default) is what the island says. A reply arriving while
//    another toast shows takes the slot once that one has been up `minShown` (so nothing flashes by unread); replies
//    waiting are taken newest first, and a reply that goes up supersedes the plain replies posted before it (they
//    are dropped, never shown after it out of order — the review's A, B, C showed A, C, then B). Passive lines (`.passive`: launch messages, a job that finished, reminders) wait
//    their turn in the order they came, behind every reply.
//  • replaced, not repeated: a toast with the same `key` as the one showing takes its place at once (its text, its
//    action, a fresh clock); one with the same key waiting is replaced. The same text again just restarts the clock.
//    `drop(key:)` forgets a kind of toast (dictation's, when a new take starts).
//  • stale ones go: a reply that waited longer than `staleReply` describes something that is over, so it is dropped
//    unshown; a passive line after `stalePassive`. Questions never go stale.
//  • long enough to read and act on: every toast stays at least `minSeconds` (an Undo window is never shorter), and
//    its clock stops while the pointer is on it (`tick(…, paused: true)`) — nor does it give way then.
//  • a toast pushed out by a newer one comes back after it when it still matters: a question (it waits for an answer)
//    or one with an action (an Undo) with more than `minShown` left — for exactly the time it had left (the 5 s floor
//    was its first showing's); a plain line is simply superseded.
//  • every toast that goes without being acted on — expired, replaced, superseded, stale, dropped — is handed to
//    `onGone` once (the island answers the main window's page "gone", so its Undo never outlives the island's).
//    `dismissCurrent()` is the one exit that isn't: the toast was acted on, answered or closed by its owner.
//  • a click on a toast's body (ToastQueue.bodyClick): a toast with a button acts only through that button (a click
//    meant to open the island never runs an Undo); a line with an action and no button (a peck's "open the item") is
//    its own button.
// The clock is passed in (seconds, any monotonic origin); showing is the caller's.
import Foundation

public final class ToastQueue<Payload> {
    public enum Kind: Equatable { case reply, passive }

    public struct Entry {
        public var payload: Payload
        public var key: String?
        public var text: String
        public var kind: Kind
        /// How long it shows (at least `minSeconds`; `.infinity` for a question).
        public var seconds: Double
        /// It has something to act on (an Undo, Show…): it comes back if a newer toast pushed it out early.
        public var actionable: Bool
        /// A question: it waits for an answer, never goes stale, and comes back if pushed out.
        public var question: Bool
        /// When it was posted (or put back in the queue): it goes stale from then.
        public var posted: Double = 0
        /// The order it was posted in (newest = highest; kept when it is put back).
        public internal(set) var order = 0
        /// How long it has been on screen (the clock stops while it is pointed at).
        public var shown: Double = 0
        /// Put back after a newer toast pushed it out: `seconds` is the time it had left (no 5 s floor again).
        public internal(set) var resumed = false

        public init(_ payload: Payload, text: String, key: String? = nil, kind: Kind = .reply, seconds: Double,
                    actionable: Bool = false, question: Bool = false) {
            self.payload = payload
            self.text = text
            self.key = key
            self.kind = kind
            self.seconds = seconds
            self.actionable = actionable
            self.question = question
        }

        var duration: Double { question ? .infinity : resumed ? seconds : max(seconds, ToastQueue.minSeconds) }
        /// Gone once something newer is up: a plain reply (no question, nothing to act on).
        var supersedable: Bool { kind == .reply && !question && !actionable }
    }

    public enum Outcome: Equatable { case shown, replaced, refreshed, queued }

    public static var minSeconds: Double { 5 }
    public static var minShown: Double { 1 }
    public static var staleReply: Double { 8 }
    public static var stalePassive: Double { 60 }

    public private(set) var current: Entry?
    public private(set) var waiting: [Entry] = []
    private var lastTick: Double?
    private var posts = 0
    /// Tests and screenshots: every toast stays at least this long.
    public var floorSeconds: Double = 0
    /// A toast left without being acted on (expired, replaced, superseded, stale, dropped): called once for each.
    public var onGone: ((Entry) -> Void)?

    public enum BodyClick: Equatable {
        /// run the toast's action (it has no button: the line is the button)
        case act
        /// open the island (the toast is held; its button is the only way to its action)
        case open
    }

    /// What a click on a toast's body does (not on its button).
    public static func bodyClick(hasButton: Bool, hasAction: Bool) -> BodyClick { hasAction && !hasButton ? .act : .open }

    public init() {}

    /// A new toast. `canShowNow`: the island can take it at once (nothing showing, or this one may go over what is).
    @discardableResult
    public func post(_ e: Entry, now: Double, canShowNow: Bool = true) -> Outcome {
        var e = e
        e.posted = now
        e.shown = 0
        posts += 1
        e.order = posts
        if let k = e.key, let c = current, c.key == k {
            current = e
            onGone?(c)
            remove { $0.key == k }
            return .replaced
        }
        if let c = current, c.key == nil, e.key == nil, c.text == e.text {
            current?.shown = 0
            current?.payload = e.payload
            onGone?(c)                     // (its payload is the new one's now)
            return .refreshed
        }
        remove { ($0.key != nil && $0.key == e.key) || ($0.key == nil && e.key == nil && $0.text == e.text) }
        waiting.append(e)
        if current == nil, canShowNow, next(now: now, canShow: { _ in true }), current?.order == e.order { return .shown }
        return .queued
    }

    /// Forgets every toast with this key, the one showing too.
    public func drop(key: String) {
        remove { $0.key == key }
        if let c = current, c.key == key { current = nil; onGone?(c) }
    }

    /// The one showing was acted on, answered or closed (by its owner: not `onGone`).
    public func dismissCurrent() { current = nil }

    /// Advances the clock. `paused`: the pointer is on the toast (its clock stops, and it doesn't give way).
    /// `canShow`: whether a waiting toast may go up now (e.g. the open island takes only toasts meant to go over it).
    /// True when what shows changed.
    @discardableResult
    public func tick(now: Double, paused: Bool, canShow: (Entry) -> Bool) -> Bool {
        // (a gap in the ticks — the island's display link idles while nothing shows — is not time on screen)
        let dt = min(0.5, max(0, now - (lastTick ?? now)))
        lastTick = now
        var changed = false
        if var c = current {
            if !paused { c.shown += dt }
            current = c
            let floor = max(c.duration, floorSeconds)
            if c.shown >= floor {
                current = nil
                onGone?(c)
                changed = true
            } else if !paused, c.shown >= ToastQueue.minShown, let n = candidate(now: now, canShow: canShow), outranks(n, c) {
                // newest first: a newer reply takes the slot; this one comes back after it if it still matters (a
                // question, an Undo, a passive line that was never meant to be skipped)
                current = nil
                if c.question || ((c.actionable || c.kind == .passive) && floor - c.shown > ToastQueue.minShown) {
                    var back = c
                    if !c.question { back.seconds = floor - c.shown; back.resumed = true }
                    back.shown = 0
                    back.posted = now
                    waiting.append(back)
                } else {
                    onGone?(c)
                }
                changed = true
            }
        }
        dropStale(now: now)
        if current == nil, next(now: now, canShow: canShow) { changed = true }
        return changed
    }

    /// The toast that would go up next: the newest reply, else the oldest passive line (stale ones dropped first).
    private func candidate(now: Double, canShow: (Entry) -> Bool) -> Entry? {
        dropStale(now: now)
        return pick(canShow).map { waiting[$0] }
    }

    private func pick(_ canShow: (Entry) -> Bool) -> Int? {
        let ok = waiting.indices.filter { canShow(waiting[$0]) }
        if let r = ok.filter({ waiting[$0].kind == .reply }).max(by: { waiting[$0].order < waiting[$1].order }) { return r }
        return ok.filter { waiting[$0].kind == .passive }.min { waiting[$0].order < waiting[$1].order }
    }

    /// A waiting toast pushes the one showing out only if it is a reply posted after it.
    private func outranks(_ n: Entry, _ c: Entry) -> Bool { n.kind == .reply && n.order > c.order }

    private func dropStale(now: Double) {
        remove { e in
            guard !e.question else { return false }
            return now - e.posted > (e.kind == .reply ? ToastQueue.staleReply : ToastQueue.stalePassive)
        }
    }

    /// Takes the waiting toasts that match out of the queue, each handed to `onGone`.
    private func remove(where match: (Entry) -> Bool) {
        let gone = waiting.filter(match)
        guard !gone.isEmpty else { return }
        waiting.removeAll(where: match)
        gone.forEach { onGone?($0) }
    }

    @discardableResult
    private func next(now: Double, canShow: (Entry) -> Bool) -> Bool {
        guard let i = pick(canShow) else { return false }
        var e = waiting.remove(at: i)
        e.shown = 0
        current = e
        // a reply going up supersedes the plain replies before it that could have gone up instead (one held back by
        // `canShow` — the open island — still waits its turn)
        if e.kind == .reply { remove { $0.supersedable && $0.order < e.order && canShow($0) } }
        return true
    }
}
