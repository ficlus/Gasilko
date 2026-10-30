package si.gasilko.app.feature.incidents

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import si.gasilko.app.R
import si.gasilko.app.core.ui.*
import si.gasilko.app.feature.hydrants.domain.HydrantQuery
import si.gasilko.app.feature.hydrants.presentation.HydrantViewModel
import si.gasilko.app.feature.hydrants.presentation.MapHydrantsState
import si.gasilko.app.feature.map.*
import kotlinx.serialization.json.*

private data class ExternalMapIntent(val feature: String,val point: si.gasilko.app.feature.map.domain.GeoPoint,
    val revision: String,val version: String)

@Composable internal fun mapKind(kind: String)=stringResource(when(kind) {
    "TASK_TARGET"->R.string.im_targets;"INCIDENT_SECTOR"->R.string.im_sectors
    "INCIDENT_MAP_OBJECT"->R.string.im_objects;"INCIDENT_LINKED_HYDRANT"->R.string.im_linked
    "ROUTE"->R.string.im_routes;"REGISTRY_HYDRANT"->R.string.im_background;else->R.string.im_center
})

@Composable private fun mapNavigationStatus(code: String)=stringResource(when(code) {
    "PLANNED"->R.string.im_nav_planned;"ACTIVE"->R.string.im_nav_active;"PAUSED"->R.string.im_nav_paused
    "ARRIVED_REPORTED"->R.string.im_nav_arrived;"STOPPED"->R.string.im_nav_stopped
    "CANCELLED"->R.string.im_nav_cancelled;"SUPERSEDED"->R.string.im_nav_superseded
    else->R.string.im_nav_unknown
})
@Composable
@OptIn(ExperimentalLayoutApi::class)
internal fun IncidentMapScreen(model: IncidentViewModel,registry: HydrantViewModel,incidentId: String,
    initialAssignment: String?,openAssignment: (String)->Unit,back: ()->Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    val stale by model.stale.collectAsStateWithLifecycle()
    val failure by model.syncFailure.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    val incident=state.incidents.find {it.text("id")==incidentId}
    BackHandler(onBack=back)
    if(state.locked || incident==null) {
        Column(Modifier.padding(16.dp)) {
            TextButton(onClick=back){Text(stringResource(R.string.h_back))}
            FieldBanner(stringResource(R.string.field_locked),FieldTone.WARNING)
        };return
    }
    val projection=remember(incident.obj("field_map"),incident["assignments"],incident.text("revision"),incident.flag("leader_reset")){fieldMapData(incident)}
    if(!projection.supported) {
        Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            TextButton(onClick=back){Text(stringResource(R.string.h_back))}
            FieldBanner(stringResource(if(incident.flag("leader_reset"))R.string.ul_scope_lost else R.string.im_backend),FieldTone.WARNING)
            TextButton(onClick=model::sync){Text(stringResource(R.string.h_sync_now))}
        };return
    }
    val query=remember(model.organization){HydrantQuery(organization=model.organization)}
    val flow=remember(registry,query){registry.mapHydrants(query)}
    val registryData by flow.collectAsStateWithLifecycle(initialValue=MapHydrantsState(loading=true))
    var layers by remember {mutableStateOf(setOf("TASK_TARGET","INCIDENT_SECTOR","INCIDENT_MAP_OBJECT","INCIDENT_LINKED_HYDRANT","ROUTE"))}
    var background by remember {mutableStateOf(false)}
    var selected by remember(initialAssignment){mutableStateOf(initialAssignment?.let {"TASK_TARGET/$it"})}
    var choices by remember {mutableStateOf<List<String>>(emptyList())}
    var choicePage by remember {mutableIntStateOf(0)}
    var browse by remember {mutableStateOf(false)}
    var showUnits by remember {mutableStateOf(false)}
    var focusKey by remember(initialAssignment) {mutableIntStateOf(if(initialAssignment==null)0 else 1)}
    var routeFocus by remember {mutableStateOf(false)}
    var external by remember {mutableStateOf<ExternalMapIntent?>(null)}
    var changedReview by remember {mutableStateOf(false)}
    var noExternal by remember {mutableStateOf(false)}
    val registryAllowed=!registryData.loading && registryData.error==null
    // Both permissions: incident link plus independently authorized local registry UUID.
    val linked=incident.obj("field_map").rows("features").filter {it.text("kind")=="INCIDENT_LINKED_HYDRANT"}
        .associate { "INCIDENT_LINKED_HYDRANT/"+it.text("id") to it.text("hydrant_id") }
    val registryFeatures=if(background && registryAllowed)registryData.rows.filter {
        HydrantMapLayers.valid(it) && it.id !in linked.values
    }.map {h->IncidentMapFeature("REGISTRY_HYDRANT/"+h.id,"REGISTRY_HYDRANT",h.code ?: h.id.take(8),
        buildJsonObject {put("type","Point");put("coordinates",buildJsonArray {add(h.longitude!!);add(h.latitude!!)})},
        version=h.version.toString(),status=h.status.name)} else emptyList()
    val features=projection.features.mapNotNull {f->
        if(f.kind!="INCIDENT_LINKED_HYDRANT")f else {
            val h=registryData.rows.find {it.id==linked[f.id]}
            if(!registryAllowed || h==null || !HydrantMapLayers.valid(h))null else f.copy(
                label=h.code ?: h.id.take(8),version=h.version.toString(),
                geometry=buildJsonObject {put("type","Point");put("coordinates",buildJsonArray {add(h.longitude!!);add(h.latitude!!)})})
        }
    }+registryFeatures
    val selectedFeature=features.find {it.id==selected}
    val assignment=incident.rows("assignments").find {it.text("id")==selectedFeature?.assignment}
    val route=projection.routes.find {it.text("assignment_id")==selectedFeature?.assignment}
    val visible=features.filter {it.kind in layers || it.kind=="REGISTRY_HYDRANT" || it.id==selected}
    val routeFeature=route?.takeIf {"ROUTE" in layers}?.let {
        IncidentMapFeature("ROUTE/"+it.text("route_id"),"ROUTE",it.text("provider"),it.obj("geometry"),version=it.text("route_revision"))
    }
    val center=runCatching {
        val g=buildJsonObject {put("type","Point");put("coordinates",buildJsonArray {
            add(incident.text("longitude").toDouble());add(incident.text("latitude").toDouble())
        })}
        if(fieldGeometry(g))IncidentMapFeature("CENTER","INCIDENT_CENTER",incident.text("reference"),g) else null
    }.getOrNull()
    val focus=if(routeFocus && routeFeature!=null)routeFeature.id else selectedFeature?.id ?: center?.id
    val scene=IncidentMapScene(visible+listOfNotNull(routeFeature,center),selected,focus,focusKey)
    LaunchedEffect(features,selected) {
        if(selected!=null && selectedFeature==null){selected=null;external=null}
        choices=choices.filter {id->visible.any {it.id==id}}
    }
    val alive=remember {booleanArrayOf(true)}
    DisposableEffect(Unit){onDispose {alive[0]=false}}
    val context=LocalContext.current
    MapScreen(onBack=back,hydrants=emptyList(),
        onOpenHydrant=null,creationEnabled=false,incidentScene=scene,
        onIncidentSelect={ids->routeFocus=false;if(ids.size==1){selected=ids.first();choices=emptyList()}else {choices=ids;choicePage=0}},
        dataLoading=registryData.loading && background,dataError=registryData.error?.takeIf {background},
        navigationContent={
            Column(Modifier.padding(horizontal=16.dp),verticalArrangement=Arrangement.spacedBy(6.dp)) {
                ScreenHeading(incident.text("reference"))
                if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(incident.text("title"))
                FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                    StatusBadge(stringResource(if(incident.text("mode")=="TRAINING")R.string.field_training else R.string.ul_real),FieldTone.WARNING)
                    StatusBadge(stringResource(if(stale || failure!=null)R.string.field_stale else R.string.im_current),FieldTone.INFO)
                }
                Text(stringResource(R.string.ul_verified,state.verifiedAt?.let {
                    java.text.DateFormat.getDateTimeInstance().format(java.util.Date(it))}.orEmpty()))
                if(state.warning)FieldBanner(stringResource(R.string.field_lease_warning),FieldTone.WARNING)
                if(stale || failure!=null)FieldBanner(stringResource(R.string.im_offline),FieldTone.WARNING)
                if(projection.limited)FieldBanner(stringResource(R.string.im_limit),FieldTone.WARNING)
                if(changedReview)FieldBanner(stringResource(R.string.im_review_changed),FieldTone.WARNING)
                if(projection.invalid)FieldBanner(stringResource(R.string.im_invalid),FieldTone.WARNING)
                Text(stringResource(R.string.im_scope),style=MaterialTheme.typography.bodySmall)
                FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                    listOf("TASK_TARGET","INCIDENT_SECTOR","INCIDENT_MAP_OBJECT","INCIDENT_LINKED_HYDRANT","ROUTE").forEach {kind->
                        FilterChip(selected=kind in layers,onClick={layers=if(kind in layers)layers-kind else layers+kind},label={Text(mapKind(kind))})
                    }
                    FilterChip(selected=background,onClick={background=!background},label={Text(stringResource(R.string.im_background))})
                }
                FlowRow {
                    TextButton(onClick={browse=true;choices=visible.filter {it.kind!="ROUTE"}.map {it.id};choicePage=0}){Text(stringResource(R.string.im_features))}
                    TextButton(onClick={showUnits=true}){Text(stringResource(R.string.im_units))}
                    TextButton(onClick=model::sync){Text(stringResource(R.string.h_sync_now))}
                    TextButton(onClick={routeFocus=false;focusKey++},enabled=focus!=null){Text(stringResource(R.string.im_focus))}
                }
                if(selectedFeature==null)Text(stringResource(R.string.im_select))
                if(initialAssignment!=null && features.none {it.assignment==initialAssignment})
                    Text(stringResource(R.string.im_missing))
            }
        },incidentDetails={
            selectedFeature?.let { f->OperationalCard {
                    Text(f.label,style=MaterialTheme.typography.titleMedium);Text(mapKind(f.kind))
                    Text(stringResource(if(f.issued)R.string.im_issued else R.string.im_reference))
                    if(f.kind=="REGISTRY_HYDRANT")registryData.rows.find { "REGISTRY_HYDRANT/"+it.id==f.id }?.let {h->Text(stringResource(si.gasilko.app.feature.hydrants.presentation.statusLabel(h.status)))}
                    if(f.version.isNotEmpty())Text(stringResource(R.string.im_version,f.version))
                    assignment?.let {a->Text(a.obj("task").text("title"));Text(stateName(a.text("status")))}
                    val destination=mapPoint(f.geometry)
                    if(destination==null)Text(stringResource(R.string.im_nonpoint))
                    if(route!=null) {
                        Text(stringResource(R.string.im_route_summary,route.text("provider"),route.text("distance_m"),route.text("duration_s")))
                        Text(stringResource(R.string.im_planning_origin));Text(route.text("calculated_at"))
                        Text(stringResource(R.string.im_route_state,mapNavigationStatus(route.text("status"))))
                        if(route.flag("stale") || stale || failure!=null)FieldBanner(stringResource(R.string.im_route_stale),FieldTone.WARNING)
                        Text(stringResource(R.string.im_no_steps))
                        RouteAttribution(route.text("provider"))
                        TextButton(onClick={routeFocus=true;focusKey++}){Text(stringResource(R.string.im_focus_route))}
                    } else Text(stringResource(R.string.im_target_only))
                    FlowRow {
                        if(f.assignment!=null)TextButton(onClick={openAssignment(f.assignment)}){Text(stringResource(R.string.im_back_task))}
                        if(destination!=null)OutlinedButton(onClick={external=ExternalMapIntent(f.id,destination,incident.text("revision"),f.version);noExternal=false;changedReview=false}){Text(stringResource(R.string.im_external))}
                        TextButton(onClick={selected=null}){Text(stringResource(R.string.im_deselect))}
                    }

            } }
        })
    val availableChoices=choices.mapNotNull {id->visible.find {it.id==id}}
    if(availableChoices.isNotEmpty() && (choices.size>1 || browse))AlertDialog(onDismissRequest={choices=emptyList();browse=false},
        title={Text(stringResource(R.string.im_features))},text={
            Column(Modifier.heightIn(max=360.dp).verticalScroll(rememberScrollState())) {
                availableChoices.drop(choicePage*30).take(30).forEach {f->
                    TextButton(onClick={selected=f.id;routeFocus=false;focusKey++;choices=emptyList();browse=false}){Text(mapKind(f.kind)+": "+f.label)}
                }
                Row {
                    TextButton(enabled=choicePage>0,onClick={choicePage--}){Text(stringResource(R.string.im_previous))}
                    TextButton(enabled=(choicePage+1)*30<availableChoices.size,onClick={choicePage++}){Text(stringResource(R.string.im_next))}
                }
            }
        },confirmButton={TextButton(onClick={choices=emptyList();browse=false}){Text(stringResource(R.string.h_back))}})
    if(showUnits)AlertDialog(onDismissRequest={showUnits=false},title={Text(stringResource(R.string.im_units))},
        text={Column(Modifier.heightIn(max=360.dp).verticalScroll(rememberScrollState())) {
            incident.rows("units").forEach {u->Text(u.text("name"));Text(leaderStatus(u.text("status")));Text(stringResource(R.string.im_no_position))}
        }},confirmButton={TextButton(onClick={showUnits=false}){Text(stringResource(R.string.h_back))}})
    external?.let { intent->val f=features.find {it.id==intent.feature};val point=f?.let {mapPoint(it.geometry)}
        val permitted=f!=null && point==intent.point && f.version==intent.version && incident.text("revision")==intent.revision
        if(!permitted)LaunchedEffect(intent,point,incident.text("revision")){external=null;changedReview=true}
        if(permitted)AlertDialog(onDismissRequest={external=null},title={Text(stringResource(R.string.im_external))},
            text={Column {Text(stringResource(R.string.im_external_warning));Text(intent.point.latitude.toString()+", "+intent.point.longitude)
                if(noExternal)Text(stringResource(R.string.im_no_external))}},
            confirmButton={TextButton(enabled=!busy,onClick={
                // Recheck the secure incident lease and exact current Room target,
                // then hand off frozen coordinates only. No persistent operation.
                f?.let { chosen->
                    model.verifyMapHandoff(incidentId,chosen.kind,chosen.id,chosen.geometry,intent.revision,intent.version) { allowed->
                        if(alive[0] && external==intent) {
                            if(allowed && !model.state.value.locked) {
                                try {
                                    val handoff=Intent(Intent.ACTION_VIEW,Uri.parse("geo:0,0?q="+intent.point.latitude+","+intent.point.longitude))
                                    context.startActivity(handoff);external=null
                                } catch(_: ActivityNotFoundException){noExternal=true}
                                catch(_: SecurityException){noExternal=true}
                            } else {external=null;changedReview=true}
                        }
                    }
                }
            }){Text(stringResource(R.string.im_open_external))}},
            dismissButton={TextButton(onClick={external=null}){Text(stringResource(R.string.h_back))}})
    }
}
