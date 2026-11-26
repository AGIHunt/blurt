// The file engine (RemoteFiles.kt, the port of RemoteFiles.swift): a sender and a receiver wired back to back, through a drop and a resume,
// a stop on either end, a clip, a locked receiver, a batch, an older receiver, the mobile-data hold, the share sheet's hour, and the limits
// (docs/design/remote-files.md). The same cases as RemoteFilesTests.swift.
package dev.blurt.remote.core

import java.io.File
import java.nio.file.Files
import java.util.concurrent.Executors
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RemoteFilesTest {
    private lateinit var dir: File
    private val answers = Executors.newSingleThreadExecutor()

    @BeforeTest fun setUp() { dir = Files.createTempDirectory("blurt-files-test").toFile() }
    @AfterTest fun tearDown() { dir.deleteRecursively() }

    private fun file(name: String, size: Int): File {
        val f = File(dir, "src/$name")
        f.parentFile.mkdirs()
        f.writeBytes(ByteArray(size) { (it * 31 + 7).toByte() })
        return f
    }

    /** Between the two: `up` false drops every message, as a dead session does. */
    private class Pipe {
        @Volatile var up = true
        /** bytes of chunks, then the pipe drops */
        var cutAfter: Long? = null
        var chunked = 0L
        /** ms per chunk, as a slow network */
        var delay = 0L
        val lock = Object()
    }

    private class Pair2(val s: RemoteFileSender, val r: RemoteFileReceiver, val out: File)

    private fun pair(resume: Boolean = true, pipe: Pipe = Pipe()): Pair2 {
        val out = File(dir, "Download/Blurt")
        val r = RemoteFileReceiver(File(dir, "parts"), resume, RemoteFileReceiver.intoFolder { out })
        lateinit var s: RemoteFileSender
        s = RemoteFileSender(send = { m ->
            synchronized(pipe.lock) {
                if (!pipe.up) return@RemoteFileSender false
                if (m is RemoteFileOut.Chunk) {
                    if (pipe.delay > 0) Thread.sleep(pipe.delay)
                    val cut = pipe.cutAfter
                    if (cut != null) {
                        if (pipe.chunked >= cut) { pipe.up = false; return@RemoteFileSender false }
                    }
                    pipe.chunked += m.data.size
                }
                r.heard(m, "phone-1") { a -> answers.execute { s.heard(a) } }
                true
            }
        }, ready = { pipe.up }, peerResumes = { resume })
        s.pollMs = 2
        return Pair2(s, r, out)
    }

    private fun wait(what: String, timeoutMs: Long = 10_000, ok: () -> Boolean) {
        val end = System.currentTimeMillis() + timeoutMs
        while (!ok() && System.currentTimeMillis() < end) Thread.sleep(10)
        assertTrue(ok(), what)
    }

    private val done = RemoteTransfer.State.Done
    private val paused = RemoteTransfer.State.Paused

    @Test fun aBatchArrivesWholeAndInOrder() {
        val p = pair()
        val a = file("a.txt", 5)
        val b = file("b.bin", RemoteFiles.CHUNK * 3 + 17)
        val c = file("c.txt", 0)
        p.s.add(listOf(FileSource(a), FileSource(b), FileSource(c)))
        wait("all three saved") { p.s.transfers.all { it.state == done } }
        assertContentEquals(b.readBytes(), File(p.out, "b.bin").readBytes())
        assertEquals(0, File(p.out, "c.txt").length())
        assertEquals(listOf(1, 2, 3), p.s.transfers.map { it.index })
        assertEquals(listOf(3, 3, 3), p.s.transfers.map { it.count })
    }

    @Test fun aNameInUseGetsANumber() {
        val p = pair()
        p.out.mkdirs()
        File(p.out, "a.txt").writeText("")
        p.s.add(listOf(FileSource(file("a.txt", 3))))
        wait("saved as a 2.txt") { File(p.out, "a 2.txt").exists() }
        wait("the list says so") { p.s.transfers.first().name == "a 2.txt" }
        assertEquals("a 3.txt", RemoteFiles.unique("a.txt") { it == "a.txt" || it == "a 2.txt" })
        assertEquals("Lessons 2", RemoteFiles.unique("Lessons") { it == "Lessons" })
    }

    @Test fun aDropPausesAndTheSameFileGoesOnFromWhereItWas() {
        val pipe = Pipe().apply { cutAfter = RemoteFiles.CHUNK * 30L }   // ~5.6 MB of 12 MB
        val p = pair(pipe = pipe)
        val big = file("big.mov", RemoteFiles.CHUNK * 64)
        p.s.add(listOf(FileSource(big)))
        wait("paused after the drop") { p.s.transfers.firstOrNull()?.state == paused }
        p.s.connection(false)
        p.r.suspend("phone-1")
        assertEquals(paused, p.s.transfers.first().state)
        assertEquals(paused, p.r.current.first().state)
        val had = p.r.current.first().done
        assertTrue(had > 0)
        // back: the rest only
        synchronized(pipe.lock) { pipe.cutAfter = null; pipe.chunked = 0; pipe.up = true }
        p.s.connection(true)
        wait("saved") { p.s.transfers.first().state == done }
        assertContentEquals(big.readBytes(), File(p.out, "big.mov").readBytes())
        assertTrue(pipe.chunked <= RemoteFiles.CHUNK * 64L - had + RemoteFiles.CHUNK, "only what was missing went again: ${pipe.chunked} after $had")
    }

    @Test fun aPartKeptOverAnHourIsGone() {
        val pipe = Pipe().apply { cutAfter = RemoteFiles.CHUNK * 4L }
        val p = pair(pipe = pipe)
        p.s.add(listOf(FileSource(file("x.zip", RemoteFiles.CHUNK * 40))))
        wait("dropped") { !pipe.up }
        p.r.suspend("phone-1")
        assertEquals(1, p.r.current.size)
        p.r.now = { System.currentTimeMillis() + RemoteFiles.KEEP_PARTS_MS + 1 }
        p.r.expire()
        assertTrue(p.r.current.isEmpty())
        assertEquals(0, File(dir, "parts").listFiles()!!.size)
    }

    @Test fun aSenderPausedOverAnHourDoesntGoOn() {
        val pipe = Pipe().apply { cutAfter = RemoteFiles.CHUNK * 4L }
        val p = pair(pipe = pipe)
        p.s.add(listOf(FileSource(file("x.zip", RemoteFiles.CHUNK * 40))))
        wait("paused") { p.s.transfers.first().state == paused }
        p.s.connection(false)
        p.s.now = { System.currentTimeMillis() + RemoteFiles.KEEP_PARTS_MS + 1 }
        p.s.connection(true)
        assertEquals(RemoteTransfer.State.Failed("other"), p.s.transfers.first().state)
    }

    @Test fun stopOnTheSenderDeletesThePart() {
        val pipe = Pipe().apply { delay = 5 }
        val p = pair(pipe = pipe)
        val t = p.s.add(listOf(FileSource(file("slow.bin", RemoteFiles.CHUNK * 200))))[0]
        wait("going") { (p.r.current.firstOrNull()?.done ?: 0) > 0 }
        p.s.stop(t.id)
        wait("part gone") { p.r.current.isEmpty() }
        assertEquals(RemoteTransfer.State.Failed("stopped"), p.s.transfers.first().state)
        assertFalse(File(p.out, "slow.bin").exists())
        wait("no part left") { File(dir, "parts").listFiles()!!.isEmpty() }
    }

    @Test fun stopOnTheReceiverStopsTheSender() {
        val pipe = Pipe().apply { delay = 5 }
        val p = pair(pipe = pipe)
        val t = p.s.add(listOf(FileSource(file("slow.bin", RemoteFiles.CHUNK * 200))))[0]
        wait("going") { (p.r.current.firstOrNull()?.done ?: 0) > 0 }
        p.r.stop(t.id, "phone-1") { a -> p.s.heard(a) }
        wait("stopped") { p.s.transfers.first().state == RemoteTransfer.State.Failed("stopped") }
    }

    @Test fun aClipGoesToTheClipboardNotTheFolder() {
        val p = pair()
        var got: Pair<String, Int>? = null
        p.r.onClip = { f, n, _ -> got = n to f.readBytes().size }
        p.s.add(listOf(FileSource(file("Image.png", 1000))), clip = true)
        wait("clip heard") { got != null }
        assertEquals("Image.png" to 1000, got)
        assertFalse(File(p.out, "Image.png").exists())
    }

    @Test fun aLockedReceiverTakesNothing() {
        val p = pair()
        p.r.locked = { true }
        p.s.add(listOf(FileSource(file("a.txt", 3))))
        wait("refused") { p.s.transfers.first().state == RemoteTransfer.State.Failed("locked") }
    }

    @Test fun noRoomIsSaidBeforeAByteGoes() {
        val p = pair()
        p.r.free = { RemoteFiles.SPARE + 10 }
        p.s.add(listOf(FileSource(file("a.bin", 100))))
        wait("refused") { p.s.transfers.first().state == RemoteTransfer.State.Failed("space") }
    }

    @Test fun aLockBeforeTheSameFileGoesOnKeepsItsPart() {
        val pipe = Pipe().apply { cutAfter = RemoteFiles.CHUNK * 10L }
        val p = pair(pipe = pipe)
        p.s.add(listOf(FileSource(file("big.bin", RemoteFiles.CHUNK * 40))))
        wait("paused") { p.s.transfers.first().state == paused }
        p.s.connection(false)
        p.r.suspend("phone-1")
        p.r.locked = { true }
        synchronized(pipe.lock) { pipe.cutAfter = null; pipe.up = true }
        p.s.connection(true)
        wait("refused") { p.s.transfers.first().state == RemoteTransfer.State.Failed("locked") }
        assertEquals(1, p.r.current.size, "the part stays for when it's open again")
    }

    @Test fun aNameMadeMeanwhileIsNotReplaced() {
        val out = File(dir, "out").apply { mkdirs() }
        val part = File(dir, "p.part").apply { writeText("new") }
        val save = RemoteFileReceiver.intoFolder { out }
        // another file appears under the name after it was looked at: the claim fails and the next name is used
        File(out, "a.txt").writeText("theirs")
        val s = save(part, "a.txt", "d")!!
        assertEquals("a 2.txt", s.name)
        assertEquals("theirs", File(out, "a.txt").readText())
        assertEquals("new", File(out, "a 2.txt").readText())
    }

    @Test fun anOlderReceiverWithoutResumeStillGetsTheFile() {
        val p = pair(resume = false)
        val f = file("doc.pdf", RemoteFiles.CHUNK * 25 + 1)
        p.s.add(listOf(FileSource(f)))
        wait("saved") { p.s.transfers.first().state == done }
        assertContentEquals(f.readBytes(), File(p.out, "doc.pdf").readBytes())
    }

    @Test fun aHeldFileStopsAWindowInAndGoesOnWhenReleased() {
        val p = pair()
        var asked: RemoteFileInfo? = null
        p.r.hold = { i, _ -> asked = i; true }
        val f = file("film.mp4", RemoteFiles.CHUNK * 40)   // 7.5 MB: more than the window
        p.s.add(listOf(FileSource(f)))
        wait("asked") { asked != null }
        Thread.sleep(300)
        val had = p.r.current.first().done
        assertTrue(had <= RemoteFiles.WINDOW + RemoteFiles.CHUNK, "no further than the window while asked: $had")
        assertEquals(RemoteTransfer.State.Going, p.s.transfers.first().state)
        p.r.release(asked!!.id, "phone-1") { a -> p.s.heard(a) }
        wait("saved") { p.s.transfers.first().state == done }
        assertContentEquals(f.readBytes(), File(p.out, "film.mp4").readBytes())
    }

    @Test fun aFileThatGoesOnAfterADropIsAskedAboutAgain() {
        val pipe = Pipe().apply { cutAfter = RemoteFiles.CHUNK * 10L }
        val p = pair(pipe = pipe)
        val f = file("film.mp4", RemoteFiles.CHUNK * 64)   // 12 MB
        p.s.add(listOf(FileSource(f)))
        wait("paused after the drop") { p.s.transfers.firstOrNull()?.state == paused }
        p.s.connection(false)
        p.r.suspend("phone-1")
        val had = p.r.current.first().done
        // back, now on mobile data: the rest is asked about, and stops a window in until the answer
        var asked: RemoteFileInfo? = null
        p.r.hold = { i, _ -> asked = i; true }
        synchronized(pipe.lock) { pipe.cutAfter = null; pipe.chunked = 0; pipe.up = true }
        p.s.connection(true)
        wait("asked") { asked != null }
        assertEquals(RemoteFiles.CHUNK * 64L - had, asked!!.size, "only what's left is asked about")
        Thread.sleep(300)
        assertTrue(pipe.chunked <= RemoteFiles.WINDOW + RemoteFiles.CHUNK, "no further than the window while asked: ${pipe.chunked}")
        p.r.release(asked!!.id, "phone-1") { a -> p.s.heard(a) }
        wait("saved") { p.s.transfers.first().state == done }
        assertContentEquals(f.readBytes(), File(p.out, "film.mp4").readBytes())
    }

    @Test fun aSharedItemNotBegunWithinItsTimeIsDropped() {
        val pipe = Pipe().apply { up = false }
        val p = pair(pipe = pipe)
        p.s.connection(false)
        p.s.add(listOf(FileSource(file("a.txt", 3))), expiresIn = 3_600_000)
        p.s.now = { System.currentTimeMillis() + 3_600_001 }
        pipe.up = true
        p.s.connection(true)
        wait("dropped") { p.s.transfers.first().state == RemoteTransfer.State.Failed("other") }
        assertFalse(File(p.out, "a.txt").exists())
    }

    @Test fun aFileForAnotherComputerWaits() {
        var to = "office"
        val out = File(dir, "Download/Blurt")
        val r = RemoteFileReceiver(File(dir, "parts"), true, RemoteFileReceiver.intoFolder { out })
        lateinit var s: RemoteFileSender
        s = RemoteFileSender({ m -> r.heard(m, to) { a -> answers.execute { s.heard(a) } }; true }, { true }, { true }, target = { to })
        s.pollMs = 2
        s.add(listOf(FileSource(file("home.txt", 4))), target = "home")
        Thread.sleep(300)
        assertEquals(RemoteTransfer.State.Waiting, s.transfers.first().state)
        to = "home"
        s.connection(true)
        wait("sent to its own computer") { s.transfers.first().state == done }
    }

    @Test fun aTemporaryCopyIsDeletedOnceOver() {
        val p = pair()
        val f = file("pasted.png", 10)
        p.s.add(listOf(FileSource(f, temporary = true)), clip = true)
        wait("over") { p.s.transfers.first().state == done }
        wait("deleted") { !f.exists() }
    }

    @Test fun anUnreadableFileFailsAsRead() {
        val p = pair()
        p.s.add(listOf(FileSource(File(dir, "gone.txt"))))
        wait("read") { p.s.transfers.first().state == RemoteTransfer.State.Failed("read") }
    }

    @Test fun namesAreCleaned() {
        assertEquals("bashrc", RemoteFiles.clean("../secret/.bashrc"))
        assertEquals("报告.pdf", RemoteFiles.clean("C:\\Users\\me\\报告.pdf"))
        assertEquals("a-b.txt", RemoteFiles.clean("a:b.txt"))
        assertEquals("file", RemoteFiles.clean("  "))
        assertEquals(200, RemoteFiles.clean("x".repeat(300)).length)
        assertTrue(RemoteFiles.isMedia("作业 3.JPG") && RemoteFiles.isVideo("a.mp4") && !RemoteFiles.isMedia("Q4 报价单.xlsx"))
    }

    @Test fun theWindowFollowsTheRate() {
        assertEquals(RemoteFiles.MIN_WINDOW.toLong(), RemoteFiles.window(null, true))
        assertEquals(750_000L, RemoteFiles.window(1_500_000.0, true), "half a second of a slow link")
        assertEquals(RemoteFiles.WINDOW.toLong(), RemoteFiles.window(50_000_000.0, true), "capped on a fast one")
        assertEquals(RemoteFiles.WINDOW.toLong(), RemoteFiles.window(1_500_000.0, false), "an older peer acks every 1 MiB")
        assertEquals(null, RemoteFiles.rate(listOf(0L to 0L, 100L to 1000L)), "0.2 s apart at least")
        assertEquals(10_000.0, RemoteFiles.rate(listOf(0L to 0L, 200L to 2000L)))
    }

    @Test fun timeLeftNeedsTwoSeconds() {
        assertEquals(null, RemoteFiles.left(listOf(0L to 0L, 1000L to 100L), 1000))
        assertEquals(9.0, RemoteFiles.left(listOf(0L to 0L, 2000L to 200L), 1100), "100 B/s, 900 to go")
    }
}
