// The phone's keyboard as the computer's (port of Keys/TypeField.swift). Words go across as they're committed, so a Chinese input method
// composes here and only the chosen words reach the computer. Delete with nothing here deletes there, Return is Return, and with ⌘ held a
// letter is a shortcut, not text. Suggestions are off: what's typed is what lands.
package dev.blurt.remote.app.keys

import android.content.Context
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import dev.blurt.remote.app.Haptics
import dev.blurt.remote.app.Remote
import dev.blurt.remote.core.RemoteChord
import dev.blurt.remote.core.RemoteKey
import dev.blurt.remote.core.ToMac

class TypeField(c: Context) : View(c) {
    var onSent: (() -> Unit)? = null
    var open = false
        private set

    init {
        isFocusable = true
        isFocusableInTouchMode = true
    }

    override fun onCheckIsTextEditor() = true

    fun show() {
        open = true
        requestFocus()
        (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(this, 0)
    }

    fun hide() {
        open = false
        (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(windowToken, 0)
        clearFocus()
    }

    private fun send(m: ToMac) {
        Remote.link.send(m)
        Remote.sticky.used()
        onSent?.invoke()
    }

    private fun key(name: String) = send(ToMac.Key(RemoteChord(0, name), null))

    private fun text(s: String) {
        if (s.isEmpty()) return
        if (s == "\n") return key("Return")
        val held = Remote.sticky.held
        val k = if (held != 0 && s.codePointCount(0, s.length) == 1) RemoteKey.named(s.uppercase()) else null
        if (k != null) send(ToMac.Key(RemoteChord(held, k.name), null)) else send(ToMac.Text(s))
    }

    override fun onCreateInputConnection(out: EditorInfo): InputConnection {
        out.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        out.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_ACTION_NONE or
            EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        out.initialSelStart = 0
        out.initialSelEnd = 0
        return object : BaseInputConnection(this, false) {
            override fun commitText(t: CharSequence?, newCursorPosition: Int): Boolean {
                editable?.clear()
                text(t?.toString() ?: "")
                return true
            }

            override fun finishComposingText(): Boolean {
                // a composition left as it is (the keyboard closed mid-word): what was there goes as typed
                val e = editable
                val s = e?.toString().orEmpty()
                val r = super.finishComposingText()
                if (s.isNotEmpty()) { e?.clear(); text(s) }
                return r
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                val e = editable
                if (e.isNullOrEmpty()) {
                    Haptics.step()
                    repeat(maxOf(1, beforeLength)) { key("Delete") }
                    return true
                }
                return super.deleteSurroundingText(beforeLength, afterLength)
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean {
                if (event.action == KeyEvent.ACTION_DOWN) when (event.keyCode) {
                    KeyEvent.KEYCODE_DEL -> if (editable.isNullOrEmpty()) { Haptics.step(); key("Delete"); return true }
                    KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> { key("Return"); return true }
                    KeyEvent.KEYCODE_TAB -> { key("Tab"); return true }
                    else -> {
                        val ch = event.unicodeChar
                        if (ch != 0) { text(String(Character.toChars(ch))); return true }
                    }
                }
                if (event.action == KeyEvent.ACTION_UP) return true
                return super.sendKeyEvent(event)
            }

            override fun performEditorAction(actionCode: Int): Boolean {
                key("Return")
                return true
            }
        }
    }
}
