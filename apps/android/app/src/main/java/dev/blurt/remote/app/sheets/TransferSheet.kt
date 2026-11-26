// The Transfer sheet (docs/design/remote-files.md §What the user does): send photos or files to the computer, get what's copied there, and
// the transfers list, this run's and the last 50 before. The pickers are the system's: Android's photo picker (no permission asked; on
// phones without it, the document picker), the document picker for files and for a folder, which goes zipped.
package dev.blurt.remote.app.sheets

import android.content.Context
import android.icu.text.MeasureFormat
import android.icu.util.Measure
import android.icu.util.MeasureUnit
import android.net.Uri
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.files.Downloads
import dev.blurt.remote.app.files.Transfers
import dev.blurt.remote.app.net.Link
import dev.blurt.remote.core.RemoteFiles
import dev.blurt.remote.core.RemoteTransfer
import java.util.Locale

@Composable
fun TransferSheet(onClose: () -> Unit) {
    val ctx = LocalContext.current
    val tr = Remote.transfers
    val link = Remote.link
    val rows by tr.rows.collectAsState()
    val got by tr.got.collectAsState()
    val cur by link.current.collectAsState()
    val state by link.state.collectAsState()
    val meeting by link.meeting.collectAsState()
    val features by link.hostFeatures.collectAsState()
    val macName = cur?.title ?: ""
    val connected = state == Link.State.CONNECTED

    DisposableEffect(Unit) {
        tr.sheetOpen = true
        onDispose { tr.sheetOpen = false }
    }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(RemoteFiles.MAX_COUNT)) { tr.send(it) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { tr.send(it.take(RemoteFiles.MAX_COUNT)) }
    val folder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { it?.let(tr::sendFolder) }

    SheetTop(stringResource(R.string.transfer), navigation = {
        IconButton(onClose) { Sym("close") }
    })
    LazyColumn(Modifier.fillMaxWidth().navigationBarsPadding()) {
        item {
            Section {
                ActionRow(stringResource(R.string.send_photos), "image") {
                    photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                }
                Divider()
                ActionRow(stringResource(R.string.send_files), "description", trailing = {
                    val label = stringResource(R.string.send_folder)
                    IconButton({ folder.launch(null) }, Modifier.semantics { contentDescription = label }) {
                        Sym("folder", color = MaterialTheme.colorScheme.primary)
                    }
                }) { files.launch(arrayOf("*/*")) }
                Divider()
                // an older computer can't give what's copied: it says so, and how to get it
                val canClip = dev.blurt.remote.core.RemoteFeature.CLIPBOARD in features
                ActionRow(stringResource(R.string.get_copied, macName), "content_paste_go", enabled = connected && canClip,
                    sub = if (connected && !canClip) stringResource(R.string.update_host, macName) else null) { tr.getCopied() }
                got?.let { Got(it, tr) }
            }
        }
        item {
            if (rows.isEmpty()) {
                Text(stringResource(R.string.transfers_empty), Modifier.fillMaxWidth().padding(32.dp), style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
        }
        if (rows.isNotEmpty()) item { Spacer(Modifier.heightIn(min = 4.dp)) }
        items(rows, key = { (if (it.t.incoming) "in-" else "out-") + it.t.id }) { r ->
            Box(Modifier.padding(horizontal = 16.dp, vertical = 3.dp)) {
                androidx.compose.material3.Surface(shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
                    TransferRow(ctx, r, meeting = meeting, connected = connected)
                }
            }
        }
        item { Spacer(Modifier.heightIn(min = 24.dp)) }
    }
}

@Composable
private fun ActionRow(label: String, icon: String, enabled: Boolean = true, sub: String? = null, trailing: (@Composable () -> Unit)? = null, act: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled) { act() }.heightIn(min = 52.dp).padding(start = 16.dp, end = 4.dp, top = 6.dp, bottom = 6.dp)
        .alpha(if (enabled) 1f else 0.45f), verticalAlignment = Alignment.CenterVertically) {
        Sym(icon, color = MaterialTheme.colorScheme.primary)
        Column(Modifier.weight(1f).padding(start = 14.dp, end = 8.dp)) {
            Text(label, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary.takeIf { enabled } ?: MaterialTheme.colorScheme.onSurface)
            if (sub != null) Text(sub, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (trailing != null) trailing() else Spacer(Modifier.width(12.dp))
    }
}

/** What Get Copied Items brought: under the button, until the next. */
@Composable
private fun Got(g: Transfers.Got, tr: Transfers) {
    Divider()
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        when (g) {
            Transfers.Got.Asking -> androidx.compose.material3.CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            is Transfers.Got.Text -> {
                Sym("check", color = MaterialTheme.colorScheme.primary)
                Column(Modifier.weight(1f).padding(start = 14.dp)) {
                    Text(stringResource(R.string.copied), style = MaterialTheme.typography.bodyMedium)
                    Text(Transfers.firstWords(g.words), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            is Transfers.Got.Image -> {
                Sym("image", color = MaterialTheme.colorScheme.primary)
                Text(stringResource(R.string.image_copied), Modifier.weight(1f).padding(start = 14.dp), style = MaterialTheme.typography.bodyMedium)
                if (Downloads.canSaveToGallery(g.name)) {
                    if (g.inGallery) Sym("check", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    else TextButton({ tr.saveClipToGallery() }) { Text(stringResource(R.string.save_to_gallery)) }
                }
            }
            is Transfers.Got.None -> {
                Sym("info", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(g.line, Modifier.weight(1f).padding(start = 14.dp), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable
private fun TransferRow(ctx: Context, r: Transfers.Row, meeting: Boolean, connected: Boolean) {
    val t = r.t
    val tr = Remote.transfers
    val going = t.state == RemoteTransfer.State.Going
    val paused = t.state == RemoteTransfer.State.Paused
    val done = t.state == RemoteTransfer.State.Done
    val uri = t.location?.let(Uri::parse)
    val opens = done && t.incoming && uri != null
    Column(Modifier.fillMaxWidth().clickable(opens) { if (uri != null) Downloads.open(ctx, uri, t.name) }.padding(start = 16.dp, end = 4.dp, top = 10.dp, bottom = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Sym(when {
                RemoteFiles.isImage(t.name) -> "image"
                RemoteFiles.isVideo(t.name) -> "play_arrow"
                t.name.endsWith(".zip", true) -> "folder"
                else -> "description"
            }, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Column(Modifier.weight(1f).padding(start = 14.dp, end = 8.dp)) {
                Text(t.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                Text(line(ctx, r, meeting), style = MaterialTheme.typography.bodySmall, color = if (t.state is RemoteTransfer.State.Failed &&
                    (t.state as RemoteTransfer.State.Failed).why != "stopped") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2)
            }
            // Continue on a paused one whose session didn't come back by itself, and on one that didn't go
            val again = !t.incoming && (paused && !connected || t.state == RemoteTransfer.State.Failed("other"))
            if (again) TextButton({ tr.again(r) }) { Text(stringResource(R.string.continue_transfer)) }
            if (!t.isOver && !r.zipping) {
                val label = stringResource(R.string.stop)
                IconButton({ tr.stop(r) }, Modifier.semantics { contentDescription = label }) { Sym("close", color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
        if (going || paused || r.zipping) {
            val f = t.fraction.toFloat()
            if (r.zipping) LinearProgressIndicator(Modifier.fillMaxWidth().padding(start = 38.dp, end = 12.dp, top = 8.dp))
            else LinearProgressIndicator({ f }, Modifier.fillMaxWidth().padding(start = 38.dp, end = 12.dp, top = 8.dp),
                color = if (paused) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary)
        }
        if (opens && uri != null) {
            Row(Modifier.padding(start = 30.dp, top = 2.dp), horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                TextButton({ Downloads.open(ctx, uri, t.name) }) { Text(stringResource(R.string.open), fontSize = 14.sp) }
                TextButton({ Downloads.share(ctx, uri, t.name) }) { Text(stringResource(R.string.share), fontSize = 14.sp) }
                if (Downloads.canSaveToGallery(t.name)) {
                    if (r.inGallery) Box(Modifier.padding(12.dp)) { Sym("check", size = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    else TextButton({ tr.saveToGallery(r) }) { Text(stringResource(R.string.save_to_gallery), fontSize = 14.sp) }
                }
            }
        }
    }
}

/** The row's second line, in the Copy table's words: where, how far and how long, or how it ended. */
fun line(c: Context, r: Transfers.Row, meeting: Boolean): String {
    val t = r.t
    val size = Formatter.formatShortFileSize(c, t.size)
    val batch = if (t.index != null && t.count != null) c.getString(R.string.transfer_batch, t.index, t.count) + " · " else ""
    if (r.zipping) return c.getString(R.string.transfer_compressing)
    return when (t.state) {
        RemoteTransfer.State.Waiting -> batch + c.getString(if (meeting) R.string.transfer_connecting else R.string.transfer_waiting)
        RemoteTransfer.State.Paused -> batch + c.getString(R.string.transfer_paused)
        RemoteTransfer.State.Going -> {
            val done = Formatter.formatShortFileSize(c, t.done)
            val where = c.getString(if (t.incoming) R.string.transfer_from else R.string.transfer_to, r.peerName, done, size)
            val left = t.secondsLeft?.let { " · " + c.getString(R.string.transfer_left, duration(it)) } ?: ""
            batch + where + left
        }
        RemoteTransfer.State.Done -> if (t.incoming) c.getString(R.string.transfer_received) else c.getString(R.string.transfer_sent, r.peerName)
        is RemoteTransfer.State.Failed -> Transfers.failedLine(c, t)
    }
}

/** Time left as the system says a short duration: "3 min", "3分钟". */
fun duration(seconds: Double): String {
    val f = MeasureFormat.getInstance(Locale.getDefault(), MeasureFormat.FormatWidth.SHORT)
    val s = seconds.toLong().coerceAtLeast(1)
    return when {
        s < 60 -> f.formatMeasures(Measure(s, MeasureUnit.SECOND))
        s < 3600 -> f.formatMeasures(Measure((s + 30) / 60, MeasureUnit.MINUTE))
        else -> f.formatMeasures(Measure(s / 3600, MeasureUnit.HOUR), Measure((s % 3600) / 60, MeasureUnit.MINUTE))
    }
}
