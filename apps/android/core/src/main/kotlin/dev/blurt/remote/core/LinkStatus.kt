// What the pad says about the connection, worked out apart from the views so it can be tested, and so both phones say the same thing in the
// same order (iOS: apps/ios/BlurtRemote/Model/LinkStatus.swift, the same table). docs/design/remote.md §Connection, "What the pad says".
//
// The rule: connected and working, the pad says nothing (the computer's name, small, in its corner). In every other state one card in the
// middle of the pad says it at reading size: a mark, a strong line that names the state, at most one line with the one thing to do, and at
// most one button for it.
package dev.blurt.remote.core

enum class LinkPhase { UNPAIRED, CONNECTING, UNREACHABLE, CONNECTED, FORGOTTEN, REPLACED, ENDED }

/** The connection as the pad needs to know it. Nothing here comes from the wire that Link doesn't already publish. */
data class LinkStatus(
    val phase: LinkPhase,
    /** a session was up and went while the app was in use: it's coming back, not starting (StatusFollower) */
    val dropped: Boolean = false,
    /** the computer in hand has a relay: it can be anywhere, so "the same network" isn't the thing to check */
    val hasRelay: Boolean = false,
    /** more than one computer is paired: there's another to try */
    val otherComputers: Boolean = false,
    val canControl: Boolean = true,
    /** "permission", "off": why the computer won't show its screen; anything else, the picture stopped */
    val screenError: String? = null,
    /** the user asked for the picture (the screen button); one that came on by itself says nothing when the computer won't show it */
    val screenAsked: Boolean = true,
    /** the picture is showing */
    val showing: Boolean = false,
    /** the computer's screen is locked, and it can't show that */
    val locked: Boolean = false,
    /** on the public connection service, the direct path isn't open yet: nothing is carried until it is */
    val meeting: Boolean = false,
    /** this phone has no network at all */
    val offline: Boolean = false,
    /** what the computer's relay says of it while it can't be reached */
    val presence: Presence? = null,
    /** the computer is asking its owner about this phone's code */
    val waiting: Boolean = false,
    /** a pairing just didn't take; Link has the sentences */
    val pairFailed: Boolean = false,
    /** the code that didn't take can still work (it couldn't be reached, and is still being tried): Try Again */
    val pairRetry: Boolean = false,
    /** why away doesn't work through Blurt's go-between; said once nothing else has answered (remote-go-between.md §What each end shows) */
    val away: AwayTrouble? = null,
)

/**
 * How a pairing ended without a key. The computer never says why (a refused handshake, or a bare close), so it's read from when, as the Mac
 * viewer does (docs/design/remote-desktop-viewer.md). iOS: Link.swift `PairFailure.Why`.
 */
enum class PairEnd {
    /** refused before anyone was asked: the code ran out or was used already */
    SPENT,
    /** the question was asked and the computer let go: its owner said no */
    DECLINED,
    /** closed at 90 % of the computer's two-minute question or later: nobody answered */
    UNANSWERED,
    /** the app went to the background while the computer was asking: the code is spent */
    LEFT,
    /** nothing answered; still trying, and the digits take this one's place as soon as the computer asks */
    UNREACHABLE;

    val canRetry: Boolean get() = this == UNREACHABLE

    companion object {
        /** how long a computer asks its owner about a new device before it takes the silence as a no (the hosts' pairing life) */
        const val QUESTION_LIFE_MS = 120_000L

        /** `askedAt`: when the computer began asking (null: it never did). */
        fun of(askedAt: Long?, now: Long): PairEnd = when {
            askedAt == null -> SPENT
            now - askedAt >= QUESTION_LIFE_MS * 9 / 10 -> UNANSWERED
            else -> DECLINED
        }
    }
}

/** What a relay says of a computer that isn't waiting there (RemotePresence): it said it was going to sleep, or it was last seen then. */
enum class Presence { ASLEEP, LAST_ONLINE }

/** What Blurt's go-between couldn't do */
enum class AwayTrouble {
    /** the direct path didn't open on this network (`noDirect`, or close code 4003): a relay of the owner's own fixes it */
    NO_DIRECT,
    /** out of today's free quota, or rate-limited */
    BUSY,
    /** the computer's own relay doesn't answer; the public connection service is tried meanwhile (2026-11-20, the office) */
    RELAY_DOWN,
}

/** what's drawn beside the words: a state is never told by colour alone */
enum class StatusMark { BUSY, PROBLEM, PHONE, CODE }

enum class StatusLine {
    CONNECTING, RECONNECTING,
    /** met on the public connection service; the direct path is being opened */
    CONNECTING_DIRECT,
    NO_NETWORK, TURN_ON_NETWORK,
    CANT_REACH, CHECK_NETWORK, CHECK_AWAKE,
    /** since when, or when it was last there: from its relay (the time is in the words) */
    ASLEEP_SINCE, LAST_ONLINE,
    NEEDS_PAIRING, FORGOTTEN,
    OTHER_PHONE,
    ENDED_THERE,
    PAIR_FIRST, WHERE_THE_CODE_IS,
    WAITING, ALLOW_ON_COMPUTER,
    PAIRING_FAILED, WHY_PAIRING_FAILED,
    CANT_CONTROL, HOW_TO_ALLOW_CONTROL,
    CANT_SHOW_SCREEN, ALLOW_SCREEN, SCREEN_IS_OFF, PICTURE_STOPPED,
    LOCKED, UNLOCK_FIRST,
    NO_DIRECT, GO_BETWEEN_BUSY, RELAY_DOWN,
}

