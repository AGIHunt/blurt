// Blurt in the system share sheet (ACTION_SEND, ACTION_SEND_MULTIPLE: pictures, videos, any file). One question, naming the computer last
// controlled: "Send to Office PC", the items (name · size) under it, then Cancel and Send. That tap is the act (remote-files.md, P4): the items are copied here while the share's grant lasts, queued
// in the transfers list, and go once the session is up; anything not begun within the hour is dropped. With no session, the app opens on the
// Transfer sheet, which connects and shows them going.
package dev.blurt.remote.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.format.Formatter
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import dev.blurt.remote.app.files.UriSource
import dev.blurt.remote.app.sheets.BlurtTheme
import dev.blurt.remote.core.RemoteFiles
import java.io.File

class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Remote.start(applicationContext)
        val uris = streams(intent)
        if (uris.isEmpty()) return finish()
        val mac = Remote.link.current.value
        // name · size, the size whole on its line ("2.4 MB", not "2.4" then "MB")
        val items = uris.take(5).mapNotNull { u -> UriSource.of(this, u)?.takeIf { it.name.isNotEmpty() } }.map { s ->
            if (s.size < 0) s.name else s.name + " · " + Formatter.formatShortFileSize(this, s.size).replace(' ', '\u00A0')
        }
        setContent {
            BlurtTheme {
                var copying by remember { mutableStateOf(false) }
                // nothing paired, or more than one batch can carry (nothing goes, rather than the first 1,000)
                val refusal = when {
                    mac == null -> R.string.share_pair_first
                    uris.size > RemoteFiles.MAX_COUNT -> R.string.send_too_many
                    else -> null
                }
                if (mac == null || refusal != null) {
                    AlertDialog(
                        onDismissRequest = { finish() },
                        text = { Text(stringResource(refusal ?: R.string.share_pair_first)) },
                        confirmButton = { TextButton({ finish() }) { Text(stringResource(R.string.ok)) } },
                    )
                } else AlertDialog(
                    onDismissRequest = { if (!copying) finish() },
                    title = { Text(stringResource(R.string.share_send_to, mac.title)) },
                    text = {
                        Column {
                            for (n in items.take(4)) Text(n, maxLines = 1, overflow = TextOverflow.MiddleEllipsis, style = MaterialTheme.typography.bodyMedium)
                            if (uris.size > 4) Text("…", style = MaterialTheme.typography.bodyMedium)
                        }
                    },
                    confirmButton = {
                        if (copying) CircularProgressIndicator()
                        else TextButton({
                            copying = true
                            Thread {
                                val files = copy(uris)
                                runOnUiThread { queued(files, mac.id) }
                            }.start()
                        }) { Text(stringResource(R.string.send)) }
                    },
                    dismissButton = { if (!copying) TextButton({ finish() }) { Text(stringResource(R.string.cancel)) } },
                )
            }
        }
    }

    /** Copies here, while the share's grant lasts: the items go later, maybe after this screen is gone. */
    private fun copy(uris: List<Uri>): List<File> {
        val dir = File(Remote.transfers.outbox(), "share-" + RemoteFiles.newID()).apply { mkdirs() }
        return uris.mapNotNull { u ->
            val s = UriSource.of(this, u) ?: return@mapNotNull null
            val f = File(dir, RemoteFiles.unique(RemoteFiles.clean(s.name)) { File(dir, it).exists() })
            runCatching { s.open().use { i -> f.outputStream().use { i.copyTo(it, 1 shl 16) } }; f }.getOrNull()
        }
    }

    private fun queued(files: List<File>, to: String) {
        Remote.transfers.sendShared(files, to)
        // no session in hand (or a question about mobile data waits): the app comes up on the list, which connects
        if (!Remote.link.ready || Remote.transfers.ask.value != null) {
            startActivity(Intent(this, MainActivity::class.java).putExtra(MainActivity.SHOW_TRANSFERS, true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        finish()
    }

    companion object {
        @Suppress("DEPRECATION")
        fun streams(i: Intent): List<Uri> = when (i.action) {
            Intent.ACTION_SEND -> listOfNotNull(if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else i.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri)
            Intent.ACTION_SEND_MULTIPLE -> (if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)).orEmpty()
            else -> emptyList()
        }
    }
}
