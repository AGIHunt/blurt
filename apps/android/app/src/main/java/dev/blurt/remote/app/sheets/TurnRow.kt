// Which way the screen is turned: in Settings, and in the dialog a hold on the screen button opens.
package dev.blurt.remote.app.sheets

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import dev.blurt.remote.app.Haptics
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.ScreenTurn

@Composable
fun TurnRow(modifier: Modifier = Modifier) {
    val changed by Remote.prefs.changed.collectAsState()
    changed.hashCode()
    val now = Remote.prefs.turn
    SingleChoiceSegmentedButtonRow(modifier.fillMaxWidth()) {
        for ((i, t) in ScreenTurn.entries.withIndex()) {
            SegmentedButton(now == t, { Haptics.tick(); Remote.prefs.turn = t }, SegmentedButtonDefaults.itemShape(i, ScreenTurn.entries.size), icon = {}) {
                Text(stringResource(when (t) { ScreenTurn.AUTO -> R.string.turn_auto; ScreenTurn.PORTRAIT -> R.string.turn_portrait; ScreenTurn.LANDSCAPE -> R.string.turn_landscape }), maxLines = 1)
            }
        }
    }
}
