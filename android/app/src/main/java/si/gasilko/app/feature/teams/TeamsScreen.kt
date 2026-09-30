package si.gasilko.app.feature.teams

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Alignment
import si.gasilko.app.core.ui.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import si.gasilko.app.R
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.hydrants.presentation.HydrantViewModel
import si.gasilko.app.feature.hydrants.presentation.errorLabel
import java.util.UUID

data class TeamViewData(val data: TeamData = TeamData(), val error: RegistryError? = null)
private data class TeamEditor(val id: String, val creating: Boolean, val name: String = "", val members: Set<String> = emptySet())

@Composable
@OptIn(ExperimentalLayoutApi::class)
fun TeamsScreen(model: HydrantViewModel, organization: String, back: ()->Unit) {
    val flow=remember(model,organization) { model.teamData(organization) }
    val observed by flow.collectAsStateWithLifecycle(initialValue=TeamViewData())
    val data=observed.data
    val scope=rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<RegistryError?>(null) }
    var selected by remember { mutableStateOf<String?>(null) }
    var editor by remember { mutableStateOf<TeamEditor?>(null) }
    var picking by remember { mutableStateOf(false) }
    var pending by remember { mutableStateOf<TeamChange?>(null) }
    fun refresh() {
        if(busy)return
        busy=true;error=null
        scope.launch {
            try { model.refreshTeams(organization);pending=null;editor=null;picking=false }
            catch(e: CancellationException) { throw e }
            catch(e: Exception) { error=(e as? RegistryFailure)?.reason ?: RegistryError.SERVER }
            finally { busy=false }
        }
    }
    fun submit(change: TeamChange) {
        if(busy)return
        val request=pending ?: change
        pending=request;busy=true;error=null
        scope.launch {
            try {
                model.manageTeam(organization,request)
                pending=null;editor=null;picking=false;selected=request.id
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                error=(e as? RegistryFailure)?.reason ?: RegistryError.SERVER
                if(error==RegistryError.VALIDATION)pending=null
            }
            finally { busy=false }
        }
    }
    LaunchedEffect(organization) { refresh() }
    val team=data.teams.find { it.id==selected }
    val members=data.members.filter { it.teamId==team?.id }
    val editable=!busy && pending==null
    fun goBack() { if(!busy) { if(selected!=null)selected=null else back() } }
    BackHandler(onBack=::goBack)
    Scaffold { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding)) {
        val availableHeight = maxHeight
        Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            ScrollableHeader(availableHeight * 0.5f) {
                ScreenHeading(stringResource(R.string.teams_title))
                FieldBanner(stringResource(R.string.teams_online_notice))
                FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
                    CompactAction(onClick=::goBack,enabled=!busy) { ActionLabel(stringResource(R.string.h_back),R.drawable.ic_field_arrow_back) }
                    CompactAction(onClick=::refresh,enabled=!busy) { ActionLabel(stringResource(R.string.h_refresh),R.drawable.ic_field_refresh) }
                    PrimaryAction(onClick={editor=TeamEditor(UUID.randomUUID().toString(),true)},enabled=editable) { Text(stringResource(R.string.teams_new)) }
                    pending?.let { change -> TextButton(onClick={submit(change)},enabled=!busy) { Text(stringResource(R.string.photo_retry)) } }
                }
                if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
                (error ?: observed.error)?.let {
                    FieldBanner(stringResource(errorLabel(it)),FieldTone.DANGER)
                    Text(stringResource(R.string.teams_retry_notice))
                }
            }
            LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                if(team==null) {
                    if(data.teams.isEmpty())item { FieldBanner(stringResource(R.string.teams_empty)) }
                    items(data.teams,key={it.id}) { item ->
                        OutlinedCard(onClick={selected=item.id},enabled=!busy,modifier=Modifier.fillMaxWidth(),
                            colors=CardDefaults.outlinedCardColors(containerColor=MaterialTheme.colorScheme.surface)) {
                            Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
                                Text(item.name,style=MaterialTheme.typography.titleLarge)
                                StatusBadge(stringResource(if(item.active)R.string.h_active else R.string.h_inactive),
                                    if(item.active)FieldTone.SUCCESS else FieldTone.NEUTRAL)
                            }
                        }
                    }
                } else {
                    item {
                        Text(team.name,style=MaterialTheme.typography.titleLarge)
                        StatusBadge(stringResource(if(team.active)R.string.h_active else R.string.h_inactive),if(team.active)FieldTone.SUCCESS else FieldTone.NEUTRAL)
                        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
                            TextButton(onClick={editor=TeamEditor(team.id,false,team.name)},enabled=editable) { Text(stringResource(R.string.teams_rename)) }
                            TextButton(onClick={submit(TeamChange(team.id,TeamOperation.ACTIVE,active=!team.active))},
                                enabled=editable && (team.active || members.any { it.active })) {
                                Text(stringResource(if(team.active)R.string.h_deactivate else R.string.h_reactivate))
                            }
                            TextButton(onClick={picking=true},enabled=editable) { Text(stringResource(R.string.teams_add_member)) }
                        }
                        SectionHeading(stringResource(R.string.teams_members))
                        FieldBanner(stringResource(R.string.teams_last_member))
                    }
                    items(members,key={it.userId}) { member ->
                        OperationalCard {
                            Text(personLabel(member.displayName,member.userId),style=MaterialTheme.typography.titleMedium)
                            StatusBadge(stringResource(if(member.active)R.string.h_active else R.string.h_inactive),if(member.active)FieldTone.SUCCESS else FieldTone.NEUTRAL)
                            if(member.active)TextButton(onClick={submit(TeamChange(team.id,TeamOperation.REMOVE,member=member.userId))},
                                enabled=editable && members.count { it.active }>1) { Text(stringResource(R.string.teams_remove_member)) }
                        }
                    }
                }
            }
        }
        }
    }
    editor?.let { draft ->
        AlertDialog(onDismissRequest={if(!busy)editor=null},title={Text(stringResource(if(draft.creating)R.string.teams_new else R.string.teams_rename))},
            text={Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(draft.name,{editor=draft.copy(name=it.take(120))},enabled=editable,
                    label={Text(stringResource(R.string.teams_name))},singleLine=true,modifier=Modifier.fillMaxWidth())
                if(draft.creating) {
                    SectionHeading(stringResource(R.string.teams_members))
                    if(data.people.isEmpty())Text(stringResource(R.string.teams_no_candidates))
                    LazyColumn(Modifier.heightIn(max=260.dp)) {
                        items(data.people,key={it.id}) { person ->
                            Row(Modifier.fillMaxWidth().heightIn(min=48.dp),verticalAlignment=Alignment.CenterVertically) {
                                Checkbox(person.id in draft.members,{checked ->
                                    editor=draft.copy(members=if(checked)draft.members+person.id else draft.members-person.id)
                                },enabled=editable)
                                Text(personLabel(person.displayName,person.id),modifier=Modifier.weight(1f))
                            }
                        }
                    }
                }
                error?.let { FieldBanner(stringResource(errorLabel(it)),FieldTone.DANGER);Text(stringResource(R.string.teams_retry_notice)) }
            }},
            confirmButton={TextButton(onClick={submit(TeamChange(draft.id,if(draft.creating)TeamOperation.CREATE else TeamOperation.RENAME,
                name=draft.name.trim(),initialMembers=draft.members.sorted()))},
                enabled=!busy && draft.name.isNotBlank() && (!draft.creating || draft.members.isNotEmpty())) {
                Text(stringResource(if(pending==null)R.string.h_save else R.string.photo_retry))
            }},
            dismissButton={TextButton(onClick={editor=null},enabled=!busy) { Text(stringResource(R.string.h_cancel)) }})
    }
    if(picking && team!=null)AlertDialog(onDismissRequest={if(!busy)picking=false},
        title={Text(stringResource(R.string.teams_add_member))},
        text={LazyColumn(Modifier.heightIn(max=320.dp)) {
            val candidates=data.people.filter { person -> members.none { it.userId==person.id && it.active } }
            if(candidates.isEmpty())item { Text(stringResource(R.string.teams_no_candidates)) }
            items(candidates,key={it.id}) { person ->
                SecondaryAction(onClick={submit(TeamChange(team.id,TeamOperation.ADD,member=person.id))},enabled=editable,modifier=Modifier.fillMaxWidth()) {
                    Text(personLabel(person.displayName,person.id))
                }
            }
            if(error!=null)item {
                Text(stringResource(errorLabel(error!!)))
                TextButton(onClick={pending?.let(::submit)},enabled=!busy) { Text(stringResource(R.string.photo_retry)) }
            }
        }},confirmButton={TextButton(onClick={picking=false},enabled=!busy) { Text(stringResource(R.string.h_cancel)) }})
}

@Composable private fun personLabel(name: String?, id: String) =
    (name?.takeIf { it.isNotBlank() } ?: stringResource(R.string.teams_member_unknown))+" · "+id.take(8)
