package si.gasilko.app.feature.incidents

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.io.File
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.UUID

internal const val EVIDENCE_MAX=20*1024*1024
internal fun evidenceHash(bytes: ByteArray)=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
internal fun evidenceExtension(mime: String)=when(mime) {
    "image/jpeg"->"jpg";"image/webp"->"webp";"application/pdf"->"pdf";else->error("ATTACHMENT_TYPE_UNSUPPORTED")
}
internal fun evidenceName(value: String)=value.filterNot { it.isISOControl() || it in "\u061c\u200e\u200f\ufeff/\\\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069" }.trim().take(120).ifEmpty { "evidence" }
/** Uses the existing photo storage policy: app-private noBackupFilesDir, no automatic cleanup.
 * Unlike hydrant image preparation, evidentiary bytes are NOT resized/re-encoded or EXIF-stripped. */
internal class IncidentEvidenceFiles(private val context: Context) {
    private val root=File(context.noBackupFilesDir,"incident-evidence")
    private fun file(account: String,org: String,incident: String,id: String): File {
        listOf(account,org,incident,id).forEach { require(UUID.fromString(it).toString()==it) }
        return File(root,"$account/$org/$incident/$id")
    }
    suspend fun stage(account: String,org: String,incident: String,id: String,uri: Uri,checkAcquisition: ()->Unit): JsonObject=withContext(Dispatchers.IO) {
        checkAcquisition();currentCoroutineContext().ensureActive()
        val mime=context.contentResolver.getType(uri) ?: error("ATTACHMENT_TYPE_UNSUPPORTED")
        evidenceExtension(mime)
        val max=if(mime=="application/pdf")EVIDENCE_MAX else EVIDENCE_MAX/2
        var name="evidence."+evidenceExtension(mime)
        context.contentResolver.query(uri,arrayOf(OpenableColumns.DISPLAY_NAME),null,null,null)?.use {
            if(it.moveToFirst())name=evidenceName(it.getString(0).orEmpty())
        }
        val used=File(root,"$account/$org").walkTopDown().filter { it.isFile }.sumOf { it.length() }
        require(used+max<=134217728) { "ATTACHMENT_LIMIT" }
        val target=file(account,org,incident,id)
        check(!target.exists())
        check(target.parentFile!!.isDirectory || target.parentFile!!.mkdirs())
        val temp=File(target.parentFile,target.name+".part")
        try {
            var total=0L
            context.contentResolver.openInputStream(uri)?.use { input ->
                temp.outputStream().use { out ->
                    val buffer=ByteArray(8192)
                    while(true) {
                        currentCoroutineContext().ensureActive();checkAcquisition()
                        val n=input.read(buffer);if(n<0)break
                        total+=n;if(total>max)error("ATTACHMENT_TOO_LARGE")
                        out.write(buffer,0,n)
                    }
                }
            } ?: error("ATTACHMENT_MALFORMED")
            check(total>0) { "ATTACHMENT_MALFORMED" }
            val bytes=temp.readBytes()
            require(localSignature(bytes,mime)) { "ATTACHMENT_MALFORMED" }
            checkAcquisition();currentCoroutineContext().ensureActive()
            check(temp.renameTo(target))
            buildJsonObject { put("filename",name);put("mime",mime);put("size",total.toString());put("sha256",evidenceHash(bytes)) }
        } finally { temp.delete() } // Only this not-yet-registered partial copy. Never delete queued evidence.
    }
    suspend fun read(account: String,org: String,incident: String,id: String,metadata: JsonObject): ByteArray=withContext(Dispatchers.IO) {
        val target=file(account,org,incident,id)
        require(target.isFile && target.length() in 1..EVIDENCE_MAX.toLong()) { "ATTACHMENT_LOCAL_MISSING" }
        val out=ByteArrayOutputStream()
        target.inputStream().use { input ->
            val buffer=ByteArray(8192)
            while(true) { val n=input.read(buffer);if(n<0)break;require(out.size()+n<=EVIDENCE_MAX);out.write(buffer,0,n) }
        }
        out.toByteArray().also { require(it.size.toString()==metadata.text("size") && evidenceHash(it)==metadata.text("sha256")) { "ATTACHMENT_LOCAL_MISMATCH" } }
    }
    private fun localSignature(b: ByteArray,mime: String)=when(mime) {
        "image/jpeg" -> b.size>=4 && b[0]==(-1).toByte() && b[1]==(-40).toByte()
        "image/webp" -> b.size>=12 && String(b,0,4,Charsets.US_ASCII)=="RIFF" && String(b,8,4,Charsets.US_ASCII)=="WEBP"
        "application/pdf" -> b.size>=8 && String(b,0,5,Charsets.US_ASCII)=="%PDF-"
        else -> false
    }
}
