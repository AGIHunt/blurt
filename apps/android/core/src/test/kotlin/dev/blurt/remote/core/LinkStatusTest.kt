// What the pad says for each state of the connection (LinkStatus.kt; docs/design/remote.md §Connection, "What the pad says").
// The same cases as apps/ios/BlurtRemoteTests/LinkStatusTests.swift: the two phones say the same thing.
package dev.blurt.remote.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LinkStatusTest {
    private fun banner(s: LinkStatus) = StatusBanner.of(s)

    @Test fun connectedAndWorkingSaysNothing() {
        assertNull(banner(LinkStatus(LinkPhase.CONNECTED)))
        assertNull(banner(LinkStatus(LinkPhase.CONNECTED, dropped = true, hasRelay = true, otherComputers = true)))
    }

    @Test fun connectingShowsItIsBusyAndNeedsNothing() {
        assertEquals(StatusBanner(StatusMark.BUSY, StatusLine.CONNECTING), banner(LinkStatus(LinkPhase.CONNECTING)))
        // a session that went while in use is coming back, and says so
        assertEquals(StatusBanner(StatusMark.BUSY, StatusLine.RECONNECTING), banner(LinkStatus(LinkPhase.CONNECTING, dropped = true)))
    }

    @Test fun cantReachSaysTheOneThingToCheckAndOffersRetry() {
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_REACH, StatusLine.CHECK_NETWORK, StatusAction.RETRY), banner(LinkStatus(LinkPhase.UNREACHABLE)))
        // with a relay the computer can be anywhere: the network isn't the thing to check
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_REACH, StatusLine.CHECK_AWAKE, StatusAction.RETRY),
            banner(LinkStatus(LinkPhase.UNREACHABLE, hasRelay = true)))
        // another computer to try is the second thing, never the first
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_REACH, StatusLine.CHECK_NETWORK, StatusAction.RETRY, StatusAction.ANOTHER),
            banner(LinkStatus(LinkPhase.UNREACHABLE, otherComputers = true)))
    }

    @Test fun pairingStates() {
        assertEquals(StatusBanner(StatusMark.CODE, StatusLine.PAIR_FIRST, StatusLine.WHERE_THE_CODE_IS, StatusAction.SCAN), banner(LinkStatus(LinkPhase.UNPAIRED)))
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.NEEDS_PAIRING, StatusLine.FORGOTTEN, StatusAction.SCAN), banner(LinkStatus(LinkPhase.FORGOTTEN)))
        assertEquals(StatusBanner(StatusMark.PHONE, StatusLine.OTHER_PHONE, action = StatusAction.TAKE_OVER), banner(LinkStatus(LinkPhase.REPLACED)))
        assertEquals(StatusBanner(StatusMark.PHONE, StatusLine.ENDED_THERE, action = StatusAction.RECONNECT), banner(LinkStatus(LinkPhase.ENDED)))
    }

    @Test fun aPairingUnderWayIsSaidOverTheRest() {
        for (p in listOf(LinkPhase.UNPAIRED, LinkPhase.CONNECTING, LinkPhase.UNREACHABLE, LinkPhase.CONNECTED)) {
            assertEquals(StatusBanner(StatusMark.BUSY, StatusLine.WAITING, StatusLine.ALLOW_ON_COMPUTER), banner(LinkStatus(p, waiting = true)), "$p")
        }
        // one that didn't take: why, until it's read (OK), and never a dead end: a new code
        val failed = StatusBanner(StatusMark.PROBLEM, StatusLine.PAIRING_FAILED, StatusLine.WHY_PAIRING_FAILED, StatusAction.SCAN, StatusAction.DISMISS)
        assertEquals(failed, banner(LinkStatus(LinkPhase.UNPAIRED, pairFailed = true)))
        assertEquals(failed, banner(LinkStatus(LinkPhase.CONNECTING, pairFailed = true)))
        assertEquals(failed, banner(LinkStatus(LinkPhase.CONNECTED, pairFailed = true)))
        assertEquals(failed, banner(LinkStatus(LinkPhase.UNREACHABLE, pairFailed = true, otherComputers = true)))
        // a code that can't be reached is still being tried: the same code again first, a new one second
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.PAIRING_FAILED, StatusLine.WHY_PAIRING_FAILED, StatusAction.RETRY, StatusAction.SCAN),
            banner(LinkStatus(LinkPhase.UNREACHABLE, pairFailed = true, pairRetry = true)))
        // once the computer asks, its digits take the failure's place, so they can be compared
        assertEquals(StatusBanner(StatusMark.BUSY, StatusLine.WAITING, StatusLine.ALLOW_ON_COMPUTER),
            banner(LinkStatus(LinkPhase.UNREACHABLE, pairFailed = true, pairRetry = true, waiting = true)))
    }

    /** Why a pairing ended is read from when, as the Mac viewer does: a spent code is not "didn't allow", and no answer is not a no. */
    @Test fun whyAPairingEnded() {
        val t = 1_000_000L
        assertEquals(PairEnd.SPENT, PairEnd.of(null, t))
        assertEquals(PairEnd.DECLINED, PairEnd.of(t - 5_000, t))
        assertEquals(PairEnd.DECLINED, PairEnd.of(t - 107_000, t))
        assertEquals(PairEnd.UNANSWERED, PairEnd.of(t - 108_000, t))
        assertEquals(PairEnd.UNANSWERED, PairEnd.of(t - 121_000, t))
        assertEquals(listOf(PairEnd.UNREACHABLE), PairEnd.entries.filter { it.canRetry })
    }

    @Test fun connectedButNotWorking() {
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_CONTROL, StatusLine.HOW_TO_ALLOW_CONTROL), banner(LinkStatus(LinkPhase.CONNECTED, canControl = false)))
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_SHOW_SCREEN, StatusLine.ALLOW_SCREEN), banner(LinkStatus(LinkPhase.CONNECTED, screenError = "permission")))
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_SHOW_SCREEN, StatusLine.SCREEN_IS_OFF), banner(LinkStatus(LinkPhase.CONNECTED, screenError = "off")))
        // the screen was just asked for: that's the one said
        assertEquals(StatusLine.SCREEN_IS_OFF, banner(LinkStatus(LinkPhase.CONNECTED, canControl = false, screenError = "off"))?.detail)
        // not connected, neither matters
        assertEquals(StatusBanner(StatusMark.BUSY, StatusLine.CONNECTING), banner(LinkStatus(LinkPhase.CONNECTING, canControl = false, screenError = "off")))
    }

    @Test fun everyStateButConnectedSaysSomething() {
        for (p in LinkPhase.entries) if (p != LinkPhase.CONNECTED) assertNotNull(banner(LinkStatus(p)), "$p")
        for (p in LinkPhase.entries) for (relay in listOf(false, true)) for (others in listOf(false, true)) {
            val b = banner(LinkStatus(p, hasRelay = relay, otherComputers = others)) ?: continue
            // a button never without the line that says what it's for, but where the title and the button say it all
            if (b.action != null && p != LinkPhase.REPLACED && p != LinkPhase.ENDED) assertNotNull(b.detail, "$p")
            if (b.second != null) assertNotNull(b.action, "$p")
        }
    }

    /** Met on the public connection service: not connected until everything goes direct, and it says that's what it's doing. */
    @Test fun connectingDirectly() {
        val direct = StatusBanner(StatusMark.BUSY, StatusLine.CONNECTING_DIRECT)
        assertEquals(direct, banner(LinkStatus(LinkPhase.CONNECTING, hasRelay = true, meeting = true)))
        assertEquals(direct, banner(LinkStatus(LinkPhase.CONNECTING, dropped = true, meeting = true)))
        assertNull(banner(LinkStatus(LinkPhase.CONNECTED, meeting = false)))
    }

    @Test fun noNetworkIsTheFirstThingToSay() {
        val none = StatusBanner(StatusMark.PROBLEM, StatusLine.NO_NETWORK, StatusLine.TURN_ON_NETWORK)
        assertEquals(none, banner(LinkStatus(LinkPhase.CONNECTING, offline = true)))
        assertEquals(none, banner(LinkStatus(LinkPhase.CONNECTING, dropped = true, offline = true)))
        assertEquals(none, banner(LinkStatus(LinkPhase.UNREACHABLE, offline = true, otherComputers = true, away = AwayTrouble.NO_DIRECT, presence = Presence.ASLEEP)))
        // a pairing under way is still what the user is looking at; the rest has nothing to do with it
        assertEquals(StatusLine.WAITING, banner(LinkStatus(LinkPhase.CONNECTING, offline = true, waiting = true))?.title)
        assertNull(banner(LinkStatus(LinkPhase.CONNECTED, offline = true)))
        assertEquals(StatusLine.OTHER_PHONE, banner(LinkStatus(LinkPhase.REPLACED, offline = true))?.title)
    }

    @Test fun whatItsRelaySaysOfIt() {
        val p = LinkStatus(LinkPhase.UNREACHABLE, hasRelay = true)
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_REACH, StatusLine.ASLEEP_SINCE, StatusAction.RETRY), banner(p.copy(presence = Presence.ASLEEP)))
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_REACH, StatusLine.LAST_ONLINE, StatusAction.RETRY, StatusAction.ANOTHER),
            banner(p.copy(presence = Presence.LAST_ONLINE, otherComputers = true)))
        assertEquals(StatusLine.CHECK_AWAKE, banner(p)?.detail)
        // why the public connection service can't carry it comes first
        assertEquals(StatusLine.NO_DIRECT, banner(p.copy(presence = Presence.ASLEEP, away = AwayTrouble.NO_DIRECT))?.detail)
        assertEquals(StatusLine.GO_BETWEEN_BUSY, banner(p.copy(presence = Presence.ASLEEP, away = AwayTrouble.BUSY))?.detail)
        assertEquals(StatusLine.CONNECTING, banner(LinkStatus(LinkPhase.CONNECTING, presence = Presence.ASLEEP))?.title)
    }

    @Test fun whatARelaysAnswerMeans() {
        val asleep = RemotePresence.parse("""{"host":false,"asleep":1795631850383,"seen":1795631850000}""")
        assertEquals(RemotePresence(false, 1795631850383, 1795631850000), asleep)
        assertEquals(Presence.ASLEEP, asleep?.says)
        assertEquals(1795631850383, asleep?.since)
        val seen = RemotePresence.parse("""{"host":false,"seen":1795631850000,"asleep":null}""")
        assertEquals(Presence.LAST_ONLINE, seen?.says)
        assertEquals(1795631850000, seen?.since)
        // waiting there now, or never seen: the plain line
        assertNull(RemotePresence.parse("""{"host":true,"asleep":1795631850383}""")?.says)
        assertNull(RemotePresence.parse("""{"host":false}""")?.says)
        for (b in listOf("", "blurt relay", "[]", "{}", """{"host":"yes"}""", """{"host":1}""")) assertNull(RemotePresence.parse(b), b)
        assertEquals("https://relay.example.com/secret/v1/room/peek", RemoteRelay.peekURL("relay.example.com/secret/", "room"))
        assertEquals("http://10.0.0.2:8787/v1/room/peek", RemoteRelay.peekURL("ws://10.0.0.2:8787", "room"))
        assertNull(RemoteRelay.peekURL("http://x", "room"))
    }

    @Test fun lockedIsSaidWhileThePictureShows() {
        val locked = StatusBanner(StatusMark.PROBLEM, StatusLine.LOCKED, StatusLine.UNLOCK_FIRST)
        assertEquals(locked, banner(LinkStatus(LinkPhase.CONNECTED, locked = true, showing = true)))
        assertEquals(locked, banner(LinkStatus(LinkPhase.CONNECTED, locked = true, showing = true, canControl = false)))
        assertNull(banner(LinkStatus(LinkPhase.CONNECTED, locked = true)), "a trackpad and keys have nothing to show")
        assertEquals(StatusLine.CONNECTING, banner(LinkStatus(LinkPhase.CONNECTING, locked = true, showing = true))?.title)
    }

    @Test fun aPictureThatStoppedIsSaid() {
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_SHOW_SCREEN, StatusLine.PICTURE_STOPPED, StatusAction.SHOW_SCREEN),
            banner(LinkStatus(LinkPhase.CONNECTED, screenError = "The display went to sleep.")))
        // the picture that came on by itself and was refused: a trackpad, and nothing said
        for (e in listOf("off", "permission")) assertNull(banner(LinkStatus(LinkPhase.CONNECTED, screenError = e, screenAsked = false)), e)
        assertEquals(StatusLine.CANT_CONTROL, banner(LinkStatus(LinkPhase.CONNECTED, screenError = "off", screenAsked = false, canControl = false))?.title)
    }

    // MARK: a drop, and coming back

    @Test fun aDropInUseIsFeltAndSoIsComingBack() {
        val f = StatusFollower()
        assertNull(f.see(LinkPhase.CONNECTING, "a", true))
        assertNull(f.see(LinkPhase.CONNECTED, "a", true), "a first connection is no news to the thumb")
        assertEquals(StatusCue.DROPPED, f.see(LinkPhase.CONNECTING, "a", true))
        assertTrue(f.dropped)
        assertNull(f.see(LinkPhase.CONNECTING, "a", true), "once")
        assertNull(f.see(LinkPhase.UNREACHABLE, "a", true))
        assertTrue(f.dropped, "still the same drop")
        assertNull(f.see(LinkPhase.CONNECTING, "a", true), "Retry")
        assertEquals(StatusCue.BACK, f.see(LinkPhase.CONNECTED, "a", true))
        assertFalse(f.dropped)
        assertNull(f.see(LinkPhase.CONNECTED, "a", true))
    }

    @Test fun leavingTheAppOrChoosingAnotherComputerIsNoDrop() {
        val f = StatusFollower()
        f.see(LinkPhase.CONNECTED, "a", true)
        // the app went to the background: Link lets go and will connect again
        assertNull(f.see(LinkPhase.CONNECTING, "a", false))
        assertFalse(f.dropped)
        assertNull(f.see(LinkPhase.CONNECTING, "a", true))
        assertNull(f.see(LinkPhase.CONNECTED, "a", true))
        // another computer chosen: a first connection to it
        assertNull(f.see(LinkPhase.CONNECTING, "b", true))
        assertFalse(f.dropped)
        assertNull(f.see(LinkPhase.CONNECTED, "b", true))
    }

    @Test fun aDropThatEndsElsewhereIsNotComingBack() {
        val f = StatusFollower()
        f.see(LinkPhase.CONNECTED, "a", true)
        assertEquals(StatusCue.DROPPED, f.see(LinkPhase.CONNECTING, "a", true))
        assertNull(f.see(LinkPhase.FORGOTTEN, "a", true))
        assertFalse(f.dropped)
        assertNull(f.see(LinkPhase.CONNECTING, "a", true))
        assertNull(f.see(LinkPhase.CONNECTED, "a", true), "paired again: a first connection")
    }
}
