package si.gasilko.app.feature.incidents

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.provider.OpenableColumns
import java.io.FileNotFoundException
import java.util.UUID

/** Ephemeral, granted document-viewer delivery only. No disk file survives process death.
 * The provider is non-exported; Android enforces the exact temporary URI read grant.
 * It is NOT an offline cache, credential store, upload path or source of authority. */
class IncidentEvidenceProvider: ContentProvider() {
    private data class Document(val bytes: ByteArray,val expires: Long)
    companion object {
        private val documents=mutableMapOf<String,Document>()
        @Synchronized internal fun grant(context: Context,bytes: ByteArray): Uri {
            require(bytes.size in 1..EVIDENCE_MAX)
            documents.entries.removeAll { it.value.expires<=SystemClock.elapsedRealtime() }
            require(documents.size<2)
            val id=UUID.randomUUID().toString()
            documents[id]=Document(bytes,SystemClock.elapsedRealtime()+60_000)
            return Uri.Builder().scheme("content").authority(context.packageName+".incident-evidence").appendPath(id).build()
        }
        @Synchronized internal fun release(context: Context,uri: Uri) {
            documents.remove(uri.lastPathSegment)
            context.revokeUriPermission(uri,android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        @Synchronized private fun document(uri: Uri): ByteArray {
            val id=uri.lastPathSegment ?: throw FileNotFoundException()
            val item=documents[id] ?: throw FileNotFoundException()
            if(item.expires<=SystemClock.elapsedRealtime()) { documents.remove(id);throw FileNotFoundException() }
            return item.bytes
        }
    }
    override fun onCreate()=true
    override fun getType(uri: Uri): String { document(uri);return "application/pdf" }
    override fun query(uri: Uri,projection: Array<out String>?,selection: String?,selectionArgs: Array<out String>?,sortOrder: String?): Cursor {
        val bytes=document(uri)
        val columns=(projection ?: arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE))
            .filter { it in listOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE) }.toTypedArray()
        return MatrixCursor(columns).apply { addRow(columns.map { if(it==OpenableColumns.SIZE)bytes.size else "evidence.pdf" }) }
    }
    override fun openFile(uri: Uri,mode: String): ParcelFileDescriptor {
        if(mode!="r")throw FileNotFoundException()
        val bytes=document(uri)
        return openPipeHelper(uri,"application/pdf",null,bytes) { output,_,_,_,payload->
            try { ParcelFileDescriptor.AutoCloseOutputStream(output).use { it.write(payload) } }
            catch(_: java.io.IOException) { output.close() } // Viewer closed its authorized copy; no canonical evidence is changed.
        }
    }
    override fun insert(uri: Uri,values: ContentValues?): Uri?=throw SecurityException()
    override fun update(uri: Uri,values: ContentValues?,selection: String?,selectionArgs: Array<out String>?): Int=throw SecurityException()
    override fun delete(uri: Uri,selection: String?,selectionArgs: Array<out String>?): Int=throw SecurityException()
}
