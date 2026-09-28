package si.gasilko.app.feature.photos.data

import android.content.Context
import android.graphics.*
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.exifinterface.media.ExifInterface
import kotlinx.coroutines.*
import si.gasilko.app.feature.photos.domain.*
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import kotlin.math.max

class PhotoCaptureProvider : FileProvider()
class InvalidPhoto : Exception()

/** Only this disposable directory is exposed to the external camera. */
class PhotoInputs(private val context: Context) {
    fun cameraFile(id: String): File {
        photoUuid(id)
        return File(context.cacheDir,"photo-capture/$id.jpg")
    }
    fun cameraUri(id: String): Uri = FileProvider.getUriForFile(context,"${context.packageName}.photo-capture",cameraFile(id))
    suspend fun createCamera(id: String): Uri = withContext(Dispatchers.IO) {
        val file=cameraFile(id)
        if(!file.parentFile!!.isDirectory && !file.parentFile!!.mkdirs())throw InvalidPhoto()
        if(file.exists() && !file.delete())throw InvalidPhoto() // Unregistered camera scratch file only.
        if(!file.createNewFile())throw InvalidPhoto()
        cameraUri(id)
    }
    suspend fun clear(id: String) = withContext(Dispatchers.IO) {
        context.revokeUriPermission(cameraUri(id),android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        val file=cameraFile(id)
        if(file.exists() && !file.delete())android.util.Log.w("PhotoCapture","temporary capture cleanup failed")
    }
}

/** One-time preparation; sync retries use the finalized bytes without re-encoding. */
class ImagePreparation(context: Context) {
    private val app=context.applicationContext
    suspend fun prepare(id: String, source: Uri, destination: String) = withContext(Dispatchers.IO) {
        photoUuid(id)
        val incoming=File(app.cacheDir,"photo-processing/$id.input")
        val output=File(destination)
        val part=File(output.parentFile,"${output.name}.preparing")
        var decoded: Bitmap?=null
        var oriented: Bitmap?=null
        var flattened: Bitmap?=null
        try {
            if(source.scheme!="content" || output.exists() || part.exists())throw InvalidPhoto()
            if(!incoming.parentFile!!.isDirectory && !incoming.parentFile!!.mkdirs())throw InvalidPhoto()
            // Never retain the external URI. Copy a bounded stream before parsing metadata or pixels.
            app.contentResolver.openInputStream(source)?.use { input ->
                incoming.outputStream().use { target ->
                    val buffer=ByteArray(8192);var total=0L
                    while(true) {
                        currentCoroutineContext().ensureActive()
                        val count=input.read(buffer);if(count<0)break
                        total+=count
                        if(total>32L*1024*1024)throw InvalidPhoto()
                        target.write(buffer,0,count)
                    }
                    if(total==0L)throw InvalidPhoto()
                }
            } ?: throw InvalidPhoto()
            val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
            BitmapFactory.decodeFile(incoming.path,bounds)
            val width=bounds.outWidth;val height=bounds.outHeight
            if(bounds.outMimeType !in setOf("image/jpeg","image/png","image/webp") || width !in 1..32768 || height !in 1..32768 ||
                width.toLong()*height>120_000_000L)throw InvalidPhoto()
            var sample=1
            while(width/sample>3840 || height/sample>3840 || (width.toLong()/sample)*(height/sample)>8_000_000L)sample*=2
            val orientation=ExifInterface(incoming).getAttributeInt(ExifInterface.TAG_ORIENTATION,ExifInterface.ORIENTATION_NORMAL)
            currentCoroutineContext().ensureActive()
            val pixels=BitmapFactory.decodeFile(incoming.path,BitmapFactory.Options().apply {
                inSampleSize=sample;inPreferredConfig=Bitmap.Config.ARGB_8888;inScaled=false
            }) ?: throw InvalidPhoto()
            decoded=pixels
            if(pixels.width.toLong()*pixels.height>8_000_000L)throw InvalidPhoto()
            val matrix=Matrix().apply {
                when(orientation) {
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> setScale(-1f,1f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> setScale(1f,-1f)
                    ExifInterface.ORIENTATION_TRANSPOSE -> { setRotate(90f);postScale(-1f,1f) }
                    ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
                    ExifInterface.ORIENTATION_TRANSVERSE -> { setRotate(-90f);postScale(-1f,1f) }
                    ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
                }
                val scale=minOf(1f,1920f/max(pixels.width,pixels.height))
                postScale(scale,scale)
            }
            val rotated=Bitmap.createBitmap(pixels,0,0,pixels.width,pixels.height,matrix,true)
            oriented=rotated
            if(rotated.width !in 1..1920 || rotated.height !in 1..1920)throw InvalidPhoto()
            val clean=Bitmap.createBitmap(rotated.width,rotated.height,Bitmap.Config.ARGB_8888)
            flattened=clean
            Canvas(clean).apply { drawColor(Color.WHITE);drawBitmap(rotated,0f,0f,null) }
            // Fresh bitmap encoding copies no source EXIF/XMP/GPS/filename metadata.
            if(!part.createNewFile())throw InvalidPhoto()
            var accepted=false
            for(quality in listOf(85,75,65)) {
                currentCoroutineContext().ensureActive()
                FileOutputStream(part).use { stream ->
                    if(!clean.compress(Bitmap.CompressFormat.JPEG,quality,stream))throw InvalidPhoto()
                    stream.fd.sync()
                }
                if(part.length() in 1..MAX_PHOTO_BYTES) { accepted=true;break }
            }
            if(!accepted)throw InvalidPhoto()
            currentCoroutineContext().ensureActive()
            // Same-directory move, without REPLACE_EXISTING; never overwrite a finalized file.
            Files.move(part.toPath(),output.toPath())
        } catch(e: OutOfMemoryError) { throw InvalidPhoto() }
        finally {
            flattened?.recycle()
            if(oriented!==decoded)oriented?.recycle()
            decoded?.recycle()
            if(incoming.exists() && !incoming.delete())android.util.Log.w("PhotoCapture","temporary input cleanup failed")
            if(part.exists() && !part.delete())android.util.Log.w("PhotoCapture","unfinished output cleanup failed")
        }
    }
}
