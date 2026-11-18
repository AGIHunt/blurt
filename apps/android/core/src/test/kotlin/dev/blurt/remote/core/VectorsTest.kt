// Every golden vector in tests/remote-vectors/vectors.json (written by RemoteVectorsTests.swift), byte for byte. JSON is compared as parsed
// values: numbers by value, objects by keys, arrays in order.
package dev.blurt.remote.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

internal fun hex(d: ByteArray) = d.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
internal fun unhex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

/** Equal as parsed JSON values. */
internal fun sameJson(a: JsonElement, b: JsonElement): Boolean = when {
    a is JsonObject && b is JsonObject -> a.keys == b.keys && a.keys.all { sameJson(a[it]!!, b[it]!!) }
    a is JsonArray && b is JsonArray -> a.size == b.size && a.indices.all { sameJson(a[it], b[it]) }
    a is JsonNull || b is JsonNull -> a == b
    a is JsonPrimitive && b is JsonPrimitive -> when {
        a.isString || b.isString -> a.isString == b.isString && a.content == b.content
        a.content == "true" || a.content == "false" || b.content == "true" || b.content == "false" -> a.content == b.content
        else -> a.content.toDouble() == b.content.toDouble()
    }
    else -> false
}

internal fun assertSameJson(expected: JsonElement, actual: JsonElement, what: String) {
    assertTrue(sameJson(expected, actual), "$what\nexpected $expected\nactual   $actual")
}

internal object Vectors {
    val file = File(System.getProperty("blurt.vectors") ?: "../../../tests/remote-vectors/vectors.json")
    val root: JsonObject by lazy { Json.parseToJsonElement(file.readText()).jsonObject }
}

class VectorsTest {
    private val v = Vectors.root

    @Test
    fun versionIsOurs() {
        assertEquals(RemoteCrypto.VERSION, v["version"]!!.jsonPrimitive.int)
    }

    @Test
    fun everyToMacMessageDecodesAndEncodesTheSame() {
        val list = v["toMac"]!!.jsonArray
        assertEquals(40, list.size)
        for (e in list) {
            val name = e.jsonObject["name"]!!.jsonPrimitive.content
            val json = e.jsonObject["json"]!!
            val m = ToMac.fromJson(json) ?: fail("toMac $name didn't decode: $json")
            assertSameJson(json, m.toJson(), "toMac $name")
            assertEquals(m, ToMac.decode(m.encode()), "toMac $name through bytes")
        }
    }

    @Test
    fun everyToPhoneMessageDecodesAndEncodesTheSame() {
        val list = v["toPhone"]!!.jsonArray
        assertEquals(26, list.size)
        for (e in list) {
            val name = e.jsonObject["name"]!!.jsonPrimitive.content
            val json = e.jsonObject["json"]!!
            val m = ToPhone.fromJson(json) ?: fail("toPhone $name didn't decode: $json")
            assertSameJson(json, m.toJson(), "toPhone $name")
            assertEquals(m, ToPhone.decode(m.encode()), "toPhone $name through bytes")
        }
    }

