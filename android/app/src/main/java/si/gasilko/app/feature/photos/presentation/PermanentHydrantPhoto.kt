package si.gasilko.app.feature.photos.presentation

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import si.gasilko.app.R
import si.gasilko.app.feature.hydrants.presentation.HydrantViewModel

/** Read-only identification; never adds a photo to an inspection draft. */
@Composable
fun PermanentHydrantPhoto(model: HydrantViewModel,organization: String,hydrant: String,code: String? = null,refreshMetadata: Boolean = true) {
    key(model,model.photoScope,organization,hydrant) {
        val flow=remember { model.permanentPhotoEntries(organization,hydrant) }
        val state by flow.collectAsStateWithLifecycle(initialValue=PhotoGalleryState())
        var refreshFailed by remember { mutableStateOf(false) }
        // Metadata refresh uses the shared repository lock. Cancel it when the inspection
        // freezes for completion so an optional preview cannot wait on the network ahead of the write.
        LaunchedEffect(refreshMetadata) {
            if(!refreshMetadata)return@LaunchedEffect
            try { model.refreshPermanentPhotos(organization,hydrant) }
            catch(e: CancellationException) { throw e }
            catch(_: Exception) { refreshFailed=true }
        }
        Column(verticalArrangement=Arrangement.spacedBy(6.dp)) {
            Text(stringResource(R.string.photo_identification),style=MaterialTheme.typography.labelLarge)
            code?.let { Text(it,style=MaterialTheme.typography.titleMedium) }
            // There is no primary-photo flag: reuse the gallery's deterministic newest-first order.
            val entry=state.entries.firstOrNull()
            if(entry!=null)PhotoImage(model,entry,Modifier.fillMaxWidth().height(136.dp).clip(MaterialTheme.shapes.medium),
                permanentPreview=true)
            else Surface(Modifier.fillMaxWidth(),shape=MaterialTheme.shapes.medium,color=MaterialTheme.colorScheme.surfaceContainer) {
                Column(Modifier.padding(12.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    if(!state.loaded && state.error==null)LinearProgressIndicator(Modifier.fillMaxWidth())
                    Text(stringResource(if(state.error!=null || refreshFailed)R.string.photo_load_failed else R.string.photo_no_permanent),
                        style=MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

/** Same scoped permanent-photo read/cache as identification previews, without an empty placeholder. */
@Composable
fun ApproachHydrantPhoto(model: HydrantViewModel,organization: String,hydrant: String,visible: Boolean,expanded: Boolean) {
    key(model,model.photoScope,organization,hydrant) {
        val flow=remember { model.permanentPhotoEntries(organization,hydrant) }
        val state by flow.collectAsStateWithLifecycle(initialValue=PhotoGalleryState())
        var viewed by remember { mutableStateOf<String?>(null) }
        // Once per target/scope, not once per GPS fix or distance-threshold crossing.
        LaunchedEffect(Unit) {
            try { model.refreshPermanentPhotos(organization,hydrant) }
            catch(e: CancellationException) { throw e }
            catch(_: Exception) { /* Optional remote metadata: retain the authorized cached photo. */ }
        }
        val entry=state.entries.firstOrNull().takeIf { state.error==null }
        if(visible && entry!=null) {
            PhotoImage(model,entry,Modifier.fillMaxWidth().height(if(expanded)176.dp else 88.dp)
                .clip(MaterialTheme.shapes.medium).clickable(onClickLabel=stringResource(R.string.photo_title)) { viewed=entry.photo.id },
                permanentPreview=true)
        }
        val viewedEntry=state.entries.find { it.photo.id==viewed }.takeIf { state.error==null }
        LaunchedEffect(viewedEntry) { if(viewedEntry==null)viewed=null }
        if(viewedEntry!=null)Dialog(onDismissRequest={viewed=null},properties=DialogProperties(usePlatformDefaultWidth=false)) {
            PhotoViewer(model,viewedEntry,permanentPreview=true,back={viewed=null})
        }
    }
}
