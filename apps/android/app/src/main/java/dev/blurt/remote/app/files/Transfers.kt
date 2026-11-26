// Files and the clipboard between this phone and its computer (docs/design/remote-files.md; the engine is core/RemoteFiles.kt). One of these
// for the app: it sends what the Transfer sheet, the share sheet and Paste from This Device give it, takes what the computer sends, keeps the
// transfers list (this run and the last 50 before), and puts what Get Copied Items brings onto the phone's clipboard.
//
// Threads: the sender has its own; everything the receiver hears runs on `io`, in order, straight from the network thread (Link.onControl),
// so 192 KiB chunks never go through the main thread the trackpad draws on. The list and the questions change on the main thread.
package dev.blurt.remote.app.files

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.core.content.FileProvider
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.core.FileSource
import dev.blurt.remote.core.RemoteFeature
import dev.blurt.remote.core.RemoteFileInfo
import dev.blurt.remote.core.RemoteFileReceiver
import dev.blurt.remote.core.RemoteFileSender
import dev.blurt.remote.core.RemoteFileSource
import dev.blurt.remote.core.RemoteFileWire
import dev.blurt.remote.core.RemoteFiles
import dev.blurt.remote.core.RemoteTransfer
import dev.blurt.remote.core.ToMac
import dev.blurt.remote.core.ToPhone
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.util.concurrent.Executors

class Transfers(private val c: Context) {
    /** One line of the list. `zipping`: a folder being compressed, not yet a transfer. `inGallery`: saved to the gallery from here.
     *  `intoDownloads`: sent to an older computer (no `resume`), which saves into Downloads itself, not Downloads/Blurt */
    data class Row(val t: RemoteTransfer, val peerName: String, val zipping: Boolean = false, val inGallery: Boolean = false,
        val intoDownloads: Boolean = false)

    /** What Get Copied Items brought, for the sheet (or a toast when it's closed). */
    sealed class Got {
        data object Asking : Got()
        data class Text(val words: String) : Got()
        data class Image(val uri: Uri, val name: String, val inGallery: Boolean = false) : Got()
        /** a line from the Copy table: nothing copied, locked, too many, can't */
        data class None(val line: String) : Got()
    }

