// Files and the clipboard's content between the phone and its computer (docs/design/remote-files.md, remote-protocol.md §Clipboard and
// files): the port of BlurtRemoteKit/RemoteFiles.swift, the same behaviour on a JVM. A sender goes one file at a time, a chunk at a time,
// never more than `WINDOW` past what the receiver says it has written; a receiver writes a part, keeps it an hour if the session drops, and
// goes on from there when the same file begins again. Nothing here knows which way the wire's classes point: the app maps RemoteFileOut and
// RemoteFileAnswer onto ToMac / ToPhone (RemoteFileWire).
package dev.blurt.remote.core

import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.Executors

object RemoteFiles {
    const val CHUNK = 192 * 1024
    const val WINDOW = 4 shl 20
    const val PROGRESS_EVERY = 1 shl 20
    const val MAX_SIZE = 4L shl 30
    const val MAX_COUNT = 1000
    /** an image the phone pastes */
    const val MAX_CLIP_IMAGE = 20 shl 20
    /** a dropped file's part waits this long for the same file to begin again */
    const val KEEP_PARTS_MS = 3_600_000L
    /** a sender that sees `resume` waits this long for the receiver to say where to start */
    const val RESUME_WAIT_MS = 10_000L
    /** the receiver keeps this much free beyond the file */
    const val SPARE = 256L shl 20
    /** a phone on mobile data asks before more than this goes either way */
    const val ASK_ON_CELLULAR = 100_000_000L

    val imageExtensions = setOf("png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp")
    val videoExtensions = setOf("mov", "mp4", "m4v", "hevc", "avi", "3gp")

    fun extension(name: String): String = name.substringAfterLast('/').let { n -> if ('.' in n) n.substringAfterLast('.').lowercase() else "" }
    fun isImage(name: String) = extension(name) in imageExtensions
    fun isVideo(name: String) = extension(name) in videoExtensions
    fun isMedia(name: String) = isImage(name) || isVideo(name)

    /** A name to write under: no folders, no `:`, no hidden or empty names, at most 200 characters. */
    fun clean(name: String): String {
        var n = name.replace('\\', '/').trimEnd('/').substringAfterLast('/').replace(":", "-").trim()
        n = n.filter { it.code >= 0x20 && it.code != 0x7F }
        n = n.trimStart('.')
        if (n.isEmpty()) return "file"
        if (n.codePointCount(0, n.length) <= 200) return n
        return n.substring(0, n.offsetByCodePoints(0, 200))
    }

    /** `name`, or the first of "name 2.ext", "name 3.ext" … that `taken` says isn't. */
    fun unique(name: String, taken: (String) -> Boolean): String {
        if (!taken(name)) return name
        val dot = name.lastIndexOf('.').takeIf { it > 0 }
        val base = dot?.let { name.substring(0, it) } ?: name
        val ext = dot?.let { name.substring(it) } ?: ""
        for (i in 2..100_000) {
            val c = "$base $i$ext"
            if (!taken(c)) return c
        }
        return name
    }

    /** Seconds left from what moved lately (ms, bytes): null until 2 s of progress. */
    fun left(samples: List<Pair<Long, Long>>, size: Long): Double? {
        val first = samples.firstOrNull() ?: return null
        val last = samples.last()
        if (last.first - first.first < 2000 || last.second <= first.second) return null
        val rate = (last.second - first.second) / ((last.first - first.first) / 1000.0)
        return maxOf(0L, size - last.second) / rate
    }

    fun newID(): String = UUID.randomUUID().toString().uppercase()
}

/** A file's begin, either way: ToMac.FileBegin / ToPhone.FileBegin. */
data class RemoteFileInfo(
    val id: String, val name: String, val size: Long, val clip: Boolean = false, val index: Int? = null, val count: Int? = null, val total: Long? = null,
)

/** What a sender puts on the wire. */
sealed class RemoteFileOut {
    data class Begin(val info: RemoteFileInfo) : RemoteFileOut()
    class Chunk(val id: String, val data: ByteArray) : RemoteFileOut() {
        override fun equals(other: Any?) = other is Chunk && other.id == id && other.data.contentEquals(data)
        override fun hashCode() = id.hashCode() * 31 + data.contentHashCode()
    }
    data class End(val id: String) : RemoteFileOut()
}

