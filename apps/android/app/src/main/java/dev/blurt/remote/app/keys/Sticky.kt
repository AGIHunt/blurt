// The modifiers held on the computer (core's HeldModifiers, with the computer to tell).
package dev.blurt.remote.app.keys

import dev.blurt.remote.app.Remote
import dev.blurt.remote.core.HeldModifiers
import dev.blurt.remote.core.RemoteChord
import dev.blurt.remote.core.ToMac

fun Sticky() = HeldModifiers(
    tell = { Remote.link.send(ToMac.Mods(it)) },
    tellAltGr = { Remote.link.send(ToMac.Key(RemoteChord(0, "AltGr"), it)) },
    press = { Remote.link.send(ToMac.Key(RemoteChord(it, ""), null)) },
)