    /** A question about mobile data: `bytes` either way. */
    data class Ask(val bytes: Long, val incoming: Boolean, val yes: () -> Unit, val no: () -> Unit)

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "blurt-files-in").apply { isDaemon = true } }
    private val prefs = c.getSharedPreferences("transfers", Context.MODE_PRIVATE)
    private val link get() = Remote.link

    val rows = MutableStateFlow(load())
    val got = MutableStateFlow<Got?>(null)
    val ask = MutableStateFlow<Ask?>(null)
    /** the Transfer sheet is open: what Get Copied Items brings shows there, not as a toast */
    @Volatile var sheetOpen = false
    /** Get Copied Items was tapped at (elapsed ms), and nothing has answered it yet: 0 when nothing is asked. The first answer that
     *  completes it takes it (text, nothing, a `clip` file finishing, or the copied files beginning); a drop or 30 s ends it. What comes
     *  unasked never reaches the clipboard (remote-files.md §Rules: nothing moves by itself) */
    private var askedClipAt = 0L
    private val askLock = Any()

    val sender = RemoteFileSender(
        send = { link.sendFile(RemoteFileWire.toMac(it)) },
        ready = { link.ready },
        peerResumes = { link.peerResumes },
        target = { link.current.value?.id },
        up = false,
    )
    private val receiver = RemoteFileReceiver(File(c.cacheDir, "parts"), resumes = true) { part, name, _ -> Downloads.save(c, part, name) }

    init {
        sender.onChange = { t -> main.post { changed(t) } }
        receiver.onChange = { t, _ -> main.post { changed(t) } }
        receiver.free = { Downloads.free(c) }
        receiver.onClip = { f, name, _ -> clip(f, name) }
        receiver.hold = { i, device -> holdForData(i, device) }
        // what was shared or zipped for a run that ended can't be sent from here any more
        File(c.cacheDir, "outbox").deleteRecursively()
    }

    // MARK: the link

    /** The messages that are files, either way: they skip the main thread. */
    fun takes(m: ToPhone): Boolean = m is ToPhone.FileBegin || m is ToPhone.FileChunk || m is ToPhone.FileEnd || m is ToPhone.FileProgress ||
        m is ToPhone.FileSaved || m is ToPhone.FileFailed

    /** From the network thread, in order. */
    fun fromHost(m: ToPhone, device: String) {
        RemoteFileWire.answer(m)?.let { return sender.heard(it) }
        // the copied files beginning answer Get Copied Items: they're listed, nothing goes on the clipboard
        if (m is ToPhone.FileBegin && m.clip != true && take()) main.post { if (got.value == Got.Asking) got.value = null }
        val o = RemoteFileWire.out(m) ?: return
        io.execute { receiver.heard(o, device) { a -> link.sendFile(RemoteFileWire.toMac(a)) } }
    }

    /** the question about going on over mobile data, while it's up: the sender waits for it */
    private var resumeAsk: Ask? = null

    /** The session carries everything (and on the go-between its stream has moved): files go. What paused with the last session goes on
     *  by itself, unless the phone is now on mobile data with more than 100 MB of it left: that's asked first, as when it was picked. */
    fun connected() = main.post {
        if (resumeAsk != null) return@post
        val all = sender.transfers.filter { !it.clip }
        val paused = all.filter { it.state == RemoteTransfer.State.Paused }
        // the rest of a batch that paused waits behind it: it counts too
        val batches = paused.map { it.at }.toSet()
        val left = all.filter { it.state == RemoteTransfer.State.Paused || it.state == RemoteTransfer.State.Waiting && it.at in batches }
            .sumOf { maxOf(0L, it.size - it.done) }
        if (paused.isEmpty() || left <= RemoteFiles.ASK_ON_CELLULAR || !cellular()) return@post sender.connection(true)
        val q = Ask(left, incoming = false, yes = {
            resumeAsk = null
            ask.value = null
            if (link.ready) sender.connection(true)
        }, no = {
            resumeAsk = null
            ask.value = null
            paused.forEach { sender.stop(it.id) }
            all.filter { it.state == RemoteTransfer.State.Waiting && it.at in batches }.forEach { sender.stop(it.id) }
            if (link.ready) sender.connection(true)
        })
        resumeAsk = q
        ask.value = q
    }

    /** The session with `device` ended: what goes pauses, what comes keeps its part an hour. */
    fun dropped(device: String) {
        synchronized(askLock) { askedClipAt = 0 }
        main.post {
            if (got.value == Got.Asking) got.value = null
            // asked again when the next session is up
            resumeAsk?.let { q -> if (ask.value === q) ask.value = null }
            resumeAsk = null
        }
        sender.connection(false)
        io.execute { receiver.suspend(device) }
    }

    val hostTakesFiles: Boolean get() = RemoteFeature.FILES in link.hostFeatures.value
    val hostHasClipboard: Boolean get() = RemoteFeature.CLIPBOARD in link.hostFeatures.value

    // MARK: sending

    /** Photos or files picked here: to the computer in hand, after a question on mobile data for a big batch. */
    fun send(uris: List<Uri>) {
        if (uris.isEmpty()) return
        // more than a batch can carry: nothing goes, rather than the first 1,000 of them
        if (uris.size > RemoteFiles.MAX_COUNT) return toast(c.getString(R.string.send_too_many))
        val to = link.current.value?.id
        io.execute {
            val sources = uris.mapNotNull { UriSource.of(c, it) }
            main.post { confirm(sources.sumOf { maxOf(0, it.size) }, incoming = false) { sender.add(sources, target = to) } }
        }
    }

    /** A folder picked here goes as a zip, named after it: the row says Compressing… meanwhile. */
    fun sendFolder(tree: Uri) {
        val to = link.current.value?.id
        val name = Zip.name(c, tree) ?: return
        val wait = Row(RemoteTransfer("zip-" + RemoteFiles.newID(), "$name.zip", 0, incoming = false, peer = to), peerName(to), zipping = true)
        rows.value = listOf(wait) + rows.value
        io.execute {
            val zip = runCatching { Zip.folder(c, tree, File(outbox(), RemoteFiles.newID()).apply { mkdirs() }, name) }.getOrNull()
            main.post {
                rows.value = rows.value.filter { it.t.id != wait.t.id }
                if (zip == null) return@post toast(c.getString(R.string.not_sent))
                confirm(zip.length(), incoming = false) { sender.add(listOf(FileSource(zip, temporary = true)), target = to) }
            }
        }
    }

    /** From the share sheet: copied here already, to `to`; anything not begun within the hour is dropped. */
    fun sendShared(files: List<File>, to: String?) {
        if (files.isEmpty()) return
        confirm(files.sumOf { it.length() }, incoming = false) {
            sender.add(files.map { FileSource(it, temporary = true) }, target = to, expiresIn = RemoteFiles.KEEP_PARTS_MS)
        }
    }

    /** Paste from This Device with an image on the phone's clipboard: the computer puts it on its clipboard and pastes it. */
    fun pasteImage(uri: Uri) {
        val to = link.current.value?.id
        io.execute {
            val s = UriSource.of(c, uri) ?: return@execute
            if (s.size > RemoteFiles.MAX_CLIP_IMAGE) {
                main.post { toast(c.getString(R.string.image_too_big)) }
                return@execute
            }
            // a copy: the clipboard may change, and its grant end, before it goes
            val f = File(outbox(), "Image." + (RemoteFiles.extension(s.name).ifEmpty { "png" }))
            runCatching { s.open().use { i -> f.outputStream().use { i.copyTo(it) } } }.onFailure { return@execute }
            sender.add(listOf(FileSource(f, temporary = true)), clip = true, target = to)
        }
    }

    fun outbox(): File = File(c.cacheDir, "outbox").apply { mkdirs() }

    /** × on a row, either way. */
    fun stop(r: Row) {
        if (r.zipping) return
        if (!r.t.incoming) return sender.stop(r.t.id)
        val device = r.t.peer ?: return
        io.execute { receiver.stop(r.t.id, device) { a -> link.sendFile(RemoteFileWire.toMac(a)) } }
    }

    /** Continue on a paused one whose session didn't come back by itself. */
    fun again(r: Row) {
        if (r.t.incoming) return link.tryAgain()
        confirm(maxOf(0L, r.t.size - r.t.done), incoming = false) {
            sender.again(r.t.id)
            if (!link.ready) link.tryAgain()
        }
    }

    // MARK: Get Copied Items

    fun getCopied() {
        if (!link.ready) return
        val at = SystemClock.elapsedRealtime()
        synchronized(askLock) { askedClipAt = at }
        got.value = Got.Asking
        link.send(ToMac.GetClipboard)
        // nothing came at all: an older computer, or a lost answer
        main.postDelayed({
            synchronized(askLock) { if (askedClipAt == at) askedClipAt = 0 }
            if (got.value == Got.Asking) got.value = null
        }, ASK_MS)
    }

    /** The pending Get Copied Items, taken by the answer that completes it: false when nothing is asked (any thread). */
    private fun take(): Boolean = synchronized(askLock) {
        val asked = askedClipAt != 0L && SystemClock.elapsedRealtime() - askedClipAt < ASK_MS
        askedClipAt = 0
        asked
    }

    /** The computer's text, as Get Copied Items asked for it; unasked, ignored. */
    fun clipboardText(text: String) {
        if (!take()) return
        putText(text)
    }

    fun clipboardNone(why: String) {
        if (!take()) return
        val name = link.current.value?.title ?: ""
        say(Got.None(c.getString(when (why) {
            "empty" -> R.string.clip_none_empty
            "locked" -> R.string.clip_none_locked
            "too_big" -> R.string.clip_none_too_many
            "too_large" -> R.string.clip_none_too_large
            else -> R.string.clip_none_unsupported
        }, name)))
    }

    /** A `clip` file from the computer (io thread): an image by its extension, anything else as UTF-8 text. Unasked, its content is
     *  dropped (the receiver deletes the file). */
    private fun clip(f: File, name: String) {
        if (!take()) return
        if (!RemoteFiles.isImage(name)) {
            val t = runCatching { f.readText(Charsets.UTF_8) }.getOrNull() ?: return
            main.post { putText(t) }
            return
        }
        val dir = File(c.cacheDir, "clip")
        dir.deleteRecursively()
        dir.mkdirs()
        val out = File(dir, name)
        if (runCatching { f.copyTo(out, overwrite = true) }.isFailure) return
        val uri = FileProvider.getUriForFile(c, Downloads.authority(c), out)
        main.post {
            clipboard()?.setPrimaryClip(ClipData.newUri(c.contentResolver, name, uri))
            say(Got.Image(uri, name))
        }
    }

    private fun putText(t: String) {
        clipboard()?.setPrimaryClip(ClipData.newPlainText(c.getString(R.string.app_name), t))
        say(Got.Text(t))
    }

    private fun clipboard() = c.getSystemService(ClipboardManager::class.java)

    private fun say(g: Got) {
        got.value = g
        if (sheetOpen) return
        toast(when (g) {
            is Got.Text -> c.getString(R.string.copied) + " · " + firstWords(g.words)
            is Got.Image -> c.getString(R.string.image_copied)
            is Got.None -> g.line
            Got.Asking -> return
        })
    }

    /** The Image Copied card's Save to Gallery. */
    fun saveClipToGallery() {
        val g = got.value as? Got.Image ?: return
        io.execute {
            val ok = Downloads.toGallery(c, g.uri, g.name)
            main.post { if (ok) got.value = g.copy(inGallery = true) else toast(c.getString(R.string.not_received)) }
        }
    }

    fun saveToGallery(r: Row) {
        val uri = r.t.location?.let(Uri::parse) ?: return
        io.execute {
            val ok = Downloads.toGallery(c, uri, r.t.name)
            main.post {
                if (ok) rows.value = rows.value.map { if (it.t.id == r.t.id && it.t.incoming) it.copy(inGallery = true) else it }
                else toast(c.getString(R.string.not_received))
            }
        }
    }

    // MARK: mobile data

    fun cellular(): Boolean {
        val cm = c.getSystemService(ConnectivityManager::class.java) ?: return false
        val n = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
        return n.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) && !n.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    /** Main thread: more than 100 MB over mobile data asks first. */
    private fun confirm(bytes: Long, incoming: Boolean, go: () -> Unit) {
        if (bytes <= RemoteFiles.ASK_ON_CELLULAR || !cellular()) return go()
        ask.value = Ask(bytes, incoming, yes = { ask.value = null; go() }, no = { ask.value = null })
    }

    /** said yes or no to a batch from the computer, until then (elapsed ms): its next files aren't asked about again */
    @Volatile private var dataYesUntil = 0L
    @Volatile private var dataNoUntil = 0L

    /** io thread: a big file from the computer over mobile data waits, `WINDOW` in, for the question. */
    private fun holdForData(i: RemoteFileInfo, device: String): Boolean {
        val bytes = i.total ?: i.size
        if (i.clip || bytes <= RemoteFiles.ASK_ON_CELLULAR || !cellular()) return false
        val now = SystemClock.elapsedRealtime()
        if (now < dataYesUntil) return false
        val answer: (dev.blurt.remote.core.RemoteFileAnswer) -> Unit = { a -> link.sendFile(RemoteFileWire.toMac(a)) }
        if (now < dataNoUntil) {
            io.execute { receiver.stop(i.id, device, answer) }
            return true
        }
        main.post {
            var answered = false
            val q = Ask(bytes, incoming = true, yes = {
                answered = true
                ask.value = null
                dataYesUntil = SystemClock.elapsedRealtime() + 10 * 60_000
                io.execute { receiver.release(i.id, device, answer) }
            }, no = {
                answered = true
                ask.value = null
                dataNoUntil = SystemClock.elapsedRealtime() + 30_000
                io.execute { receiver.stop(i.id, device, answer) }
            })
            ask.value = q
            // the computer waits a minute for this file to move: not answered by then, it's no
            main.postDelayed({ if (!answered && ask.value === q) q.no() }, 50_000)
        }
        return true
    }

    // MARK: the list

    private fun peerName(id: String?): String = link.macs.value.firstOrNull { it.id == id }?.title ?: link.current.value?.title ?: ""

    /** A transfer moved: its row, newest first. A clip isn't listed: it says itself where it went. */
    private fun changed(t: RemoteTransfer) {
        if (t.clip) {
            if (!t.incoming && t.state is RemoteTransfer.State.Failed) toast(failedLine(c, t))
            return
        }
        val list = rows.value
        val i = list.indexOfFirst { it.t.id == t.id && it.t.incoming == t.incoming }
        // sent: where it went depends on the computer's version (an older one saves into Downloads)
        val downloads = !t.incoming && t.state == RemoteTransfer.State.Done && !link.peerResumes
        if (i >= 0) {
            rows.value = list.toMutableList().also { l -> l[i] = l[i].copy(t = t.copy(at = l[i].t.at), intoDownloads = l[i].intoDownloads || downloads) }
        } else {
            // the same file going again: its stopped row goes, so the list doesn't keep a "Stopped" beside the copy that arrived
            val again = list.filter { stoppedCopy(it.t, t) }
            rows.value = listOf(Row(t, peerName(t.peer), intoDownloads = downloads)) + (list - again.toSet())
            if (again.isNotEmpty()) save()
        }
        if (t.isOver) save()
    }

    /** `old` was stopped, and `new` is the same file (name, way, computer) beginning again. */
    private fun stoppedCopy(old: RemoteTransfer, new: RemoteTransfer) = old.state == RemoteTransfer.State.Failed("stopped") &&
        old.id != new.id && old.name == new.name && old.incoming == new.incoming && old.peer == new.peer

    /** Done ones and failed ones the list keeps: the last 50. */
    private fun save() {
        val a = JSONArray()
        rows.value.filter { it.t.isOver && !it.zipping }.take(50).forEach { r ->
            val t = r.t
            a.put(JSONObject().put("id", t.id).put("name", t.name).put("size", t.size).put("done", t.done).put("in", t.incoming)
                .put("state", when (val s = t.state) { is RemoteTransfer.State.Failed -> s.why; else -> "done" })
                .put("index", t.index ?: 0).put("count", t.count ?: 0).put("at", t.at).put("peer", t.peer).put("peerName", r.peerName)
                .put("location", t.location).put("gallery", r.inGallery).put("downloads", r.intoDownloads))
        }
        prefs.edit().putString("list.v1", a.toString()).apply()
    }

    private fun load(): List<Row> = runCatching {
        val a = JSONArray(prefs.getString("list.v1", "[]"))
        (0 until a.length()).map { k ->
            val o = a.getJSONObject(k)
            val st = o.getString("state")
            Row(RemoteTransfer(o.getString("id"), o.getString("name"), o.getLong("size"), o.optLong("done"), o.getBoolean("in"),
                state = if (st == "done") RemoteTransfer.State.Done else RemoteTransfer.State.Failed(st),
                index = o.optInt("index").takeIf { it > 0 }, count = o.optInt("count").takeIf { it > 0 }, location = o.optString("location").ifEmpty { null },
                at = o.getLong("at"), peer = o.optString("peer").ifEmpty { null }), o.optString("peerName"), inGallery = o.optBoolean("gallery"),
                intoDownloads = o.optBoolean("downloads"))
        }
    }.getOrDefault(emptyList())

    /** Something is going or waiting: the bar's button has a dot. */
    val busy: Boolean get() = rows.value.any { !it.t.isOver }

    private fun toast(s: String) = Toast.makeText(c, s, Toast.LENGTH_SHORT).show()

    companion object {
        /** Get Copied Items waits this long for its answer */
        const val ASK_MS = 30_000L

        /** the first words of copied text, on one line */
        fun firstWords(t: String): String {
            val one = t.trim().replace(Regex("\\s+"), " ")
            return if (one.length > 40) one.take(40).trimEnd() + "…" else one
        }

        /** Why a transfer didn't go, in the Copy table's words. */
        fun failedLine(c: Context, t: RemoteTransfer): String {
            val why = (t.state as? RemoteTransfer.State.Failed)?.why ?: return ""
            if (why == "stopped") return c.getString(R.string.transfer_stopped)
            return c.getString(if (t.incoming) when (why) {
                "space" -> R.string.not_received_space
                else -> R.string.not_received
            } else when (why) {
                "space" -> R.string.not_sent_space
                "too_big" -> R.string.not_sent_too_big
                "locked" -> R.string.not_sent_locked
                else -> R.string.not_sent
            })
        }
    }
}

/** A picked photo or file, read where it is. */
class UriSource(private val c: Context, val uri: Uri, override val name: String, override val size: Long) : RemoteFileSource {
    override fun open(): InputStream = c.contentResolver.openInputStream(uri) ?: throw java.io.FileNotFoundException(uri.toString())
    override fun exists(): Boolean = runCatching { c.contentResolver.openFileDescriptor(uri, "r")?.close() != null }.getOrDefault(false)

    companion object {
        fun of(c: Context, uri: Uri): UriSource? {
            var name: String? = null
            var size = -1L
            runCatching {
                c.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { q ->
                    if (q.moveToFirst()) {
                        name = q.getString(0)
                        if (!q.isNull(1)) size = q.getLong(1)
                    }
                }
            }
            if (size < 0) size = runCatching { c.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L }.getOrDefault(-1L)
            val n = name ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
            return UriSource(c, uri, n, size)
        }
    }
}
