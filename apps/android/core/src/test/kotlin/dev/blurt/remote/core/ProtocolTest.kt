package dev.blurt.remote.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProtocolTest {
    @Test
    fun framesHaveLimits() {
        val r = RemoteFrameReader()
        r.feed(byteArrayOf(0, 0, 0, 0))
        assertFailsWith<RemoteFrameError> { r.next() }
        val big = RemoteFrameReader()
        big.feed(RemoteFrameReader.framed(ByteArray(1025)))
        assertFailsWith<RemoteFrameError> { big.next() }
        val hello = RemoteFrameReader()
        hello.feed(RemoteFrameReader.framed(ByteArray(1024)))
        assertEquals(1024, hello.next()?.size, "a hello up to 1 KB")
        val after = RemoteFrameReader().apply { limit = RemoteFrameReader.MAX_FRAME }
        after.feed(RemoteFrameReader.framed(ByteArray(1 shl 20)))
        assertEquals(1 shl 20, after.next()?.size)
        after.feed(byteArrayOf(0, 0x10, 0, 1))
        assertFailsWith<RemoteFrameError> { after.next() }
        val split = RemoteFrameReader()
        val two = RemoteFrameReader.framed(byteArrayOf(1, 2)) + RemoteFrameReader.framed(byteArrayOf(3))
        for (b in two) split.feed(byteArrayOf(b))
        assertContentEquals(byteArrayOf(1, 2), split.next())
        assertContentEquals(byteArrayOf(3), split.next())
        assertNull(split.next())
        assertContentEquals(byteArrayOf(0, 0, 0, 2, 7, 8), RemoteFrameReader.framed(byteArrayOf(7, 8)))
    }

    @Test
    fun unknownCasesAreNullNotErrors() {
        assertNull(ToMac.decode("""{"teleport":{"_0":1}}""".toByteArray()))
        assertNull(ToPhone.decode("""{"hologram":{}}""".toByteArray()))
        assertNull(ToMac.decode("garbage".toByteArray()))
        assertNull(ToMac.decode("""{"key":{"_0":{"key":"C"}}}""".toByteArray()), "a chord without mods isn't one")
        assertNull(ToMac.decode("""{"blurt":{"_0":"fly"}}""".toByteArray()))
        assertEquals(ToMac.Text("hi"), ToMac.decode("""{"text":{"_0":"hi","later":true}}""".toByteArray()), "unknown keys are ignored")
        assertEquals(ToPhone.ScreenView(1.0, 2.0), ToPhone.decode("""{"screenView":{"width":1,"height":2}}""".toByteArray()))
    }

    @Test
    fun dataIsStandardBase64WithPadding() {
        val m = ToPhone.NewKey(byteArrayOf(-1, -2, -3, -4))
        assertEquals("""{"newKey":{"_0":"//79/A=="}}""", m.encode().decodeToString())
        assertEquals(m, ToPhone.decode("""{"newKey":{"_0":"\/\/79\/A=="}}""".toByteArray()), "Swift escapes the slashes")
    }

    @Test
    fun cropsStayInside() {
        assertEquals(RemoteCrop.WHOLE, RemoteCrop(Float.NaN, 0f, 1f, 1f).valid)
        assertEquals(RemoteCrop(0.9f, 0f, 0.1f, 0.1f), RemoteCrop(5f, -1f, 0.01f, 0.01f).valid)
        assertEquals(RemoteCrop(0.25f, 0.25f, 0.5f, 0.5f), RemoteCrop.centered(2f))
        assertEquals(RemoteCrop.WHOLE, RemoteCrop.centered(0.5f))
    }

    @Test
    fun aFrameMissingAPieceWaitsForAKeyframe() {
        val a = RemoteVideoAssembler()
        fun p(f: Long, i: Int, n: Int, key: Boolean) = RemoteVideoPacket(f, i, n, key, 0.0, byteArrayOf(f.toByte(), i.toByte()))
        assertNull(a.add(p(1, 0, 1, false)), "nothing before a keyframe")
        assertTrue(a.waitingForKey)
        assertNotNull(a.add(p(2, 0, 1, true)))
        assertNotNull(a.add(p(3, 0, 1, false)))
        assertNull(a.add(p(4, 0, 2, false)))
        assertNull(a.add(p(5, 0, 1, false)), "4 never finished: 5 can't be decoded")
        assertEquals(1, a.dropped)
        assertTrue(a.waitingForKey)
        assertNull(a.add(p(4, 1, 2, false)), "late")
        assertNull(a.add(p(7, 0, 1, false)), "6 skipped entirely")
        assertEquals(2, a.dropped)
        val f = assertNotNull(a.add(p(8, 0, 1, true)))
        assertEquals(8L, f.id)
        assertTrue(!a.waitingForKey)
        assertNull(RemoteVideoPacket.decode(ByteArray(16)))
        assertTrue(RemoteVideoPacket.decode(RemoteVideoPacket(1, 2, 2, false, 0.0, ByteArray(0)).encoded())!!.isParity, "index past count: parity")
        assertNull(RemoteVideoPacket.decode(RemoteVideoPacket(1, 2 + RemoteVideoFEC.MAX_PARITY, 2, false, 0.0, ByteArray(0)).encoded()), "past any parity")
        assertNull(RemoteVideoPayload.unpack(ByteArray(16)))
        assertNull(RemoteVideoPayload.unpack(ByteArray(16) + byteArrayOf(1, 0, 5)), "a parameter set longer than what's there")
    }

    @Test
    fun pointerPacketsRefuseNonsense() {
        assertNull(RemotePointerPacket.decode(ByteArray(0)))
        assertNull(RemotePointerPacket.decode(byteArrayOf(9)))
        assertNull(RemotePointerPacket.decode(byteArrayOf(0, 0, 0)))
        assertNull(RemotePointerPacket.decode(RemotePointerPacket.Move(1e6f, 0f).encoded()), "absurd")
        assertNull(RemotePointerPacket.decode(RemotePointerPacket.Move(Float.NaN, 0f).encoded()))
        assertNull(RemotePointerPacket.decode(byteArrayOf(1, 9, 0, 0, 0, 0, 0, 0, 0, 0)), "no such phase")
    }

    // the pointer's numbers (1.0.17)

    @Test
    fun aNumberedMoveIsReadByAHostThatKnowsNoNumbers() {
        val numbered = RemotePointerPacket.Move(1.5f, -2.25f, 258).encoded()
        assertEquals(13, numbered.size)
        assertEquals(RemotePointerPacket.Move(1.5f, -2.25f, 258), RemotePointerPacket.decode(numbered))
        // what a host before 1.0.17 reads: the first nine bytes
        assertEquals(RemotePointerPacket.Move(1.5f, -2.25f), RemotePointerPacket.decode(numbered.copyOf(9)))
        assertContentEquals(numbered.copyOf(9), RemotePointerPacket.Move(1.5f, -2.25f).encoded())
        assertEquals(0xFFFF_FFFFL, (RemotePointerPacket.decode(RemotePointerPacket.Move(0f, 0f, 0xFFFF_FFFFL).encoded()) as RemotePointerPacket.Move).seq,
            "the top of a u32 comes back as it went")
        val to = ToMac.PointerTo(0.5f, 0.75f).encode()
        assertTrue(!to.decodeToString().contains("seq"))
        assertNull((ToMac.decode(to) as ToMac.PointerTo).seq)
        val toN = ToMac.decode(ToMac.PointerTo(0.5f, 0.75f, 7).encode()) as ToMac.PointerTo
        assertEquals(listOf(0.5f, 0.75f), listOf(toN.x, toN.y))
        assertEquals(7L, toN.seq)
        assertNull(ToMac.decode("""{"pointerTo":{"x":0.5,"y":0.75,"seq":-1}}""".toByteArray()), "not a u32")
    }

    @Test
    fun theCursorSaysHowFarTheHostHasGot() {
        val plain = RemoteCursor(0.5f, 0.25f).encoded()
        assertEquals(8, plain.size)
        assertEquals(RemoteCursor(0.5f, 0.25f), RemoteCursor.decode(plain))
        val numbered = RemoteCursor(0.5f, 0.25f, 258).encoded()
        assertEquals(12, numbered.size)
        assertEquals(258L, RemoteCursor.decode(numbered)?.seq)
        assertNull(RemoteCursor.decode(numbered.copyOf(10)))
        assertNull(RemoteCursor.decode(numbered + byteArrayOf(0)), "8 or 12, nothing else")
        assertNull(RemoteCursor.decode(RemoteCursor(Float.NaN, 0f).encoded()))
        val max = 0xFFFF_FFFFL
        assertTrue(RemoteCursor.covers(5, 5))
        assertTrue(RemoteCursor.covers(6, 5))
        assertTrue(!RemoteCursor.covers(4, 5))
        assertTrue(RemoteCursor.covers(2, max - 1), "counting round")
        assertTrue(!RemoteCursor.covers(max - 1, 2))
    }

    @Test
    fun theHostsWordWaitsUntilItIncludesEveryMoveSent() {
        // a word that includes everything sent counts at once, however lately the finger moved
        assertEquals(0.0, RemoteCursor.wait(host = 9, sent = 9, quiet = 0.0, rtt = 0.05, lossless = false))
        assertEquals(0.0, RemoteCursor.wait(host = 10, sent = 9, quiet = 0.0, rtt = 2.0, lossless = true))
        assertEquals(0.0, RemoteCursor.wait(host = 1, sent = 0xFFFF_FFFFL, quiet = 0.0, rtt = 0.05, lossless = false), "counting round")
        // one that's behind is the pointer before the last moves: it waits, in case a move was lost on the way
        assertEquals(0.5, RemoteCursor.wait(host = 8, sent = 9, quiet = 0.0, rtt = 0.05, lossless = false), 1e-9)
        assertEquals(0.3, RemoteCursor.wait(host = 8, sent = 9, quiet = 0.2, rtt = 0.05, lossless = false), 1e-9)
        assertEquals(1.2, RemoteCursor.wait(host = 8, sent = 9, quiet = 0.0, rtt = 0.3, lossless = false), 1e-9, "four round trips on a slow path")
        assertTrue(RemoteCursor.wait(host = 8, sent = 9, quiet = 0.6, rtt = 0.05, lossless = false) <= 0, "long enough: it counts anyway")
        // the relay's stream loses nothing, but much can queue
        assertEquals(3.0, RemoteCursor.wait(host = 8, sent = 9, quiet = 0.0, rtt = 0.05, lossless = true), 1e-9)
        assertEquals(1.0, RemoteCursor.wait(host = 8, sent = 9, quiet = 2.0, rtt = 0.8, lossless = true), 1e-9)
        // a host that sends no numbers (before 1.0.17): as it was
        assertEquals(0.12, RemoteCursor.wait(host = null, sent = 9, quiet = 0.0, rtt = 0.0, lossless = false), 1e-9)
        assertEquals(0.02, RemoteCursor.wait(host = null, sent = 9, quiet = 0.1, rtt = 0.05, lossless = false), 1e-9)
        assertEquals(0.3, RemoteCursor.wait(host = null, sent = 9, quiet = 0.0, rtt = 0.2, lossless = true), 1e-9)
        assertTrue(RemoteCursor.wait(host = null, sent = 0, quiet = 0.2, rtt = 0.05, lossless = false) <= 0)
    }

    @Test
    fun relayAddresses() {
        assertEquals("wss://relay.example.com", RemoteRelay.address("  relay.example.com/ \n"))
        assertEquals("ws://10.0.0.2:8080", RemoteRelay.address("ws://10.0.0.2:8080"))
        assertEquals("wss://r.example.com/sub", RemoteRelay.address("wss://r.example.com/sub//"))
        assertEquals("wss://[2001:db8::1]:443", RemoteRelay.address("[2001:db8::1]:443"))
        assertNull(RemoteRelay.address(""))
        assertNull(RemoteRelay.address("https://relay.example.com"))
        assertNull(RemoteRelay.address("wss://relay.example.com?x=1"))
        assertNull(RemoteRelay.address("wss://relay.example.com#a"))
        assertNull(RemoteRelay.address("wss://"))
        assertNull(RemoteRelay.address("relay example.com"))
        assertEquals("wss://relay.example.com/v1/room/phone", RemoteRelay.url("relay.example.com", "room", "phone"))
        assertEquals(4000, RemoteRelay.PHONE_LEFT)
        assertEquals(4001, RemoteRelay.MAC_GONE)
        assertEquals(4002, RemoteRelay.REPLACED)
    }

    @Test
    fun pairingLinks() {
        val key = RemoteCrypto.newKey()
        val p = RemotePairing("m", "d", key, "Zoë's PC & co=1+2", 1, listOf(), null)
        val back = assertNotNull(RemotePairing.parse(p.url))
        assertEquals(p, back)
        assertTrue(!p.url.contains(" "))
        assertNull(RemotePairing.parse(p.url.replace("v=1", "v=2")))
        assertNull(RemotePairing.parse("https://pair?v=1"))
        assertNull(RemotePairing.parse(p.url.replace("p=1", "p=70000")))
        assertNull(RemotePairing.parse(p.url.replace(RemoteCrypto.base64url(key), "AAAA")), "a key is 32 bytes")
        assertEquals("Mac", RemotePairing.parse(p.url.replace("&n=", "&x="))?.macName)
        assertNull(RemotePairing.parse("blurtremote://pair?v=1&mac=m&id=d&k=${RemoteCrypto.base64url(key)}&p=1&r=https://x")?.relay, "a relay that isn't one is left out")
    }

    @Test
    fun stun() {
        val txn = ByteArray(12) { it.toByte() }
        val req = RemoteSTUN.request(txn)
        assertEquals("000100002112a442000102030405060708090a0b", hex(req))
        // a Binding success with a SOFTWARE attribute first, then XOR-MAPPED-ADDRESS 203.0.113.5:50123
        val port = 50123 xor 0x2112
        val ip = byteArrayOf(203.toByte(), 0, 113, 5).mapIndexed { i, b -> (b.toInt() xor byteArrayOf(0x21, 0x12, 0xA4.toByte(), 0x42)[i].toInt()).toByte() }
        val software = byteArrayOf(0x80.toByte(), 0x22, 0, 3, 'a'.code.toByte(), 'b'.code.toByte(), 'c'.code.toByte(), 0)
        val mapped = byteArrayOf(0, 0x20, 0, 8, 0, 1, (port shr 8).toByte(), port.toByte()) + ip
        val head = byteArrayOf(1, 1, 0, (software.size + mapped.size).toByte(), 0x21, 0x12, 0xA4.toByte(), 0x42) + txn
        assertEquals(RemoteCandidate("203.0.113.5", 50123), RemoteSTUN.parse(head + software + mapped, txn))
        assertNull(RemoteSTUN.parse(head + software + mapped, ByteArray(12)), "someone else's transaction")
        assertNull(RemoteSTUN.parse(req, txn), "a request isn't an answer")
    }

    @Test
    fun cryptoBits() {
        assertTrue(RemoteCrypto.same(byteArrayOf(1, 2), byteArrayOf(1, 2)))
        assertTrue(!RemoteCrypto.same(byteArrayOf(1, 2), byteArrayOf(1, 3)))
        assertTrue(!RemoteCrypto.same(byteArrayOf(1), byteArrayOf(1, 2)))
        assertEquals(22, RemoteCrypto.newID().length, "16 bytes, base64url without padding")
        val k = RemoteCrypto.newKey()
        assertContentEquals(k, RemoteCrypto.base64url(RemoteCrypto.base64url(k)))
        assertContentEquals(byteArrayOf(-5, -1), RemoteCrypto.base64url("+/8"), "either alphabet")
        assertNull(RemoteCrypto.base64url("!!!"))
    }

    @Test
    fun hostAwareLabels() {
        val copy = RemoteChord(RemoteModifiers.CONTROL, "C")
        assertEquals("⌃C", copy.label(RemoteHost.MAC))
        assertEquals("Ctrl+C", copy.label(RemoteHost.WINDOWS))
        assertEquals("⌃⌥⇧⌘", RemoteModifiers.glyphs(15, RemoteHost.MAC))
        assertEquals("Win+Ctrl+Alt+Shift", RemoteModifiers.glyphs(15, RemoteHost.WINDOWS))
        assertEquals("Super+Shift", RemoteModifiers.glyphs(RemoteModifiers.COMMAND or RemoteModifiers.SHIFT, RemoteHost.LINUX))
        assertEquals("Ctrl+Shift+Tab", RemoteChord(RemoteModifiers.CONTROL or RemoteModifiers.SHIFT, "Tab").label(RemoteHost.LINUX))
        assertEquals("⌃⇧⇥", RemoteChord(RemoteModifiers.CONTROL or RemoteModifiers.SHIFT, "Tab").label(RemoteHost.MAC))
        assertEquals("Alt+F4", RemoteChord(RemoteModifiers.OPTION, "F4").label(RemoteHost.WINDOWS))
        assertEquals("Win", RemoteChord(RemoteModifiers.COMMAND, "").label(RemoteHost.WINDOWS))
        assertEquals("⌫", RemoteChord(0, "Delete").label(RemoteHost.WINDOWS))
        assertEquals("Alt+←", RemoteChord(RemoteModifiers.OPTION, "Left").label(RemoteHost.LINUX))
        assertEquals(RemoteHost.LINUX, RemoteHost.from("linux"))
        assertEquals(RemoteHost.MAC, RemoteHost.from("amiga"))
        assertEquals(73, RemoteKey.all.size)
        assertEquals(36, RemoteKey.named("Return")?.code)
        assertNull(RemoteKey.named("Hyper"))
    }
}
