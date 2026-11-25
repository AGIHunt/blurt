// The phone's settings, the same ones as on the iPhone (App/Prefs.swift). Plain SharedPreferences: nothing secret is here; the paired keys
// live in KeyVault.
package dev.blurt.remote.app

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ActivityInfo
import dev.blurt.remote.core.ScreenQuality
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Which way the screen is turned. Auto follows the phone, and the phone's own rotation lock. */
enum class ScreenTurn {
    AUTO, PORTRAIT, LANDSCAPE;

    /** Portrait and landscape hold whatever the rotation lock says; landscape still turns end over end. */
    val orientation: Int get() = when (this) {
        AUTO -> ActivityInfo.SCREEN_ORIENTATION_FULL_USER
        PORTRAIT -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        LANDSCAPE -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    }

    companion object {
        /** A phone's. On a tablet or an open foldable Android 16 ignores what an app asks for. */
        fun applies(c: Context) = c.resources.configuration.smallestScreenWidthDp < 600
    }
}

class Prefs(c: Context) {
    private val d: SharedPreferences = c.getSharedPreferences("prefs", Context.MODE_PRIVATE)
    private val _changed = MutableStateFlow(0)
    /** bumps on any change: the main screen re-reads what it needs */
    val changed: StateFlow<Int> = _changed

    private fun bump() { _changed.value += 1 }

    /** 1 = default; both ends of the slider stay usable */
    var pointerSpeed: Float
        get() = d.getFloat("pointerSpeed", 1f)
        set(v) { d.edit().putFloat("pointerSpeed", v).apply(); bump() }
    var scrollSpeed: Float
        get() = d.getFloat("scrollSpeed", 1f)
        set(v) { d.edit().putFloat("scrollSpeed", v).apply(); bump() }
    var reverseScroll: Boolean
        get() = d.getBoolean("reverseScroll", false)
        set(v) { d.edit().putBoolean("reverseScroll", v).apply(); bump() }
    var haptics: Boolean
        get() = d.getBoolean("haptics", true)
        set(v) { d.edit().putBoolean("haptics", v).apply(); bump() }
    /** the talk key and the arrow key at the other end, and the keys' panel on the left on a big screen */
    var lefty: Boolean
        get() = d.getBoolean("lefty", false)
        set(v) { d.edit().putBoolean("lefty", v).apply(); bump() }
    /** false: dictation listens through the computer's microphone */
    var micOnPhone: Boolean
        get() = d.getBoolean("micOnPhone", true)
        set(v) { d.edit().putBoolean("micOnPhone", v).apply(); bump() }
    /** a session is kept a while after the app leaves the screen (Link.background) */
    var stayConnected: Boolean
        get() = d.getBoolean("stayConnected", true)
        set(v) { d.edit().putBoolean("stayConnected", v).apply(); bump() }
    /** the picture comes on with the computer: from the first time, until the user turns it off (the founder, 2026-11-26) */
    var screenWanted: Boolean
        get() = d.getBoolean("screenWanted", true)
        set(v) { d.edit().putBoolean("screenWanted", v).apply() }
    /** with the computer's screen showing: a tap clicks what's under the finger. Off: a trackpad, clicking where the pointer is */
    var tapWhereTouched: Boolean
        get() = d.getBoolean("tapWhereTouched", true)
        set(v) { d.edit().putBoolean("tapWhereTouched", v).apply(); bump() }
    /** with the picture showing it fills the screen: only the talk key and a way out stay. The picture off, the keys are back */
    var fullScreen: Boolean
        get() = d.getBoolean("fullScreen", false)
        set(v) { d.edit().putBoolean("fullScreen", v).apply(); bump() }
    /** which way the screen is turned */
    var turn: ScreenTurn
        get() = runCatching { ScreenTurn.valueOf(d.getString("turn", null) ?: "AUTO") }.getOrDefault(ScreenTurn.AUTO)
        set(v) { d.edit().putString("turn", v.name).apply(); bump() }
    /** which keyboard the keyboard button opens: the computer's keys, or the phone's own for text. The one last used */
    var computerKeyboard: Boolean
        get() = d.getBoolean("computerKeyboard", false)
        set(v) { d.edit().putBoolean("computerKeyboard", v).apply() }
    /** it was open when last left: on a big screen it's open again; a phone never starts with it */
    var boardOpen: Boolean
        get() = d.getBoolean("boardOpen", false)
        set(v) { d.edit().putBoolean("boardOpen", v).apply() }
    /** look for a newer version on GitHub once a day (Updates.kt) */
    var autoUpdateCheck: Boolean
        get() = d.getBoolean("autoUpdateCheck", true)
        set(v) { d.edit().putBoolean("autoUpdateCheck", v).apply(); bump() }
    /** when it last got an answer, in ms */
    var updateCheckedAt: Long
        get() = d.getLong("updateCheckedAt", 0)
        set(v) { d.edit().putLong("updateCheckedAt", v).apply() }
    /** the line over the picture the first time it showed (two fingers scroll, pinch with ⌘ held) */
    var pictureHintShown: Boolean
        get() = d.getBoolean("pictureHintShown", false)
        set(v) { d.edit().putBoolean("pictureHintShown", v).apply() }
    var quality: ScreenQuality
        get() = runCatching { ScreenQuality.valueOf(d.getString("quality", null) ?: "AUTO") }.getOrDefault(ScreenQuality.AUTO)
        set(v) { d.edit().putString("quality", v.name).apply(); bump() }

    fun string(k: String): String? = d.getString(k, null)
    fun putString(k: String, v: String?) { d.edit().putString(k, v).apply() }
}
