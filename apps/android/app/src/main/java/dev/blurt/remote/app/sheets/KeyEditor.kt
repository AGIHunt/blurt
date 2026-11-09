// Editing the keys (port of Sheets/KeyEditor.swift): the list as it is, with the dock on top. Hold a key and drag it: the others make way as
// it passes, so what will happen shows before it's let go; into or out of the dock it's a swap, since the dock always has its keys. Tap one to
// change what it shows or what it does, the minus to remove it, the plus to add one. Nothing to write on the computer.
package dev.blurt.remote.app.sheets

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.blurt.remote.app.Haptics
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.keys.DeckText
import dev.blurt.remote.app.pad.PadScreen
import dev.blurt.remote.core.Deck
import dev.blurt.remote.core.KeyAction
import dev.blurt.remote.core.KeySlot
import dev.blurt.remote.core.RemoteChord
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.core.RemoteKey
import dev.blurt.remote.core.RemoteModifiers
import kotlin.math.roundToInt

private sealed class Page {
    data object Keys : Page()
    data class Face(val id: String) : Page()
    data class Pick(val section: String?, val replacing: String?) : Page()
    data class Chord(val section: String?, val replacing: String?) : Page()
    data class Words(val section: String?, val replacing: String?) : Page()
}

@Composable
fun KeyEditor(screen: PadScreen, onClose: () -> Unit, back: Boolean = false) {
    val host by Remote.link.host.collectAsState()
    var deck by remember(host) { mutableStateOf(screen.currentDeck) }
    var page by remember { mutableStateOf<Page>(Page.Keys) }
    fun update(d: Deck) { deck = d; screen.setDeck(d) }
    fun picked(s: KeySlot, section: String?, replacing: String?) {
        if (replacing != null) {
            val old = slotOf(deck, replacing) ?: return
            update(deck.replace(replacing, old.copy(action = s.action, glyph = old.glyph ?: s.glyph, hint = s.hint)))
            page = Page.Face(replacing)
        } else if (section != null) {
            update(deck.add(s, section))
            page = Page.Keys
        }
    }
    when (val p = page) {
        Page.Keys -> Keys(deck, host, ::update, onClose, back, onFace = { page = Page.Face(it) }, onAdd = { page = Page.Pick(it, null) })
        is Page.Face -> FaceEditor(deck, p.id, host, ::update, onBack = { page = Page.Keys }, onChange = { page = Page.Pick(null, p.id) })
        is Page.Pick -> Picker(host, onBack = { page = if (p.replacing != null) Page.Face(p.replacing) else Page.Keys },
            onPick = { picked(it, p.section, p.replacing) }, onChord = { page = Page.Chord(p.section, p.replacing) }, onText = { page = Page.Words(p.section, p.replacing) })
        is Page.Chord -> ChordMaker(host, onBack = { page = Page.Pick(p.section, p.replacing) }) { picked(it, p.section, p.replacing) }
        is Page.Words -> TextMaker(onBack = { page = Page.Pick(p.section, p.replacing) }) { picked(it, p.section, p.replacing) }
    }
}

/** every tile one height, captioned or not, so the rows line up as the keys do */
private val TILE = 52.dp

private fun slotOf(d: Deck, id: String): KeySlot? = d.dock.firstOrNull { it.id == id } ?: d.sections.flatMap { it.slots }.firstOrNull { it.id == id }

