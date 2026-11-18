// The session's cryptography (Swift: RemoteCrypto.swift; docs/design/remote-protocol.md §Layers, remote.md §Security). BouncyCastle's
// lightweight API, so it runs the same on every Android version: the platform's own X25519 and ChaCha20-Poly1305 are uneven before API 33.
//
//    phone → host   hello  {v, id, eph, c}      in the clear; `id` picks the paired key, `c` commits to a nonce
//    host → phone   hello  {v, eph, proof}      proof = HMAC(paired key, "mac" ∥ transcript)
//    phone → host   first sealed frame          ToMac.Hello, revealing the nonce: only the paired key could have sealed it
package dev.blurt.remote.core

import kotlinx.serialization.json.JsonObject
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.macs.HMac
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import java.util.Base64

object RemoteCrypto {
    const val VERSION = 1

    private val random = SecureRandom()

    fun random(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }
    fun newKey(): ByteArray = random(32)
    fun newID(): String = base64url(random(16))

    /** base64url without padding */
    fun base64url(d: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(d)

    fun base64url(s: String): ByteArray? {
        var t = s.replace('+', '-').replace('/', '_')
        while (t.length % 4 != 0) t += "="
        return try {
            Base64.getUrlDecoder().decode(t)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val d = SHA256Digest()
        for (p in parts) d.update(p, 0, p.size)
        return ByteArray(32).also { d.doFinal(it, 0) }
    }

    fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val m = HMac(SHA256Digest())
        m.init(KeyParameter(key))
        for (p in parts) m.update(p, 0, p.size)
        return ByteArray(32).also { m.doFinal(it, 0) }
    }

    /** SHA-256("blurt-remote-1" ∥ id ∥ phoneEph ∥ hostEph) */
    fun transcript(id: String, phoneEph: ByteArray, macEph: ByteArray): ByteArray =
        sha256("blurt-remote-$VERSION".toByteArray(), id.toByteArray(Charsets.UTF_8), phoneEph, macEph)

    /** Six digits both ends show while a new phone waits for a yes: SHA-256("check" ∥ transcript ∥ nonce), first 4 bytes BE mod 10⁶. */
    fun check(transcript: ByteArray, nonce: ByteArray): String {
        val h = sha256("check".toByteArray(), transcript, nonce)
        val n = ByteBuffer.wrap(h, 0, 4).order(ByteOrder.BIG_ENDIAN).getInt().toLong() and 0xFFFF_FFFFL
        return "%06d".format(n % 1_000_000)
    }

    fun commitment(nonce: ByteArray): ByteArray = sha256("commit".toByteArray(), nonce)

    /** Equal keys, compared in constant time. */
    fun same(a: ByteArray, b: ByteArray): Boolean {
        if (a.size != b.size) return false
        var r = 0
        for (i in a.indices) r = r or (a[i].toInt() xor b[i].toInt())
        return r == 0
    }

    fun proof(paired: ByteArray, transcript: ByteArray): ByteArray = hmac(paired, "mac".toByteArray(), transcript)

    /** The raw X25519 public key for a 32-byte private one (clamped as RFC 7748 says). */
    fun publicKey(privateKey: ByteArray): ByteArray = X25519PrivateKeyParameters(privateKey, 0).generatePublicKey().encoded

    /** null for a public key that gives the all-zero secret (a small-order point), as CryptoKit refuses it. */
    fun sharedSecret(privateKey: ByteArray, publicKey: ByteArray): ByteArray? {
        if (publicKey.size != 32) return null
        val a = X25519Agreement()
        a.init(X25519PrivateKeyParameters(privateKey, 0))
        val out = ByteArray(32)
        return try {
            a.calculateAgreement(X25519PublicKeyParameters(publicKey, 0), out, 0)
            if (out.all { it.toInt() == 0 }) null else out
        } catch (_: IllegalStateException) {
            null
        }
    }

    /** HKDF-SHA256(ikm = secret, salt = paired, info = transcript, 64): first 32 phone→host, last 32 host→phone. */
    fun sessionKeys(secret: ByteArray, paired: ByteArray, transcript: ByteArray): Pair<ByteArray, ByteArray> {
        val g = HKDFBytesGenerator(SHA256Digest())
        g.init(HKDFParameters(secret, paired, transcript))
        val k = ByteArray(64)
        g.generateBytes(k, 0, 64)
        return k.copyOfRange(0, 32) to k.copyOfRange(32, 64)
    }

    internal fun b64(d: ByteArray): String = Base64.getEncoder().encodeToString(d)
}

class RemoteHandshakeError(val kind: Kind) : Exception(kind.name) {
    enum class Kind { NOT_PAIRED, BAD_PROOF, BAD_MESSAGE, VERSION }
}

class RemoteFrameError : Exception("bad frame length")

/** The phone's end of the handshake. `ephemeral` and `nonce` are fresh unless given (tests reproduce the vectors with fixed ones). */
class PhoneHandshake(
    val id: String,
    private val paired: ByteArray,
    private val ephemeral: ByteArray = RemoteCrypto.newKey(),
    /** committed to in the hello, revealed in the first sealed message (ToMac.Hello): it goes into the six digits */
    val nonce: ByteArray = RemoteCrypto.newKey(),
) {
    val publicKey: ByteArray = RemoteCrypto.publicKey(ephemeral)

    fun hello(): ByteArray = J.bytes(
        J.obj("v" to J.int(RemoteCrypto.VERSION), "id" to J.str(id), "eph" to J.data(publicKey), "c" to J.data(RemoteCrypto.commitment(nonce))),
    )

    /** The host's reply → the session's sealer. Throws RemoteHandshakeError. */
    fun finish(reply: ByteArray): RemoteSealer {
        val m = J.parse(reply) as? JsonObject ?: throw RemoteHandshakeError(RemoteHandshakeError.Kind.BAD_MESSAGE)
        val v = J.int(m, "v") ?: throw RemoteHandshakeError(RemoteHandshakeError.Kind.BAD_MESSAGE)
        if (J.str(m, "error") == "not_paired") throw RemoteHandshakeError(RemoteHandshakeError.Kind.NOT_PAIRED)
        if (v != RemoteCrypto.VERSION) throw RemoteHandshakeError(RemoteHandshakeError.Kind.VERSION)
        val e = J.data(m, "eph")
        val proof = J.data(m, "proof")
        if (e == null || proof == null || e.size != 32) throw RemoteHandshakeError(RemoteHandshakeError.Kind.BAD_MESSAGE)
        val secret = RemoteCrypto.sharedSecret(ephemeral, e) ?: throw RemoteHandshakeError(RemoteHandshakeError.Kind.BAD_MESSAGE)
        val t = RemoteCrypto.transcript(id, publicKey, e)
        if (!RemoteCrypto.same(proof, RemoteCrypto.proof(paired, t))) throw RemoteHandshakeError(RemoteHandshakeError.Kind.BAD_PROOF)
        val (toMac, toPhone) = RemoteCrypto.sessionKeys(secret, paired, t)
        return RemoteSealer(toMac, toPhone, t)
    }
}

/** The host's end: `lookup` says which paired key an id has (null: not one of ours). For tests and loopback; hosts have their own. */
object MacHandshake {
    class Answer(
        val reply: ByteArray,
        val sealer: RemoteSealer?,
        val id: String?,
        /** the paired key the handshake used */
        val key: ByteArray? = null,
        /** what the phone committed to */
        val commitment: ByteArray? = null,
    )

