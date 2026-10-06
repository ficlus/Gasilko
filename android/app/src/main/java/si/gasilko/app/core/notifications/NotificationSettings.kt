package si.gasilko.app.core.notifications

import android.Manifest
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import si.gasilko.app.R
import si.gasilko.app.core.ui.*

@Composable
fun NotificationSettings(repository: NotificationRepository, back: ()->Unit) {
    val context=LocalContext.current
    val scope=rememberCoroutineScope()
    var values by remember { mutableStateOf<Map<String,Boolean>?>(null) }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var permissionDenied by remember { mutableStateOf(false) }
    val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        permissionDenied=!granted
        if(granted)NotificationInstallation.enqueue(context)
    }
    fun update(change: Map<String,Boolean> = emptyMap()) {
        if(busy)return
        busy=true;failed=false
        scope.launch { try { values=repository.preferences(change) }
            catch(e: CancellationException) { throw e }
            catch(_: Exception) { failed=true }
            finally { busy=false } }
    }
    LaunchedEffect(repository) { update() }
    BackHandler(onBack=back)
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        ScreenHeading(stringResource(R.string.notifications_title))
        TextButton(onClick=back) { Text(stringResource(R.string.h_back)) }
        FieldBanner(stringResource(R.string.notifications_privacy))
        if(!NotificationInstallation.firebase(context))FieldBanner(stringResource(R.string.notifications_configuration),FieldTone.WARNING)
        if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
        listOf("ASSIGNMENT" to R.string.notifications_assignment,"ACTIVATION" to R.string.notifications_activation,
            "HYDRANT" to R.string.notifications_hydrant).forEach { (key,label)->
            Row(Modifier.fillMaxWidth(),verticalAlignment=androidx.compose.ui.Alignment.CenterVertically) {
                Text(stringResource(label),Modifier.weight(1f))
                Switch(checked=values?.get(key)==true,enabled=values!=null && !busy,
                    onCheckedChange={update(mapOf(key to it))})
            }
        }
        Text(stringResource(R.string.notifications_defaults))
        if(failed) { FieldBanner(stringResource(R.string.notifications_network),FieldTone.WARNING)
            TextButton(onClick={update()}) { Text(stringResource(R.string.map_retry)) } }
        PrimaryAction(onClick={
            if(Build.VERSION.SDK_INT>=33)permission.launch(Manifest.permission.POST_NOTIFICATIONS)
            else context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,context.packageName))
        }) { Text(stringResource(R.string.notifications_enable)) }
        if(permissionDenied)FieldBanner(stringResource(R.string.notifications_denied),FieldTone.WARNING)
        TextButton(onClick={context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,context.packageName))}) {
            Text(stringResource(R.string.notifications_system_settings))
        }
    }
}
