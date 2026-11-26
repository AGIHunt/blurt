// The sheets over the main screen: Material 3, dark, Blurt's teal. They live in the same activity, so opening one never ends the session.
// On a big screen a sheet is a card in the middle, not a wall of settings across a tablet.
package dev.blurt.remote.app.sheets

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.pad.PadScreen
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

sealed class Sheet {
    data object Settings : Sheet()
    data object Pair : Sheet()
    data object Editor : Sheet()
    data object Switch : Sheet()
    data object MicDenied : Sheet()
    data object Displays : Sheet()
    data object Transfer : Sheet()
}

class Sheets {
    private val _current = MutableStateFlow<Sheet?>(null)
    val current: StateFlow<Sheet?> = _current
    fun show(s: Sheet) { _current.value = s }
    fun close() { _current.value = null }
}

val Teal = Color(0xFF1AA487)
val Mint = Color(0xFF61DBBD)

private val scheme = darkColorScheme(
    // Blurt's teal, as the iPhone's sheets have it: mint is kept for one thing, listening (docs/design/system.md §1)
    primary = Teal,
    onPrimary = Color.White,
    primaryContainer = Color(0xFF123F35),
    onPrimaryContainer = Color(0xFF9FE7D4),
    secondary = Teal,
    secondaryContainer = Color(0xFF333333),
    onSecondaryContainer = Color(0xFFECECEC),
    surfaceTint = Color.Transparent,
    background = Color(0xFF0E0E0E),
    surface = Color(0xFF0E0E0E),
    surfaceVariant = Color(0xFF333333),
    surfaceContainerLowest = Color(0xFF0A0A0A),
    surfaceContainerLow = Color(0xFF161616),
    surfaceContainer = Color(0xFF1C1C1C),
    surfaceContainerHigh = Color(0xFF242424),
    surfaceContainerHighest = Color(0xFF2E2E2E),
    onSurface = Color(0xFFECECEC),
    onSurfaceVariant = Color(0xFFA0A0A0),
    outline = Color(0xFF4A4A4A),
    outlineVariant = Color(0xFF2A2A2A),
    error = Color(0xFFFF8A80),
)

/** Light, for what shows over another app when the phone is light (the share sheet's question): the same teal, a shade deeper on white */
private val lightScheme = lightColorScheme(
    primary = Color(0xFF0B7F68),
    onPrimary = Color.White,
    secondary = Color(0xFF0B7F68),
    surfaceTint = Color.Transparent,
    // neutral greys, as the dark ones are: Material's defaults lean purple
    surface = Color.White,
    surfaceContainer = Color(0xFFF4F4F4),
    surfaceContainerHigh = Color(0xFFF1F1F1),
    onSurface = Color(0xFF1C1C1C),
    onSurfaceVariant = Color(0xFF5E5E5E),
)

/** `dark`: the app is always dark; a screen over another app follows the phone. */
@Composable
fun BlurtTheme(dark: Boolean = true, content: @Composable () -> Unit) = MaterialTheme(colorScheme = if (dark) scheme else lightScheme, content = content)

/**
 * A Material dialog with its spaces as the spec draws them: 24 dp around, 16 dp under the title, 24 dp from the text to the buttons and from
 * the buttons' labels to the bottom. (AlertDialog adds the buttons' 48 dp touch height under 24 dp of padding: about 45 dp below them.) The
 * title breaks into even lines, so "data?" never sits alone on the second.
 */
