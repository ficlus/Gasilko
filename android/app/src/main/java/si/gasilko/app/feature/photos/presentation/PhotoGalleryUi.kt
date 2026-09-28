package si.gasilko.app.feature.photos.presentation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import coil3.request.CachePolicy
import coil3.request.ImageRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import si.gasilko.app.R
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.hydrants.presentation.HydrantViewModel
import si.gasilko.app.feature.photos.domain.*
import java.io.File
import java.text.DateFormat
import java.util.Date

data class PhotoGalleryState(val entries: List<PhotoEntry> = emptyList(), val loaded: Boolean = false, val error: RegistryError? = null)

@Composable
fun PhotoPreview(model: HydrantViewModel, state: PhotoGalleryState, enabled: Boolean,
    openGallery: ()->Unit, openPhoto: (String)->Unit) {
    Text(stringResource(R.string.photo_count,state.entries.size),style=MaterialTheme.typography.titleMedium)
    if(!state.loaded && state.error==null)CircularProgressIndicator(Modifier.size(24.dp))
    if(state.error!=null)Text(stringResource(R.string.photo_metadata_failed))
    if(state.loaded && state.entries.isEmpty())Text(stringResource(R.string.photo_empty))
    Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
        state.entries.take(3).forEach { entry ->
            key(entry.photo.id) {
                Column(Modifier.weight(1f)) {
                    PhotoImage(model,entry,Modifier.fillMaxWidth().height(100.dp).clickable(enabled) { openPhoto(entry.photo.id) })
                    PhotoState(entry)
                }
            }
        }
    }
    TextButton(onClick=openGallery,enabled=enabled) { Text(stringResource(R.string.photo_all)) }
}

@Composable
@OptIn(ExperimentalLayoutApi::class)
fun PhotoGalleryScreen(model: HydrantViewModel, organization: String, hydrant: String, label: String,
    state: PhotoGalleryState, busy: Boolean, canAdd: Boolean, phase: SyncPhase?,
    openPhoto: (String)->Unit, back: ()->Unit) {
    val context=LocalContext.current
    val scope=rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    var refreshFailed by remember { mutableStateOf(false) }
    BackHandler { if(!busy)back() }
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.photo_all),style=MaterialTheme.typography.headlineSmall)
            Text(label)
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                TextButton(back,enabled=!busy) { Text(stringResource(R.string.h_back)) }
                TextButton(onClick={
                    refreshing=true;refreshFailed=false
                    scope.launch {
                        try { model.refreshPhotoMetadata(organization,hydrant) }
                        catch(e: CancellationException) { throw e }
                        catch(_: Exception) { refreshFailed=true }
                        finally { refreshing=false }
                    }
                },enabled=!refreshing && !busy) { Text(stringResource(R.string.h_refresh)) }
                if(canAdd) {
                    TextButton(onClick=model::syncNow,enabled=!busy && phase!=SyncPhase.SYNCING) { Text(stringResource(R.string.h_sync_now)) }
                    TextButton(onClick={model.addPhoto(context)},enabled=!busy) { Text(stringResource(R.string.photo_add)) }
                }
            }
            if(refreshing || (!state.loaded && state.error==null))LinearProgressIndicator(Modifier.fillMaxWidth())
            if(refreshFailed || state.error!=null)Text(stringResource(R.string.photo_metadata_failed),color=MaterialTheme.colorScheme.error)
            if(state.loaded && state.entries.isEmpty())Text(stringResource(R.string.photo_empty))
            LazyVerticalGrid(columns=GridCells.Adaptive(144.dp),modifier=Modifier.weight(1f),
                horizontalArrangement=Arrangement.spacedBy(12.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                items(state.entries,key={it.photo.id}) { entry ->
                    Column {
                        PhotoImage(model,entry,Modifier.fillMaxWidth().height(150.dp).clickable(!busy) { openPhoto(entry.photo.id) })
                        Text(photoDate(entry),style=MaterialTheme.typography.bodySmall)
                        PhotoState(entry)
                    }
                }
            }
        }
    }
}

@Composable
fun PhotoViewer(model: HydrantViewModel, entry: PhotoEntry?, back: ()->Unit) {
    BackHandler(onBack=back)
    Surface(Modifier.fillMaxSize(),color=Color(0xFF151515),contentColor=Color.White) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            TextButton(back) { Text(stringResource(R.string.h_back)) }
            if(entry==null)Text(stringResource(R.string.photo_empty))
            else {
                Text(photoDate(entry))
                PhotoState(entry)
                PhotoImage(model,entry,Modifier.fillMaxWidth().weight(1f),ContentScale.Fit)
            }
        }
    }
}

@Composable private fun PhotoState(entry: PhotoEntry) {
    Text(stringResource(when(entry.state) {
        PhotoSyncState.SYNCED -> R.string.inspection_synced
        PhotoSyncState.PENDING -> R.string.inspection_pending
        PhotoSyncState.ATTENTION -> R.string.inspection_attention
    }),style=MaterialTheme.typography.bodySmall)
}
private fun photoDate(entry: PhotoEntry) =
    DateFormat.getDateTimeInstance(DateFormat.SHORT,DateFormat.SHORT).format(Date(entry.photo.capturedAt))

private data class ImageFile(val path: String? = null, val error: Int? = null)

@Composable
private fun PhotoImage(model: HydrantViewModel, entry: PhotoEntry, modifier: Modifier,
    scale: ContentScale = ContentScale.Crop) {
    val photo=entry.photo
    var retry by remember(photo.id) { mutableIntStateOf(0) }
    val file by produceState(ImageFile(),model,model.photoScope,photo,entry.localPath,retry) {
        value=ImageFile()
        try { value=ImageFile(path=model.photoImage(photo.organization,photo.hydrantId,photo.id)) }
        catch(e: CancellationException) { throw e }
        catch(e: PhotoImageFailure) {
            value=ImageFile(error=if(e.reason==PhotoImageError.MISSING_LOCAL)R.string.photo_missing_local else R.string.photo_corrupt)
        } catch(e: RegistryFailure) {
            value=ImageFile(error=if(e.reason in listOf(RegistryError.FORBIDDEN,RegistryError.EXPIRED))
                R.string.photo_access_denied else R.string.photo_load_failed)
        } catch(_: Exception) { value=ImageFile(error=R.string.photo_load_failed) }
    }
    val context=LocalContext.current
    var decodeFailed by remember(file,retry) { mutableStateOf(false) }
    var decoding by remember(file,retry) { mutableStateOf(true) }
    val request=remember(context,file.path,retry) {
        file.path?.let {
            // No global image-memory reuse across authorization changes. The repository
            // owns the bounded, account-partitioned disk cache and checks every read.
            ImageRequest.Builder(context).data(File(it))
                .memoryCachePolicy(CachePolicy.DISABLED).diskCachePolicy(CachePolicy.DISABLED).build()
        }
    }
    Box(modifier,contentAlignment=Alignment.Center) {
        val error=file.error ?: if(decodeFailed)R.string.photo_corrupt else null
        if(error!=null)Column(horizontalAlignment=Alignment.CenterHorizontally) {
            Text(stringResource(error),style=MaterialTheme.typography.bodySmall)
            TextButton(onClick={retry++}) { Text(stringResource(R.string.photo_retry)) }
        } else {
            if(request!=null)AsyncImage(model=request,contentDescription=stringResource(R.string.photo_title),
                modifier=Modifier.fillMaxSize(),contentScale=scale,
                onSuccess={decoding=false},onError={decoding=false;decodeFailed=true})
            if(request==null || decoding)CircularProgressIndicator(Modifier.size(24.dp))
        }
    }
}
