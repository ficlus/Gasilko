package si.gasilko.app.feature.photos.data

import androidx.room.withTransaction
import kotlinx.serialization.json.Json
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.photos.domain.*

/** Called only by the existing ordered engine, while holding hydrantRemoteAccess. */
internal suspend fun uploadQueuedPhoto(db: RegistryDatabase, online: HydrantRepository, files: PhotoFiles?,
    operation: PendingHydrantChange, checkContext: ()->Unit) {
    val account=operation.account;val org=operation.organization;val id=operation.operationId
    try {
        val photo=decodePhoto(Json.parseToJsonElement(operation.payload))
        val local=db.photos().identity(account,id) ?: throw RegistryFailure(RegistryError.VALIDATION)
        if(photo.id!=id || photo.organization!=org || photo.hydrantId!=operation.entityId || photo.createdBy!=account ||
            !local.value.sameContent(photo) || local.syncIssue!=null)throw RegistryFailure(RegistryError.VALIDATION)
        fun verify(server: Photo): Photo {
            if(!photo.sameContent(server))throw RegistryFailure(RegistryError.VALIDATION)
            checkContext()
            return server
        }
        checkContext()
        var server=verify(online.reservePhoto(photo))
        if(server.uploadedAt==null)server=verify(online.confirmPhoto(photo)) // Recover a lost object/metadata ACK before requiring the file.
        if(server.uploadedAt==null) {
            val bytes=try {
                (files ?: throw RegistryFailure(RegistryError.UNAVAILABLE)).read(account,org,photo.hydrantId,id,
                    photo.mimeType,local.localPath ?: throw RegistryFailure(RegistryError.VALIDATION))
            } catch(_: java.io.IOException) { throw RegistryFailure(RegistryError.VALIDATION) }
            if(bytes.size.toLong()!=photo.byteSize || bytes.photoHash()!=photo.sha256)throw RegistryFailure(RegistryError.VALIDATION)
            checkContext()
            online.uploadPhotoObject(photo,bytes) // Insert-only: no replacement of an existing immutable object.
            checkContext()
            server=verify(online.confirmPhoto(photo))
        }
        val uploaded=server.uploadedAt ?: throw RegistryFailure(RegistryError.SERVER)
        db.withTransaction {
            checkContext()
            val head=db.registry().nextChange(account,org)
            if(head==null || head.sequence!=operation.sequence || head.state!="PENDING")throw RegistryFailure(RegistryError.UNAVAILABLE)
            check(db.photos().acknowledge(account,org,id,server.createdAt,uploaded,server.active)==1)
            // Photos do not mutate hydrant versions. The version lookup skips these receipts.
            check(db.registry().acknowledge(account,org,operation.sequence,null)==1)
            checkContext()
        }
    } catch(e: RegistryFailure) {
        if(e.reason==RegistryError.VALIDATION) {
            checkContext()
            recordPhotoIssue(db,account,org,id,"PHOTO_DATA_INVALID_OR_MISMATCH")
        }
        throw e
    }
}
