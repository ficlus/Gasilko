package si.gasilko.app.feature.photos.presentation

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import si.gasilko.app.R
import si.gasilko.app.feature.photos.data.PhotoInputs

/** Registered at the registry root, independent of which detail section is composed. */
@Composable fun PhotoAcquisitionHost(controller: PhotoAcquisition) {
    val context=LocalContext.current
    val state by controller.state.collectAsStateWithLifecycle()
    var cameraId by rememberSaveable { mutableStateOf<String?>(null) }
    var pickerId by rememberSaveable { mutableStateOf<String?>(null) }
    val cameraContract=remember { object : ActivityResultContracts.TakePicture() {
        override fun createIntent(context: Context, input: Uri): Intent = super.createIntent(context,input).apply {
            clipData=ClipData.newRawUri("capture",input)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
    } }
    val camera=rememberLauncherForActivityResult(cameraContract) { success ->
        val id=cameraId;cameraId=null
        controller.result(id,if(success && id!=null)PhotoInputs(context).cameraUri(id) else null,context)
    }
    val picker=rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        val id=pickerId;pickerId=null;controller.result(id,uri,context)
    }
    LaunchedEffect(state.step,state.id) {
        val id=state.id ?: return@LaunchedEffect
        val step=state.step;val uri=state.camera
        if(step==PhotoStep.CAMERA || step==PhotoStep.PICKER) {
            controller.launched(id)
            try {
                if(step==PhotoStep.CAMERA) { cameraId=id;camera.launch(uri!!) }
                else { pickerId=id;picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
            } catch(_: Exception) { cameraId=null;pickerId=null;controller.launchFailed(id) }
        }
    }
    when(state.step) {
        PhotoStep.CHOOSE -> AlertDialog(onDismissRequest=controller::clear,
            title={Text(stringResource(R.string.photo_add))},
            text={Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Button(onClick={controller.choose(true)},modifier=Modifier.fillMaxWidth()) { Text(stringResource(R.string.photo_take)) }
                OutlinedButton(onClick={controller.choose(false)},modifier=Modifier.fillMaxWidth()) { Text(stringResource(R.string.photo_choose)) }
            }},confirmButton={TextButton(onClick=controller::clear) { Text(stringResource(R.string.h_cancel)) }})
        PhotoStep.FAILED -> AlertDialog(onDismissRequest=controller::clear,
            title={Text(stringResource(R.string.photo_title))},
            text={Text(stringResource(when {
                state.registrationFailure -> R.string.photo_registration_failed
                state.invalid -> R.string.photo_invalid
                else -> R.string.photo_prepare_failed
            }))},
            confirmButton={TextButton(onClick=controller::retry) { Text(stringResource(R.string.photo_retry)) }},
            dismissButton={TextButton(onClick=controller::clear) { Text(stringResource(R.string.h_cancel)) }})
        PhotoStep.PREPARING,PhotoStep.CAMERA,PhotoStep.PICKER,PhotoStep.WAITING -> AlertDialog(onDismissRequest={},
            title={Text(stringResource(R.string.photo_title))},text={Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
                LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(stringResource(if(state.step==PhotoStep.WAITING)R.string.photo_waiting else R.string.photo_preparing))
            }},confirmButton={})
        else -> Unit
    }
}