    fun answer(hello: ByteArray, ephemeral: ByteArray = RemoteCrypto.newKey(), lookup: (String) -> ByteArray?): Answer {
        fun refuse(e: String) = Answer(J.bytes(J.obj("v" to J.int(RemoteCrypto.VERSION), "error" to J.str(e))), null, null)
        val h = J.parse(hello) as? JsonObject ?: return refuse("bad_message")
        val v = J.int(h, "v")
        val id = J.str(h, "id")
        val eph = J.data(h, "eph")
        if (v == null || id == null || eph == null) return refuse("bad_message")
        val c = if (J.has(h, "c")) J.data(h, "c") ?: return refuse("bad_message") else null
        if (v != RemoteCrypto.VERSION) return refuse("version")
        val paired = lookup(id) ?: return refuse("not_paired")
        if (eph.size != 32) return refuse("bad_message")
        val secret = RemoteCrypto.sharedSecret(ephemeral, eph) ?: return refuse("bad_message")
        val macEph = RemoteCrypto.publicKey(ephemeral)
        val t = RemoteCrypto.transcript(id, eph, macEph)
        val (toMac, toPhone) = RemoteCrypto.sessionKeys(secret, paired, t)
        val reply = J.obj("v" to J.int(RemoteCrypto.VERSION), "eph" to J.data(macEph), "proof" to J.data(RemoteCrypto.proof(paired, t)))
        return Answer(J.bytes(reply), RemoteSealer(toPhone, toMac, t), id, paired, c)
    }
}

/**
 * Seals and opens a session's frames. Not thread-safe: each side uses it from one thread or under one lock.
 * Nonce = u32 BE channel ∥ u64 BE counter. TCP: channel 0, counters from 0, implicit. UDP: channel 1, counters from 1, in the packet.
 */
class RemoteSealer(private val sendKey: ByteArray, private val receiveKey: ByteArray, val transcript: ByteArray = ByteArray(0)) {
    private var sent = 0L
    private var received = 0L
    private var sentUDP = 0L
    private var receivedUDP = 0L
    private var seenUDP = 0L

    /** the six digits for this session, with the phone's nonce */
    fun check(nonce: ByteArray): String = RemoteCrypto.check(transcript, nonce)