@Composable
private fun Keys(deck: Deck, host: RemoteHost, update: (Deck) -> Unit, onClose: () -> Unit, back: Boolean, onFace: (String) -> Unit, onAdd: (String) -> Unit) {
    var dragging by remember { mutableStateOf<String?>(null) }
    var at by remember { mutableStateOf(Offset.Zero) }
    var origin by remember { mutableStateOf(Offset.Zero) }
    val bounds = remember { mutableStateMapOf<String, Rect>() }
    var lastTarget by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<String?>(null) }
    var name by remember { mutableStateOf("") }
    var current by remember { mutableStateOf(deck) }
    current = deck
    if (back) BackHandler { onClose() }

    fun over(p: Offset) {
        val from = dragging ?: return
        val target = bounds.entries.firstOrNull { it.key != from && it.value.contains(p) }?.key ?: return
        if (target == lastTarget) return
        lastTarget = target
        val d = current
        if (target.startsWith("end:")) {
            // the end of a section: there, after its last key
            if (d.dock.any { it.id == from }) return
            val s = slotOf(d, from) ?: return
            val sec = target.removePrefix("end:")
            if (d.sections.firstOrNull { it.id == sec }?.slots?.lastOrNull()?.id == from) return
            update(d.remove(from).add(s, sec))
        } else {
            update(d.move(from, target))
        }
        Haptics.step()
    }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            SheetTop(stringResource(R.string.edit_keys),
                navigation = if (back) ({ IconButton(onClose) { Sym("keyboard_arrow_left", 28.sp) } }) else null,
                actions = {
                    Box {
                        IconButton({ menu = true }) { Sym("more_vert") }
                        DropdownMenu(menu, { menu = false }) {
                            DropdownMenuItem({ Text(stringResource(R.string.restore_keys)) }, { menu = false; update(Deck.standard(host)) })
                        }
                    }
                    if (!back) TextButton(onClose) { Text(stringResource(R.string.done)) }
                })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState(), enabled = dragging == null).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(stringResource(R.string.editor_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Heading(stringResource(R.string.always_here))
                Text(stringResource(R.string.always_here_footer), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Grid(deck.dock.map { it.id } + "mic") { id ->
                    if (id == "mic") Box(Modifier.fillMaxWidth().height(TILE).background(Color(0xFF0F0F0F), RoundedCornerShape(10.dp)), contentAlignment = Alignment.Center) {
                        Sym("mic", 20.sp, MaterialTheme.colorScheme.onSurfaceVariant, filled = true)
                    } else Tile(deck.dock.first { it.id == id }, host, removable = false, dragging == id, bounds,
                        onTap = { onFace(id) }, onRemove = {},
                        drag = { start, p -> if (start) { dragging = id; origin = p; at = p; lastTarget = null } else { at += p; over(at) } },
                        end = { dragging = null; lastTarget = null })
                }
                for (sec in deck.sections) key(sec.id) {
                    var more by remember { mutableStateOf(false) }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Heading(DeckText.tr(sec.name), Modifier.weight(1f))
                        Box {
                            IconButton({ more = true }) { Sym("more_horiz", 20.sp, MaterialTheme.colorScheme.onSurfaceVariant) }
                            DropdownMenu(more, { more = false }) {
                                DropdownMenuItem({ Text(stringResource(R.string.rename)) }, { more = false; name = DeckText.tr(sec.name); renaming = sec.id })
                                DropdownMenuItem({ Text(stringResource(R.string.add_section)) }, { more = false; update(deck.addSection(DeckText.tr("New Section"))) },
                                    enabled = deck.sections.size < Deck.MAX_SECTIONS)
                                DropdownMenuItem({ Text(stringResource(R.string.delete_section), color = MaterialTheme.colorScheme.error) },
                                    { more = false; update(deck.removeSection(sec.id)) }, enabled = deck.sections.size > 1)
                            }
                        }
                    }
                    Grid(sec.slots.map { it.id } + "end:${sec.id}") { id ->
                        if (id.startsWith("end:")) Box(Modifier.fillMaxWidth().height(TILE).onGloballyPositioned { bounds[id] = it.boundsInRoot() }
                            .border(1.dp, Color(0xFF333333), RoundedCornerShape(10.dp)).clickable { onAdd(sec.id) }, contentAlignment = Alignment.Center) {
                            Sym("add", 20.sp, MaterialTheme.colorScheme.onSurfaceVariant)
                        } else Tile(sec.slots.first { it.id == id }, host, removable = true, dragging == id, bounds,
                            onTap = { onFace(id) }, onRemove = { update(deck.remove(id)) },
                            drag = { start, p -> if (start) { dragging = id; origin = p; at = p; lastTarget = null } else { at += p; over(at) } },
                            end = { dragging = null; lastTarget = null })
                    }
                }
            }
        }
        // the key under the finger, while it's carried
        dragging?.let { id ->
            slotOf(deck, id)?.let { s ->
                val d = LocalDensity.current
                Box(Modifier.offset { IntOffset((at.x - with(d) { 27.dp.toPx() }).roundToInt(), (at.y - with(d) { 46.dp.toPx() }).roundToInt()) }
                    .size(54.dp, 48.dp).background(Color(0xFF3A3A3A), RoundedCornerShape(10.dp)), contentAlignment = Alignment.Center) {
                    FaceView(s.face(host), 18.dp)
                }
            }
        }
    }
    renaming?.let { id ->
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text(stringResource(R.string.section_name)) },
            text = { OutlinedTextField(name, { name = it }, singleLine = true) },
            confirmButton = { TextButton({ update(deck.renameSection(id, name)); renaming = null }) { Text(stringResource(R.string.ok)) } },
            dismissButton = { TextButton({ renaming = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    origin.hashCode()
}

@Composable
private fun Heading(t: String, modifier: Modifier = Modifier) =
    Text(t, modifier.padding(top = 6.dp), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
private fun Grid(ids: List<String>, cell: @Composable (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
        for (row in ids.chunked(Deck.COLUMNS)) Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            for (id in row) key(id) { Box(Modifier.weight(1f)) { cell(id) } }
            repeat(Deck.COLUMNS - row.size) { Spacer(Modifier.weight(1f)) }
        }
    }
}

@Composable
private fun Tile(s: KeySlot, host: RemoteHost, removable: Boolean, carried: Boolean, bounds: MutableMap<String, Rect>, onTap: () -> Unit, onRemove: () -> Unit,
                 drag: (Boolean, Offset) -> Unit, end: () -> Unit) {
    var origin by remember { mutableStateOf(Rect.Zero) }
    Box(Modifier.fillMaxWidth().onGloballyPositioned { origin = it.boundsInRoot(); bounds[s.id] = origin }
        .alpha(if (carried) 0.25f else 1f).scale(if (carried) 0.92f else 1f)
        .pointerInput(s.id) {
            detectDragGesturesAfterLongPress(
                onDragStart = { p -> Haptics.grab(); drag(true, origin.topLeft + p) },
                onDrag = { c, amount -> c.consume(); drag(false, amount) },
                onDragEnd = { end() }, onDragCancel = { end() })
        }) {
        Column(Modifier.fillMaxWidth().height(TILE).background(Color(0xFF222222), RoundedCornerShape(10.dp)).clickable(onClick = onTap).padding(vertical = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            FaceView(s.face(host), 17.dp)
            s.detail(host)?.let { Text(DeckText.tr(it), fontSize = 8.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Clip) }
        }
        if (removable) Box(Modifier.align(Alignment.TopEnd).offset(4.dp, (-4).dp).size(18.dp).background(Color(0xFF4A4A4A), CircleShape).clickable(onClick = onRemove),
            contentAlignment = Alignment.Center) { Sym("remove", 13.sp, Color.White) }
    }
}

/** What a key shows, and what it does. Any text or emoji will do; the longer it is the smaller it reads. */
@Composable
private fun FaceEditor(deck: Deck, id: String, host: RemoteHost, update: (Deck) -> Unit, onBack: () -> Unit, onChange: () -> Unit) {
    val slot = slotOf(deck, id) ?: run { onBack(); return }
    val inList = deck.dock.none { it.id == id }
    var text by remember(id) { mutableStateOf(slot.glyph?.takeIf { !it.startsWith("sf:") && !it.startsWith("mark:") } ?: "") }
    var small by remember(id) { mutableStateOf(slot.caption ?: "") }
    BackHandler { onBack() }
    fun save(s: KeySlot) = update(deck.replace(id, s))
    Column(Modifier.fillMaxSize()) {
        SheetTop(DeckText.tr(slot.title(host)), navigation = { IconButton(onBack) { Sym("keyboard_arrow_left", 28.sp) } })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                Column(Modifier.size(72.dp, 62.dp).background(Color(0xFF292929), RoundedCornerShape(12.dp)), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center) {
                    FaceView(slot.face(host), 24.dp)
                    slot.detail(host)?.let { Text(DeckText.tr(it), fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1) }
                }
            }
            Section(stringResource(R.string.on_the_key), stringResource(R.string.longer_smaller)) {
                OutlinedTextField(text, { t ->
                    text = t
                    val keepIcon = slot.face(host).let { it.startsWith("sf:") || it.startsWith("mark:") }
                    save(slot.copy(glyph = if (t.isEmpty()) (if (keepIcon) slot.glyph else null) else t))
                }, Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), singleLine = true, label = { Text(stringResource(R.string.text_or_emoji)) })
                OutlinedTextField(small, { t -> small = t; save(slot.copy(caption = t.ifEmpty { null })) },
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), singleLine = true, label = { Text(stringResource(R.string.small_line)) },
                    placeholder = { Text(if (slot.caption == null) DeckText.tr(slot.detail(host) ?: "") else "") })
            }
            Section(stringResource(R.string.icon)) {
                Column(Modifier.padding(8.dp)) {
                    for (row in Deck.icons.chunked(7)) Row {
                        for (n in row) Box(Modifier.weight(1f).height(44.dp).clickable { text = ""; save(slot.copy(glyph = "sf:$n")) }, contentAlignment = Alignment.Center) {
                            FaceView("sf:$n", 20.dp, if (slot.glyph == "sf:$n") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                        }
                        repeat(7 - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
            Section {
                Row2(stringResource(R.string.change_what), modifier = Modifier.clickable(onClick = onChange)) { Sym("keyboard_arrow_right", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                if (inList) {
                    Divider()
                    Row2(stringResource(R.string.remove), modifier = Modifier.clickable { update(deck.remove(id)); onBack() })
                }
            }
        }
    }
}

/** Everything a key can be: search the list, or make one. */
@Composable
private fun Picker(host: RemoteHost, onBack: () -> Unit, onPick: (KeySlot) -> Unit, onChord: () -> Unit, onText: () -> Unit) {
    var query by remember { mutableStateOf("") }
    BackHandler { onBack() }
    val all = remember(host) { Deck.catalogue(host) }
    val groups = if (query.isBlank()) all else all.mapNotNull { g ->
        val hits = g.slots.filter { s -> listOf(DeckText.tr(s.title(host)), s.title(host), s.detail(host) ?: "").any { it.contains(query, ignoreCase = true) } }
        if (hits.isEmpty()) null else g.copy(slots = hits)
    }
    Column(Modifier.fillMaxSize()) {
        SheetTop(stringResource(R.string.choose_key), navigation = { IconButton(onBack) { Sym("keyboard_arrow_left", 28.sp) } })
        OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp), singleLine = true,
            leadingIcon = { Sym("search", 20.sp, MaterialTheme.colorScheme.onSurfaceVariant) }, placeholder = { Text(stringResource(R.string.search)) })
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Section {
                    Row2(stringResource(R.string.new_shortcut), modifier = Modifier.clickable(onClick = onChord)) { Sym("keyboard_arrow_right", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    Divider()
                    Row2(stringResource(R.string.text), modifier = Modifier.clickable(onClick = onText)) { Sym("keyboard_arrow_right", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
            items(groups, key = { it.group }) { g ->
                Section(DeckText.tr(g.group)) {
                    for (s in g.slots) Row(Modifier.fillMaxWidth().clickable { onPick(s) }.heightIn(min = 48.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(DeckText.tr(s.title(host)), Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                        s.detail(host)?.let { Text(it, Modifier.padding(end = 10.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        Box(Modifier.widthIn(min = 32.dp), contentAlignment = Alignment.Center) { FaceView(s.face(host), 18.dp, MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                }
            }
        }
    }
}

/** A shortcut, built by tapping: modifiers, then the key. */
@Composable
private fun ChordMaker(host: RemoteHost, onBack: () -> Unit, onPick: (KeySlot) -> Unit) {
    var mods by remember { mutableStateOf(if (host == RemoteHost.MAC) RemoteModifiers.COMMAND else RemoteModifiers.CONTROL) }
    var key by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var cycle by remember { mutableStateOf(false) }
    BackHandler { onBack() }
    Column(Modifier.fillMaxSize()) {
        SheetTop(stringResource(R.string.new_shortcut), navigation = { IconButton(onBack) { Sym("keyboard_arrow_left", 28.sp) } }, actions = {
            TextButton({ onPick(KeySlot(KeyAction.Chord(RemoteChord(mods, key), cycle), caption = name.ifEmpty { null })) }, enabled = key.isNotEmpty()) { Text(stringResource(R.string.add)) }
        })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Text(RemoteChord(mods, key).label(host), Modifier.fillMaxWidth().padding(20.dp), fontSize = 32.sp, textAlign = TextAlign.Center)
            Section(stringResource(R.string.modifiers)) {
                Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for ((m, g) in RemoteModifiers.ordered(host)) FilterChip((mods and m) != 0, { mods = mods xor m }, { Text(g) }, Modifier.weight(1f))
                }
            }
            Section(stringResource(R.string.key)) {
                Column(Modifier.padding(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (row in RemoteKey.all.chunked(7)) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        for (k in row) FilterChip(key == k.name, { key = k.name }, { Text(k.label(host), maxLines = 1, fontSize = 12.sp) }, Modifier.weight(1f))
                        repeat(7 - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
            Section {
                OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth().padding(12.dp), singleLine = true, label = { Text(stringResource(R.string.name)) })
                Row2(stringResource(R.string.hold_slide)) { Switch(cycle, { cycle = it }) }
            }
        }
    }
}

@Composable
private fun TextMaker(onBack: () -> Unit, onPick: (KeySlot) -> Unit) {
    var text by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var enter by remember { mutableStateOf(true) }
    BackHandler { onBack() }
    Column(Modifier.fillMaxSize()) {
        SheetTop(stringResource(R.string.text), navigation = { IconButton(onBack) { Sym("keyboard_arrow_left", 28.sp) } }, actions = {
            TextButton({ onPick(KeySlot(KeyAction.Text(text, enter), caption = name.ifEmpty { null })) }, enabled = text.isNotEmpty()) { Text(stringResource(R.string.add)) }
        })
        Section(stringResource(R.string.text)) {
            OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth().padding(12.dp), placeholder = { Text("/compact") })
        }
        Section {
            OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth().padding(12.dp), singleLine = true, label = { Text(stringResource(R.string.name)) })
            Row2(stringResource(R.string.press_return)) { Switch(enter, { enter = it }) }
        }
    }
}