/** What a receiver answers. */
sealed class RemoteFileAnswer {
    abstract val id: String
    data class Progress(override val id: String, val bytes: Long) : RemoteFileAnswer()
    data class Saved(override val id: String, val name: String) : RemoteFileAnswer()
    data class Failed(override val id: String, val why: String) : RemoteFileAnswer()
}

/** The phone's side of the mapping: it sends to the host as ToMac and answers the host's files as ToMac. */
object RemoteFileWire {
    fun toMac(o: RemoteFileOut): ToMac = when (o) {
        is RemoteFileOut.Begin -> o.info.let { ToMac.FileBegin(it.id, it.name, it.size, if (it.clip) true else null, it.index, it.count, it.total) }
        is RemoteFileOut.Chunk -> ToMac.FileChunk(o.id, o.data)
        is RemoteFileOut.End -> ToMac.FileEnd(o.id)
    }

    fun toMac(a: RemoteFileAnswer): ToMac = when (a) {
        is RemoteFileAnswer.Progress -> ToMac.FileProgress(a.id, a.bytes)
        is RemoteFileAnswer.Saved -> ToMac.FileSaved(a.id, a.name)
        is RemoteFileAnswer.Failed -> ToMac.FileFailed(a.id, a.why)
    }

    /** A file coming from the host, as the receiver sees it (null for anything else). */
    fun out(m: ToPhone): RemoteFileOut? = when (m) {
        is ToPhone.FileBegin -> RemoteFileOut.Begin(RemoteFileInfo(m.id, m.name, m.size, m.clip == true, m.index, m.count, m.total))
        is ToPhone.FileChunk -> RemoteFileOut.Chunk(m.id, m.data)
        is ToPhone.FileEnd -> RemoteFileOut.End(m.id)
        else -> null
    }

    /** The host's answer to a file from the phone. */
    fun answer(m: ToPhone): RemoteFileAnswer? = when (m) {
        is ToPhone.FileProgress -> RemoteFileAnswer.Progress(m.id, m.bytes)
        is ToPhone.FileSaved -> RemoteFileAnswer.Saved(m.id, m.name)
        is ToPhone.FileFailed -> RemoteFileAnswer.Failed(m.id, m.why)
        else -> null
    }

    /** What the host does with a file from the phone (the fake host's side, and tests). */
    fun out(m: ToMac): RemoteFileOut? = when (m) {
        is ToMac.FileBegin -> RemoteFileOut.Begin(RemoteFileInfo(m.id, m.name, m.size, m.clip == true, m.index, m.count, m.total))
        is ToMac.FileChunk -> RemoteFileOut.Chunk(m.id, m.data)
        is ToMac.FileEnd -> RemoteFileOut.End(m.id)
        else -> null
    }

    fun toPhone(o: RemoteFileOut): ToPhone = when (o) {
        is RemoteFileOut.Begin -> o.info.let { ToPhone.FileBegin(it.id, it.name, it.size, if (it.clip) true else null, it.index, it.count, it.total) }
        is RemoteFileOut.Chunk -> ToPhone.FileChunk(o.id, o.data)
        is RemoteFileOut.End -> ToPhone.FileEnd(o.id)
    }

    fun toPhone(a: RemoteFileAnswer): ToPhone = when (a) {
        is RemoteFileAnswer.Progress -> ToPhone.FileProgress(a.id, a.bytes)
        is RemoteFileAnswer.Saved -> ToPhone.FileSaved(a.id, a.name)
        is RemoteFileAnswer.Failed -> ToPhone.FileFailed(a.id, a.why)
    }

    fun answer(m: ToMac): RemoteFileAnswer? = when (m) {
        is ToMac.FileProgress -> RemoteFileAnswer.Progress(m.id, m.bytes)
        is ToMac.FileSaved -> RemoteFileAnswer.Saved(m.id, m.name)
        is ToMac.FileFailed -> RemoteFileAnswer.Failed(m.id, m.why)
        else -> null
    }
}

