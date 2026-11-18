// What every sheet is made of: a top bar, sections with a heading and a footnote, rows, and key faces drawn as on the keys.
package dev.blurt.remote.app.sheets

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.blurt.remote.app.R
import dev.blurt.remote.app.keys.Face
import dev.blurt.remote.app.keys.Icons
import dev.blurt.remote.app.keys.KeyMarks

val SymbolsFont = FontFamily(Font(R.font.symbols))
val SymbolsFill = FontFamily(Font(R.font.symbols_fill))

/** A Material Symbol by name. */
@Composable
fun Sym(name: String, size: TextUnit = 22.sp, color: Color = MaterialTheme.colorScheme.onSurface, filled: Boolean = false, modifier: Modifier = Modifier) {
    Text(Icons.char(name), modifier, color = color, fontSize = size, fontFamily = if (filled) SymbolsFill else SymbolsFont)
}

/** A key's face, as on the key: a symbol, a mark drawn here, or text. */
@Composable
fun FaceView(face: String, size: Dp = 20.dp, color: Color = MaterialTheme.colorScheme.onSurface, modifier: Modifier = Modifier) {
    val mark = face.removePrefix("mark:").takeIf { face.startsWith("mark:") && it in KeyMarks.names }
    val g = if (face.startsWith("sf:")) Icons.glyph(face) else Icons.modifierFaces[face]?.let { Icons.glyph(it) }
    when {
        mark != null -> {
            val (w, h) = KeyMarks.size(mark)
            Canvas(modifier.size((w * size.value / 22f).dp, (h * size.value / 22f).dp)) {
                KeyMarks.draw(drawContext.canvas.nativeCanvas, mark, this.size.width / 2, this.size.height / 2, density * size.value / 22f, color.toArgb())
            }
        }
        g != null -> Text(g.char, modifier, color = color, fontSize = (size.value * 1.1f).sp, fontFamily = if (g.filled) SymbolsFill else SymbolsFont)
        else -> {
            val t = if (face.startsWith("sf:") || face.startsWith("mark:")) "" else face
            Text(t, modifier, color = color, fontSize = (Face.textSize(t) * size.value / 22f).sp, maxLines = 1, overflow = TextOverflow.Clip)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SheetTop(title: String, navigation: (@Composable () -> Unit)? = null, actions: @Composable RowScope.() -> Unit = {}) {
    CenterAlignedTopAppBar(
        title = { Text(title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        navigationIcon = { navigation?.invoke() },
        actions = actions,
        colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
    )
}

@Composable
fun Section(title: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        if (title != null) Text(title, Modifier.padding(start = 16.dp, bottom = 6.dp), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
            Column(Modifier.fillMaxWidth()) { content() }
        }
        if (footer != null) Text(footer, Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun Divider() = HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)

@Composable
fun Row2(label: String, value: String? = null, modifier: Modifier = Modifier, sub: String? = null, trailing: @Composable (() -> Unit)? = null) {
    Row(modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween) {
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyLarge)
            if (sub != null) Text(sub, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (value != null) Text(value, Modifier.padding(start = 12.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (trailing != null) Box(Modifier.padding(start = 12.dp)) { trailing() }
    }
}

@Composable
fun ToggleRow(label: String, on: Boolean, set: (Boolean) -> Unit) {
    Row2(label, modifier = Modifier.toggleable(on, role = Role.Switch, onValueChange = set)) { Switch(on, null) }
}

val Small = 13.sp
