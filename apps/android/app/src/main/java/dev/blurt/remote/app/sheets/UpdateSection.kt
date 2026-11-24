// Settings → Updates: what there is, and one button for the next step (Updates.kt).
package dev.blurt.remote.app.sheets

import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.Updates.State
import dev.blurt.remote.core.AppUpdate

@Composable
fun UpdateSection() {
    val u = Remote.updates
    val state by u.state.collectAsState()
    val ctx = LocalContext.current
    Section(stringResource(R.string.updates), stringResource(R.string.updates_footer)) {
        val s = state
        when (s) {
            State.Idle, State.Current, State.CheckFailed -> Row2(stringResource(R.string.check_updates), modifier = Modifier.clickable { u.check() },
                sub = when (s) {
                    State.Current -> stringResource(R.string.update_current)
                    State.CheckFailed -> stringResource(R.string.update_check_failed)
                    else -> null
                })
            State.Checking -> Row2(stringResource(R.string.check_updates)) { CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) }
            is State.Downloading -> Row2(stringResource(R.string.update_to, s.version), sub = stringResource(R.string.update_downloading, s.percent)) {
                CircularProgressIndicator({ s.percent / 100f }, Modifier.size(20.dp), strokeWidth = 2.dp)
            }
            is State.Available, is State.Ready, is State.DownloadFailed, is State.InstallFailed -> {
                Row2(stringResource(R.string.update_to, s.newer.orEmpty()), sub = when (s) {
                    is State.DownloadFailed -> stringResource(R.string.update_download_failed)
                    is State.InstallFailed -> stringResource(R.string.update_install_failed)
                    else -> null
                }) {
                    Button({ u.install() }) { Text(stringResource(if (s is State.Ready) R.string.update_install else R.string.update_get)) }
                }
                // what can't be done here can be done in the browser
                if (s is State.DownloadFailed || s is State.InstallFailed) {
                    Divider()
                    Row2(stringResource(R.string.update_github), modifier = Modifier.clickable {
                        runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, AppUpdate.page(s.newer.orEmpty()).toUri())) }
                    })
                }
            }
        }
        Divider()
        ToggleRow(stringResource(R.string.update_auto), Remote.prefs.autoUpdateCheck) { Remote.prefs.autoUpdateCheck = it }
    }
}
