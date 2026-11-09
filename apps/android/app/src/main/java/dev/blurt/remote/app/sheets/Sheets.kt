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
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
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
import androidx.compose.ui.unit.dp
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

@Composable
fun BlurtTheme(content: @Composable () -> Unit) = MaterialTheme(colorScheme = scheme, content = content)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SheetHost(sheets: Sheets, screen: PadScreen) {
    val current by sheets.current.collectAsState()
    val offered by Remote.link.offered.collectAsState()
    BlurtTheme {
        Box(Modifier.fillMaxSize()) {
            val s = current
            if (s is Sheet.Settings || s is Sheet.Pair || s is Sheet.Editor) {
                BackHandler { sheets.close() }
                Box(Modifier.fillMaxSize().background(Color(0x99000000)).clickable(remember { MutableInteractionSource() }, null) { sheets.close() })
            }
            AnimatedVisibility(s is Sheet.Settings || s is Sheet.Pair || s is Sheet.Editor, enter = slideInVertically { it / 3 } + fadeIn(), exit = slideOutVertically { it / 3 } + fadeOut()) {
                Card {
                    when (s) {
                        Sheet.Settings -> SettingsSheet(screen, onClose = { sheets.close() }, onPair = { sheets.show(Sheet.Pair) })
                        Sheet.Pair -> PairSheet(onClose = { sheets.close() })
                        Sheet.Editor -> KeyEditor(screen, onClose = { sheets.close() })
                        else -> {}
                    }
                }
            }
            if (s is Sheet.Switch) SwitchDialog(onClose = { sheets.close() }, onAdd = { sheets.show(Sheet.Pair) })
            if (s is Sheet.MicDenied) MicDeniedDialog(onClose = { sheets.close() })
            if (s is Sheet.Displays) DisplayMap(onClose = { sheets.close() })
            offered?.let { p -> ConfirmPairing(p) }
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
    val again = l.macs.value.any { it.id == p.macID }
    AlertDialog(
        onDismissRequest = { l.offered.value = null },
        title = { Text(stringResource(R.string.pair_with_q, p.macName)) },
        text = { Text(stringResource(if (again) R.string.pair_replaces else R.string.pair_warning)) },
        // Pair isn't the default: a link from outside was made by someone
        confirmButton = { TextButton({ l.offered.value = null; l.pair(p) }) { Text(stringResource(R.string.pair)) } },
        dismissButton = { TextButton({ l.offered.value = null }) { Text(stringResource(R.string.cancel)) } },
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
