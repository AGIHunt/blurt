// The look: an instrument in the dark, as on the iPhone (apps/ios/BlurtRemote/App/Theme.swift). True black, keys as slabs barely lighter
// than it, white marks. Mint means one thing, as everywhere in Blurt: it is listening (docs/design/system.md §1).
package dev.blurt.remote.app

import android.content.Context
import android.content.res.Resources
import android.graphics.Color
import android.graphics.Typeface
import androidx.core.content.res.ResourcesCompat

object Theme {
    val mint = Color.rgb(0x61, 0xDB, 0xBD)
    val onMint = Color.rgb(0x04, 0x26, 0x1E)
    val slab = white(0.135f)
    val slabPressed = white(0.27f)
    /** the key that ends things, findable at a glance: Return */
    val slabStrong = white(0.21f)
    val edge = Color.argb(18, 255, 255, 255)
    val glass = white(0.04f)
    val slabLatched = white(0.88f)
    val hairline = white(0.17f)
    val mark = Color.argb(230, 255, 255, 255)
    val caption = Color.argb(168, 255, 255, 255)
    val faint = Color.argb(107, 255, 255, 255)
    val talkRest = Color.rgb(33, 51, 47)
    /** the sheets' accent: Blurt's teal, a shade deeper than mint so it never reads as "listening" */
    val accent = Color.rgb(26, 164, 135)
    const val RADIUS = 16f
    const val KEY_RADIUS = 11f

    private fun white(v: Float): Int { val c = (v * 255).toInt(); return Color.rgb(c, c, c) }
}

/** dp to px: the layout is written in dp, which match the iPhone's points closely (a Pixel is 412 dp wide, an iPhone 17 Pro 402 pt). */
val Float.dp: Float get() = this * Resources.getSystem().displayMetrics.density
val Int.dp: Float get() = this * Resources.getSystem().displayMetrics.density
val Float.px2dp: Float get() = this / Resources.getSystem().displayMetrics.density

object Fonts {
    private var symbols: Typeface? = null
    private var symbolsFilled: Typeface? = null
    fun symbols(c: Context): Typeface = symbols ?: (ResourcesCompat.getFont(c, R.font.symbols) ?: Typeface.DEFAULT).also { symbols = it }
    fun symbolsFilled(c: Context): Typeface = symbolsFilled ?: (ResourcesCompat.getFont(c, R.font.symbols_fill) ?: Typeface.DEFAULT).also { symbolsFilled = it }
    val text: Typeface = Typeface.create("sans-serif", Typeface.NORMAL)
    val medium: Typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
}