enum class StatusAction { RETRY, SCAN, ANOTHER, TAKE_OVER, RECONNECT, DISMISS }

data class StatusBanner(
    val mark: StatusMark,
    val title: StatusLine,
    val detail: StatusLine? = null,
    val action: StatusAction? = null,
    val second: StatusAction? = null,
) {
    companion object {
        /** null: connected and working, nothing to say. */
        fun of(s: LinkStatus): StatusBanner? {
            val away = s.phase == LinkPhase.CONNECTING || s.phase == LinkPhase.UNREACHABLE
            val b: StatusBanner? = if (away && s.offline) StatusBanner(StatusMark.PROBLEM, StatusLine.NO_NETWORK, StatusLine.TURN_ON_NETWORK)
            else when (s.phase) {
                LinkPhase.UNPAIRED -> StatusBanner(StatusMark.CODE, StatusLine.PAIR_FIRST, StatusLine.WHERE_THE_CODE_IS, StatusAction.SCAN)
                LinkPhase.CONNECTING -> StatusBanner(StatusMark.BUSY, when {
                    s.meeting -> StatusLine.CONNECTING_DIRECT
                    s.dropped -> StatusLine.RECONNECTING
                    else -> StatusLine.CONNECTING
                })
                LinkPhase.UNREACHABLE -> StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_REACH, when (s.away) {
                    // the go-between said why it can't carry this: once nothing else has answered either, that's the one thing to say
                    AwayTrouble.NO_DIRECT -> StatusLine.NO_DIRECT
                    AwayTrouble.BUSY -> StatusLine.GO_BETWEEN_BUSY
                    AwayTrouble.RELAY_DOWN -> StatusLine.RELAY_DOWN
                    null -> when (s.presence) {
                        Presence.ASLEEP -> StatusLine.ASLEEP_SINCE
                        Presence.LAST_ONLINE -> StatusLine.LAST_ONLINE
                        null -> if (s.hasRelay) StatusLine.CHECK_AWAKE else StatusLine.CHECK_NETWORK
                    }
                }, StatusAction.RETRY, if (s.otherComputers) StatusAction.ANOTHER else null)
                LinkPhase.FORGOTTEN -> StatusBanner(StatusMark.PROBLEM, StatusLine.NEEDS_PAIRING, StatusLine.FORGOTTEN, StatusAction.SCAN)
                // a button, not any touch: a phone in a pocket, or a screen being wiped, mustn't take the computer from whoever has it
                LinkPhase.REPLACED -> StatusBanner(StatusMark.PHONE, StatusLine.OTHER_PHONE, action = StatusAction.TAKE_OVER)
                LinkPhase.ENDED -> StatusBanner(StatusMark.PHONE, StatusLine.ENDED_THERE, action = StatusAction.RECONNECT)
                LinkPhase.CONNECTED -> when {
                    // locked: why there's no picture, and why it may not take input either
                    s.locked && s.showing -> StatusBanner(StatusMark.PROBLEM, StatusLine.LOCKED, StatusLine.UNLOCK_FIRST)
                    s.screenAsked && s.screenError != null -> StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_SHOW_SCREEN, when (s.screenError) {
                        "off" -> StatusLine.SCREEN_IS_OFF
                        "permission" -> StatusLine.ALLOW_SCREEN
                        else -> StatusLine.PICTURE_STOPPED
                    })
                    !s.canControl -> StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_CONTROL, StatusLine.HOW_TO_ALLOW_CONTROL)
                    else -> null
                }
            }
            // a pairing under way is what the user is looking at: it's said over whatever the computer in hand is doing. The digits win:
            // once the computer asks, whatever went wrong before is past
            if (s.waiting) return StatusBanner(StatusMark.BUSY, StatusLine.WAITING, StatusLine.ALLOW_ON_COMPUTER)
            if (s.pairFailed) {
                // never a dead end: the same code once more where it can still work, else a new one
                return if (s.pairRetry) StatusBanner(StatusMark.PROBLEM, StatusLine.PAIRING_FAILED, StatusLine.WHY_PAIRING_FAILED, StatusAction.RETRY, StatusAction.SCAN)
                // it stays until it's read: a tap on OK, or the next pairing
                else StatusBanner(StatusMark.PROBLEM, StatusLine.PAIRING_FAILED, StatusLine.WHY_PAIRING_FAILED, StatusAction.SCAN, StatusAction.DISMISS)
            }
            return b
        }
    }
}

/** What the thumb should feel, and TalkBack say, when the connection goes and comes back while the phone is in use. */
enum class StatusCue { DROPPED, BACK }

/**
 * Follows the phases, to tell a drop from a first connection. Opening the app, coming back to it and choosing another computer are all
 * first connections: only a session that went while the app was in front is a drop.
 */
class StatusFollower {
    var dropped = false
        private set
    private var last: LinkPhase? = null
    private var computer: String? = null

    /** `computer`: the id of the one in hand. `inUse`: the app is in front. */
    fun see(p: LinkPhase, computer: String?, inUse: Boolean): StatusCue? {
        val was = last
        val same = computer == this.computer
        last = p
        this.computer = computer
        if (!inUse || !same) { dropped = false; return null }
        val away = p == LinkPhase.CONNECTING || p == LinkPhase.UNREACHABLE
        if (was == LinkPhase.CONNECTED && away) {
            dropped = true
            return StatusCue.DROPPED
        }
        if (p == LinkPhase.CONNECTED && dropped) {
            dropped = false
            return StatusCue.BACK
        }
        // forgotten, taken by another phone: no longer a drop that's coming back
        if (!away) dropped = false
        return null
    }
}
