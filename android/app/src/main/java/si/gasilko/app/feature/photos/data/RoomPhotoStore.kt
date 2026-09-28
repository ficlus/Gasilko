package si.gasilko.app.feature.photos.data

import androidx.room.withTransaction
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.data.hydrantRemoteAccess
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.photos.domain.*

/** Photo slice of the registry repository; shares its authorization, write lock and queue. */
internal class RoomPhotoStore(
    private val db: RegistryDatabase, private val online: HydrantRepository, private val files: PhotoFiles?,
    private val account: ()->String, private val access: suspend (String,String)->Hydrant,
    private val changes: Mutex, private val schedule: (String,String)->Unit,
    private val work: (String,String)->Flow<SyncPhase>,
) {
    private fun check(expected: String) { if(account()!=expected)throw RegistryFailure(RegistryError.EXPIRED) }
    private fun scheduleSafely(actor: String, org: String) {
        try { schedule(actor,org) } catch(_: Exception) { android.util.Log.w("HydrantSync","schedule failed; photo retained") }
    }
    suspend fun discard(org: String, hydrant: String, input: LocalPhotoInput) = changes.withLock {
        val actor=account();access(org,hydrant)
        db.withTransaction {
            check(actor)
            // Serialize ownership check/deletion with registration, including other repository instances.
            if(db.photos().identity(actor,input.id)==null) {
                (files ?: throw RegistryFailure(RegistryError.UNAVAILABLE)).discard(actor,org,hydrant,input)
                true
            } else false
        }
    }
    suspend fun destination(org: String, hydrant: String, id: String, mime: String): String {
        val actor=account();access(org,hydrant)
        if(db.photos().identity(actor,id)!=null)throw RegistryFailure(RegistryError.VALIDATION)
        return (files ?: throw RegistryFailure(RegistryError.UNAVAILABLE)).prepare(actor,org,hydrant,id,mime).also { check(actor) }
    }
    suspend fun register(org: String, hydrant: String, input: LocalPhotoInput): Photo = changes.withLock {
        val actor=account();access(org,hydrant)
        val result=db.withTransaction {
            val parent=access(org,hydrant)
            // Ownership cleanup cannot delete a file between validation and Room insertion.
            val bytes=(files ?: throw RegistryFailure(RegistryError.UNAVAILABLE)).read(actor,org,hydrant,input.id,input.mimeType,input.localPath)
            val now=System.currentTimeMillis()
            val photo=Photo(input.id,org,hydrant,input.inspectionId,input.category,
                photoStoragePath(org,hydrant,input.id,input.inspectionId,input.mimeType),input.mimeType,bytes.size.toLong(),
                bytes.photoHash(),input.capturedAt,actor,now).also { it.validate() }
            val queue=db.registry().pendingChanges(actor,org)
            if(parent.version==0L && queue.none { it.entityId==hydrant && it.operation=="CREATE" && it.state!="SYNCED" })
                throw RegistryFailure(RegistryError.VALIDATION)
            if(input.inspectionId!=null) {
                val event=db.registry().inspection(actor,org,input.inspectionId) ?: throw RegistryFailure(RegistryError.UNAVAILABLE)
                if(event.value.hydrantId!=hydrant || (event.acknowledgedAt==null && queue.none {
                        it.operation=="CREATE_INSPECTION" && it.operationId==input.inspectionId && it.entityId==hydrant }))
                    throw RegistryFailure(RegistryError.VALIDATION)
            }
            val existing=db.photos().identity(actor,input.id)
            if(existing!=null) {
                if(!existing.value.sameContent(photo) || existing.localPath!=input.localPath)throw RegistryFailure(RegistryError.VALIDATION)
                check(actor)
                return@withTransaction existing.value
            }
            db.photos().insert(PhotoEntity(actor,photo,input.localPath))
            db.registry().enqueue(PendingHydrantChange(operationId=photo.id,account=actor,organization=org,entityId=hydrant,
                operation=UPLOAD_PHOTO,payload=photo.payload().toString(),baseVersion=null,createdAt=now))
            check(actor)
            photo
        }
        scheduleSafely(actor,org)
        result
    }
    fun observe(org: String, hydrant: String, inspection: String?): Flow<List<PhotoEntry>> = flow {
        val actor=account()
        emitAll(combine(db.invalidationTracker.createFlow("photos","pending_hydrant_changes","hydrants","organizations"),work(actor,org)) { _, phase ->
            access(org,hydrant)
            db.withTransaction {
                val queue=db.registry().pendingChanges(actor,org)
                val blocked=queue.any { it.state in listOf("CONFLICT","ATTENTION") }
                val ops=queue.filter { it.operation==UPLOAD_PHOTO && it.entityId==hydrant }.associateBy { it.operationId }
                db.photos().list(actor,org,hydrant,inspection).map { row ->
                    val op=ops[row.value.id]
                    val state=when {
                        row.syncIssue!=null || op?.state=="ATTENTION" -> PhotoSyncState.ATTENTION
                        op!=null && op.state!="SYNCED" -> if(blocked || phase==SyncPhase.RETRY)PhotoSyncState.ATTENTION else PhotoSyncState.PENDING
                        row.value.uploadedAt!=null && (op==null || op.state=="SYNCED") -> PhotoSyncState.SYNCED
                        else -> PhotoSyncState.ATTENTION
                    }
                    PhotoEntry(row.value,row.localPath,state,row.syncIssue)
                }.also { check(actor) }
            }
        }.distinctUntilChanged())
    }
    suspend fun refresh(org: String, hydrant: String) = hydrantRemoteAccess.withLock { changes.withLock refresh@{
        val actor=account()
        if(access(org,hydrant).version==0L)return@refresh
        val rows=mutableListOf<Photo>()
        for(category in PhotoCategory.entries) {
            var after: String?=null
            do {
                val page=online.listPhotos(org,hydrant,category,after)
                if(page.any { it.organization!=org || it.hydrantId!=hydrant || it.category!=category || (after!=null && it.id<=after!!) })
                    throw RegistryFailure(RegistryError.VALIDATION)
                rows.addAll(page.filter { it.uploadedAt!=null });after=page.lastOrNull()?.id
                check(actor)
            } while(page.size==100)
        }
        db.withTransaction {
            access(org,hydrant)
            val ops=db.registry().pendingChanges(actor,org).filter { it.operation==UPLOAD_PHOTO }.associateBy { it.operationId }
            for(photo in rows) {
                val existing=db.photos().identity(actor,photo.id)
                if(existing==null)db.photos().insert(PhotoEntity(actor,photo))
                else {
                    if(existing.value.organization!=org)throw RegistryFailure(RegistryError.VALIDATION)
                    if(!existing.value.sameContent(photo))recordPhotoIssue(db,actor,org,photo.id,"SERVER_PHOTO_MISMATCH")
                    else if(ops[photo.id]?.state.let { it==null || it=="SYNCED" })
                        db.photos().acknowledge(actor,org,photo.id,photo.createdAt,photo.uploadedAt!!,photo.active)
                    // Matching pending rows are acknowledged only when the worker reaches their ordered head.
                }
            }
            check(actor)
        }
        scheduleSafely(actor,org)
    } }
}

internal suspend fun recordPhotoIssue(db: RegistryDatabase, account: String, organization: String, id: String, issue: String) = db.withTransaction {
    db.photos().issue(account,organization,id,issue)
    db.photos().block(account,organization,id)
}
