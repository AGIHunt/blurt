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
        for (vpn in listOf(false, true)) {
            assertEquals(LinkPath.TAILSCALE, LinkPath.of("100.101.102.103", onMyNetwork = false, throughVpn = vpn))
            assertEquals(LinkPath.TAILSCALE, LinkPath.of("100.101.102.103", onMyNetwork = true, throughVpn = vpn), "the range says it, whatever the phone thinks")
            assertEquals(LinkPath.SAME_NETWORK, LinkPath.of("192.168.1.20", onMyNetwork = true, throughVpn = vpn))
        }
        // ZeroTier's: an address of its own, out through the VPN
        assertEquals(LinkPath.OVERLAY, LinkPath.of("10.147.17.5", onMyNetwork = false, throughVpn = true))
        assertEquals(LinkPath.OVERLAY, LinkPath.of("fd12:3456::1", onMyNetwork = false, throughVpn = true))
        // another subnet of the office: its addresses look the same, but no VPN is in between
        assertEquals(LinkPath.SAME_NETWORK, LinkPath.of("10.20.3.4", onMyNetwork = false, throughVpn = false))
        assertEquals(LinkPath.SAME_NETWORK, LinkPath.of("192.168.40.7", onMyNetwork = false, throughVpn = false))
        // and no overlay has a public address
        assertEquals(LinkPath.SAME_NETWORK, LinkPath.of("203.0.113.5", onMyNetwork = false, throughVpn = true))
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

    /** Coming back, Retry or another network ends the wait by then at the latest; it never makes one longer, and the next refusal's is as long
     *  as it would have been. */
    @Test fun askingAgainEndsTheWaitSooner() {
        val b = GoBetweenBackoff()
        b.notAfter(50.0)
        assertTrue(b.mayTry(0.0), "nothing to wait for")
        b.refused(0.0)
        b.notAfter(60.0)
        assertEquals(30.0, b.until, "never longer")
        b.notAfter(12.0)
        assertFalse(b.mayTry(11.9))
        assertTrue(b.mayTry(12.0))
        assertTrue(b.busy)
        b.refused(12.0)
        assertEquals(132.0, b.until, "the second refusal's two minutes")
        b.notAfter(Double.NEGATIVE_INFINITY)
        assertTrue(b.mayTry(13.0))
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
        assertEquals(StatusLine.CHECK_DIGITS, StatusBanner.of(LinkStatus(LinkPhase.UNREACHABLE, waiting = true, away = AwayTrouble.NO_DIRECT))?.title)
        assertEquals(StatusLine.WAITING, StatusBanner.of(LinkStatus(LinkPhase.UNREACHABLE, waiting = true, digitsConfirmed = true, away = AwayTrouble.NO_DIRECT))?.title)
    }
}
