// The computer's displays as its display settings arrange them, to scale: tap one to show it, or let the picture follow the pointer from
// display to display. A dialog, so nothing covers the picture once it's gone.
package dev.blurt.remote.app.sheets

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.blurt.remote.app.Haptics
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import kotlin.math.min

@Composable
fun DisplayMap(onClose: () -> Unit) {
    val l = Remote.link
    val all by l.displays.collectAsState()
    val shown by l.shownDisplay.collectAsState()
    val list = l.displaysInOrder
    val teal = MaterialTheme.colorScheme.primary
    val ink = MaterialTheme.colorScheme.onSurface
    val faint = MaterialTheme.colorScheme.outline
    all.hashCode()

    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(stringResource(R.string.displays)) },
        text = {
            Column {
                Text(stringResource(R.string.displays_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (list.isNotEmpty()) {
                    val minX = list.minOf { it.x }
                    val minY = list.minOf { it.y }
                    val spanW = list.maxOf { it.x + it.width } - minX
                    val spanH = list.maxOf { it.y + it.height } - minY
                    var frames = emptyList<Pair<String, Rect>>()
                    Canvas(Modifier.fillMaxWidth().height(200.dp).padding(top = 16.dp).pointerInput(list) {
                        detectTapGestures { p ->
                            frames.firstOrNull { it.second.contains(p) }?.let { (id, _) ->
                                Haptics.tick()
                                l.showDisplay(id)
                                onClose()
                            }
                        }
                    }) {
                        // to scale, centred, with a little room between displays that touch
                        val k = min(size.width / spanW.toFloat(), size.height / spanH.toFloat())
                        val ox = (size.width - spanW.toFloat() * k) / 2
                        val oy = (size.height - spanH.toFloat() * k) / 2
                        val gap = 3.dp.toPx()
                        frames = list.map { d ->
                            d.id to Rect(Offset(ox + ((d.x - minX) * k).toFloat() + gap, oy + ((d.y - minY) * k).toFloat() + gap),
                                Size((d.width * k).toFloat() - gap * 2, (d.height * k).toFloat() - gap * 2))
                        }
                        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { textAlign = android.graphics.Paint.Align.CENTER }
                        for ((i, f) in frames.withIndex()) {
                            val on = f.first == shown
                            val r = f.second
                            drawRoundRect(if (on) teal.copy(alpha = 0.28f) else Color(0xFF242424), r.topLeft, r.size, CornerRadius(6.dp.toPx()))
                            drawRoundRect(if (on) teal else faint, r.topLeft, r.size, CornerRadius(6.dp.toPx()), style = Stroke(if (on) 2.dp.toPx() else 1.dp.toPx()))
                            paint.color = ink.toArgb()
                            paint.textSize = 18.dp.toPx()
                            drawContext.canvas.nativeCanvas.drawText("${i + 1}", r.center.x, r.center.y - 2.dp.toPx(), paint)
                            paint.textSize = 11.dp.toPx()
                            paint.color = ink.copy(alpha = 0.7f).toArgb()
                            val name = list[i].name.let { if (paint.measureText(it) > r.width - 8.dp.toPx()) "" else it }
                            drawContext.canvas.nativeCanvas.drawText(name, r.center.x, r.center.y + 16.dp.toPx(), paint)
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton({ l.showDisplay(null); onClose() }) { Text(stringResource(R.string.follow_pointer)) } },
        dismissButton = { TextButton(onClose) { Text(stringResource(R.string.done)) } },
    )
}