    @Test
    fun theMessagesMeanWhatSwiftMeant() {
        fun mac(name: String) = ToMac.fromJson(v["toMac"]!!.jsonArray.first { it.jsonObject["name"]!!.jsonPrimitive.content == name }.jsonObject["json"])
        fun phone(name: String) = ToPhone.fromJson(v["toPhone"]!!.jsonArray.first { it.jsonObject["name"]!!.jsonPrimitive.content == name }.jsonObject["json"])
        val crop = RemoteCrop(0.25f, 0.125f, 0.5f, 0.5f)
        val nonce = bytes(9)
        assertEquals(ToMac.Key(RemoteChord(RemoteModifiers.COMMAND, "C"), null), mac("key_tap"))
        assertEquals(ToMac.Key(RemoteChord(RemoteModifiers.COMMAND or RemoteModifiers.SHIFT, "Tab"), true), mac("key_down"))
        assertEquals(ToMac.Key(RemoteChord(RemoteModifiers.SHIFT, ""), false), mac("key_up_modifier_alone"))
        assertEquals(ToMac.Mods(RemoteModifiers.COMMAND or RemoteModifiers.OPTION), mac("mods"))
        assertEquals(ToMac.Run(listOf(RemoteStep.Key(RemoteChord(0, "Escape")), RemoteStep.Wait(80), RemoteStep.Key(RemoteChord(0, "Escape")),
            RemoteStep.Text("/compact"))), mac("run"))
        assertEquals(ToMac.Text("你好 hello\n"), mac("text"))
        assertEquals(ToMac.Button(RemoteMouseButton.LEFT, true), mac("button_down"))
        assertEquals(ToMac.Button(RemoteMouseButton.RIGHT, false), mac("button_up_right"))
        assertEquals(ToMac.DragBegin, mac("drag_begin"))
        assertEquals(ToMac.DictationKey(true), mac("dictation_key"))
        assertEquals(ToMac.Blurt(RemoteBlurtCommand.VOICE_NOTE), mac("blurt"))
        assertEquals(ToMac.System(RemoteSystemMove.MISSION_CONTROL), mac("system"))
        assertEquals(ToMac.Activate("com.apple.Terminal"), mac("activate"))
        assertEquals(ToMac.Hud("常用"), mac("hud"))
        assertEquals(ToMac.Hello("Pixel 9", true, nonce), mac("hello"))
        assertEquals(ToMac.Hello("iPhone", false, null), mac("hello_no_nonce"))
        assertEquals(ToMac.SetMicOnPhone(false), mac("set_mic_on_phone"))
        assertEquals(ToMac.ReleaseAll, mac("release_all"))
        assertEquals(ToMac.KeyStored, mac("key_stored"))
        assertEquals(ToMac.Screen(RemoteScreenRequest("display", crop, 1600, 1000, 4_000_000, 30, listOf("h264"))), mac("screen"))
        assertEquals(ToMac.Screen(RemoteScreenRequest("display", width = 1280, height = 800, bitrate = 1_000_000, fps = 15, codecs = null)), mac("screen_old_phone"))
        assertEquals(ToMac.Screen(null), mac("screen_off"))
        assertEquals(ToMac.Screen(RemoteScreenRequest("display", RemoteCrop.WHOLE, 1600, 900, 4_000_000, 30, listOf("h264"), "69733382")),
            mac("screen_pinned_display"))
        assertNull((mac("screen") as ToMac.Screen).request!!.display, "no display: follow the pointer")
        assertEquals(ToMac.Screen(RemoteScreenRequest("display", RemoteCrop.WHOLE, 2622, 1206, 12_000_000, 120, listOf("hevc", "h264"),
            features = listOf("nack", "ltr", "fec"))), mac("screen_repairs"))
        assertNull((mac("screen") as ToMac.Screen).request!!.features, "a phone before 1.0.15 offers none")
        assertEquals(ToMac.ShowDisplay("69733382"), mac("show_display"))
        assertEquals(ToMac.ShowDisplay(null), mac("show_display_follow"))
        assertEquals(ToMac.ScreenCrop(crop), mac("screen_crop"))
        assertEquals(ToMac.PointerTo(0.5f, 0.75f), mac("pointer_to"))
        assertEquals(ToMac.PointerTo(0.5f, 0.75f, 7), mac("pointer_to_seq"))
        assertEquals(ToMac.Candidates(listOf(RemoteCandidate("203.0.113.5", 50123), RemoteCandidate("2001:db8::1", 50123))), mac("candidates"))
        assertEquals(ToMac.RequestKeyframe, mac("request_keyframe"))
        assertEquals(ToMac.ScreenReport(RemoteScreenReport(30, 1, 0.25, 123_456)), mac("screen_report"))
        assertEquals(ToMac.ScreenReport(RemoteScreenReport(0, 0, null, 0)), mac("screen_report_no_rtt"))
        assertEquals(ToMac.ScreenPace(true), mac("screen_pace"))
        assertEquals(ToMac.Unpair, mac("unpair"))
        assertEquals(ToMac.Replaces("old-device-id"), mac("replaces"))
        assertEquals(ToMac.OfferRelay("wss://relay.example.com"), mac("offer_relay"))
        assertEquals(ToMac.ScreenStats("fps=30"), mac("screen_stats"))
        assertEquals(ToMac.ScreenSnapshot("a", byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte())), mac("screen_snapshot"))
        assertEquals(ToMac.Ping(12.5), mac("ping"))

