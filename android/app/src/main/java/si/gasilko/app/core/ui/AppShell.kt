package si.gasilko.app.core.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import si.gasilko.app.R

/** Existing destinations keep ownership of their title, actions and back handling. */
@Composable fun OrganizationFrame(organization: String?,content: @Composable ()->Unit) {
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        Surface(color=MaterialTheme.colorScheme.surfaceContainer) {
            Column(Modifier.fillMaxWidth().heightIn(max=72.dp).verticalScroll(rememberScrollState()).padding(horizontal=16.dp,vertical=8.dp)) {
                Text(organization ?: stringResource(R.string.h_no_organization),style=MaterialTheme.typography.labelLarge)
            }
        }
        Box(Modifier.weight(1f)) { content() }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable fun AppHeader(title: String,organization: String?,home: (()->Unit)?,enabled: Boolean,
    refresh: ()->Unit,requestAccess: ()->Unit,signOut: ()->Unit,canRequestAccess: Boolean,canSignOut: Boolean) {
    var menu by remember { mutableStateOf(false) }
    ScreenHeading(title,organization)
    FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
        home?.let { action ->
            CompactAction(onClick=action,enabled=enabled) {
                ActionLabel(stringResource(R.string.shell_home),R.drawable.ic_field_arrow_back)
            }
        }
        CompactAction(onClick=refresh,enabled=enabled,modifier=Modifier.testTag("refresh")) {
            ActionLabel(stringResource(R.string.h_refresh),R.drawable.ic_field_refresh)
        }
        Box {
            CompactAction(onClick={menu=true}) { Text(stringResource(R.string.shell_account)) }
            DropdownMenu(expanded=menu,onDismissRequest={menu=false}) {
                DropdownMenuItem(text={Text(stringResource(R.string.access_request_access))},enabled=canRequestAccess,
                    onClick={menu=false;requestAccess()})
                DropdownMenuItem(text={Text(stringResource(R.string.auth_sign_out))},enabled=canSignOut,
                    onClick={menu=false;signOut()})
            }
        }
    }
}
