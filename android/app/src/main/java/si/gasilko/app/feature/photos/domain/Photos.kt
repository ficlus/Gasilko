package si.gasilko.app.feature.photos.domain

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import si.gasilko.app.feature.hydrants.domain.*
import java.util.UUID

const val UPLOAD_PHOTO = "UPLOAD_PHOTO"
const val PHOTO_BUCKET = "hydrant-photos"
const val MAX_PHOTO_BYTES = 5 * 1024 * 1024L
enum class PhotoCategory { HYDRANT, INSPECTION }
enum class PhotoSyncState { PENDING, SYNCED, ATTENTION }
enum class PhotoImageError { MISSING_LOCAL, CORRUPT }
class PhotoImageFailure(val reason: PhotoImageError): Exception()

data class LocalPhotoInput(val id: String, val category: PhotoCategory, val inspectionId: String?,
    val mimeType: String, val capturedAt: Long, val localPath: String)

data class Photo(val id: String, val organization: String, val hydrantId: String, val inspectionId: String?,
    val category: PhotoCategory, val storagePath: String, val mimeType: String, val byteSize: Long,
    val sha256: String, val capturedAt: Long, val createdBy: String, val createdAt: Long,
    val active: Boolean = true, val uploadedAt: Long? = null) {
    fun sameContent(other: Photo) = copy(createdAt=0,uploadedAt=null,active=true)==other.copy(createdAt=0,uploadedAt=null,active=true)
    fun validate() {
        listOfNotNull(id,organization,hydrantId,inspectionId,createdBy).forEach(::photoUuid)
        if((category==PhotoCategory.INSPECTION)!=(inspectionId!=null) || byteSize !in 1..MAX_PHOTO_BYTES ||
            !sha256.matches(Regex("[0-9a-f]{64}")) || capturedAt !in 0..253402300799999L ||
            storagePath!=photoStoragePath(organization,hydrantId,id,inspectionId,mimeType))
            throw RegistryFailure(RegistryError.VALIDATION)
    }
}
data class PhotoEntry(val photo: Photo, val localPath: String?, val state: PhotoSyncState, val issue: String? = null)

fun photoUuid(value: String) {
    if(runCatching { UUID.fromString(value).toString() }.getOrNull()!=value)throw RegistryFailure(RegistryError.VALIDATION)
}
fun photoExtension(mime: String) = when(mime) {
    "image/jpeg" -> "jpg"
    "image/webp" -> "webp"
    else -> throw RegistryFailure(RegistryError.VALIDATION)
}
fun photoStoragePath(organization: String, hydrant: String, id: String, inspection: String?, mime: String): String {
    listOfNotNull(organization,hydrant,id,inspection).forEach(::photoUuid)
    val folder=inspection?.let { "inspections/$it" } ?: "main"
    return "hydrants/$organization/$hydrant/$folder/$id.${photoExtension(mime)}"
}

interface PhotoRepository {
    /** Authorized presentation file; never an upload source for remotely cached images. */
    suspend fun displayPhoto(organization: String, hydrantId: String, id: String): String =
        throw RegistryFailure(RegistryError.UNAVAILABLE)
    suspend fun downloadPhotoObject(photo: Photo): ByteArray = throw RegistryFailure(RegistryError.UNAVAILABLE)
    /** M6.2 writes an optimized, closed file here before registration. Never rewrite registered files. */
    suspend fun photoFile(organization: String, hydrantId: String, id: String, mimeType: String): String =
        throw RegistryFailure(RegistryError.UNAVAILABLE)
    /** Atomically persists metadata and appends upload to the existing global queue. */
    suspend fun registerPhoto(organization: String, hydrantId: String, input: LocalPhotoInput): Photo =
        throw RegistryFailure(RegistryError.UNAVAILABLE)
    /** Acquisition cancellation only: repository must prove no Room row owns this file. */
    suspend fun discardUnregisteredPhoto(organization: String, hydrantId: String, input: LocalPhotoInput): Boolean {
        throw RegistryFailure(RegistryError.UNAVAILABLE)
    }
    fun observePhotos(organization: String, hydrantId: String, inspectionId: String? = null): Flow<List<PhotoEntry>> = flowOf(emptyList())
    suspend fun refreshPhotos(organization: String, hydrantId: String) {}
    // Online adapter methods are used only by the existing sync engine/explicit refresh.
    suspend fun reservePhoto(photo: Photo): Photo = throw RegistryFailure(RegistryError.UNAVAILABLE)
    suspend fun confirmPhoto(photo: Photo): Photo = throw RegistryFailure(RegistryError.UNAVAILABLE)
    suspend fun uploadPhotoObject(photo: Photo, bytes: ByteArray) { throw RegistryFailure(RegistryError.UNAVAILABLE) }
    suspend fun listPhotos(organization: String, hydrantId: String, category: PhotoCategory, after: String?): List<Photo> = emptyList()
}
