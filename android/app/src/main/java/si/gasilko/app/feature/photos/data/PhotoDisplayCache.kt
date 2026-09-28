package si.gasilko.app.feature.photos.data

import android.content.Context
import android.graphics.BitmapFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import si.gasilko.app.feature.photos.domain.*
import java.io.File
import java.io.IOException

/** Replaceable authenticated downloads only. Never traverses or removes pending-photos. */
internal class PhotoDisplayCache(context: Context) {
    private val root=File(context.applicationContext.cacheDir,"photo-display")
    companion object {
        private val lock=Mutex()
        private const val LIMIT=64L*1024*1024
    }
    suspend fun file(account: String, photo: Photo, download: suspend ()->ByteArray): String =
        lock.withLock { withContext(Dispatchers.IO) {
            photoUuid(account);photo.validate()
            val file=File(root,"$account/${photo.organization}/${photo.hydrantId}/${photo.id}-${photo.sha256}.${photoExtension(photo.mimeType)}")
            if(file.isFile && file.length()==photo.byteSize && valid(file.readBytes(),photo)) {
                file.setLastModified(System.currentTimeMillis())
                return@withContext file.absolutePath
            }
            // Only a replaceable, invalid display-cache entry is removed.
            if(file.exists() && !file.delete())throw IOException("Display cache unavailable")
            val bytes=download()
            if(!valid(bytes,photo))throw PhotoImageFailure(PhotoImageError.CORRUPT)
            if(!file.parentFile!!.isDirectory && !file.parentFile!!.mkdirs())throw IOException("Display cache unavailable")
            val entries=root.walkTopDown().filter { it.isFile }.sortedBy { it.lastModified() }.toList()
            var size=entries.sumOf { it.length() }
            for(entry in entries) {
                if(size+bytes.size<=LIMIT)break
                val length=entry.length()
                if(entry.delete())size-=length
            }
            if(size+bytes.size>LIMIT)throw IOException("Display cache full")
            val temporary=File(file.parentFile,file.name+".part")
            try {
                temporary.outputStream().use { it.write(bytes) }
                if(!temporary.renameTo(file))throw IOException("Display cache unavailable")
            } finally { temporary.delete() }
            file.absolutePath
        } }
    private fun valid(bytes: ByteArray, photo: Photo): Boolean {
        if(bytes.size.toLong()!=photo.byteSize || bytes.size.toLong() !in 1..MAX_PHOTO_BYTES || bytes.photoHash()!=photo.sha256)return false
        val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
        BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
        return bounds.outMimeType==photo.mimeType && bounds.outWidth in 1..1920 && bounds.outHeight in 1..1920
    }
}
