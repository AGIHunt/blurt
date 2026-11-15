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
        assertEquals(StatusBanner(StatusMark.PHONE, StatusLine.OTHER_PHONE, StatusLine.TOUCH_TO_TAKE_OVER), banner(LinkStatus(LinkPhase.REPLACED)))
    }

    @Test fun aPairingUnderWayIsSaidOverTheRest() {
        for (p in listOf(LinkPhase.UNPAIRED, LinkPhase.CONNECTING, LinkPhase.UNREACHABLE, LinkPhase.CONNECTED)) {
            assertEquals(StatusBanner(StatusMark.BUSY, StatusLine.WAITING, StatusLine.ALLOW_ON_COMPUTER), banner(LinkStatus(p, waiting = true)), "$p")
        }
        // one that didn't take: why, and what there was to do is still there to do
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.PAIRING_FAILED, StatusLine.WHY_PAIRING_FAILED, StatusAction.SCAN),
            banner(LinkStatus(LinkPhase.UNPAIRED, pairFailed = true)))
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.PAIRING_FAILED, StatusLine.WHY_PAIRING_FAILED), banner(LinkStatus(LinkPhase.CONNECTING, pairFailed = true)))
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.PAIRING_FAILED, StatusLine.WHY_PAIRING_FAILED, StatusAction.RETRY, StatusAction.ANOTHER),
            banner(LinkStatus(LinkPhase.UNREACHABLE, pairFailed = true, otherComputers = true)))
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
        // a button never without the line that says what it's for
        for (p in LinkPhase.entries) for (relay in listOf(false, true)) for (others in listOf(false, true)) {
            val b = banner(LinkStatus(p, hasRelay = relay, otherComputers = others)) ?: continue
            if (b.action != null) assertNotNull(b.detail, "$p")
            if (b.second != null) assertNotNull(b.action, "$p")
        }
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
