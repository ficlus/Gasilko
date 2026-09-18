package si.gasilko.app.feature.auth
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch
import si.gasilko.app.R
import si.gasilko.app.core.access.*
@Composable
private fun Selection(label:String,choices:List<Choice>,selected:String?,enabled:Boolean,onSelect:(Choice)->Unit) {
    var open by remember { mutableStateOf(false) }
    Text(label)
    Box { OutlinedButton(enabled=enabled,onClick={open=true}){Text(choices.find{it.id==selected}?.name?:label)}
        DropdownMenu(expanded=open,onDismissRequest={open=false}){choices.forEach{choice->DropdownMenuItem(text={Text(choice.name)},onClick={open=false;onSelect(choice)})}}
    }
}
@Composable
fun AccessScreen(repository:AccessRepository,back:()->Unit,signOut:()->Unit,refreshAccount:()->Unit = {}) {
    val state by repository.state.collectAsStateWithLifecycle();val scope=rememberCoroutineScope()
    var ready by remember { mutableStateOf(false) }
    LaunchedEffect(repository){repository.load();ready=true}
    var selected by remember(state.country,state.trail){mutableStateOf<String?>(null)}
    var role by remember {mutableStateOf("FIREFIGHTER")}
    Scaffold{padding->Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
        Text(stringResource(R.string.access_request_access),style=MaterialTheme.typography.headlineMedium)
        Text(stringResource(R.string.access_request_no_access))
        TextButton(onClick=back){Text(stringResource(R.string.access_back_account))}
        if(!ready){CircularProgressIndicator()}else{
            Selection(stringResource(R.string.access_select_country),state.countries,state.country,!state.busy){country->scope.launch{repository.browse(country.id,emptyList())}}
            state.country?.let{country->
                Text(state.trail.joinToString(" / "){it.name}.ifBlank{stringResource(R.string.access_all_areas)})
                if(state.trail.isNotEmpty())TextButton(enabled=!state.busy,onClick={scope.launch{repository.browse(country,state.trail.dropLast(1))}}){Text(stringResource(R.string.access_parent_area))}
                Selection(stringResource(R.string.access_select_area),state.areas,null,!state.busy){area->scope.launch{repository.browse(country,state.trail+area)}}
                if(state.moreAreas)TextButton(enabled=!state.busy,onClick={scope.launch{repository.more("areas")}}){Text(stringResource(R.string.access_load_more))}
                Selection(stringResource(R.string.access_select_organization),state.organizations.map{Choice(it.id,it.name+" ("+it.code+")")},selected,!state.busy){selected=it.id}
                if(state.moreOrganizations)TextButton(enabled=!state.busy,onClick={scope.launch{repository.more("organizations")}}){Text(stringResource(R.string.access_load_more))}
                Text(stringResource(R.string.access_requested_role))
                Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){
                    FilterChip(enabled=!state.busy,selected=role=="FIREFIGHTER",onClick={role="FIREFIGHTER"},label={Text(stringResource(R.string.access_firefighter))})
                    FilterChip(enabled=!state.busy,selected=role=="MANAGER",onClick={role="MANAGER"},label={Text(stringResource(R.string.access_manager))})
                }
                Button(enabled=!state.busy&&selected!=null,onClick={selected?.let{org->scope.launch{repository.submit(org,role)}}}){Text(stringResource(R.string.access_confirm_request))}
            }
            state.result?.let{result->Text(stringResource(when(result){"SUBMITTED"->R.string.access_request_submitted;"DUPLICATE_REQUEST"->R.string.access_duplicate_request;"ALREADY_MEMBER"->R.string.access_already_member;else->R.string.access_request_error}))}
            Text(stringResource(R.string.access_current_requests),style=MaterialTheme.typography.titleLarge)
            if(state.history.isEmpty())Text(stringResource(R.string.access_no_requests))
            state.history.forEach{r->Text(r.organizationName);Text(stringResource(if(r.role=="MANAGER")R.string.access_manager else R.string.access_firefighter));Text(stringResource(when(r.status){"PENDING"->R.string.access_request_pending;"APPROVED"->R.string.access_request_approved;"REJECTED"->R.string.access_request_rejected;else->R.string.access_request_error}))}
            if(state.moreHistory)TextButton(enabled=!state.busy,onClick={scope.launch{repository.more("history")}}){Text(stringResource(R.string.access_load_more))}
            Button(enabled=!state.busy,onClick={scope.launch{repository.load();refreshAccount()}}){Text(stringResource(R.string.access_refresh_requests))}
        }
        TextButton(onClick=signOut){Text(stringResource(R.string.auth_sign_out))}
    }}
}