/** One transfer as the list shows it, either way. */
data class RemoteTransfer(
    val id: String,
    val name: String,
    val size: Long,
    /** written at the other end (sending) or here (receiving) */
    val done: Long = 0,
    val incoming: Boolean,
    val clip: Boolean = false,
    val state: State = State.Waiting,
    val index: Int? = null,
    val count: Int? = null,
    /** receiving: where it was saved (the app's own words for it, a content URI); sending: what was read */
    val location: String? = null,
    val secondsLeft: Double? = null,
    /** ms since 1970 */
    val at: Long = System.currentTimeMillis(),
    /** the computer it goes to or came from (its id) */
    val peer: String? = null,
) {
    sealed class State {
        /** not begun: behind another file, or until the session is up (and its stream has moved) */
        data object Waiting : State()
        data object Going : State()
        /** the session dropped: it goes on from `done` when it's back */
        data object Paused : State()
        data object Done : State()
        /** "space", "too_big", "write", "locked", "read", "stopped", "other" */
        data class Failed(val why: String) : State()
    }

    val fraction: Double get() = if (size > 0) minOf(1.0, done.toDouble() / size) else if (state == State.Done) 1.0 else 0.0
    val isOver: Boolean get() = state == State.Done || state is State.Failed
}

/** What a sender reads: a file on disk, a content URI on a phone. */
interface RemoteFileSource {
    val name: String
    /** -1: can't be known (it'll fail as `read`) */
    val size: Long
    fun open(): InputStream
    fun exists(): Boolean = true
    /** a temporary copy (a zip, a pasted image, a shared item) is deleted once over */
    val temporary: Boolean get() = false
    fun delete() {}
}

class FileSource(val file: File, override val temporary: Boolean = false, override val name: String = file.name) : RemoteFileSource {
    override val size: Long get() = if (file.isFile) file.length() else -1
    override fun open(): InputStream = FileInputStream(file)
    override fun exists() = file.isFile
    override fun delete() { file.delete() }
}

// MARK: - sending

/**
 * Sends files one at a time, in the order asked. `send` puts a message on the wire and says false when there's no session to put it on.
 * `ready` says whether files may go now (a session is up and, on the public connection service, its stream has moved). Call `heard` with
 * the receiver's answers and `connection` when the session drops or is back. `target`: the computer the session is with now; a file asked
 * for one computer waits while the session is with another.
 */
