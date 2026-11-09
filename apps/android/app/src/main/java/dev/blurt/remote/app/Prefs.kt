// The phone's settings, the same ones as on the iPhone (App/Prefs.swift). Plain SharedPreferences: nothing secret is here; the paired keys
// live in KeyVault.
package dev.blurt.remote.app

import android.content.Context
import android.content.SharedPreferences
import dev.blurt.remote.core.ScreenQuality
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

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
    /** with the computer's screen showing: a tap clicks what's under the finger. Off: a trackpad, clicking where the pointer is */
    var tapWhereTouched: Boolean
        get() = d.getBoolean("tapWhereTouched", true)
        set(v) { d.edit().putBoolean("tapWhereTouched", v).apply(); bump() }
    var quality: ScreenQuality
        get() = runCatching { ScreenQuality.valueOf(d.getString("quality", null) ?: "AUTO") }.getOrDefault(ScreenQuality.AUTO)
        set(v) { d.edit().putString("quality", v.name).apply(); bump() }

    fun string(k: String): String? = d.getString(k, null)
    fun putString(k: String, v: String?) { d.edit().putString(k, v).apply() }
}
