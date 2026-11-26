// A folder picked with the system's folder picker (a document tree) goes as one zip, named after it, as Finder and Files make them for
// sharing a folder. java.util.zip, stored as it walks: nothing is downloaded and nothing needs a permission beyond the tree's own grant.
package dev.blurt.remote.app.files

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import dev.blurt.remote.core.RemoteFiles
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

object Zip {
    /** The folder's own name, as the picker showed it. */
    fun name(c: Context, tree: Uri): String? = runCatching {
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        c.contentResolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { q ->
            if (q.moveToFirst()) q.getString(0) else null
        }
    }.getOrNull()?.let { RemoteFiles.clean(it) }

    /** `<dir>/<name>.zip` of everything under the tree, folders and all. Synchronous: off the main thread. */
    fun folder(c: Context, tree: Uri, dir: File, name: String): File {
        val out = File(dir, "$name.zip")
        ZipOutputStream(out.outputStream().buffered()).use { z ->
            fun walk(docId: String, path: String) {
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
                val cols = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE)
                c.contentResolver.query(children, cols, null, null, null)?.use { q ->
                    while (q.moveToNext()) {
                        val id = q.getString(0)
                        val n = RemoteFiles.clean(q.getString(1) ?: continue)
                        if (q.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                            z.putNextEntry(ZipEntry("$path$n/"))
                            z.closeEntry()
                            walk(id, "$path$n/")
                        } else {
                            z.putNextEntry(ZipEntry("$path$n"))
                            c.contentResolver.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, id))?.use { it.copyTo(z, 1 shl 16) }
                            z.closeEntry()
                        }
                    }
                }
            }
            val root = DocumentsContract.getTreeDocumentId(tree)
            z.putNextEntry(ZipEntry("$name/"))
            z.closeEntry()
            walk(root, "$name/")
        }
        return out
    }
}
