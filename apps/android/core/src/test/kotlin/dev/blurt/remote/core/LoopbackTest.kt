// A whole session in memory: the phone's handshake against the host's over length-prefixed frames, then sealed frames both ways, then UDP's
// replay window (exactly as RemoteSealer.openPacket in Swift: newer taken, the last 64 unseen taken, older and repeats dropped).
package dev.blurt.remote.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LoopbackTest {
    private class Pair(val phone: RemoteSealer, val mac: RemoteSealer, val nonce: ByteArray, val commitment: ByteArray?)

    /** The bytes go phone → host → phone through a frame reader on each end, split awkwardly. */
    private fun connect(id: String = "phone-1", paired: ByteArray = RemoteCrypto.newKey(), hostKey: ByteArray? = paired): Pair {
        val phone = PhoneHandshake(id, paired)
        val toHost = RemoteFrameReader()
        val wire = RemoteFrameReader.framed(phone.hello())
        toHost.feed(wire.copyOfRange(0, 3))
        assertNull(toHost.next(), "not whole yet")
        toHost.feed(wire.copyOfRange(3, wire.size))
        val hello = assertNotNull(toHost.next())
        val answer = MacHandshake.answer(hello) { if (it == id) hostKey else null }
        val toPhone = RemoteFrameReader()
        toPhone.feed(RemoteFrameReader.framed(answer.reply))
        val sealer = phone.finish(assertNotNull(toPhone.next()))
        return Pair(sealer, assertNotNull(answer.sealer), phone.nonce, answer.commitment)
    }

    @Test
    fun aSessionBothWays() {
        val s = connect()
        assertEquals(s.phone.check(s.nonce), s.mac.check(s.nonce), "the same six digits on both ends")
        assertEquals(6, s.phone.check(s.nonce).length)
        assertTrue(RemoteCrypto.same(RemoteCrypto.commitment(s.nonce), s.commitment!!))

        val hostReader = RemoteFrameReader()
        val hello = byteArrayOf(RemoteFrameKind.CONTROL.raw.toByte()) + ToMac.Hello("Pixel", true, s.nonce).encode()
        val stream = RemoteFrameReader.framed(s.phone.seal(hello)) + RemoteFrameReader.framed(s.phone.seal(byteArrayOf(1, 0, 0)))
        hostReader.feed(stream)
        val f0 = s.mac.open(assertNotNull(hostReader.next()))
        hostReader.limit = RemoteFrameReader.MAX_FRAME      // after the first sealed frame
        assertEquals(ToMac.Hello("Pixel", true, s.nonce), ToMac.decode(f0.copyOfRange(1, f0.size)))
        assertContentEquals(byteArrayOf(1, 0, 0), s.mac.open(assertNotNull(hostReader.next())))
        assertNull(hostReader.next())

        val big = ByteArray(200_000) { it.toByte() }
        assertContentEquals(big, s.phone.open(s.mac.seal(big)))
        val m = ToPhone.Session(RemoteSessionInfo("PC", 50000, 9, true, "1.0.15", platform = "linux"))
        val back = s.phone.open(s.mac.seal(byteArrayOf(0) + m.encode()))
        assertEquals(m, ToPhone.decode(back.copyOfRange(1, back.size)))
    }

    @Test
    fun aFrameOutOfOrderOrTamperedEndsTheSession() {
        val s = connect()
        val a = s.phone.seal(byteArrayOf(1))
        val b = s.phone.seal(byteArrayOf(2))
        assertFailsWith<Exception> { s.mac.open(b) }
        val t = connect()
        val f = t.phone.seal(byteArrayOf(1, 2, 3))
        f[0] = (f[0].toInt() xor 1).toByte()
        assertFailsWith<Exception> { t.mac.open(f) }
        assertFailsWith<Exception> { t.mac.open(ByteArray(15)) }
        assertNotEquals(hex(a), hex(b))
    }

    @Test
    fun aStrangerOrAWrongKeyIsRefused() {
        assertEquals(RemoteHandshakeError.Kind.NOT_PAIRED, assertFailsWith<RemoteHandshakeError> { connect(hostKey = null) }.kind)
        assertEquals(RemoteHandshakeError.Kind.BAD_PROOF, assertFailsWith<RemoteHandshakeError> { connect(hostKey = RemoteCrypto.newKey()) }.kind)
        val p = PhoneHandshake("x", RemoteCrypto.newKey())
        assertEquals(RemoteHandshakeError.Kind.BAD_MESSAGE, assertFailsWith<RemoteHandshakeError> { p.finish("nope".toByteArray()) }.kind)
        assertEquals(RemoteHandshakeError.Kind.VERSION, assertFailsWith<RemoteHandshakeError> { p.finish("""{"v":2,"error":"version"}""".toByteArray()) }.kind)
        assertEquals(RemoteHandshakeError.Kind.BAD_MESSAGE, assertFailsWith<RemoteHandshakeError> { p.finish("""{"v":1,"error":"bad_message"}""".toByteArray()) }.kind)
        // a small-order point gives a zero secret: refused, as CryptoKit does
        val zero = """{"v":1,"eph":"${RemoteCrypto.b64(ByteArray(32))}","proof":"${RemoteCrypto.b64(ByteArray(32))}"}"""
        assertEquals(RemoteHandshakeError.Kind.BAD_MESSAGE, assertFailsWith<RemoteHandshakeError> { p.finish(zero.toByteArray()) }.kind)
    }

    @Test
    fun theHostRefusesWhatIsntAHello() {
        fun err(hello: String) = J.str(J.parse(MacHandshake.answer(hello.toByteArray()) { RemoteCrypto.newKey() }.reply) as kotlinx.serialization.json.JsonObject, "error")
        assertEquals("bad_message", err("{}"))
        assertEquals("bad_message", err("not json"))
        assertEquals("version", err("""{"v":2,"id":"a","eph":"${RemoteCrypto.b64(ByteArray(32))}"}"""))
        assertEquals("bad_message", err("""{"v":1,"id":"a","eph":"${RemoteCrypto.b64(ByteArray(5))}"}"""))
        assertEquals("not_paired", J.str(J.parse(MacHandshake.answer(PhoneHandshake("a", ByteArray(32)).hello()) { null }.reply) as kotlinx.serialization.json.JsonObject, "error"))
    }

    @Test
    fun udpTakesNewerAndUnseenWithinSixtyFour() {
        val s = connect()
        val p = (1..200).map { s.phone.sealPacket(byteArrayOf(it.toByte()), 7) }    // counters 1…200
        fun take(n: Int) = s.mac.openPacket(p[n - 1])?.let { it[0].toInt() and 0xFF }

        assertEquals(1, take(1))
        assertNull(take(1), "a replay")
        assertEquals(3, take(3))
        assertEquals(2, take(2), "overtaken but not seen: taken")
        assertNull(take(2))
        assertEquals(70, take(70))
        assertEquals(7, take(7), "63 back: still in the window")
        assertNull(take(6), "64 back: too old")
        assertEquals(69, take(69))
        assertEquals(200, take(200), "a jump far ahead clears the window")
        assertNull(take(100), "100 back")
        assertEquals(137, take(137), "63 back")
        assertNull(take(137))
        assertNull(take(136), "64 back")
    }

    @Test
    fun udpDropsWhatIsntOurs() {
        val s = connect()
        val other = connect()
        val good = s.phone.sealPacket(byteArrayOf(5), 1)
        assertNull(other.mac.openPacket(good), "another session's key")
        val damaged = good.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
        assertNull(s.mac.openPacket(damaged))
        assertNull(s.mac.openPacket(ByteArray(27)), "too short")
        val zero = good.copyOf().also { for (i in 4 until 12) it[i] = 0 }
        assertNull(s.mac.openPacket(zero), "counter 0 is never sent")
        assertContentEquals(byteArrayOf(5), s.mac.openPacket(good), "a damaged copy doesn't spend the real one")
        assertNull(RemoteSealer.sessionOfPacket(ByteArray(10)))
        assertEquals(0xFFFF_FFFEL, RemoteSealer.sessionOfPacket(s.phone.sealPacket(byteArrayOf(1), 0xFFFF_FFFEL)))
    }

    @Test
    fun hostToPhoneDatagramsToo() {
        val s = connect()
        val piece = RemoteVideoPacket(1, 0, 1, true, 2.0, byteArrayOf(9, 9)).encoded()
        val d = s.mac.sealPacket(byteArrayOf(RemoteFrameKind.VIDEO.raw.toByte()) + piece, 3)
        val plain = assertNotNull(s.phone.openPacket(d))
        assertEquals(RemoteFrameKind.VIDEO, RemoteFrameKind.from(plain[0].toInt()))
        assertEquals(RemoteVideoPacket(1, 0, 1, true, 2.0, byteArrayOf(9, 9)), RemoteVideoPacket.decode(plain.copyOfRange(1, plain.size)))
    }
}
