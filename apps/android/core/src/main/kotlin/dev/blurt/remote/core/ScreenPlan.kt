// How much of the screen to ask for (Swift: apps/ios/BlurtRemote/Pad/ScreenPlan.swift; docs/design/remote.md §What it costs). One choice for
// the user, not a frame rate, a resolution and a bitrate. Auto knows what the phone is on. Whatever this says is a ceiling: under it the host
// follows the network by itself (RemoteRate).
//
//   Auto, same network          the phone's width   12 Mbps  the panel's rate (60, 90, 120)
//   Auto, Wi-Fi elsewhere       1800 on a phone, a tablet's own (two pixels a dp)   4–8 Mbps  30 fps
//   Auto, mobile data           1440                 2 Mbps  24 fps
//   Auto, Data Saver            1280                 1 Mbps  15 fps   (Android's Data Saver is iOS's Low Data Mode)
//   Sharp away / Balanced       the phone's / 1800   8 / 4   30 fps
package dev.blurt.remote.core

import kotlin.math.max
import kotlin.math.min

enum class ScreenQuality(val raw: String) {
    AUTO("auto"), SHARP("sharp"), BALANCED("balanced"), SAVER("saver");

    /** What it's called in Settings (English; the app localises). */
    val title: String
        get() = when (this) {
            AUTO -> "Auto"; SHARP -> "Sharp"; BALANCED -> "Balanced"; SAVER -> "Data Saver"
        }

    /** The most it can cost: a still screen costs next to nothing. */
    val detail: String
        get() = when (this) {
            AUTO -> "Sharpest on your own network, lighter on mobile data"
            SHARP -> "At most about 90 MB a minute, 60 frames at home"
            BALANCED -> "At most about 30 MB a minute, 30 frames"
            SAVER -> "At most about 8 MB a minute, 15 frames"
        }

    companion object { fun from(raw: String?): ScreenQuality = entries.firstOrNull { it.raw == raw } ?: AUTO }
}

/** Which way the session reaches the host (iOS: Link.Route). Local = the same network, or Wi-Fi Direct. */
enum class LinkRoute { LOCAL, DIRECT, RELAY }

data class ScreenPlan(val width: Int, val height: Int, val bitrate: Int, val fps: Int) {
    companion object {
        /**
         * `cellular`: the phone is on mobile data (a public address on mobile data isn't home). `lowData`: Data Saver is on.
         * `native`: the phone's screen in pixels, either way round. `panel`: the display's top refresh rate. At home the picture comes at up
         * to that (120 on a 120 Hz panel): a frame waits half as long for its turn, and scrolling moves as the phone's own does. The bitrate
         * ceiling stays, so it costs no more data, only motion's share of it. `scale`: the panel's pixels per dp. Away on Wi-Fi, Auto on
         * a big screen (1000 dp or more the long way: a tablet, a foldable open) asks for two pixels a dp: 1800 across was the picture
         * stretched there, and text soft however long it stood. A phone stays at 1800, already two pixels a dp. The rate goes with the
         * pixels, 4 Mbps for 1800 across up to 8.
         */
        operator fun invoke(
            q: ScreenQuality, route: LinkRoute, cellular: Boolean, lowData: Boolean, native: PadSize, panel: Int = 60, scale: Double = 3.0,
        ): ScreenPlan {
            val long = max(native.width, native.height).toInt()
            val short = min(native.width, native.height).toInt()
            fun size(w: Int, h: Int) = min(long, w) to min(short, h)
            val tier = if (q == ScreenQuality.AUTO) {
                if (lowData) ScreenQuality.SAVER else if (route == LinkRoute.LOCAL && !cellular) ScreenQuality.SHARP else ScreenQuality.BALANCED
            } else q
            return when {
                tier == ScreenQuality.SAVER -> size(1280, 800).let { ScreenPlan(it.first, it.second, 1_000_000, 15) }
                tier == ScreenQuality.SHARP && route == LinkRoute.LOCAL -> ScreenPlan(long, short, 12_000_000, min(120, max(60, panel)))
                tier == ScreenQuality.SHARP -> ScreenPlan(long, short, 8_000_000, 30)
                // data the user pays for, and nobody asked for less: most of the picture for less than half
                q == ScreenQuality.AUTO && cellular -> size(1440, 900).let { ScreenPlan(it.first, it.second, 2_000_000, 24) }
                else -> {
                    val two = Math.round(long / max(scale, 1.0) * 2).toInt()
                    val across = if (q == ScreenQuality.AUTO && two >= 2000) min(long, two) / 2 * 2 else 1800
                    val (w, h) = size(across, across * 11 / 36 * 2)
                    ScreenPlan(w, h, min(8_000_000, max(4_000_000, (w.toDouble() * h / (1800 * 1100) * 4_000_000).toInt())), 30)
                }
            }
        }
    }
}
