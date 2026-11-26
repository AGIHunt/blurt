// What the phone decides on Blurt's public relay (PublicRelay.kt; docs/design/remote-go-between.md §The public relay): where `noDirect`
// sends it, which voice it sends, whether a file may go.
package dev.blurt.remote.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PublicRelayTest {
    private val room = "guZRlWLF0yQX0I21ZnxtHFAtfVV5pDTmSepPGKS3c8w"
    private val ticket = "1764000060.vSDxp8K1xSfY.Zd8TTbFbCLl3pNcSNSWE0A"
    private val ours = ToPhone.PublicRelay("wss://relay.blurt.work", room, ticket)

    @Test fun onlyBlurtsRelayOrTheTestBuildsOwn() {
        assertTrue(RemotePublicRelay.allowed("wss://relay.blurt.work"))
        assertFalse(RemotePublicRelay.allowed("wss://relay.example.com"))
        assertFalse(RemotePublicRelay.allowed("ws://relay.blurt.work"), "wss only")
        assertFalse(RemotePublicRelay.allowed("ws://10.0.2.2:8790"))
        assertTrue(RemotePublicRelay.allowed("ws://10.0.2.2:8790", testing = "ws://10.0.2.2:8790"))
        assertTrue(RemotePublicRelay.allowed("wss://relay.blurt.work", testing = "ws://10.0.2.2:8790"))
    }

    @Test fun aRoomOrTicketThatCantBeOneMakesNoURL() {
        assertEquals("wss://relay.blurt.work/v1/$room/phone?t=$ticket", RemotePublicRelay.url(ours.address, room, "phone", ticket))
        assertNull(RemotePublicRelay.url(ours.address, "short", "phone", ticket))
        assertNull(RemotePublicRelay.url(ours.address, room, "phone", "$ticket&x=1"))
        assertNull(RemotePublicRelay.url(ours.address, room.dropLast(1) + "/", "phone", ticket))
    }

    @Test fun noDirectGoesThereOnlyRightAfterAnAllowedOffer() {
        val o = PublicRelayOffer()
        assertNull(o.take(1000), "nothing offered: the no-direct line")
        assertTrue(o.heard(ours, 1000))
        assertEquals(ours, o.take(1000 + RemotePublicRelay.FRESH_MS))
        assertNull(o.take(1000 + RemotePublicRelay.FRESH_MS), "taken once: no loop")
        o.heard(ours, 1000)
        assertNull(o.take(1001 + RemotePublicRelay.FRESH_MS), "older than 10 s")
        assertFalse(o.heard(ours.copy(address = "wss://evil.example"), 2000))
        assertNull(o.take(2000), "an address this phone doesn't go to is dropped")
        val local = ours.copy(address = "ws://10.0.2.2:8790")
        assertFalse(o.heard(local, 3000))
        assertTrue(o.heard(local, 3000, testing = "ws://10.0.2.2:8790"))
        assertEquals(local, o.take(3500))
        o.heard(ours, 4000)
        o.clear()
        assertNull(o.take(4000), "a new session forgets it")
    }

    @Test fun theVoiceOnEachPath() {
        assertEquals(VoiceWay.PCM, VoiceWay.of(publicRelay = false, phoneOpus = false, hostFeatures = null))
        assertEquals(VoiceWay.PCM, VoiceWay.of(publicRelay = false, phoneOpus = true, hostFeatures = listOf(RemoteFeature.OPUS)))
        assertEquals(VoiceWay.OPUS, VoiceWay.of(publicRelay = true, phoneOpus = true, hostFeatures = listOf(RemoteFeature.PUBLIC_RELAY, RemoteFeature.OPUS)))
        // never PCM on the public relay
        assertEquals(VoiceWay.HOST_CANT, VoiceWay.of(publicRelay = true, phoneOpus = true, hostFeatures = listOf(RemoteFeature.PUBLIC_RELAY)))
        assertEquals(VoiceWay.HOST_CANT, VoiceWay.of(publicRelay = true, phoneOpus = true, hostFeatures = null))
        assertEquals(VoiceWay.PHONE_CANT, VoiceWay.of(publicRelay = true, phoneOpus = false, hostFeatures = listOf(RemoteFeature.OPUS)))
        // no Opus here: the phone's microphone line, not an update the computer can't help with
        assertEquals(VoiceWay.PHONE_CANT, VoiceWay.of(publicRelay = true, phoneOpus = false, hostFeatures = listOf(RemoteFeature.PUBLIC_RELAY)))
        assertTrue(VoiceWay.OPUS.carries)
        assertFalse(VoiceWay.HOST_CANT.carries)
        assertFalse(VoiceWay.PHONE_CANT.carries)
    }

    @Test fun fiftyMBADayAndAQuestionOverTwenty() {
        val day = 20_418L * 86_400_000L      // 2025-11-26 00:00 UTC
        val f = PublicRelayFiles()
        assertEquals(PublicRelayFiles.Gate.GO, f.gate(20_000_000, day))
        assertEquals(PublicRelayFiles.Gate.ASK, f.gate(20_000_001, day))
        assertEquals(PublicRelayFiles.Gate.ASK, f.gate(35_000_000, day))
        assertEquals(PublicRelayFiles.Gate.ASK, f.gate(50_000_000, day))
        assertEquals(PublicRelayFiles.Gate.OVER, f.gate(50_000_001, day))
        f.count(35_000_000, day + 1000)
        assertEquals(15_000_000, f.left(day + 2000))
        assertEquals(PublicRelayFiles.Gate.GO, f.gate(15_000_000, day + 2000))
        assertEquals(PublicRelayFiles.Gate.OVER, f.gate(15_000_001, day + 2000))
        f.count(15_000_000, day + 3000)
        assertTrue(f.spent(day + 3000))
        assertEquals(PublicRelayFiles.Gate.OVER, f.gate(1, day + 86_399_999))
        // a new UTC day starts over
        assertEquals(PublicRelayFiles.Gate.GO, f.gate(1, day + 86_400_000))
        assertEquals(0, f.sent)
        assertEquals(20_419, f.day)
        // kept across runs: what was saved is today's count, or yesterday's (gone)
        assertEquals(10_000_000, PublicRelayFiles(20_418, 40_000_000).left(day + 5))
        assertEquals(50_000_000, PublicRelayFiles(20_417, 40_000_000).left(day + 5))
    }

    @Test fun thePhoneWaitsForTheTicketsBeforeItGivesUpOnTheMeeting() {
        // 8 s for the direct path, 3 s for the tickets, 5 s for the relay to open: publicRelay and noDirect come within 16 s
        assertTrue(Reconnect.meetingDueMs(true) > 16_000)
        assertEquals(Reconnect.MEETING_DUE_MS, Reconnect.meetingDueMs(false))
    }

    @Test fun thePublicRelayIsAwayAndLabelledApart() {
        assertEquals(LinkRoute.RELAY, LinkPath.PUBLIC_RELAY.route)
        val plan = ScreenPlan(ScreenQuality.SHARP, LinkRoute.RELAY, cellular = false, lowData = false, native = PadSize(2400.0, 1080.0), publicRelay = true)
        assertEquals(ScreenPlan(1280, 800, 1_000_000, 15), plan)
    }
}
