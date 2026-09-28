package si.gasilko.app.feature.photos.presentation

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.photos.data.*
import si.gasilko.app.feature.photos.domain.*
import java.util.UUID

enum class PhotoStep { IDLE, CHOOSE, PREPARING, CAMERA, PICKER, WAITING, FAILED, SAVED }
data class PhotoAcquisitionState(val step: PhotoStep=PhotoStep.IDLE, val id: String?=null,
    val camera: Uri?=null, val invalid: Boolean=false, val registrationFailure: Boolean=false) {
    val busy get() = step !in listOf(PhotoStep.IDLE,PhotoStep.SAVED)
}

/** Owned by the existing hydrant ViewModel; retained across Activity recreation, never uploads. */
class PhotoAcquisition(private val repository: HydrantRepository, private val scope: CoroutineScope,
    private val validScope: (String,String,Int)->Boolean, private val authorizationFailed: (RegistryError)->Unit) {
    private data class Request(val app: Context, val id: String, val organization: String, val hydrant: String,
        val generation: Int, val capturedAt: Long, var path: String?=null, var finalized: Boolean=false) {
        fun input() = path?.let { LocalPhotoInput(id,PhotoCategory.HYDRANT,null,"image/jpeg",capturedAt,it) }
    }
    private val mutable=MutableStateFlow(PhotoAcquisitionState())
    val state=mutable.asStateFlow()
    private var request: Request?=null
    private var job: Job?=null
    private fun check(r: Request) {
        if(request!==r)throw CancellationException()
        if(!validScope(r.organization,r.hydrant,r.generation))throw RegistryFailure(RegistryError.FORBIDDEN)
    }
    fun begin(context: Context, organization: String, hydrant: String, generation: Int) {
        if(state.value.busy)return
        val r=Request(context.applicationContext,UUID.randomUUID().toString(),organization,hydrant,generation,System.currentTimeMillis())
        request=r;mutable.value=PhotoAcquisitionState(PhotoStep.CHOOSE,r.id)
    }
    fun choose(camera: Boolean) {
        val r=request ?: return
        if(state.value.step!=PhotoStep.CHOOSE)return
        mutable.value=PhotoAcquisitionState(PhotoStep.PREPARING,r.id)
        job=scope.launch {
            try {
                check(r)
                if(r.path==null)r.path=repository.photoFile(r.organization,r.hydrant,r.id,"image/jpeg")
                check(r)
                val uri=if(camera)PhotoInputs(r.app).createCamera(r.id) else null
                check(r)
                mutable.value=PhotoAcquisitionState(if(camera)PhotoStep.CAMERA else PhotoStep.PICKER,r.id,uri)
            } catch(e: CancellationException) {
                withContext(NonCancellable) { clearCapture(r.app,r.id);discard(r) };throw e
            }
            catch(e: Exception) { fail(r,e,false) }
        }
    }
    fun launched(id: String) {
        if(state.value.id==id && state.value.step in listOf(PhotoStep.CAMERA,PhotoStep.PICKER))
            mutable.value=state.value.copy(step=PhotoStep.WAITING)
    }
    fun launchFailed(id: String) {
        val r=request ?: return
        if(r.id==id)fail(r,IllegalStateException(),false)
    }
    fun result(id: String?, uri: Uri?, context: Context) {
        val r=request
        if(id==null)return
        if(r==null || r.id!=id) {
            scope.launch { clearCapture(context.applicationContext,id) };return
        }
        if(state.value.step!=PhotoStep.WAITING)return // Duplicate callback cannot remove a source being processed.
        if(uri==null) { clear();return } // Cancellation is not an error.
        prepareAndRegister(r,uri)
    }
    fun retry() {
        val r=request ?: return
        if(state.value.step!=PhotoStep.FAILED || job?.isActive==true)return
        if(r.finalized)prepareAndRegister(r,null)
        else mutable.value=PhotoAcquisitionState(PhotoStep.CHOOSE,r.id) // Same logical UUID when choosing again.
    }
    private fun prepareAndRegister(r: Request, uri: Uri?) {
        mutable.value=PhotoAcquisitionState(PhotoStep.PREPARING,r.id)
        job=scope.launch {
            var registering=false
            try {
                check(r)
                val input=r.input() ?: throw InvalidPhoto()
                if(!r.finalized) {
                    ImagePreparation(r.app).prepare(r.id,uri ?: throw InvalidPhoto(),input.localPath)
                    r.finalized=true
                }
                check(r)
                registering=true
                repository.registerPhoto(r.organization,r.hydrant,input)
                check(r)
                mutable.value=PhotoAcquisitionState(PhotoStep.SAVED,r.id)
                request=null // Room owns the finalized file; it is never acquisition cleanup.
            } catch(e: CancellationException) {
                withContext(NonCancellable) { discard(r) };throw e
            }
            catch(e: Exception) {
                if(discard(r))r.finalized=false
                fail(r,e,registering)
            } finally { withContext(NonCancellable) { clearCapture(r.app,r.id) } }
        }
    }
    private fun fail(r: Request, error: Exception, registering: Boolean) {
        if(request!==r)return
        val reason=(error as? RegistryFailure)?.reason
        if(reason in listOf(RegistryError.EXPIRED,RegistryError.FORBIDDEN)) {
            authorizationFailed(reason!!);return
        }
        mutable.value=PhotoAcquisitionState(PhotoStep.FAILED,r.id,invalid=error is InvalidPhoto || reason==RegistryError.VALIDATION,
            registrationFailure=registering)
    }
    fun clear() {
        val old=request;val previous=job
        request=null;job=null;mutable.value=PhotoAcquisitionState()
        previous?.cancel()
        if(old!=null)scope.launch(start=CoroutineStart.UNDISPATCHED) {
            withContext(NonCancellable) { previous?.join();clearCapture(old.app,old.id);discard(old) }
        }
    }
    private suspend fun discard(r: Request): Boolean {
        val input=r.input() ?: return true
        return try { repository.discardUnregisteredPhoto(r.organization,r.hydrant,input) }
        catch(_: Exception) { android.util.Log.w("PhotoCapture","ownership cleanup deferred");false }
        // A failed ownership/authorization check conservatively retains the file.
    }
    private suspend fun clearCapture(app: Context, id: String) {
        try { PhotoInputs(app).clear(id) }
        catch(_: Exception) { android.util.Log.w("PhotoCapture","capture cleanup deferred") }
    }
}
