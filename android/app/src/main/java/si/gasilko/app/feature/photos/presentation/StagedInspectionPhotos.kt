package si.gasilko.app.feature.photos.presentation

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import coil3.request.CachePolicy
import coil3.request.ImageRequest
import si.gasilko.app.R
import si.gasilko.app.feature.photos.domain.LocalPhotoInput
import java.io.File

/** Unregistered sources stay only in the account-scoped inspection draft. */
@Composable
fun StagedInspectionPhotos(photos: List<LocalPhotoInput>, editable: Boolean, add: ()->Unit, remove: (String)->Unit) {
    val context=LocalContext.current
    Text(stringResource(R.string.inspection_photos),style=MaterialTheme.typography.titleMedium)
    Text(stringResource(R.string.inspection_photos_staged))
    if(photos.isEmpty())Text(stringResource(R.string.photo_empty))
    LazyRow(horizontalArrangement=Arrangement.spacedBy(12.dp)) {
        items(photos,key={it.id}) { photo ->
            var failed by remember(photo.id) { mutableStateOf(false) }
            val request=remember(photo.id) {
                ImageRequest.Builder(context).data(File(photo.localPath))
                    .memoryCachePolicy(CachePolicy.DISABLED).diskCachePolicy(CachePolicy.DISABLED).build()
            }
            Column(Modifier.width(144.dp)) {
                if(failed)Text(stringResource(R.string.photo_corrupt),modifier=Modifier.heightIn(min=120.dp))
                else AsyncImage(request,stringResource(R.string.inspection_photos),modifier=Modifier.fillMaxWidth().height(120.dp),
                    contentScale=ContentScale.Crop,onError={failed=true})
                TextButton(onClick={remove(photo.id)},enabled=editable) { Text(stringResource(R.string.photo_remove_staged)) }
            }
        }
    }
    OutlinedButton(onClick=add,enabled=editable) { Text(stringResource(R.string.photo_add)) }
}