@Composable
fun AskDialog(onDismiss: () -> Unit, title: String, confirm: @Composable () -> Unit, dismiss: (@Composable () -> Unit)? = null,
              text: (@Composable () -> Unit)? = null) {
    Dialog(onDismiss) {
        Surface(Modifier.widthIn(min = 280.dp, max = 560.dp), shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
            // the buttons are 40 dp tall in a 48 dp touch row: 10 dp here makes 24 dp to and from their labels
            Column(Modifier.padding(start = 24.dp, end = 24.dp, top = 24.dp, bottom = 10.dp)) {
                Text(title, style = MaterialTheme.typography.headlineSmall.copy(lineBreak = LineBreak.Heading), color = MaterialTheme.colorScheme.onSurface)
                if (text != null) {
                    Spacer(Modifier.height(16.dp))
                    ProvideTextStyle(MaterialTheme.typography.bodyMedium.copy(color = MaterialTheme.colorScheme.onSurfaceVariant)) { text() }
                }
                Spacer(Modifier.height(10.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                    dismiss?.invoke()
                    confirm()
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SheetHost(sheets: Sheets, screen: PadScreen) {
    val current by sheets.current.collectAsState()
    val offered by Remote.link.offered.collectAsState()
    val unsent by Remote.link.unsent.collectAsState()
    val state by Remote.link.state.collectAsState()
    val ask by Remote.transfers.ask.collectAsState()
    BlurtTheme {
        Box(Modifier.fillMaxSize()) {
            val s = current
            val carded = s is Sheet.Settings || s is Sheet.Pair || s is Sheet.Editor || s is Sheet.Transfer
            if (carded) {
                BackHandler { sheets.close() }
                Box(Modifier.fillMaxSize().background(Color(0x99000000)).clickable(remember { MutableInteractionSource() }, null) { sheets.close() })
            }
            AnimatedVisibility(carded, enter = slideInVertically { it / 3 } + fadeIn(), exit = slideOutVertically { it / 3 } + fadeOut()) {
                Card {
                    when (s) {
                        Sheet.Settings -> SettingsSheet(screen, onClose = { sheets.close() }, onPair = { sheets.show(Sheet.Pair) })
                        Sheet.Pair -> PairSheet(onClose = { sheets.close() })
                        Sheet.Editor -> KeyEditor(screen, onClose = { sheets.close() })
                        Sheet.Transfer -> TransferSheet(onClose = { sheets.close() })
                        else -> {}
                    }
                }
            }
            if (s is Sheet.Switch) SwitchDialog(onClose = { sheets.close() }, onAdd = { sheets.show(Sheet.Pair) })
            if (s is Sheet.MicDenied) MicDeniedDialog(onClose = { sheets.close() })
            if (s is Sheet.Displays) DisplayMap(onClose = { sheets.close() })
            offered?.let { p -> ConfirmPairing(p) }
            ask?.let { MobileData(it) }
            if (unsent.isNotEmpty() && state == dev.blurt.remote.app.net.Link.State.CONNECTED) SendUnsent(unsent)
        }
    }
}

/** Full screen on a phone; a card in the middle of a big one. */
@Composable
private fun Card(content: @Composable () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val wide = maxWidth > 700.dp && maxHeight > 560.dp
        Surface(
            modifier = if (wide) Modifier.widthIn(max = 560.dp).fillMaxWidth().padding(vertical = 40.dp).clip(RoundedCornerShape(28.dp))
                else Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.surface,
        ) { Column { content() } }
    }
}

@Composable
private fun ConfirmPairing(p: dev.blurt.remote.core.RemotePairing) {
    val l = Remote.link
    val macs by l.macs.collectAsState()
    val again = macs.any { it.id == p.macID }
    AlertDialog(
        onDismissRequest = { l.offered.value = null },
        title = { Text(stringResource(R.string.pair_with_q, p.macName)) },
        text = { Text(stringResource(if (again) R.string.pair_replaces else R.string.pair_warning)) },
        // Pair isn't the default: a link from outside was made by someone
        confirmButton = { TextButton({ l.offered.value = null; l.pair(p) }) { Text(stringResource(R.string.pair)) } },
        dismissButton = { TextButton({ l.offered.value = null }) { Text(stringResource(R.string.cancel)) } },
    )
}

/** What was typed with no session is asked about once there is one: it isn't lost, and doesn't land by itself wherever the caret is now. */
@Composable
private fun SendUnsent(words: String) {
    val l = Remote.link
    AlertDialog(
        onDismissRequest = {},
        title = { Text(stringResource(R.string.unsent_q)) },
        text = { Column(Modifier.heightIn(max = 240.dp).verticalScroll(rememberScrollState())) { Text(words) } },
        confirmButton = { TextButton({ l.sendUnsent() }) { Text(stringResource(R.string.send)) } },
        dismissButton = { TextButton({ l.dropUnsent() }) { Text(stringResource(R.string.discard)) } },
    )
}

/** More than 100 MB over mobile data, either way: asked first (remote-files.md §Rules). */
@Composable
private fun MobileData(a: dev.blurt.remote.app.files.Transfers.Ask) {
    val ctx = LocalContext.current
    // "136 MB" never splits between the number and its unit
    val size = android.text.format.Formatter.formatShortFileSize(ctx, a.bytes).replace(' ', '\u00A0')
    AskDialog(
        onDismiss = a.no,
        title = stringResource(if (a.incoming) R.string.data_get_q else R.string.data_send_q, size),
        confirm = { TextButton(a.yes) { Text(stringResource(if (a.incoming) R.string.data_get else R.string.send)) } },
        dismiss = { TextButton(a.no) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun SwitchDialog(onClose: () -> Unit, onAdd: () -> Unit) {
    val l = Remote.link
    val macs by l.macs.collectAsState()
    val cur by l.current.collectAsState()
    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(stringResource(R.string.switch_computer)) },
        text = {
            Column {
                for (m in macs) {
                    Text(
                        (if (m.id == cur?.id) "✓  " else "     ") + m.title,
                        Modifier.fillMaxWidth().clickable { l.choose(m); onClose() }.padding(vertical = 12.dp),
                        style = MaterialTheme.typography.bodyLarge,
                    )
                }
            }
        },
        confirmButton = { TextButton(onAdd) { Text(stringResource(R.string.add_computer)) } },
        dismissButton = { TextButton(onClose) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun MicDeniedDialog(onClose: () -> Unit) {
    val ctx = LocalContext.current
    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(stringResource(R.string.mic_off_title)) },
        text = { Text(stringResource(R.string.mic_off_text)) },
        confirmButton = {
            TextButton({
                onClose()
                ctx.startActivity(android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.fromParts("package", ctx.packageName, null)))
            }) { Text(stringResource(R.string.open_settings)) }
        },
        dismissButton = {
            TextButton({
                Remote.prefs.micOnPhone = false
                Remote.link.send(dev.blurt.remote.core.ToMac.SetMicOnPhone(false))
                onClose()
            }) { Text(stringResource(R.string.use_computer_mic)) }
        },
    )
}
