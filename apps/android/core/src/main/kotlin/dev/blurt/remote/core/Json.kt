// Swift's synthesized Codable shape, written by hand (docs/design/remote-protocol.md §Messages): an enum case is an object with one key, the
// case's name; labelled values go by label, unlabelled ones as `_0`, `_1`; a case without values is `{}`; nil is left out; Data is standard
// base64 with padding. Readers ignore keys they don't know and give null for a case they don't know (a newer peer), never an exception.
package dev.blurt.remote.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.util.Base64

internal object J {
    val format = Json { ignoreUnknownKeys = true; isLenient = false }

    fun parse(bytes: ByteArray): JsonElement? = try {
        format.parseToJsonElement(bytes.toString(Charsets.UTF_8))
    } catch (_: Exception) {
        null
    }

    fun bytes(e: JsonElement): ByteArray = e.toString().toByteArray(Charsets.UTF_8)

    /** An object from pairs, the nil ones left out. */
    fun obj(vararg pairs: Pair<String, JsonElement?>): JsonObject =
        JsonObject(pairs.filter { it.second != null }.associate { it.first to it.second!! })

    /** `{"name": {fields}}` */
    fun case(name: String, vararg fields: Pair<String, JsonElement?>): JsonObject = JsonObject(mapOf(name to obj(*fields)))

    /** The one case in `{"name": {...}}`, or null if it isn't that shape. */
    fun case(e: JsonElement?): Pair<String, JsonObject>? {
        val o = e as? JsonObject ?: return null
        if (o.size != 1) return null
        val (k, v) = o.entries.first()
        return k to (v as? JsonObject ?: return null)
    }

    fun str(s: String?): JsonElement? = s?.let { JsonPrimitive(it) }
    fun bool(b: Boolean?): JsonElement? = b?.let { JsonPrimitive(it) }
    fun int(i: Long?): JsonElement? = i?.let { JsonPrimitive(it) }
    fun int(i: Int?): JsonElement? = i?.let { JsonPrimitive(it) }

    /** A whole number as one, as Swift writes it (24, not 24.0). */
    fun double(d: Double?): JsonElement? {
        d ?: return null
        if (!d.isFinite()) return null
        return if (d == Math.rint(d) && kotlin.math.abs(d) < 1e15) JsonPrimitive(d.toLong()) else JsonPrimitive(d)
    }

    /** Float's own shortest digits (0.1, not 0.10000000149011612). */
    fun float(f: Float?): JsonElement? {
        f ?: return null
        if (!f.isFinite()) return null
        return if (f == Math.rint(f.toDouble()).toFloat() && kotlin.math.abs(f) < 1e7f) JsonPrimitive(f.toLong()) else JsonPrimitive(f)
    }

    fun data(d: ByteArray?): JsonElement? = d?.let { JsonPrimitive(Base64.getEncoder().encodeToString(it)) }
    fun <T> list(l: List<T>?, f: (T) -> JsonElement): JsonElement? = l?.let { JsonArray(it.map(f)) }

    // Reading. Each gives null when the value is missing, null, or the wrong kind.
    private fun prim(e: JsonElement?): JsonPrimitive? = (e as? JsonPrimitive)?.takeIf { it !is JsonNull }

    fun str(o: JsonObject, k: String): String? = prim(o[k])?.takeIf { it.isString }?.content
    fun bool(o: JsonObject, k: String): Boolean? = prim(o[k])?.takeIf { !it.isString }?.booleanOrNull
    fun double(o: JsonObject, k: String): Double? = prim(o[k])?.takeIf { !it.isString }?.doubleOrNull
    fun float(o: JsonObject, k: String): Float? = double(o, k)?.toFloat()
    fun long(o: JsonObject, k: String): Long? {
        val p = prim(o[k])?.takeIf { !it.isString } ?: return null
        p.longOrNull?.let { return it }
        val d = p.doubleOrNull ?: return null
        return if (d == Math.rint(d) && kotlin.math.abs(d) < 9e15) d.toLong() else null
    }
    fun int(o: JsonObject, k: String): Int? = long(o, k)?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()
    fun uint16(o: JsonObject, k: String): Int? = long(o, k)?.takeIf { it in 0..0xFFFF }?.toInt()
    fun uint32(o: JsonObject, k: String): Long? = long(o, k)?.takeIf { it in 0..0xFFFF_FFFFL }

    fun data(o: JsonObject, k: String): ByteArray? = str(o, k)?.let {
        try {
            Base64.getDecoder().decode(it)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    fun obj(o: JsonObject, k: String): JsonObject? = o[k] as? JsonObject
    fun array(o: JsonObject, k: String): JsonArray? = o[k] as? JsonArray
    /** Every element read, or null if any can't be: Swift's decoder fails the whole array. */
    fun <T> list(o: JsonObject, k: String, f: (JsonElement) -> T?): List<T>? {
        val a = array(o, k) ?: return null
        val out = ArrayList<T>(a.size)
        for (e in a) out += f(e) ?: return null
        return out
    }

    fun has(o: JsonObject, k: String): Boolean = o[k] != null && o[k] !is JsonNull
}
