// Settings (port of Sheets/SettingsSheet.swift): the computers, what the screen may cost, the trackpad, dictation, which hand, and every
// gesture written out.
package dev.blurt.remote.app.sheets

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.blurt.remote.app.BuildConfig
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.keys.DeckText
import dev.blurt.remote.app.net.Link
import dev.blurt.remote.app.net.PairedMac
import dev.blurt.remote.app.pad.PadScreen
import dev.blurt.remote.core.LinkRoute
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.core.ScreenQuality
import dev.blurt.remote.core.ToMac

@Composable
fun SettingsSheet(screen: PadScreen, onClose: () -> Unit, onPair: () -> Unit) {
    var details by remember { mutableStateOf<PairedMac?>(null) }
    var editing by remember { mutableStateOf(false) }
    val d = details
    when {
        d != null -> MacDetail(d, onBack = { details = null })
        editing -> KeyEditor(screen, onClose = { editing = false }, back = true)
        else -> Settings(onClose, onPair, onDetails = { details = it }, onEdit = { editing = true })
    }
}

@Composable
private fun Settings(onClose: () -> Unit, onPair: () -> Unit, onDetails: (PairedMac) -> Unit, onEdit: () -> Unit) {
    val l = Remote.link
    val p = Remote.prefs
    val macs by l.macs.collectAsState()
    val cur by l.current.collectAsState()
    val state by l.state.collectAsState()
    val route by l.route.collectAsState()
    val nearby by l.nearby.collectAsState()
    val use by Remote.screen.use.collectAsState()
    val host by l.host.collectAsState()
    val ctx = LocalContext.current
    // the settings as they are, re-read when any changes
    val changed by p.changed.collectAsState()
    DisposableEffect(Unit) {
        l.watchNearby(true)
        onDispose { l.watchNearby(false) }
    }
    changed.hashCode()

    Column(Modifier.fillMaxSize()) {
        SheetTop(stringResource(R.string.settings), actions = { TextButton(onClose) { Text(stringResource(R.string.done)) } })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 32.dp)) {
            Section(stringResource(R.string.computers), if (macs.size > 1) stringResource(R.string.computers_footer) else null) {
                for (m in macs) {
                    MacRow(m, m.id == cur?.id, stateOf(m, cur, state, route, nearby), onPick = { if (m.id != cur?.id) { l.choose(m); onClose() } }, onInfo = { onDetails(m) })
                    Divider()
                }
                Row2(stringResource(R.string.add_computer), modifier = Modifier.clickable(onClick = onPair)) { Sym("add", color = MaterialTheme.colorScheme.primary) }
            }
            Section(stringResource(R.string.computer_screen), stringResource(R.string.screen_footer)) {
                for (q in ScreenQuality.entries) {
                    Row(Modifier.fillMaxWidth().selectable(p.quality == q, role = Role.RadioButton) { p.quality = q }.padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(p.quality == q, null, Modifier.padding(horizontal = 8.dp))
                        Column {
                            Text(DeckText.tr(q.title), style = MaterialTheme.typography.bodyLarge)
                            Text(DeckText.tr(q.detail), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                if (use.running) {
                    Divider()
                    Row2(stringResource(R.string.now), "${rate(use.kbps)} · ${use.fps} fps")
                    Row2(stringResource(R.string.used_since_opening), android.text.format.Formatter.formatShortFileSize(ctx, use.total))
                }
            }
            Section(footer = stringResource(R.string.touch_mode_footer)) {
                ToggleRow(stringResource(R.string.touch_mode), p.tapWhereTouched) { p.tapWhereTouched = it }
            }
            Section(stringResource(R.string.keys)) {
                Row2(stringResource(R.string.edit_keys), modifier = Modifier.clickable(onClick = onEdit)) { Sym("keyboard_arrow_right", color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            Section(stringResource(R.string.trackpad)) {
                SliderRow(stringResource(R.string.pointer_speed), p.pointerSpeed, 0.4f..2.2f) { p.pointerSpeed = it }
                SliderRow(stringResource(R.string.scroll_speed), p.scrollSpeed, 0.2f..2.2f) { p.scrollSpeed = it }
                ToggleRow(stringResource(R.string.reverse_scrolling), p.reverseScroll) { p.reverseScroll = it }
                ToggleRow(stringResource(R.string.haptics), p.haptics) { p.haptics = it }
            }
            Section(stringResource(R.string.dictation), stringResource(R.string.mic_footer)) {
                ToggleRow(stringResource(R.string.use_phone_mic), p.micOnPhone) {
                    p.micOnPhone = it
                    l.send(ToMac.SetMicOnPhone(Remote.mic.usable))
                }
            }
            Section(footer = stringResource(R.string.lefty_footer)) {
                ToggleRow(stringResource(R.string.left_handed), p.lefty) { p.lefty = it }
            }
            Section(stringResource(R.string.gestures)) {
                val mod = if (host == RemoteHost.MAC) "⇧ ⌘ ⌥ ⌃" else "Shift Ctrl Alt Win"
                val cyc = if (host == RemoteHost.MAC) "⌘Tab, ⌃Tab, ⌘`" else "Alt+Tab, Ctrl+Tab"
                for ((a, b) in listOf(
                    R.string.g_tap to R.string.g_click, R.string.g_tap_drag to R.string.g_drag, R.string.g_hold_lift to R.string.g_right_click,
                    R.string.g_hold_drag to R.string.g_select_area, R.string.g_tap_touch to R.string.g_click_there, R.string.g_edge to R.string.g_scroll,
                    R.string.g_two to R.string.g_two_does, R.string.g_two_touch to R.string.g_scroll_under, R.string.g_pinch to R.string.g_zoom,
                    R.string.g_pinch_screen to R.string.g_zoom_picture, R.string.g_one_zoomed to R.string.g_move_picture,
                    R.string.g_pointer_zoomed to R.string.g_follows,
                )) GestureRow(stringResource(a), stringResource(b))
                GestureRow(stringResource(R.string.g_cycle, cyc), stringResource(R.string.g_step_both))
                GestureRow(stringResource(R.string.g_arrow_tap), stringResource(R.string.g_arrow_tap_does))
                GestureRow(stringResource(R.string.g_arrow_drag), stringResource(R.string.g_arrow_drag_does))
                GestureRow(stringResource(R.string.g_mod_tap, mod), stringResource(R.string.g_mod_tap_does))
                GestureRow(stringResource(R.string.g_mod_hold, mod), stringResource(R.string.g_mod_hold_does))
                for ((a, b) in listOf(
                    R.string.g_three_lr to R.string.g_desktop, R.string.g_three_ud to R.string.g_windows, R.string.g_talk_tap to R.string.g_start_stop,
                    R.string.g_talk_hold to R.string.g_talk_held, R.string.g_talk_double to R.string.g_send,
                )) GestureRow(stringResource(a), stringResource(b))
            }
            Text(stringResource(R.string.version, BuildConfig.VERSION_NAME), Modifier.fillMaxWidth().padding(16.dp), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun MacRow(m: PairedMac, current: Boolean, state: String, onPick: () -> Unit, onInfo: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(onClick = onPick).padding(start = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        androidx.compose.foundation.layout.Box(Modifier.width(28.dp)) { if (current) Sym("check", 18.sp, MaterialTheme.colorScheme.primary) }
        Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
            Text(m.title, style = MaterialTheme.typography.bodyLarge)
            Text(state, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        IconButton(onInfo) { Sym("info", 22.sp, MaterialTheme.colorScheme.primary) }
    }
}

@Composable
private fun stateOf(m: PairedMac, cur: PairedMac?, state: Link.State, route: LinkRoute, nearby: Set<String>): String {
    if (m.id == cur?.id) return stringResource(when (state) {
        Link.State.CONNECTED -> when (route) { LinkRoute.LOCAL -> R.string.s_connected; LinkRoute.DIRECT -> R.string.s_connected_direct; LinkRoute.RELAY -> R.string.s_connected_relay }
        Link.State.CONNECTING -> R.string.s_connecting
        Link.State.UNREACHABLE -> R.string.s_unreachable
        Link.State.FORGOTTEN -> R.string.s_forgotten
        Link.State.REPLACED -> R.string.s_replaced
        Link.State.UNPAIRED -> R.string.s_not_connected
    })
    return stringResource(if (m.id in nearby) R.string.s_on_network else if (m.relayAddress != null) R.string.s_uses_relay else R.string.s_not_on_network)
}

@Composable
private fun SliderRow(label: String, value: Float, range: ClosedFloatingPointRange<Float>, set: (Float) -> Unit) {
    var v by remember { mutableFloatStateOf(value) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(label, style = MaterialTheme.typography.bodyLarge)
        Slider(v, { v = it }, valueRange = range, onValueChangeFinished = { set(v) })
    }
}

@Composable
private fun GestureRow(a: String, b: String) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 9.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(a, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Text(b, Modifier.weight(1f).padding(start = 12.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.End)
    }
}

private fun rate(kbps: Int) = if (kbps >= 1000) String.format(java.util.Locale.ROOT, "%.1f Mbps", kbps / 1000.0) else "$kbps kbps"

/** One computer: what to call it, how it's reached, and how to drop it. */
@Composable
private fun MacDetail(mac: PairedMac, onBack: () -> Unit) {
    val l = Remote.link
    var name by remember { mutableStateOf(mac.title) }
    var removing by remember { mutableStateOf(false) }
    fun save() = l.rename(mac, if (name == mac.name) "" else name)
    androidx.activity.compose.BackHandler { save(); onBack() }
    Column(Modifier.fillMaxSize()) {
        SheetTop(mac.title, navigation = { IconButton({ save(); onBack() }) { Sym("keyboard_arrow_left", 28.sp) } })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Section(stringResource(R.string.name)) {
                OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth().padding(12.dp), singleLine = true, placeholder = { Text(mac.name) })
            }
            Section(footer = stringResource(if (mac.relayAddress == null) R.string.relay_none_footer else R.string.relay_footer)) {
                Row2(stringResource(R.string.relay), mac.relayAddress ?: stringResource(R.string.none))
            }
            Section {
                Row2(stringResource(R.string.remove_computer), modifier = Modifier.clickable { removing = true })
            }
        }
    }
    if (removing) AlertDialog(
        onDismissRequest = { removing = false },
        title = { Text(stringResource(R.string.remove_q, mac.title)) },
        text = { Text(stringResource(R.string.remove_text)) },
        confirmButton = { TextButton({ removing = false; l.forget(mac); onBack() }) { Text(stringResource(R.string.remove), color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton({ removing = false }) { Text(stringResource(R.string.cancel)) } },
    )
}