class RemoteFileSender(
    private val send: (RemoteFileOut) -> Boolean,
    private val ready: () -> Boolean,
    /** the receiver answers every begin with where to start */
    var peerResumes: () -> Boolean,
    private val target: () -> String? = { null },
    up: Boolean = true,
) {
    private class Item(
        var t: RemoteTransfer,
        val source: RemoteFileSource,
        val total: Long?,
        val target: String?,
        /** not begun by then (ms): dropped */
        val expires: Long?,
    ) {
        var acked: Long? = null
        var heardSince = false
        val samples = ArrayList<Pair<Long, Long>>()
        var pausedAt: Long? = null
    }

    private val lock = Object()
    private val items = ArrayList<Item>()
    @Volatile var onChange: ((RemoteTransfer) -> Unit)? = null
    private val worker = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "blurt-files-out").apply { isDaemon = true } }
    private var running = false
    private var up = up
    /** test hooks */
    var pollMs = 20L
    var now: () -> Long = System::currentTimeMillis

    val transfers: List<RemoteTransfer> get() = synchronized(lock) { items.map { it.t } }

    /** Queue files. `clip`: the clipboard's content (one file). Folders must already be zipped. `expiresIn`: dropped if not begun by then
     *  (ms; the share sheet's queue). Returns the transfers made, in order. */
    fun add(sources: List<RemoteFileSource>, clip: Boolean = false, target: String? = null, expiresIn: Long? = null): List<RemoteTransfer> {
        val sizes = sources.map { it.size }
        val total = sizes.sumOf { maxOf(0L, it) }
        val many = sources.size > 1
        val at = now()
        val made = sources.mapIndexed { i, s ->
            Item(RemoteTransfer(RemoteFiles.newID(), s.name, maxOf(0L, sizes[i]), incoming = false, clip = clip, index = if (many) i + 1 else null,
                count = if (many) sources.size else null, at = at, peer = target), s, if (many) total else null, target, expiresIn?.let { at + it })
        }
        synchronized(lock) { items.addAll(made) }
        made.forEach { onChange?.invoke(it.t) }
        kick()
        return made.map { it.t }
    }

    /** × on one transfer, or on all of them (null). */
    fun stop(id: String? = null) {
        val changed = ArrayList<RemoteTransfer>()
        val ends = ArrayList<String>()
        synchronized(lock) {
            for (it in items) if ((id == null || it.t.id == id) && !it.t.isOver) {
                if (it.t.state == RemoteTransfer.State.Going || it.t.state == RemoteTransfer.State.Paused) ends += it.t.id
                it.t = it.t.copy(state = RemoteTransfer.State.Failed("stopped"), secondsLeft = null)
                changed += it.t
            }
        }
        // the receiver deletes what it had: a short end
        ends.forEach { send(RemoteFileOut.End(it)) }
        changed.forEach { onChange?.invoke(it) }
        cleanUp()
    }

    /** Done and failed ones leave the list. */
    fun clear() = synchronized(lock) { items.removeAll { it.t.isOver } }

    /** A paused or failed transfer goes again (the transfers list's Continue): from where the receiver has it, if it kept it. */
    fun again(id: String) {
        val t = synchronized(lock) {
            val it = items.firstOrNull { it.t.id == id } ?: return
            if (it.t.state == RemoteTransfer.State.Failed("stopped") || it.t.state == RemoteTransfer.State.Done || !it.source.exists()) return
            if (it.t.state == RemoteTransfer.State.Going || it.t.state == RemoteTransfer.State.Waiting) return
            it.t = it.t.copy(state = RemoteTransfer.State.Waiting)
            it.pausedAt = null
            it.t
        }
        onChange?.invoke(t)
        kick()
    }

    fun heard(a: RemoteFileAnswer) {
        val t = synchronized(lock) {
            val it = items.firstOrNull { it.t.id == a.id }?.takeIf { !it.t.isOver } ?: return
            when (a) {
                is RemoteFileAnswer.Progress -> {
                    it.acked = a.bytes
                    it.heardSince = true
                    val n = System.nanoTime() / 1_000_000
                    it.samples += n to a.bytes
                    it.samples.removeAll { s -> n - s.first > 5000 }
                    it.t = it.t.copy(done = minOf(a.bytes, it.t.size), secondsLeft = RemoteFiles.left(it.samples, it.t.size))
                }
                // the name it was saved under there ("report 2.pdf"), for the list (not a clip's: that's never saved)
                is RemoteFileAnswer.Saved -> it.t = it.t.copy(state = RemoteTransfer.State.Done, done = it.t.size, secondsLeft = null,
                    name = if (it.t.clip || a.name.isEmpty()) it.t.name else a.name)
                is RemoteFileAnswer.Failed -> it.t = it.t.copy(state = RemoteTransfer.State.Failed(a.why), secondsLeft = null)
            }
            it.t
        }
        onChange?.invoke(t)
        if (t.isOver) cleanUp()
    }

    /** The session dropped (false) or is back (true). Dropped: the file going pauses where the receiver had it. */
    fun connection(up: Boolean) {
        val changed = ArrayList<RemoteTransfer>()
        synchronized(lock) {
            this.up = up
            if (!up) for (it in items) if (it.t.state == RemoteTransfer.State.Going) {
                it.t = it.t.copy(state = RemoteTransfer.State.Paused, secondsLeft = null)
                it.pausedAt = now()
                it.samples.clear()
                changed += it.t
            }
            if (up) for (it in items) if (it.t.state == RemoteTransfer.State.Paused) {
                // paused ones go on by themselves, as long as they paused less than an hour ago
                val p = it.pausedAt
                it.t = it.t.copy(state = if (p != null && now() - p > RemoteFiles.KEEP_PARTS_MS) RemoteTransfer.State.Failed("other") else RemoteTransfer.State.Waiting)
                changed += it.t
            }
        }
        changed.forEach { onChange?.invoke(it) }
        if (up) kick()
    }

    private fun kick() {
        synchronized(lock) {
            if (running) return
            running = true
        }
        worker.execute { run() }
    }

    private fun waiting(): Boolean = synchronized(lock) { up && items.any { it.t.state == RemoteTransfer.State.Waiting } }

    /** The next file to go, expired ones dropped on the way. */
    private fun next(): Item? {
        val dropped = ArrayList<RemoteTransfer>()
        val r = synchronized(lock) {
            if (!up) return@synchronized null
            val to = target()
            var found: Item? = null
            for (it in items) {
                if (it.t.state != RemoteTransfer.State.Waiting) continue
                if (it.expires != null && now() > it.expires) {
                    it.t = it.t.copy(state = RemoteTransfer.State.Failed("other"))
                    dropped += it.t
                    continue
                }
                if (it.target != null && to != null && it.target != to) continue
                found = it
                break
            }
            found
        }
        dropped.forEach { onChange?.invoke(it) }
        if (dropped.isNotEmpty()) cleanUp()
        return r
    }

    private fun run() {
        try {
            while (true) {
                val i = next() ?: break
                // the session must be up (and its stream moved) before a byte goes
                var waited = 0L
                while (!ready()) {
                    if (!synchronized(lock) { up }) return
                    Thread.sleep(100)
                    waited += 100
                    if (waited > 600_000) break
                }
                if (!ready()) return
                one(i)
            }
        } finally {
            synchronized(lock) { running = false }
            // something queued while the loop was ending
            if (waiting()) {
                if (ready() && next() != null) kick() else worker.schedule({ if (waiting()) kick() }, 250, java.util.concurrent.TimeUnit.MILLISECONDS)
            }
        }
    }

    private fun one(item: Item) {
        val info = synchronized(lock) {
            if (item.t.state != RemoteTransfer.State.Waiting) return
            item.t = item.t.copy(state = RemoteTransfer.State.Going)
            item.acked = null
            item.heardSince = false
            item.samples.clear()
            RemoteFileInfo(item.t.id, item.t.name, item.t.size, item.t.clip, item.t.index, item.t.count, item.total)
        }
        val id = info.id
        onChange?.invoke(item.t)
        if (info.size > RemoteFiles.MAX_SIZE) return finish(item, RemoteTransfer.State.Failed("too_big"), wire = false)
        if (item.source.size < 0) return finish(item, RemoteTransfer.State.Failed("read"), wire = false)
        val input = try { item.source.open() } catch (_: Exception) { return finish(item, RemoteTransfer.State.Failed("read"), wire = false) }
        input.use { h ->
            if (!send(RemoteFileOut.Begin(info))) return pause(item)
            var sent = 0L
            if (peerResumes()) {
                // where the receiver has it: 0 for a new file
                var waited = 0L
                while (synchronized(lock) { !item.heardSince && item.t.state == RemoteTransfer.State.Going }) {
                    Thread.sleep(pollMs)
                    waited += pollMs
                    if (waited > RemoteFiles.RESUME_WAIT_MS) return finish(item, RemoteTransfer.State.Failed("other"), wire = true)
                }
                if (synchronized(lock) { item.t.state } != RemoteTransfer.State.Going) return
                sent = (synchronized(lock) { item.acked } ?: 0L).coerceIn(0L, info.size)
                if (sent > 0 && !skip(h, sent)) return finish(item, RemoteTransfer.State.Failed("read"), wire = true)
            } else synchronized(lock) { item.acked = 0L }
            val buf = ByteArray(RemoteFiles.CHUNK)
            while (true) {
                var waited = 0L
                while (synchronized(lock) { item.t.state == RemoteTransfer.State.Going && sent - (item.acked ?: 0L) > RemoteFiles.WINDOW }) {
                    Thread.sleep(pollMs)
                    waited += pollMs
                    // a minute without the receiver moving
                    if (waited > 60_000) return finish(item, RemoteTransfer.State.Failed("other"), wire = true)
                }
                // stopped here (the short end went in stop), refused there, or paused
                if (synchronized(lock) { item.t.state } != RemoteTransfer.State.Going) return
                val n = try { fill(h, buf) } catch (_: Exception) { return finish(item, RemoteTransfer.State.Failed("read"), wire = true) }
                if (n <= 0) break
                if (!send(RemoteFileOut.Chunk(id, buf.copyOf(n)))) return pause(item)
                sent += n
            }
            if (!send(RemoteFileOut.End(id))) return pause(item)
        }
        // then the receiver's saved or failed; a drop before it pauses it, and the begin again finds it whole
        while (synchronized(lock) { item.t.state == RemoteTransfer.State.Going && up }) Thread.sleep(pollMs)
    }

    /** As much as fits, unless the file ends first. */
    private fun fill(h: InputStream, buf: ByteArray): Int {
        var n = 0
        while (n < buf.size) {
            val r = h.read(buf, n, buf.size - n)
            if (r < 0) break
            n += r
        }
        return n
    }

    private fun skip(h: InputStream, bytes: Long): Boolean {
        var left = bytes
        while (left > 0) {
            val s = h.skip(left)
            if (s <= 0) {
                if (h.read() < 0) return false
                left -= 1
            } else left -= s
        }
        return true
    }

    private fun pause(item: Item) {
        val t = synchronized(lock) {
            if (item.t.state != RemoteTransfer.State.Going) return
            item.t = item.t.copy(state = RemoteTransfer.State.Paused, secondsLeft = null)
            item.pausedAt = now()
            item.t
        }
        onChange?.invoke(t)
    }

    /** Over here: `wire` sends a short end so the receiver deletes its part. */
    private fun finish(item: Item, s: RemoteTransfer.State, wire: Boolean) {
        val t = synchronized(lock) {
            item.t = item.t.copy(state = s, secondsLeft = null)
            item.t
        }
        if (wire) send(RemoteFileOut.End(item.t.id))
        onChange?.invoke(t)
        cleanUp()
    }

    private fun cleanUp() {
        val gone = synchronized(lock) { items.filter { it.source.temporary && it.t.isOver }.map { it.source } }
        gone.forEach { runCatching { it.delete() } }
    }
}

