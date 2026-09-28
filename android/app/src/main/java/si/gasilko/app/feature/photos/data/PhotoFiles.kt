package si.gasilko.app.feature.photos.data

import android.content.Context
import android.graphics.BitmapFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.photos.domain.*
import java.io.File
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/** Private, non-cache/non-backup storage. No automatic cleanup, even after acknowledgement. */
class PhotoFiles(context: Context) {
    private val root=File(context.applicationContext.noBackupFilesDir,"pending-photos")
    fun destination(account: String, organization: String, hydrant: String, id: String, mime: String): File {
        listOf(account,organization,hydrant,id).forEach(::photoUuid)
        return File(root,"$account/$organization/$hydrant/$id.${photoExtension(mime)}")
    }
    suspend fun prepare(account: String, organization: String, hydrant: String, id: String, mime: String): String = withContext(Dispatchers.IO) {
        val file=destination(account,organization,hydrant,id,mime)
        if(!file.parentFile!!.isDirectory && !file.parentFile!!.mkdirs())throw RegistryFailure(RegistryError.UNAVAILABLE)
        file.absolutePath
    }
    suspend fun read(account: String, organization: String, hydrant: String, id: String, mime: String, path: String): ByteArray = withContext(Dispatchers.IO) {
        val expected=destination(account,organization,hydrant,id,mime)
        val relative=expected.relativeTo(root).path
        if(path!=expected.absolutePath || expected.canonicalPath!=File(root.canonicalFile,relative).absolutePath || !expected.isFile ||
            expected.length() !in 1..MAX_PHOTO_BYTES)throw RegistryFailure(RegistryError.VALIDATION)
        // Bounded read uses APIs available on minSdk 26, even if the file grows during reading.
        val bytes=expected.inputStream().use { source ->
            val output=ByteArrayOutputStream()
            val buffer=ByteArray(8192)
            while(true) {
                val count=source.read(buffer)
                if(count<0)break
                if(output.size().toLong()+count>MAX_PHOTO_BYTES)throw RegistryFailure(RegistryError.VALIDATION)
                output.write(buffer,0,count)
            }
            output.toByteArray()
        }
        if(bytes.size.toLong() !in 1..MAX_PHOTO_BYTES)throw RegistryFailure(RegistryError.VALIDATION)
        val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
        BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
        // M6.2 must optimize/orient/remove EXIF before staging. Refuse unoptimized dimensions here.
        if(bounds.outMimeType!=mime || bounds.outWidth !in 1..1920 || bounds.outHeight !in 1..1920)
            throw RegistryFailure(RegistryError.VALIDATION)
        bytes
    }
}
internal fun ByteArray.photoHash() = MessageDigest.getInstance("SHA-256").digest(this).joinToString("") { "%02x".format(it) }