        val s = (phone("session") as ToPhone.Session).info
        assertEquals(RemoteSessionInfo("Studio PC", 50123, 7, true, "1.0.15", listOf(RemoteCandidate("192.168.1.20", 50123)), 1.5,
            "wss://relay.example.com", "windows"), s)
        assertEquals(RemoteHost.WINDOWS, s.host)
        val old = (phone("session_old_mac") as ToPhone.Session).info
        assertNull(old.platform)
        assertEquals(RemoteHost.MAC, old.host, "a Mac before 1.0.15 says nothing")
        assertEquals(1.6, old.displayAspect)
        assertEquals(ToPhone.CanControl(true), phone("can_control"))
        assertEquals(ToPhone.Front(RemoteFront("WindowsTerminal.exe", "Terminal")), phone("front"))
        assertEquals(ToPhone.Dictation(RemoteDictationPhase.LISTENING), phone("dictation"))
        assertEquals(ToPhone.Live("你好", " wor"), phone("live"))
        assertEquals(ToPhone.Level(0.5f), phone("level"))
        assertEquals(ToPhone.Typed("hello"), phone("typed"))
        assertEquals(ToPhone.Notice("Copied"), phone("notice"))
        assertEquals(ToPhone.Pong(12.5), phone("pong"))
        assertEquals(ToPhone.UdpOK, phone("udp_ok"))
        assertEquals(ToPhone.Removed, phone("removed"))
        assertEquals(ToPhone.Relay("wss://relay.example.com"), phone("relay"))
        assertEquals(ToPhone.Relay(null), phone("relay_none"))
        assertEquals(ToPhone.Replaced, phone("replaced"))
        assertEquals(ToPhone.PairingWaits, phone("pairing_waits"))
        assertEquals(ToPhone.Listen(true), phone("listen"))
        assertEquals(ToPhone.NewKey(bytes(3)), phone("new_key"))
        assertEquals(ToPhone.Clock(100.5, 2000.25), phone("clock"))
        assertEquals(ToPhone.ScreenFailed("Screen Recording is off"), phone("screen_failed"))
        assertEquals(ToPhone.ScreenView(1920.0, 1080.0, "h264"), phone("screen_view"))
        assertEquals(ToPhone.ScreenView(1512.0, 982.0, null), phone("screen_view_old_mac"))
        assertEquals(ToPhone.ScreenView(2560.0, 1440.0, "hevc", "69733382"), phone("screen_view_display"))
        assertEquals(ToPhone.ScreenView(1512.0, 982.0, "hevc", "1", listOf("nack", "ltr")), phone("screen_view_repairs"))
        assertNull((phone("screen_view") as ToPhone.ScreenView).features, "a host before 1.0.15 uses none")
        assertEquals(ToPhone.Displays(listOf(RemoteDisplay("1", "Built-in Retina Display", 0.0, 0.0, 1512.0, 982.0, true),
            RemoteDisplay("69733382", "DELL U2723QE", 1512.0, -458.0, 2560.0, 1440.0, false))), phone("displays"))
        assertEquals(ToPhone.CursorShape(byteArrayOf(0x89.toByte(), 0x50), 1.0, 2.0, 16.0, 24.0), phone("cursor_shape"))
    }

    @Test
    fun pointerPackets() {
        val expected = mapOf(
            "move" to RemotePointerPacket.Move(1.5f, -2.25f),
            "scroll" to RemotePointerPacket.Scroll(0f, 10f, RemoteScrollPhase.CHANGED),
            "scroll_began" to RemotePointerPacket.Scroll(-3f, 0.5f, RemoteScrollPhase.BEGAN),
            "fling" to RemotePointerPacket.ScrollFling(100f, -50f),
            "stop" to RemotePointerPacket.ScrollStop,
            // numbered (1.0.17+): four more bytes, which a host before that reads past
            "move_seq" to RemotePointerPacket.Move(1.5f, -2.25f, 258),
        )
        val list = v["pointer"]!!.jsonArray
        assertEquals(expected.size, list.size)
        for (e in list) {
            val name = e.jsonObject["name"]!!.jsonPrimitive.content
            val h = e.jsonObject["hex"]!!.jsonPrimitive.content
            assertEquals(h, hex(expected.getValue(name).encoded()), name)
            assertEquals(expected.getValue(name), RemotePointerPacket.decode(unhex(h)), name)
        }
    }

    @Test
    fun videoPayloadAndPieces() {
        val video = v["video"]!!.jsonObject
        val payload = video["payload"]!!.jsonObject
        val crop = RemoteCrop.fromJson(payload["crop"])!!
        val sets = payload["parameterSets"]!!.jsonArray.map { unhex(it.jsonPrimitive.content) }
        val picture = unhex(payload["picture"]!!.jsonPrimitive.content)
        val packed = RemoteVideoPayload.pack(crop, sets, picture)
        assertEquals(payload["hex"]!!.jsonPrimitive.content, hex(packed))
        assertEquals(RemoteVideoPayload.Unpacked(crop, sets, picture), RemoteVideoPayload.unpack(packed))
        assertSameJson(payload["crop"]!!, crop.toJson(), "crop")

        val p = video["packets"]!!.jsonObject
        val pieces = RemoteVideoPacket.split(packed, p["frame"]!!.jsonPrimitive.int.toLong(), p["keyframe"]!!.jsonPrimitive.boolean,
            p["captured"]!!.jsonPrimitive.double, p["pieceSize"]!!.jsonPrimitive.int)
        assertEquals(p["hex"]!!.jsonArray.map { it.jsonPrimitive.content }, pieces.map { hex(it.encoded()) })
        val a = RemoteVideoAssembler()
        val got = p["hex"]!!.jsonArray.reversed().mapNotNull { a.add(RemoteVideoPacket.decode(unhex(it.jsonPrimitive.content))!!) }
        assertEquals(1, got.size, "the pieces in any order make one frame")
        assertContentEquals(packed, got[0].data)
        assertEquals(42L, got[0].id)
        assertEquals(1234.5, got[0].captured)
        assertTrue(got[0].keyframe)
    }

    @Test
    fun videoRepairByteForByte() {
        val r = v["videoRepair"]!!.jsonObject
        val refresh = r["refresh"]!!.jsonObject
        val data = unhex(refresh["data"]!!.jsonPrimitive.content)
        val pieces = RemoteVideoPacket.split(data, refresh["frame"]!!.jsonPrimitive.int.toLong(), refresh["keyframe"]!!.jsonPrimitive.boolean,
            refresh["captured"]!!.jsonPrimitive.double, refresh["pieceSize"]!!.jsonPrimitive.int,
            refresh = refresh["refresh"]!!.jsonPrimitive.boolean, ackRequested = refresh["ackRequested"]!!.jsonPrimitive.boolean)
        assertEquals(refresh["hex"]!!.jsonArray.map { it.jsonPrimitive.content }, pieces.map { hex(it.encoded()) })
        for (h in refresh["hex"]!!.jsonArray) {
            val p = RemoteVideoPacket.decode(unhex(h.jsonPrimitive.content))!!
            assertTrue(p.refresh && p.ackRequested && !p.keyframe && !p.isParity)
            assertEquals(h.jsonPrimitive.content, hex(p.encoded()))
        }

        val parity = r["parity"]!!.jsonObject
        val made = RemoteVideoFEC.parity(pieces, parity["group"]!!.jsonPrimitive.int)
        assertEquals(parity["hex"]!!.jsonArray.map { it.jsonPrimitive.content }, made.map { hex(it.encoded()) })
        for (h in parity["hex"]!!.jsonArray) {
            val p = RemoteVideoPacket.decode(unhex(h.jsonPrimitive.content))!!
            assertTrue(p.isParity)
            assertEquals(h.jsonPrimitive.content, hex(p.encoded()))
        }
        // a piece lost, rebuilt from the vector's parity piece
        val rx = RemoteVideoReceiver(nack = false, ltr = false)
        val key = RemoteVideoPacket.split(byteArrayOf(1, 2, 3), 42, true, 0.0)
        assertEquals(1, rx.add(key[0], 0.0).size)
        val wire = (refresh["hex"]!!.jsonArray.drop(1) + parity["hex"]!!.jsonArray).map { RemoteVideoPacket.decode(unhex(it.jsonPrimitive.content))!! }
        val got = wire.flatMap { rx.add(it, 0.01) }.filterIsInstance<RemoteVideoReceiver.Output.Frame>()
        assertEquals(1, got.size, "piece 0 rebuilt from parity")
        assertContentEquals(data, got[0].frame.data)

        for (f in r["feedback"]!!.jsonArray) {
            val h = f.jsonObject["hex"]!!.jsonPrimitive.content
            val name = f.jsonObject["name"]!!.jsonPrimitive.content
            val m = RemoteVideoFeedback.decode(unhex(h)) ?: fail("feedback $name didn't decode")
            assertEquals(h, hex(m.encoded()), "feedback $name")
            val expected = when (name) {
                "nack" -> RemoteVideoFeedback.Nack(listOf(RemoteVideoFeedback.Missing(43, listOf(1, 2)), RemoteVideoFeedback.Missing(44, emptyList())))
                "ack" -> RemoteVideoFeedback.Ack(43, 5)
                "lost" -> RemoteVideoFeedback.Lost(42)
                else -> fail("unknown feedback $name")
            }
            assertEquals(expected, m)
        }
        assertEquals(6, RemoteFrameKind.VIDEO_FEEDBACK.raw)
    }

    @Test
    fun cursor() {
        val c = v["cursor"]!!.jsonObject
        val x = c["x"]!!.jsonPrimitive.double.toFloat()
        val y = c["y"]!!.jsonPrimitive.double.toFloat()
        assertEquals(c["hex"]!!.jsonPrimitive.content, hex(RemoteCursor(x, y).encoded()))
        assertEquals(RemoteCursor(x, y), RemoteCursor.decode(unhex(c["hex"]!!.jsonPrimitive.content)))
        // to a phone that numbers its pointer instructions: the newest one this place includes
        val n = v["cursorSeq"]!!.jsonObject
        val numbered = RemoteCursor(n["x"]!!.jsonPrimitive.double.toFloat(), n["y"]!!.jsonPrimitive.double.toFloat(), n["seq"]!!.jsonPrimitive.long)
        assertEquals(258L, numbered.seq)
        assertEquals(n["hex"]!!.jsonPrimitive.content, hex(numbered.encoded()))
        assertEquals(numbered, RemoteCursor.decode(unhex(n["hex"]!!.jsonPrimitive.content)))
    }

    @Test
    fun theHandshakeByteForByte() {
        val h = v["handshake"]!!.jsonObject
        fun b(k: String) = unhex(h[k]!!.jsonPrimitive.content)
        val paired = b("paired")
        val phonePriv = b("phoneEphPrivate")
        val macPriv = b("macEphPrivate")
        val nonce = b("nonce")
        val id = h["id"]!!.jsonPrimitive.content
        assertContentEquals(bytes(1), paired, "the seeds are what RemoteVectorsTests.swift says")

        assertEquals(h["phoneEph"]!!.jsonPrimitive.content, hex(RemoteCrypto.publicKey(phonePriv)))
        assertEquals(h["macEph"]!!.jsonPrimitive.content, hex(RemoteCrypto.publicKey(macPriv)))
        val secret = RemoteCrypto.sharedSecret(phonePriv, b("macEph"))!!
        assertEquals(h["sharedSecret"]!!.jsonPrimitive.content, hex(secret))
        assertEquals(hex(secret), hex(RemoteCrypto.sharedSecret(macPriv, b("phoneEph"))!!))
        val t = RemoteCrypto.transcript(id, b("phoneEph"), b("macEph"))
        assertEquals(h["transcript"]!!.jsonPrimitive.content, hex(t))
        assertEquals(h["proof"]!!.jsonPrimitive.content, hex(RemoteCrypto.proof(paired, t)))
        val (toMac, toPhone) = RemoteCrypto.sessionKeys(secret, paired, t)
        assertEquals(h["keyToMac"]!!.jsonPrimitive.content, hex(toMac))
        assertEquals(h["keyToPhone"]!!.jsonPrimitive.content, hex(toPhone))
        assertEquals(h["commitment"]!!.jsonPrimitive.content, hex(RemoteCrypto.commitment(nonce)))
        assertEquals(h["check"]!!.jsonPrimitive.content, RemoteCrypto.check(t, nonce))

        // the two hellos, as each end writes them
        val phoneHandshake = PhoneHandshake(id, paired, phonePriv, nonce)
        val hello = phoneHandshake.hello()
        assertSameJson(h["phoneHello"]!!, Json.parseToJsonElement(hello.decodeToString()), "phone hello")
        val answer = MacHandshake.answer(hello, macPriv) { if (it == id) paired else null }
        assertSameJson(h["macHello"]!!, Json.parseToJsonElement(answer.reply.decodeToString()), "host hello")
        assertEquals(id, answer.id)
        assertContentEquals(paired, answer.key)
        assertContentEquals(b("commitment"), answer.commitment)
        val refused = MacHandshake.answer(hello, macPriv) { null }
        assertSameJson(h["macHelloRefused"]!!, Json.parseToJsonElement(refused.reply.decodeToString()), "refusal")
        assertNull(refused.sealer)
        assertEquals(RemoteHandshakeError.Kind.NOT_PAIRED, assertFailsWith<RemoteHandshakeError> { PhoneHandshake(id, paired, phonePriv, nonce).finish(refused.reply) }.kind)

        // the phone finishes from the vector's own reply bytes
        val phone = phoneHandshake.finish(J.bytes(h["macHello"]!!))
        val mac = answer.sealer!!
        assertEquals(h["check"]!!.jsonPrimitive.content, phone.check(nonce))
        assertEquals(h["check"]!!.jsonPrimitive.content, mac.check(nonce))

        val tcp = h["tcpPhoneToMac"]!!.jsonArray
        for ((i, f) in tcp.withIndex()) {
            val plain = unhex(f.jsonObject["plain"]!!.jsonPrimitive.content)
            val sealed = phone.seal(plain)
            assertEquals(f.jsonObject["sealed"]!!.jsonPrimitive.content, hex(sealed), "tcp phone→host $i")
            f.jsonObject["framed"]?.let { assertEquals(it.jsonPrimitive.content, hex(RemoteFrameReader.framed(sealed))) }
            assertContentEquals(plain, mac.open(sealed))
        }
        // the first sealed frame is the phone's hello, revealing the nonce it committed to
        val first = unhex(tcp[0].jsonObject["plain"]!!.jsonPrimitive.content)
        assertEquals(RemoteFrameKind.CONTROL, RemoteFrameKind.from(first[0].toInt()))
        val revealed = ToMac.decode(first.copyOfRange(1, first.size)) as ToMac.Hello
        assertEquals(ToMac.Hello("Pixel", true, nonce), revealed)
        assertTrue(RemoteCrypto.same(RemoteCrypto.commitment(revealed.nonce!!), answer.commitment!!))

        for ((i, f) in h["tcpMacToPhone"]!!.jsonArray.withIndex()) {
            val plain = unhex(f.jsonObject["plain"]!!.jsonPrimitive.content)
            val sealed = mac.seal(plain)
            assertEquals(f.jsonObject["sealed"]!!.jsonPrimitive.content, hex(sealed), "tcp host→phone $i")
            assertContentEquals(plain, phone.open(sealed))
            assertEquals(ToPhone.UdpOK, ToPhone.decode(plain.copyOfRange(1, plain.size)))
        }

        for (f in h["udpPhoneToMac"]!!.jsonArray) {
            val o = f.jsonObject
            val plain = unhex(o["plain"]!!.jsonPrimitive.content)
            val session = o["session"]!!.jsonPrimitive.int.toLong()
            val sealed = phone.sealPacket(plain, session)
            assertEquals(o["sealed"]!!.jsonPrimitive.content, hex(sealed), "udp ${o["counter"]}")
            assertEquals(session, RemoteSealer.sessionOfPacket(sealed))
            assertContentEquals(plain, mac.openPacket(sealed))
            assertNull(mac.openPacket(sealed), "a replay drops")
        }
    }

    @Test
    fun relayRoom() {
        val r = v["relayRoom"]!!.jsonObject
        assertEquals(r["room"]!!.jsonPrimitive.content, RemoteRelay.room(unhex(r["paired"]!!.jsonPrimitive.content)))
    }

    @Test
    fun pairingURLRoundTrip() {
        val url = v["pairingURL"]!!.jsonPrimitive.content
        val p = assertNotNull(RemotePairing.parse(url))
        assertEquals("host-id-1", p.macID)
        assertEquals("device-id-1", p.deviceID)
        assertContentEquals(bytes(1), p.key)
        assertEquals("Studio PC", p.macName)
        assertEquals(50123, p.port)
        assertEquals(listOf("192.168.1.20", "fe80::1"), p.addresses)
        assertEquals("wss://relay.example.com", p.relay)
        assertEquals(url, p.url, "written back exactly")
        assertEquals(p, RemotePairing.parse(p.url))
    }

    companion object {
        /** RemoteVectorsTests.swift's seeds: seed + i·7 */
        fun bytes(seed: Int, n: Int = 32) = ByteArray(n) { (seed + it * 7).toByte() }
    }
}