// MARK: - receiving

/**
 * Writes files as they arrive. Parts live in `parts` (this end's own folder); a finished file goes to its place through `save`, which says
 * what it was saved as (its name, and where for the list) or null when it couldn't be. One receiver serves one phone's link: parts are keyed
 * by the device they came from all the same, as on a host.
 */
class RemoteFileReceiver(
    private val parts: File,
    /** this end supports resume */
    val resumes: Boolean = true,
    private val save: (part: File, name: String, device: String) -> Saved?,
) {
    data class Saved(val name: String, val location: String?)

    private class Part(
        val device: String, val id: String, val name: String, val size: Long, val clip: Boolean, val file: File,
        var handle: RandomAccessFile?, var written: Long, var told: Long, val index: Int?, val count: Int?,
    ) {
        var keptSince: Long? = null
        val samples = ArrayList<Pair<Long, Long>>()
        /** its progress isn't said until release(): the phone is asking about mobile data */
        var held = false
    }

    private val lock = Object()
    private val list = HashMap<String, Part>()
    /** the screen is locked: nothing is taken */
    @Volatile var locked: () -> Boolean = { false }
    /** bytes free where files land */
    @Volatile var free: () -> Long = { Long.MAX_VALUE }
    /** a `clip` file arrived: put it on the clipboard. The file is deleted after this returns */
    @Volatile var onClip: ((File, String, String) -> Unit)? = null
    @Volatile var onChange: ((RemoteTransfer, String) -> Unit)? = null
    /** true: this file's progress waits for release() (a phone on mobile data asks first); the sender stops `WINDOW` in */
    @Volatile var hold: ((RemoteFileInfo, String) -> Boolean)? = null
    /** test hook */
    var now: () -> Long = System::currentTimeMillis

    init {
        parts.mkdirs()
        // parts from an earlier run: their sessions can't come back
        parts.listFiles()?.filter { it.name.endsWith(".part") }?.forEach { it.delete() }
    }

    private fun key(device: String, id: String) = device + "\u001F" + id

    /** One message about a file from `device`; `answer` goes back on the same session. Messages for one device come in order. */
    fun heard(m: RemoteFileOut, device: String, answer: (RemoteFileAnswer) -> Unit) {
        when (m) {
            is RemoteFileOut.Begin -> begin(m.info, device, answer)
            is RemoteFileOut.Chunk -> chunk(m.id, m.data, device, answer)
            is RemoteFileOut.End -> end(m.id, device, answer)
        }
    }

    private fun begin(i: RemoteFileInfo, device: String, answer: (RemoteFileAnswer) -> Unit) {
        expire()
        val k = key(device, i.id)
        // the same file again after a drop: go on from what's written
        val kept = synchronized(lock) { list[k] }
        if (resumes && kept != null && kept.name == RemoteFiles.clean(i.name) && kept.size == i.size) {
            if (kept.handle == null) {
                val h = try { RandomAccessFile(kept.file, "rw") } catch (_: Exception) { null }
                if (h == null) {
                    synchronized(lock) { list.remove(k) }
                    return begin(i, device, answer)
                }
                val at = h.length()
                h.seek(at)
                kept.handle = h
                kept.written = at
                kept.told = at
            }
            kept.keptSince = null
            answer(RemoteFileAnswer.Progress(i.id, kept.written))
            return change(kept, RemoteTransfer.State.Going)
        }
        // another file from this device begins: one that wasn't finished is kept (resume) or goes
        suspend(device, except = i.id)
        if (locked()) return answer(RemoteFileAnswer.Failed(i.id, "locked"))
        val cap = if (i.clip) maxOf(RemoteFiles.MAX_CLIP_IMAGE.toLong(), 64L shl 20) else RemoteFiles.MAX_SIZE
        if (i.size < 0 || i.size > cap) return answer(RemoteFileAnswer.Failed(i.id, "too_big"))
        if (!i.clip && i.size >= free() - RemoteFiles.SPARE) return answer(RemoteFileAnswer.Failed(i.id, "space"))
        parts.mkdirs()
        val f = File(parts, UUID.randomUUID().toString() + ".part")
        val h = try { RandomAccessFile(f, "rw").also { it.setLength(0) } } catch (_: Exception) { null }
            ?: return answer(RemoteFileAnswer.Failed(i.id, "write"))
        val p = Part(device, i.id, RemoteFiles.clean(i.name), i.size, i.clip, f, h, 0, 0, i.index, i.count)
        p.held = hold?.invoke(i, device) == true
        synchronized(lock) { list[k] = p }
        if (resumes) answer(RemoteFileAnswer.Progress(i.id, 0))
        change(p, RemoteTransfer.State.Going)
    }

    private fun chunk(id: String, d: ByteArray, device: String, answer: (RemoteFileAnswer) -> Unit) {
        val k = key(device, id)
        val p = synchronized(lock) { list[k] } ?: return
        val h = p.handle ?: return
        val ok = p.written + d.size <= p.size && runCatching { h.write(d) }.isSuccess
        if (!ok) {
            drop(k)
            answer(RemoteFileAnswer.Failed(id, "write"))
            return change(p, RemoteTransfer.State.Failed("write"))
        }
        p.written += d.size
        if (p.held || p.written - p.told < RemoteFiles.PROGRESS_EVERY) return
        p.told = p.written
        val n = System.nanoTime() / 1_000_000
        p.samples += n to p.written
        p.samples.removeAll { n - it.first > 5000 }
        answer(RemoteFileAnswer.Progress(id, p.written))
        change(p, RemoteTransfer.State.Going)
    }

    private fun end(id: String, device: String, answer: (RemoteFileAnswer) -> Unit) {
        val k = key(device, id)
        val p = synchronized(lock) { list.remove(k) } ?: return
        runCatching { p.handle?.close() }
        // short: the sender stopped it
        if (p.written != p.size) {
            p.file.delete()
            answer(RemoteFileAnswer.Failed(id, "stopped"))
            return change(p, RemoteTransfer.State.Failed("stopped"))
        }
        if (p.clip) {
            runCatching { onClip?.invoke(p.file, p.name, device) }
            p.file.delete()
            answer(RemoteFileAnswer.Saved(id, p.name))
            return change(p, RemoteTransfer.State.Done)
        }
        val s = runCatching { save(p.file, p.name, device) }.getOrNull()
        p.file.delete()
        if (s == null) {
            answer(RemoteFileAnswer.Failed(id, "write"))
            return change(p, RemoteTransfer.State.Failed("write"))
        }
        answer(RemoteFileAnswer.Saved(id, s.name))
        change(p, RemoteTransfer.State.Done, s)
    }

    /** The mobile-data question was answered yes: what's written is said, and the sender goes on. */
    fun release(id: String, device: String, answer: (RemoteFileAnswer) -> Unit) {
        val p = synchronized(lock) { list[key(device, id)] } ?: return
        if (!p.held) return
        p.held = false
        p.told = p.written
        answer(RemoteFileAnswer.Progress(id, p.written))
    }

    /** × here: the file stops and its part goes; the sender hears `stopped`. */
    fun stop(id: String, device: String, answer: (RemoteFileAnswer) -> Unit) {
        val k = key(device, id)
        val p = synchronized(lock) { list[k] } ?: return
        drop(k)
        answer(RemoteFileAnswer.Failed(id, "stopped"))
        change(p, RemoteTransfer.State.Failed("stopped"))
    }

    /** The session with `device` ended: parts wait an hour for it (or go, without resume). */
    fun suspend(device: String, except: String? = null) {
        val paused = ArrayList<Part>()
        synchronized(lock) {
            val it = list.entries.iterator()
            while (it.hasNext()) {
                val (_, p) = it.next()
                if (p.device != device || p.id == except || p.keptSince != null) continue
                runCatching { p.handle?.close() }
                p.handle = null
                if (resumes && !p.clip) {
                    p.keptSince = now()
                    p.held = false
                    paused += p
                } else {
                    p.file.delete()
                    it.remove()
                }
            }
        }
        paused.forEach { change(it, RemoteTransfer.State.Paused) }
    }

    /** Parts kept longer than an hour go. */
    fun expire() {
        synchronized(lock) {
            val it = list.entries.iterator()
            while (it.hasNext()) {
                val p = it.next().value
                val t = p.keptSince ?: continue
                if (now() - t > RemoteFiles.KEEP_PARTS_MS) {
                    p.file.delete()
                    it.remove()
                }
            }
        }
    }

    /** What's being received or kept, for a list. */
    val current: List<RemoteTransfer>
        get() = synchronized(lock) { list.values.map { transfer(it, if (it.keptSince == null) RemoteTransfer.State.Going else RemoteTransfer.State.Paused) } }

    private fun drop(k: String) {
        val p = synchronized(lock) { list.remove(k) } ?: return
        runCatching { p.handle?.close() }
        p.file.delete()
    }

    private fun transfer(p: Part, s: RemoteTransfer.State, saved: Saved? = null) = RemoteTransfer(
        p.id, saved?.name ?: p.name, p.size, if (s == RemoteTransfer.State.Done) p.size else p.written, incoming = true, clip = p.clip, state = s,
        index = p.index, count = p.count, location = saved?.location,
        secondsLeft = if (s == RemoteTransfer.State.Going) RemoteFiles.left(p.samples, p.size) else null, peer = p.device,
    )

    private fun change(p: Part, s: RemoteTransfer.State, saved: Saved? = null) {
        onChange?.invoke(transfer(p, s, saved), p.device)
    }

    companion object {
        /** Finished files into `folder()`, under a name not taken there (a host's Downloads/Blurt, a test's folder). */
        fun intoFolder(folder: () -> File): (File, String, String) -> Saved? = { part, name, _ ->
            val dir = folder().also { it.mkdirs() }
            val n = RemoteFiles.unique(name) { File(dir, it).exists() }
            val dest = File(dir, n)
            if (part.renameTo(dest) || runCatching { part.copyTo(dest); true }.getOrDefault(false)) Saved(n, dest.path) else null
        }
    }
}