    /** TCP: the frame is ciphertext ∥ tag; the nonce is how many came before. */
    fun seal(plain: ByteArray): ByteArray {
        val f = aead(true, sendKey, nonce(0, sent), plain, 0, plain.size)
        sent += 1
        return f
    }

    /** Throws for a frame that isn't the next one sealed with the other side's key; the session is over then. */
    fun open(frame: ByteArray): ByteArray {
        if (frame.size < 16) throw IllegalArgumentException("short frame")
        val d = aead(false, receiveKey, nonce(0, received), frame, 0, frame.size)
        received += 1
        return d
    }

    /** UDP: session (4) ∥ counter (8) ∥ ciphertext ∥ tag. The session id isn't secret: it finds the session on the host. */
    fun sealPacket(plain: ByteArray, session: Long): ByteArray {
        sentUDP += 1
        val sealed = aead(true, sendKey, nonce(1, sentUDP), plain, 0, plain.size)
        return ByteBuffer.allocate(12 + sealed.size).order(ByteOrder.BIG_ENDIAN).putInt(session.toInt()).putLong(sentUDP).put(sealed).array()
    }

    /**
     * null: forged, damaged, or a replay. Wi-Fi reorders a little and a frame's pieces come in any order, so anything in the last 64
     * counters that hasn't been seen is taken; older drops.
     */
    fun openPacket(p: ByteArray): ByteArray? {
        if (p.size < 28) return null
        val n = ByteBuffer.wrap(p, 4, 8).order(ByteOrder.BIG_ENDIAN).getLong()
        if (n == 0L) return null
        if (java.lang.Long.compareUnsigned(n, receivedUDP) <= 0) {
            val back = receivedUDP - n
            if (java.lang.Long.compareUnsigned(back, 64) >= 0 || seenUDP and (1L shl back.toInt()) != 0L) return null
        }
        val d = try {
            aead(false, receiveKey, nonce(1, n), p, 12, p.size - 12)
        } catch (_: Exception) {
            return null
        }
        if (java.lang.Long.compareUnsigned(n, receivedUDP) > 0) {
            val up = n - receivedUDP
            seenUDP = if (java.lang.Long.compareUnsigned(up, 64) >= 0) 0 else seenUDP shl up.toInt()
            receivedUDP = n
            seenUDP = seenUDP or 1
        } else {
            seenUDP = seenUDP or (1L shl (receivedUDP - n).toInt())
        }
        return d
    }

    companion object {
        /** The session a datagram names, u32, or null for one too short to be ours. */
        fun sessionOfPacket(p: ByteArray): Long? {
            if (p.size < 28) return null
            return ByteBuffer.wrap(p, 0, 4).order(ByteOrder.BIG_ENDIAN).getInt().toLong() and 0xFFFF_FFFFL
        }

        private fun nonce(channel: Int, n: Long): ByteArray = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN).putInt(channel).putLong(n).array()

        private fun aead(encrypt: Boolean, key: ByteArray, nonce: ByteArray, input: ByteArray, off: Int, len: Int): ByteArray {
            val c = ChaCha20Poly1305()
            c.init(encrypt, AEADParameters(KeyParameter(key), 128, nonce))
            val out = ByteArray(c.getOutputSize(len))
            val n = c.processBytes(input, off, len, out, 0)
            val m = c.doFinal(out, n)
            return if (n + m == out.size) out else out.copyOf(n + m)
        }
    }
}

/**
 * Length-prefixed frames over a byte stream: 4 bytes big-endian, then the frame. Until the handshake is done a frame can only be a hello,
 * so `limit` stays small (1 KB); after the first sealed frame, set it to MAX_FRAME (1 MiB). A length of 0 or over the limit throws.
 */
class RemoteFrameReader {
    var limit = MAX_HELLO
    private var buffer = ByteArray(0)
    private var head = 0

    /** Next whole frame, or null when more bytes are needed. Throws RemoteFrameError for a frame that can't be ours. */
    fun next(): ByteArray? {
        if (buffer.size - head < 4) return null
        val n = ByteBuffer.wrap(buffer, head, 4).order(ByteOrder.BIG_ENDIAN).getInt().toLong() and 0xFFFF_FFFFL
        if (n <= 0 || n > limit) throw RemoteFrameError()
        if (buffer.size - head < 4 + n) return null
        val f = buffer.copyOfRange(head + 4, head + 4 + n.toInt())
        head += 4 + n.toInt()
        if (head == buffer.size) {
            buffer = ByteArray(0)
            head = 0
        }
        return f
    }

    fun feed(d: ByteArray) {
        if (head > 0) {
            buffer = buffer.copyOfRange(head, buffer.size)
            head = 0
        }
        buffer += d
    }

    companion object {
        const val MAX_FRAME = 1 shl 20
        const val MAX_HELLO = 1024

        fun framed(d: ByteArray): ByteArray = ByteBuffer.allocate(4 + d.size).order(ByteOrder.BIG_ENDIAN).putInt(d.size).put(d).array()
    }
}
