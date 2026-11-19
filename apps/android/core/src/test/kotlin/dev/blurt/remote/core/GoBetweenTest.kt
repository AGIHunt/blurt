// The go-between's additions apart from the stream itself (docs/design/remote-go-between.md): the wire's new keys and cases, read the way
// older peers need, which addresses are Tailscale's, the path a session is named by, the busy back-off and what the pad says.
package dev.blurt.remote.core

import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GoBetweenTest {
    private fun json(s: String) = Json.parseToJsonElement(s)

    @Test fun helloAndSessionNameWhatTheyCanDo() {
        val h = ToMac.Hello("Pixel 9", true, null, listOf(RemoteFeature.MOVE))
        assertSameJson(json("""{"hello":{"device":"Pixel 9","micOnPhone":true,"features":["move"]}}"""), h.toJson(), "hello")
        assertEquals(h, ToMac.decode(h.encode()))
        // a phone before the go-between says nothing, and an unknown feature is carried, not refused
        assertNull((ToMac.decode("""{"hello":{"device":"a","micOnPhone":false}}""".toByteArray()) as ToMac.Hello).features)
        assertEquals(listOf("move", "later"), (ToMac.decode("""{"hello":{"device":"a","micOnPhone":false,"features":["move","later"]}}""".toByteArray()) as ToMac.Hello).features)
        assertNull(ToMac.decode("""{"hello":{"device":"a","micOnPhone":false,"features":[1]}}""".toByteArray()), "as Swift: a bad list fails the message")

        val i = RemoteSessionInfo("Studio", 50123, 7, true, "1.0.27", relay = RemoteRelay.GO_BETWEEN, platform = "mac", features = listOf("move"))
        val back = ToPhone.decode(ToPhone.Session(i).encode()) as ToPhone.Session
        assertEquals(i, back.info)
        assertSameJson(json("""["move"]"""), (ToPhone.Session(i).toJson()["session"] as kotlinx.serialization.json.JsonObject).let {
            (it["_0"] as kotlinx.serialization.json.JsonObject)["features"]!!
        }, "features")
        assertNull((ToPhone.decode("""{"session":{"_0":{"macName":"a","udpPort":1,"udpSession":2,"canControl":true,"version":"1","candidates":[],"displayAspect":1.6}}}""".toByteArray())
            as ToPhone.Session).info.features, "a host before the go-between")
    }

    @Test fun theNewCases() {
        assertSameJson(json("""{"streamMoved":{}}"""), ToMac.StreamMoved.toJson(), "toMac")
        assertSameJson(json("""{"streamMoved":{}}"""), ToPhone.StreamMoved.toJson(), "toPhone")
        assertSameJson(json("""{"noDirect":{}}"""), ToPhone.NoDirect.toJson(), "noDirect")
        assertEquals(ToMac.StreamMoved, ToMac.decode("""{"streamMoved":{}}""".toByteArray()))
        assertEquals(ToPhone.StreamMoved, ToPhone.decode("""{"streamMoved":{}}""".toByteArray()))
        assertEquals(ToPhone.NoDirect, ToPhone.decode("""{"noDirect":{}}""".toByteArray()))
        assertNull(ToMac.decode("""{"noDirect":{}}""".toByteArray()), "host → phone only")
    }

    @Test fun tailscaleAddresses() {
        for (a in listOf("100.64.0.1", "100.100.100.100", "100.127.255.254", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12:4843:cd96:6258:b240",
            "[fd7a:115c:a1e0::53]", "FD7A:115C:A1E0::1%tun0")) assertTrue(RemoteOverlay.isTailscale(a), a)
        for (a in listOf("100.63.255.255", "100.128.0.1", "192.168.1.20", "10.147.17.5", "fd7a:115c:a1e1::1", "fd7a:115c::1", "fe80::1",
            "2001:db8::1", "studio.local", "100.64.0", "", "::")) assertFalse(RemoteOverlay.isTailscale(a), a)
    }

    @Test fun addressesWorthATryAway() {
        for (a in listOf("100.64.0.1", "fd7a:115c:a1e0::1", "10.147.17.5", "172.22.1.2", "192.168.191.3", "fd12:3456::1"))
            assertTrue(RemoteOverlay.mayBeOverlay(a), a)
        for (a in listOf("203.0.113.5", "2001:db8::1", "fe80::1", "172.32.0.1", "169.254.1.1", "studio.local"))
            assertFalse(RemoteOverlay.mayBeOverlay(a), a)
    }

    @Test fun thePathsName() {
        assertEquals(LinkPath.TAILSCALE, LinkPath.of("100.101.102.103", onMyNetwork = false))
        assertEquals(LinkPath.TAILSCALE, LinkPath.of("100.101.102.103", onMyNetwork = true), "the range says it, whatever the phone thinks")
        assertEquals(LinkPath.SAME_NETWORK, LinkPath.of("192.168.1.20", onMyNetwork = true))
        assertEquals(LinkPath.OVERLAY, LinkPath.of("10.147.17.5", onMyNetwork = false))
        // an overlay is away for the picture's ceiling
        assertEquals(LinkRoute.DIRECT, LinkPath.TAILSCALE.route)
        assertEquals(LinkRoute.DIRECT, LinkPath.OVERLAY.route)
        assertEquals(LinkRoute.LOCAL, LinkPath.SAME_NETWORK.route)
        assertEquals(LinkRoute.RELAY, LinkPath.GO_BETWEEN.route)
        assertEquals(LinkRoute.RELAY, LinkPath.OWN_RELAY.route)
    }

    @Test fun theGoBetweenIsKnownByItsAddress() {
        assertTrue(RemoteRelay.isGoBetween("wss://meet.blurt.work"))
        assertTrue(RemoteRelay.isGoBetween("meet.blurt.work/"))
        assertTrue(RemoteRelay.isGoBetween("wss://MEET.blurt.work:443"))
        assertFalse(RemoteRelay.isGoBetween("ws://meet.blurt.work"))
        assertFalse(RemoteRelay.isGoBetween("wss://relay.example.com"))
        assertFalse(RemoteRelay.isGoBetween("wss://meet.blurt.work.example.com"))
        assertFalse(RemoteRelay.isGoBetween(null))
        assertEquals(4003, RemoteRelay.BUDGET)
    }

    @Test fun busyBacksOff() {
        val b = GoBetweenBackoff()
        assertTrue(b.mayTry(0.0))
        assertFalse(b.busy)
        val waits = (0 until 6).map { i -> val now = i * 10_000.0; b.refused(now); b.until - now }
        assertEquals(listOf(30.0, 120.0, 600.0, 3600.0, 3600.0, 3600.0), waits)
        assertFalse(b.mayTry(50_000.0 + 3599))
        assertTrue(b.mayTry(50_000.0 + 3600))
        b.worked()
        assertFalse(b.busy)
        b.refused(0.0)
        assertEquals(30.0, b.until, "a session that worked starts the count over")
    }

    @Test fun whatThePadSays() {
        val p = LinkPhase.UNREACHABLE
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_REACH, StatusLine.NO_DIRECT, StatusAction.RETRY),
            StatusBanner.of(LinkStatus(p, away = AwayTrouble.NO_DIRECT, hasRelay = true)))
        assertEquals(StatusBanner(StatusMark.PROBLEM, StatusLine.CANT_REACH, StatusLine.GO_BETWEEN_BUSY, StatusAction.RETRY, StatusAction.ANOTHER),
            StatusBanner.of(LinkStatus(p, away = AwayTrouble.BUSY, otherComputers = true)))
        // while the other ways are still being tried (the same network answers in a moment at home), it's only "connecting"
        assertEquals(StatusBanner(StatusMark.BUSY, StatusLine.CONNECTING), StatusBanner.of(LinkStatus(LinkPhase.CONNECTING, away = AwayTrouble.BUSY)))
        // connected some other way: nothing to say about the go-between
        assertNull(StatusBanner.of(LinkStatus(LinkPhase.CONNECTED, away = AwayTrouble.BUSY)))
        // a pairing under way is still said over it
        assertEquals(StatusLine.WAITING, StatusBanner.of(LinkStatus(LinkPhase.UNREACHABLE, waiting = true, away = AwayTrouble.NO_DIRECT))?.title)
    }
}
