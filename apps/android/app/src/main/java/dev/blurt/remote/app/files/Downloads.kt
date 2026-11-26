// Where files from the computer go, and what can be done with them there. Android 10 and later: the shared Download/Blurt folder, through
// MediaStore, which needs no storage permission for files the app adds itself. Android 8 and 9: the app's own folder (Android/data/…/files/
// Download/Blurt), since the shared one would need a permission prompt; Open and Share… reach it through the app's FileProvider. Pictures and
// videos go to the gallery only from Save to Gallery (Pictures/Blurt, Movies/Blurt), never by themselves.
package dev.blurt.remote.app.files

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import dev.blurt.remote.app.R
import dev.blurt.remote.core.RemoteFileReceiver
import dev.blurt.remote.core.RemoteFiles
import java.io.File

object Downloads {
    const val FOLDER = "Blurt"

    fun authority(c: Context) = c.packageName + ".files"

    fun mime(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(RemoteFiles.extension(name)) ?: "application/octet-stream"

    /** Below Android 10: the app's own Download/Blurt. */
    private fun ownFolder(c: Context) = File(c.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: File(c.filesDir, "Download"), FOLDER)

    /** Bytes free where files land. */
    fun free(c: Context): Long = runCatching {
        val at = if (Build.VERSION.SDK_INT >= 29) Environment.getExternalStorageDirectory() else ownFolder(c).apply { mkdirs() }
        StatFs(at.path).availableBytes
    }.getOrDefault(Long.MAX_VALUE)

    /** A finished part to its place, under a name not taken there: its name as saved, and its content URI for the list. */
    fun save(c: Context, part: File, name: String): RemoteFileReceiver.Saved? {
        if (Build.VERSION.SDK_INT < 29) {
            val s = RemoteFileReceiver.intoFolder { ownFolder(c) }(part, name, "") ?: return null
            return RemoteFileReceiver.Saved(s.name, FileProvider.getUriForFile(c, authority(c), File(s.location!!)).toString())
        }
        val cr = c.contentResolver
        val coll = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val where = Environment.DIRECTORY_DOWNLOADS + "/" + FOLDER + "/"
        val n = RemoteFiles.unique(name) { candidate ->
            cr.query(coll, arrayOf(MediaStore.MediaColumns._ID), "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND ${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
                arrayOf(where, candidate), null)?.use { it.count > 0 } ?: false
        }
        val v = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, n)
            put(MediaStore.MediaColumns.MIME_TYPE, mime(n))
            put(MediaStore.MediaColumns.RELATIVE_PATH, where)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = cr.insert(coll, v) ?: return null
        val ok = runCatching {
            cr.openOutputStream(uri)!!.use { o -> part.inputStream().use { it.copyTo(o, 1 shl 16) } }
            cr.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        }.isSuccess
        if (!ok) {
            runCatching { cr.delete(uri, null, null) }
            return null
        }
        // MediaStore may have changed the name (one taken by another app's file)
        val saved = runCatching {
            cr.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { q -> if (q.moveToFirst()) q.getString(0) else null }
        }.getOrNull() ?: n
        return RemoteFileReceiver.Saved(saved, uri.toString())
    }

    /** Save to Gallery: a copy in Pictures/Blurt or Movies/Blurt. Android 10 and later only (below, it would need a permission). */
    fun canSaveToGallery(name: String) = Build.VERSION.SDK_INT >= 29 && RemoteFiles.isMedia(name)

    fun toGallery(c: Context, from: Uri, name: String): Boolean {
        if (Build.VERSION.SDK_INT < 29) return false
        val video = RemoteFiles.isVideo(name)
        val coll = if (video) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val cr = c.contentResolver
        val v = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime(name))
            put(MediaStore.MediaColumns.RELATIVE_PATH, (if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES) + "/" + FOLDER)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = runCatching { cr.insert(coll, v) }.getOrNull() ?: return false
        val ok = runCatching {
            cr.openInputStream(from)!!.use { i -> cr.openOutputStream(uri)!!.use { i.copyTo(it, 1 shl 16) } }
            cr.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        }.isSuccess
        if (!ok) runCatching { cr.delete(uri, null, null) }
        return ok
    }

    /** Open: the app the phone opens this kind of file with. */
    fun open(c: Context, uri: Uri, name: String) {
        val i = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime(name))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { c.startActivity(i) }.onFailure { share(c, uri, name) }
    }

    /** Share…: the system's share sheet. */
    fun share(c: Context, uri: Uri, name: String) {
        val send = Intent(Intent.ACTION_SEND).setType(mime(name)).putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        // the grant goes through the chooser to the app picked only with the item as clip data too
        send.clipData = android.content.ClipData.newRawUri(name, uri)
        c.startActivity(Intent.createChooser(send, c.getString(R.string.share)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
