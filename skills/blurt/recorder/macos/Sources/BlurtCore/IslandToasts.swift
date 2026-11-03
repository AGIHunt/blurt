// What the island says, and for how long it stays true (BlurtApp Capture/Island/Island.swift shows the toasts, BlurtCore
// ToastQueue orders them; Capture/Dictation and Capture/Island/IslandContent.swift post these).
//
//  • dictation's toasts end with what they describe (DictationToastKeys). A new take drops what was said about the
//    last one — its Undo, "copied", the tip after it (`tip`), "still listening" and the 5-minute limit
//    (`listening`), "still recognizing" (`slow`) — so the island never says "Stopped at the 5-minute limit" over a
//    take that listens. A take that stops listening drops ⇧'s style line ("Structured · ⇧ to go back"): ⇧ does nothing once it has stopped. A failed
//    take's Retry, "Cancelled · Undo", the model's Download… and the once-a-day notices with a button ("No polish
//    model yet · Download…": `notice`) stay (their own keys): they are still true, and a notice dropped before it
//    showed wouldn't come back until tomorrow.
//  • a double tap whose text could only be copied (DictationDeliveredLine, DictationTakeFlow.swift): one line that
//    says both — copied, and not sent — instead of "Not sent" replaced in the same frame by "Copied — paste with ⌘V".
//    A plain copy carries the ok check like every other done line.
//  • discarding a recording (RecordingDiscard.swift): the question names what goes with it — its snaps, as the
//    island counts them.
//  • a card's name where its words can't stand in (CardName): its first line, else what it is and when ("Snap ·
//    19:03", in the user's 12/24-hour clock; "Snap · Yesterday 19:03" once it isn't today's), never a session
//    counter ("Screenshot 15" skipped numbers and told cards apart by nothing).
import Foundation

public enum DictationToastKeys {
    /// what the island says about the last take: reformat's Undo, the list chip, "nothing heard", "copied"
    public static let take = "dictation"
    /// ⇧'s style line while a take listens
    public static let style = "dictation.style"
    /// once-a-day notices with a button ("No polish model yet · Download…", "a weaker speech model ran · Get…")
    public static let notice = "dictation.notice"
    /// the first takes' tips ("Double-tap ⌥ to send"): about the take just done
    public static let tip = "dictation.tip"
    /// "still listening" and the 5-minute limit
    public static let listening = "dictation.listening"
    /// "Still recognizing… Esc to cancel": up while a slow take is on its way, gone when it lands or is cancelled
    public static let slow = "dictation.slow"
    /// "Cancelled · Undo"
    public static let cancel = "dictation.cancel"
    /// "no speech model · Download…" / "the model is ready · Retry"
    public static let model = "dictation.model"
    /// "Typeless also uses Fn · Use Right Option" (once a day per app; said after a listening take, never over it)
    public static let fnClash = "dictation.fn_clash"
    /// "Dictation deleted · Undo" (the Dictation page's Delete, said at the notch too)
    public static let historyDeleted = "dictation.history_deleted"

    /// Dropped when a new take starts: everything about the last take, and the tip it ended with (not the
    /// once-a-day notices: the day's slot is spent when they are posted, so dropped they wouldn't come back).
    public static let droppedAtStart = [take, tip, listening, slow]
    /// Dropped when a take stops listening (stopped, cancelled, or ended by itself): ⇧ means nothing after that.
    public static let droppedWhenListeningEnds = [style]
}

public enum CardName {
    /// "Snap · 19:03" names a card taken today; an older one (cards hang until they are used) says its day too —
    /// "Snap · Yesterday 19:03" — or two cards from different days read the same.
    public static func showsDay(taken: Date, now: Date, calendar: Calendar = .current) -> Bool {
        !calendar.isDate(taken, inSameDayAs: now)
    }

    /// When a card was taken, in `locale` (the app's language with the user's region) and the user's clock
    /// (`uses24Hour`, System Settings' choice — a locale built from identifiers doesn't carry it): "19:03" / "7:03 PM"
    /// today, else with its day: "Yesterday 19:03", "Oct 22, 2026 19:03" (zh: "昨天 19:03").
    public static func when(taken: Date, now: Date, locale: Locale, uses24Hour: Bool, calendar: Calendar = .current) -> String {
        let time = formatter(locale, calendar, day: false, h24: uses24Hour).string(from: taken)
        guard showsDay(taken: taken, now: now, calendar: calendar) else { return time }
        return formatter(locale, calendar, day: true, h24: uses24Hour).string(from: taken) + " " + time
    }

    // (made once per language, region, time zone and clock: a card's name is asked for on every accessibility read)
    private static var formatters: [String: DateFormatter] = [:]
    private static let lock = NSLock()
    private static func formatter(_ locale: Locale, _ calendar: Calendar, day: Bool, h24: Bool) -> DateFormatter {
        let key = "\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(day)|\(h24)"
        lock.lock(); defer { lock.unlock() }
        if let f = formatters[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if day {
            f.dateStyle = .medium
            f.timeStyle = .none
            f.doesRelativeDateFormatting = true
        } else {
            f.setLocalizedDateFormatFromTemplate(h24 ? "Hmm" : "hmm")
        }
        formatters[key] = f
        return f
    }

    /// The user's clock: 24 hours or 12 (System Settings ▸ General ▸ Date & Time), read from the system's locale.
    public static var systemUses24Hour: Bool {
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "H").contains("H")
    }

    /// The longest a name runs before it ends in "…".
    public static let maxLength = 60

    /// A card's name: the first line of its words, cut at `maxLength`; nil when it has none (the caller says what it
    /// is and when instead: "Snap · 19:03").
    public static func words(_ w: String?) -> String? {
        guard let first = w?.split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !first.isEmpty else { return nil }
        return first.count > maxLength ? String(first.prefix(maxLength - 1)) + "…" : first
    }
}
