// When a double tap may press Return (v1.0.6, the founder: a double tap with nothing dictated before it pressed
// Return in whatever app was in front — "这时候不应该有回车"). Return is the send of a dictation: it goes out only
// for a take still on its way (sent once it has been pasted), or right after a take was typed into the app that is
// still in front. Otherwise the double tap does nothing (the dictation its first tap started is cancelled as before).
// Pure: DictationSendRuleTests.
import Foundation

public enum DictationSendRule {
    /// How long after a paste a double tap still sends it.
    public static let window: TimeInterval = 60

    public enum Verdict: String { case send, queue, noTake }

    /// `pending`: takes still on their way; `lastPaste`: when (seconds, same clock as `now`) and into which app the
    /// last take was typed; `front`: the app in front now.
    public static func decide(pending: Bool, lastPaste: (at: Double, bundle: String?)?, front: String?, now: Double) -> Verdict {
        if pending { return .queue }
        guard let p = lastPaste, now - p.at <= window, p.bundle == front else { return .noTake }
        return .send
    }
}
