// How much of the screen to ask for (Swift: apps/ios/BlurtRemote/Pad/ScreenPlan.swift; docs/design/remote.md §What it costs). One choice for
// the user, not a frame rate, a resolution and a bitrate. Auto knows what the phone is on. Whatever this says is a ceiling: under it the host
// follows the network by itself (RemoteRate).
//
//   Auto, same network          the phone's width   12 Mbps  60 fps
//   Auto, Wi-Fi elsewhere       1800                 4 Mbps  30 fps
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
         * `native`: the phone's screen in pixels, either way round.
         */
        operator fun invoke(q: ScreenQuality, route: LinkRoute, cellular: Boolean, lowData: Boolean, native: PadSize): ScreenPlan {
            val long = max(native.width, native.height).toInt()
            val short = min(native.width, native.height).toInt()
            fun size(w: Int, h: Int) = min(long, w) to min(short, h)
            val tier = if (q == ScreenQuality.AUTO) {
                if (lowData) ScreenQuality.SAVER else if (route == LinkRoute.LOCAL && !cellular) ScreenQuality.SHARP else ScreenQuality.BALANCED
            } else q
            return when {
                tier == ScreenQuality.SAVER -> size(1280, 800).let { ScreenPlan(it.first, it.second, 1_000_000, 15) }
                tier == ScreenQuality.SHARP && route == LinkRoute.LOCAL -> ScreenPlan(long, short, 12_000_000, 60)
                tier == ScreenQuality.SHARP -> ScreenPlan(long, short, 8_000_000, 30)
                // data the user pays for, and nobody asked for less: most of the picture for less than half
                q == ScreenQuality.AUTO && cellular -> size(1440, 900).let { ScreenPlan(it.first, it.second, 2_000_000, 24) }
                else -> size(1800, 1100).let { ScreenPlan(it.first, it.second, 4_000_000, 30) }
            }
        }
    }
}
