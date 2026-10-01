package si.gasilko.app.feature.hydrants.presentation

import si.gasilko.app.feature.map.navigation.*

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.inspections.domain.*
import si.gasilko.app.feature.inspections.presentation.*
import si.gasilko.app.feature.photos.domain.*
import si.gasilko.app.feature.photos.presentation.PhotoGalleryState
import si.gasilko.app.feature.teams.*
import si.gasilko.app.feature.plans.*
import java.util.UUID
import java.time.Instant

data class MapHydrantsState(val rows: List<Hydrant> = emptyList(), val loading: Boolean = false, val error: RegistryError? = null)
data class InspectionHistoryState(val entries: List<InspectionHistoryEntry> = emptyList(), val error: RegistryError? = null, val loaded: Boolean = false) {
    val rows get() = entries.map { it.inspection }
}

data class RegistryState(
    val organizations: List<RegistryOrganization> = emptyList(), val organization: RegistryOrganization? = null,
    val rows: List<Hydrant> = emptyList(), val types: List<HydrantType> = emptyList(), val selected: Hydrant? = null,
    val form: HydrantForm? = null, val reviewDraft: HydrantForm? = null,
    val loading: Boolean = false, val mutating: Boolean = false,
    val query: HydrantQuery = HydrantQuery(), val filterDraft: HydrantQuery = HydrantQuery(),
    val more: Boolean = false, val error: RegistryError? = null, val conflict: Boolean = false,
    val confirmDeactivate: Boolean = false, val reloadId: String? = null,
    val inspectionDraft: InspectionDraft? = null, val inspectionSaved: Boolean = false,
    val showHistory: Boolean = false, val historyRefreshing: Boolean = false, val historyError: RegistryError? = null,
    val planStop: PlanItem? = null, val executionPlanId: String? = null,
) { val manages get() = organization?.role?.manages == true; val writable get() = organization?.active == true }

class HydrantViewModel(private val repository: HydrantRepository, private val injectedScope: CoroutineScope? = null): ViewModel() {
    private val scope get() = injectedScope ?: viewModelScope
    private val mutableState = MutableStateFlow(RegistryState())
    val state = mutableState.asStateFlow()
    internal val navigation by lazy { NavigationSession(scope) { input -> teamAccess(input.organization) { repository.navigatePlan(input) } } }
    private suspend fun <T> teamAccess(org: String, action: suspend ()->T): T {
        val stamp=generation
        if(state.value.organization?.id!=org)throw CancellationException()
        try {
            val result=action()
            if(stamp!=generation || state.value.organization?.id!=org)throw CancellationException()
            return result
        } catch(e: RegistryFailure) {
            if(stamp==generation && e.reason in listOf(RegistryError.EXPIRED,RegistryError.FORBIDDEN)) {
                clear();mutableState.value=RegistryState(error=e.reason)
            }
            throw e
        }
    }
    fun teamData(org: String): Flow<TeamViewData> {
        val stamp=generation
        return repository.observeTeamData(org).map {
            if(stamp!=generation || state.value.organization?.id!=org)throw CancellationException()
            TeamViewData(it)
        }.catch { e ->
            if(e is CancellationException)throw e
            val reason=(e as? RegistryFailure)?.reason ?: RegistryError.SERVER
            if(stamp==generation && reason in listOf(RegistryError.EXPIRED,RegistryError.FORBIDDEN)) {
                clear();mutableState.value=RegistryState(error=reason)
            }
            emit(TeamViewData(error=reason))
        }
    }
    fun planData(query: HydrantQuery): Flow<PlanViewData> {
        val stamp=generation
        return combine(repository.observePlans(query.organization),repository.observeTeamData(query.organization),
            repository.observePlanCandidates(query)) { data,teams,candidates ->
            if(stamp!=generation || state.value.organization?.id!=query.organization)throw CancellationException()
            PlanViewData(data,teams,candidates)
        }.catch { e ->
            if(e is CancellationException)throw e
            val reason=(e as? RegistryFailure)?.reason ?: RegistryError.SERVER
            if(stamp==generation && reason in listOf(RegistryError.EXPIRED,RegistryError.FORBIDDEN)) {
                clear();mutableState.value=RegistryState(error=reason)
            }
            emit(PlanViewData(error=reason))
        }
    }
    suspend fun refreshPlans(org: String) = teamAccess(org) { repository.refreshTeams(org);repository.refreshPlans(org) }
    suspend fun refreshPlanCandidates(org: String) = teamAccess(org) { repository.refreshPlanCandidates(org) }
    suspend fun activatePlan(org: String,change: PlanAssignment) = teamAccess(org) { repository.activatePlan(org,change) }
    suspend fun skipPlanItem(org: String,change: PlanSkip) = teamAccess(org) { repository.skipPlanItem(org,change) }
    suspend fun reassignPlanItem(org: String,change: PlanReassign) = teamAccess(org) { repository.reassignPlanItem(org,change) }
    internal fun startNavigation(org: String,plan: String,team: String,version: Long,key: String) {
        if(state.value.organization?.id!=org || !state.value.writable)return
        mutableState.value=state.value.copy(executionPlanId=plan)
        navigation.start(org,plan,team,version,key)
    }
    fun leaveExecution() { navigation.stop();mutableState.value=state.value.copy(executionPlanId=null) }
    suspend fun openPlanStop(org: String,plan: String,item: String) {
        val (row,hydrant)=teamAccess(org) {
            val row=repository.planStop(org,plan,item)
            row to repository.get(org,row.hydrantId)
        }
        mutableState.value=state.value.copy(selected=hydrant,planStop=row,executionPlanId=plan,inspectionSaved=false,error=null)
    }
    suspend fun routePlan(org: String, change: PlanRouting) = teamAccess(org) { repository.routePlan(org,change) }
    suspend fun assignPlan(org: String, change: PlanAssignment) = teamAccess(org) { repository.assignPlan(org,change) }
    suspend fun savePlan(org: String, change: PlanSave) = teamAccess(org) { repository.savePlan(org,change) }
    suspend fun refreshTeams(org: String) = teamAccess(org) { repository.refreshTeams(org) }
    suspend fun manageTeam(org: String, change: TeamChange) = teamAccess(org) { repository.changeTeam(org,change) }
    val photoScope get() = generation
    private fun photoScopeCurrent(org: String, hydrant: String, stamp: Int, requireSelection: Boolean = true) =
        stamp==generation && state.value.organization?.id==org && (!requireSelection || state.value.selected?.id==hydrant)
    fun photoEntries(org: String, hydrant: String): Flow<PhotoGalleryState> = photoEntries(org,hydrant,true)
    fun permanentPhotoEntries(org: String, hydrant: String): Flow<PhotoGalleryState> =
        photoEntries(org,hydrant,false).map { state -> state.copy(entries=state.entries.filter { it.photo.category==PhotoCategory.HYDRANT }) }
    private fun photoEntries(org: String, hydrant: String, requireSelection: Boolean): Flow<PhotoGalleryState> {
        val stamp=generation
        return repository.observePhotos(org,hydrant).map {
            if(!photoScopeCurrent(org,hydrant,stamp,requireSelection))throw CancellationException()
            PhotoGalleryState(it.filter { entry -> entry.photo.active }
                .sortedWith(compareByDescending<PhotoEntry> { entry -> entry.photo.capturedAt }.thenByDescending { entry -> entry.photo.id }),loaded=true)
        }.catch { e ->
            if(e is CancellationException)throw e
            val error=(e as? RegistryFailure)?.reason ?: RegistryError.SERVER
            if(photoScopeCurrent(org,hydrant,stamp,requireSelection) && error in listOf(RegistryError.EXPIRED,RegistryError.FORBIDDEN)) {
                clear();mutableState.value=RegistryState(error=error)
            }
            emit(PhotoGalleryState(error=error))
        }
    }
    private suspend fun <T> photoRead(org: String, hydrant: String, requireSelection: Boolean = true, action: suspend ()->T): T {
        val stamp=generation
        if(!photoScopeCurrent(org,hydrant,stamp,requireSelection))throw CancellationException()
        try {
            val result=action()
            if(!photoScopeCurrent(org,hydrant,stamp,requireSelection))throw CancellationException()
            return result
        } catch(e: RegistryFailure) {
            if(photoScopeCurrent(org,hydrant,stamp,requireSelection) && e.reason in listOf(RegistryError.EXPIRED,RegistryError.FORBIDDEN)) {
                clear();mutableState.value=RegistryState(error=e.reason)
            }
            throw e
        }
    }
    suspend fun photoImage(org: String, hydrant: String, id: String, inspectionId: String? = null) =
        photoRead(org,hydrant) { repository.displayPhoto(org,hydrant,id,inspectionId) }
    suspend fun refreshPhotoMetadata(org: String, hydrant: String) =
        photoRead(org,hydrant) { repository.refreshPhotos(org,hydrant) }
    // Read-only map/identification previews still pass through repository account, organization,
    // hydrant and permanent-category checks; acquisition retains its selected-hydrant gate.
    suspend fun permanentPhotoImage(org: String, hydrant: String, id: String) =
        photoRead(org,hydrant,false) { repository.displayPhoto(org,hydrant,id,null) }
    suspend fun refreshPermanentPhotos(org: String, hydrant: String) =
        photoRead(org,hydrant,false) { repository.refreshPhotos(org,hydrant) }
    val photos: si.gasilko.app.feature.photos.presentation.PhotoAcquisition by lazy { si.gasilko.app.feature.photos.presentation.PhotoAcquisition(repository,scope,
        { org,id,stamp -> val s=state.value
            stamp==generation && s.organization?.id==org && s.selected?.id==id && s.writable && (s.selected?.active==true || s.manages)
        }, { error -> clear();mutableState.value=RegistryState(error=error) },
        { org,id,stamp,input ->
            val s=state.value;val draft=s.inspectionDraft
            if(!photoScopeCurrent(org,id,stamp) || draft==null || draft.id!=input.inspectionId ||
                draft.completion!=null || s.mutating)
                throw RegistryFailure(RegistryError.FORBIDDEN)
            mutableState.value=s.copy(inspectionDraft=draft.copy(photos=(draft.photos+input).distinctBy { it.id }))
        }) }
    fun addInspectionPhoto(context: android.content.Context) {
        val s=state.value;val draft=s.inspectionDraft ?: return
        if(!s.loading && !s.mutating && s.writable && draft.completion==null)
            photos.begin(context,draft.organization,draft.hydrantId,generation,draft.id)
    }
    private fun discardStaged(draft: InspectionDraft, inputs: List<LocalPhotoInput> = draft.photos) {
        scope.launch(start=CoroutineStart.UNDISPATCHED) {
            withContext(NonCancellable) {
                inputs.forEach {
                    try { repository.discardUnregisteredPhoto(draft.organization,draft.hydrantId,it) }
                    catch(_: Exception) { android.util.Log.w("PhotoCapture","staged ownership cleanup deferred") }
                }
            }
        }
    }
    fun removeInspectionPhoto(id: String) {
        val s=state.value;val draft=s.inspectionDraft ?: return
        if(s.mutating || photos.state.value.busy || draft.completion!=null)return
        val input=draft.photos.find { it.id==id } ?: return
        mutableState.value=s.copy(inspectionDraft=draft.copy(photos=draft.photos.filterNot { it.id==id }))
        discardStaged(draft,listOf(input))
    }
    fun addPhoto(context: android.content.Context) {
        val s=state.value;val h=s.selected ?: return;val org=s.organization ?: return
        if(!s.loading && !s.mutating && s.writable && (h.active || s.manages) && s.inspectionDraft==null)
            photos.begin(context,org.id,h.id,generation)
    }
    fun inspectionHistory(organization: String, hydrantId: String): Flow<InspectionHistoryState> =
        repository.observeInspectionHistory(organization, hydrantId).map { InspectionHistoryState(entries=it,loaded=true) }
            .catch { e ->
                if(e is CancellationException) throw e
                val error=(e as? RegistryFailure)?.reason ?: RegistryError.SERVER
                if(error in listOf(RegistryError.EXPIRED,RegistryError.FORBIDDEN)) {
                    clear();mutableState.value=RegistryState(error=error)
                }
                emit(InspectionHistoryState(error=error))
            }
    private var historyJob: Job? = null
    fun openHistory() {
        val s=state.value
        if(!s.loading && !s.mutating && s.selected!=null && s.inspectionDraft==null)
            mutableState.value=s.copy(showHistory=true,historyError=null)
    }
    fun closeHistory() {
        historyJob?.cancel()
        mutableState.value=state.value.copy(showHistory=false,historyRefreshing=false,historyError=null)
    }
    fun refreshHistory() {
        val s=state.value;val h=s.selected ?: return;val org=s.organization ?: return
        if(s.historyRefreshing || s.mutating || s.loading)return
        val stamp=generation
        mutableState.value=s.copy(historyRefreshing=true,historyError=null)
        historyJob=scope.launch {
            try {
                repository.refreshInspections(org.id,h.id)
                repository.refreshPhotos(org.id,h.id)
                if(stamp==generation && state.value.selected?.id==h.id)
                    mutableState.value=state.value.copy(historyRefreshing=false)
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                if(stamp==generation && state.value.selected?.id==h.id) {
                    val error=reason(e)
                    if(error in listOf(RegistryError.EXPIRED,RegistryError.FORBIDDEN)) {
                        clear();mutableState.value=RegistryState(error=error)
                    } else mutableState.value=state.value.copy(historyRefreshing=false,historyError=error)
                }
            }
        }
    }
    val inspectionClock: Flow<Instant> = flow { while(true) { emit(Instant.now()); delay(60_000) } }
    fun changeMeasurements(pressure: String, flow: String) {
        val s=state.value;val draft=s.inspectionDraft ?: return
        if(!s.mutating && draft.completion==null && draft.mode!=InspectionMode.QUICK)
            mutableState.value=s.copy(inspectionDraft=draft.copy(pressure=pressure,flow=flow),error=null)
    }
    fun startInspection(mode: InspectionMode) {
        val s=state.value; val h=s.selected ?: return; val org=s.organization ?: return
        if(s.loading || s.mutating || s.form!=null || s.inspectionDraft!=null || !s.writable || (!h.active && !s.manages))return
        if(s.planStop?.inspectionId!=null)return
        val stamp=generation
        mutableState.value=s.copy(loading=true,error=null)
        start {
            try {
                val item=s.planStop?.let { repository.planStop(org.id,it.planId,it.id) }
                if(stamp!=generation)return@start
                if(item?.inspectionId!=null) {
                    mutableState.value=state.value.copy(planStop=item,loading=false,error=RegistryError.EXECUTION_CHANGED)
                } else mutableState.value=state.value.copy(loading=false,planStop=item,
                    inspectionDraft=InspectionDraft(UUID.randomUUID().toString(),org.id,h.id,System.currentTimeMillis(),mode=mode,
                        planContext=item?.context()),inspectionSaved=false,error=null)
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) { if(stamp==generation) {
                val error=reason(e)
                if(error in listOf(RegistryError.EXPIRED,RegistryError.FORBIDDEN)) {
                    clear();mutableState.value=RegistryState(error=error)
                } else mutableState.value=state.value.copy(loading=false,error=error)
            } }
        }
    }
    fun changeInspection(result: InspectionResult?, notes: String) {
        val s=state.value; val draft=s.inspectionDraft ?: return
        if(!s.mutating && draft.completion==null)
            mutableState.value=s.copy(inspectionDraft=draft.copy(result=result,notes=notes),error=null)
    }
    fun cancelInspection() {
        if(!state.value.mutating && !photos.state.value.busy) {
            state.value.inspectionDraft?.let { discardStaged(it) }
            photos.clear()
            mutableState.value=state.value.copy(inspectionDraft=null,error=null)
        }
    }
    fun answerInspectionCheck(check: GuidedCheck, answer: GuidedAnswer) {
        val s=state.value;val draft=s.inspectionDraft ?: return
        if(!s.mutating && draft.completion==null && (draft.mode==InspectionMode.CLASSIC ||
                (draft.mode==InspectionMode.GUIDED && GuidedCheck.entries.getOrNull(draft.step)==check)))
            mutableState.value=s.copy(inspectionDraft=draft.copy(answers=draft.answers+(check to answer)),error=null)
    }
    fun moveGuided(forward: Boolean) {
        val s=state.value;val draft=s.inspectionDraft ?: return
        if(s.mutating || photos.state.value.busy || draft.completion!=null || draft.mode!=InspectionMode.GUIDED)return
        val answered=when { draft.step<4 -> draft.answers.containsKey(GuidedCheck.entries[draft.step]); draft.step==4 -> draft.measurementsValid(); draft.step==5 -> true; else -> draft.result!=null }
        if(forward && !answered)return
        mutableState.value=s.copy(inspectionDraft=draft.copy(step=(draft.step+if(forward)1 else -1).coerceIn(0,7)),error=null)
    }
    fun completeInspection(checkNotes: String? = null) {
        val s=state.value; val draft=s.inspectionDraft ?: return; val result=draft.result ?: return
        if(s.loading || s.mutating || photos.state.value.busy || !s.writable || s.organization?.id!=draft.organization || s.selected?.id!=draft.hydrantId)return
        if(draft.mode==InspectionMode.GUIDED && draft.step!=7)return
        if(draft.mode!=InspectionMode.QUICK && (GuidedCheck.entries.any { it !in draft.answers } || checkNotes==null))return
        if(draft.mode!=InspectionMode.QUICK && !draft.measurementsValid())return
        // Freeze the full event on first confirmation, including completion time. An
        // uncertain local outcome must retry the same immutable event, not just its UUID.
        val input=draft.completion ?: InspectionCompletion(draft.mode,result,draft.startedAt,
            maxOf(draft.startedAt,System.currentTimeMillis()),
            notes=if(draft.mode!=InspectionMode.QUICK)checkNotes else draft.notes.takeIf { it.isNotBlank() },
            pressureBar=if(draft.mode==InspectionMode.QUICK)null else parseMeasurement(draft.pressure,"999.99").value,
            flowLMin=if(draft.mode==InspectionMode.QUICK)null else parseMeasurement(draft.flow,"999999.99").value,id=draft.id,
            planContext=draft.planContext)
        val stamp=generation
        mutableState.value=s.copy(inspectionDraft=draft.copy(completion=input),mutating=true,error=null)
        start {
            try {
                val saved=repository.completeInspectionWithPhotos(draft.organization,draft.hydrantId,input,draft.photos)
                if(stamp!=generation)return@start
                mutableState.value=state.value.copy(selected=saved.hydrant,
                    planStop=state.value.planStop?.copy(inspectionId=input.id,completedBy=saved.inspection.inspectorId,
                        completedAt=Instant.ofEpochMilli(input.completedAt).toString(),executionVersion=(draft.planContext?.version ?: 0)+1,
                        skipReason=null,skippedBy=null,skippedAt=null),
                    rows=state.value.rows.map { if(it.id==saved.hydrant.id)saved.hydrant else it }.filter { s.query.matches(it) },
                    inspectionDraft=null,inspectionSaved=true,mutating=false,error=null)
                // Existing Room/sync observation updates the detail and list afterwards.
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                if(stamp==generation) {
                    val error=reason(e)
                    if(error==RegistryError.EXPIRED || error==RegistryError.FORBIDDEN) {
                        clear(); mutableState.value=RegistryState(error=error)
                    } else mutableState.value=state.value.copy(mutating=false,error=error)
                }
            }
        }
    }
    fun mapHydrants(query: HydrantQuery): Flow<MapHydrantsState> = repository.observeMap(query)
        .map { MapHydrantsState(rows = it) }
        .onStart { emit(MapHydrantsState(loading = true)) }
        .catch { e ->
            if(e is CancellationException) throw e
            emit(MapHydrantsState(error = (e as? RegistryFailure)?.reason ?: RegistryError.SERVER))
        }
    private var job: Job? = null
    private var generation = 0
    private val mutableSync = MutableStateFlow(RegistrySyncState())
    val sync = mutableSync.asStateFlow()
    init {
        scope.launch {
            state.map { Triple(it.organization?.id, it.loading || it.mutating, it.query to it.selected?.id) }
                .distinctUntilChanged().collectLatest { (organization, busy, _) ->
                    if(mutableSync.value.organization != organization) mutableSync.value = RegistrySyncState(organization.orEmpty())
                    if(organization == null || busy) return@collectLatest
                    val stamp = generation
                    try {
                        repository.observeSync(organization).collectLatest { derived ->
                            val old = state.value
                            val currentOrganization=repository.organizations().firstOrNull { it.id==organization }
                                ?: throw RegistryFailure(RegistryError.FORBIDDEN)
                            // Re-read the visible pages from Room after acknowledgements/resolutions.
                            // Drafts remain untouched; their original optimistic version is retained.
                            val rows = mutableListOf<Hydrant>()
                            var page: List<Hydrant>
                            do {
                                page = repository.list(old.query, rows.lastOrNull()?.id)
                                rows.addAll(page)
                            } while(page.size == 100 && rows.size < old.rows.size)
                            val selected = old.selected?.let { h ->
                                try { repository.get(organization, h.id) }
                                catch(e: RegistryFailure) { if(e.reason != RegistryError.UNAVAILABLE) throw e; null }
                            }
                            if(stamp == generation && state.value.organization?.id == organization &&
                                state.value.query == old.query && state.value.selected?.id == old.selected?.id &&
                                !state.value.loading && !state.value.mutating) {
                                mutableSync.value = derived
                                mutableState.value = state.value.copy(rows = rows, more = page.size == 100, selected = selected,
                                    organization = currentOrganization)
                            }
                        }
                    } catch(e: CancellationException) { throw e }
                    catch(e: Exception) {
                        if(stamp == generation) {
                            val error = reason(e)
                            if(error in listOf(RegistryError.EXPIRED, RegistryError.FORBIDDEN)) {
                                clear(); mutableState.value = RegistryState(error = error)
                            } else mutableState.value = state.value.copy(error = error)
                        }
                    }
                }
        }
    }
    fun clear() { navigation.stop();state.value.inspectionDraft?.let { discardStaged(it) }; generation++; photos.clear(); job?.cancel(); historyJob?.cancel(); repository.setActiveOrganization(null); mutableSync.value=RegistrySyncState(); mutableState.value=RegistryState() }
    fun syncNow() {
        val s = state.value; val org = s.organization ?: return
        if(!s.writable || s.loading || s.mutating || sync.value.phase == SyncPhase.SYNCING) return
        try { repository.requestSync(org.id) }
        catch(e: Exception) { mutableState.value = s.copy(error = reason(e)) }
    }
    fun resolveConflict(sequence: Long, resolution: ConflictResolution) {
        val old = state.value; val org = old.organization ?: return
        if(old.loading || old.mutating || old.form != null || !old.writable) return
        val stamp = generation
        mutableState.value = old.copy(mutating = true, error = null)
        start {
            try {
                repository.resolveConflict(org.id, sequence, resolution)
                if(stamp == generation) mutableState.value = state.value.copy(mutating = false)
                // The observer restarts when idle and reads the resolved queue/cache atomically.
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                if(stamp == generation) {
                    val error = reason(e)
                    if(error in listOf(RegistryError.EXPIRED, RegistryError.FORBIDDEN)) {
                        clear(); mutableState.value = RegistryState(error = error)
                    } else mutableState.value = state.value.copy(mutating = false, error = error)
                }
            }
        }
    }
    private fun start(block: suspend ()->Unit) { job=scope.launch { block() } }
    private fun reason(e: Exception) = (e as? RegistryFailure)?.reason ?: RegistryError.SERVER
    private suspend fun hydrate(action: suspend () -> Unit): RegistryError? = try {
        action(); null
    } catch(e: RegistryFailure) {
        if(e.reason != RegistryError.NETWORK) throw e
        e.reason // Keep cached rows usable, while displaying the existing network notice.
    }
    fun refresh() { if(state.value.inspectionDraft==null)load(refreshOnline=true) }
    private fun load(refreshOnline: Boolean) {
        if(state.value.loading || state.value.mutating) return
        val old=state.value; val stamp=generation
        mutableState.value=old.copy(loading=true,error=null)
        start {
            try {
                var refreshError=if(refreshOnline)hydrate { repository.refreshOrganizations() } else null
                val organizations=repository.organizations()
                val org=organizations.find { it.id==old.organization?.id } ?: organizations.firstOrNull()
                val same=org?.id==old.organization?.id
                val query=if(org==null)HydrantQuery() else (if(same)old.query else HydrantQuery()).copy(organization=org.id).normalized(org.role)
                if(refreshOnline && refreshError==null && org!=null)refreshError=hydrate { repository.refresh(org.id) }
                val types=org?.let { repository.types(it.id) }.orEmpty()
                val rows=org?.let { repository.list(query) }.orEmpty()
                var detail: Hydrant?=null; var unavailable: RegistryError?=null
                val detailId=old.selected?.id ?: old.reloadId ?: old.reviewDraft?.id
                if(same && detailId!=null && org!=null) try { detail=repository.get(org.id,detailId) }
                    catch(e: RegistryFailure) { if(e.reason!=RegistryError.UNAVAILABLE) throw e; unavailable=e.reason }
                if(stamp!=generation)return@start
                repository.setActiveOrganization(org?.takeIf { it.active }?.id)
                if(refreshOnline && org?.active == true)repository.requestSync(org.id)
                val keepForm=same && (old.form?.baseVersion==null || org?.role?.manages==true)
                mutableState.value=old.copy(organizations=organizations,organization=org,types=types,rows=rows,
                    selected=detail,form=old.form.takeIf { keepForm },reviewDraft=old.reviewDraft.takeIf { same },
                    query=query,filterDraft=query,loading=false,more=rows.size==100,error=unavailable?:refreshError,reloadId=null)
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) { if(stamp==generation) {
                val error=reason(e)
                if(error==RegistryError.EXPIRED || error==RegistryError.FORBIDDEN)repository.setActiveOrganization(null)
                mutableState.value=if(error==RegistryError.EXPIRED || error==RegistryError.FORBIDDEN)
                    RegistryState(error=error)
                else old.copy(loading=false,rows=emptyList(),types=emptyList(),error=error)
            } }
        }
    }
    fun switchOrganization(id: String) {
        if(state.value.mutating || state.value.form!=null || state.value.inspectionDraft!=null || state.value.loading) return
        val org=state.value.organizations.find { it.id==id } ?: return
        navigation.stop();state.value.inspectionDraft?.let { discardStaged(it) }; generation++; photos.clear(); job?.cancel();historyJob?.cancel()
        repository.setActiveOrganization(null)
        mutableState.value=RegistryState(organizations=state.value.organizations,organization=org)
        refresh()
    }
    fun changeFilters(value: HydrantQuery) { val s=state.value;val org=s.organization?:return
        if(!s.loading && !s.mutating && s.selected==null && s.form==null)mutableState.value=s.copy(filterDraft=value.copy(organization=org.id,search=value.search.take(200),active=if(s.manages)value.active else ActiveFilter.ACTIVE)) }
    fun applyFilters() { val s=state.value;if(s.loading || s.mutating || s.selected!=null || s.form!=null)return
        mutableState.value=s.copy(query=s.filterDraft.normalized(s.organization?.role?:RegistryRole.FIREFIGHTER),rows=emptyList(),more=false);load(refreshOnline=false) }
    fun clearFilters() {changeFilters(HydrantQuery());applyFilters()}
    fun loadMore() {
        val old=state.value;val org=old.organization?:return
        if(old.loading || old.mutating || !old.more)return
        mutableState.value=old.copy(loading=true);val stamp=generation
        start { try { val page=repository.list(old.query,old.rows.lastOrNull()?.id)
            if(stamp==generation)mutableState.value=old.copy(rows=(old.rows+page).distinctBy { it.id },loading=false,more=page.size==100,error=null)
        }catch(e: CancellationException){throw e}catch(e: Exception){if(stamp==generation)mutableState.value=old.copy(error=reason(e))} }
    }
    fun open(id: String) {
        val old=state.value.copy(planStop=null,executionPlanId=null);val org=old.organization?:return
        if(old.loading || old.mutating)return
        photos.clear();historyJob?.cancel()
        mutableState.value=old.copy(loading=true,error=null,inspectionSaved=false,showHistory=false,historyRefreshing=false,historyError=null);val stamp=generation
        start { try { val h=repository.get(org.id,id);if(stamp==generation)mutableState.value=old.copy(selected=h,loading=false,conflict=false,error=null,inspectionSaved=false,showHistory=false,historyRefreshing=false,historyError=null) }
        catch(e: CancellationException){throw e}catch(e: Exception){if(stamp==generation)mutableState.value=old.copy(error=reason(e))} }
    }
    fun back() { if(!state.value.mutating && !state.value.loading) {
        photos.clear();historyJob?.cancel()
        mutableState.value=state.value.copy(selected=null,planStop=null,form=null,reviewDraft=null,error=null,conflict=false,confirmDeactivate=false,reloadId=null,inspectionDraft=null,inspectionSaved=false,showHistory=false,historyRefreshing=false,historyError=null)
    } }
    fun add() { if(state.value.writable && !state.value.loading && !state.value.mutating)mutableState.value=state.value.copy(form=HydrantForm(UUID.randomUUID().toString()),reviewDraft=null,error=null,conflict=false) }
    fun addAt(latitude: Double, longitude: Double, accuracy: Float?) {
        val s=state.value
        if(!s.writable || s.loading || s.mutating || s.form!=null || s.inspectionDraft!=null ||
            !latitude.isFinite() || !longitude.isFinite() || latitude !in -90.0..90.0 || longitude !in -180.0..180.0)return
        mutableState.value=s.copy(form=HydrantForm(UUID.randomUUID().toString(),
            latitude=java.math.BigDecimal.valueOf(latitude).toPlainString(),
            longitude=java.math.BigDecimal.valueOf(longitude).toPlainString(),
            coordinateAccuracy=accuracy?.takeIf { it.isFinite() && it>=0 }),reviewDraft=null,error=null,conflict=false)
    }
    private var requestedCoordinates: Triple<String,String,String>? = null
    fun requestFormLocation() {
        requestedCoordinates=state.value.form?.let { Triple(it.id,it.latitude,it.longitude) }
    }
    fun useFormLocation(expected: HydrantForm, latitude: Double, longitude: Double, accuracy: Float?) {
        val s=state.value;val form=s.form ?: return
        if(requestedCoordinates!=Triple(form.id,form.latitude,form.longitude))return
        if(!s.writable || s.loading || s.mutating || form.baseVersion!=null || form.id!=expected.id ||
            form.latitude!=expected.latitude || form.longitude!=expected.longitude ||
            !latitude.isFinite() || !longitude.isFinite() || latitude !in -90.0..90.0 || longitude !in -180.0..180.0)return
        requestedCoordinates=null
        mutableState.value=s.copy(form=form.copy(latitude=java.math.BigDecimal.valueOf(latitude).toPlainString(),
            longitude=java.math.BigDecimal.valueOf(longitude).toPlainString(),
            coordinateAccuracy=accuracy?.takeIf { it.isFinite() && it>=0 }),error=null)
    }
    fun edit() { val s=state.value; if(s.manages && s.writable && !s.loading && !s.mutating) s.selected?.let { mutableState.value=s.copy(form=HydrantForm.from(it),error=null,conflict=false) } }
    fun changeForm(form: HydrantForm) { if(!state.value.mutating && form.id==state.value.form?.id) {
        val old=state.value.form!!
        if(form.latitude!=old.latitude || form.longitude!=old.longitude)requestedCoordinates=null
        mutableState.value=state.value.copy(form=if(form.latitude!=old.latitude || form.longitude!=old.longitude)
            form.copy(coordinateAccuracy=null) else form,error=null)
    } }
    fun cancelForm() { if(!state.value.mutating)mutableState.value=state.value.copy(form=null,error=null) }
    fun reviewDraft() { val s=state.value; val draft=s.reviewDraft?:return; val latest=s.selected?:return
        if(s.manages && !s.loading && !s.mutating)mutableState.value=s.copy(form=draft.copy(baseVersion=latest.version),reviewDraft=null) }
    fun save() {
        val s=state.value;val org=s.organization?:return;val draft=s.form?:return
        if(s.mutating || s.loading || !s.writable || (draft.baseVersion!=null && !s.manages))return
        val fields=try { draft.fields() } catch(e: RegistryFailure){mutableState.value=s.copy(error=e.reason);return}
        if(s.types.none { it.id==fields.type && it.active } && !(draft.baseVersion!=null && s.selected?.type==fields.type)) {
            mutableState.value=s.copy(error=RegistryError.TYPE);return
        }
        mutate { if(draft.baseVersion==null)repository.create(org.id,draft.id,fields) else repository.update(org.id,draft.id,fields,draft.baseVersion) }
    }
    fun status(value: HydrantStatus) { val s=state.value;val h=s.selected?:return;val org=s.organization?:return
        if(!s.writable || (!h.active && !s.manages))return
        mutate { repository.changeStatus(org.id,h.id,value,h.version) }
    }
    fun requestActive() { val s=state.value;val h=s.selected?:return
        if(!s.manages || !s.writable || s.loading || s.mutating)return
        if(h.active)mutableState.value=s.copy(confirmDeactivate=true) else setActive(true)
    }
    fun dismissDeactivate() { if(!state.value.mutating)mutableState.value=state.value.copy(confirmDeactivate=false) }
    fun confirmDeactivate() { if(state.value.confirmDeactivate)setActive(false) }
    private fun setActive(active: Boolean) { val s=state.value;val org=s.organization?:return;val h=s.selected?:return
        if(!s.manages || !s.writable)return
        mutableState.value=s.copy(confirmDeactivate=false)
        mutate { repository.setActive(org.id,h.id,active,h.version) }
    }
    private fun mutate(action: suspend ()->Hydrant) {
        val old=state.value;val org=old.organization?:return
        if(old.loading || old.mutating)return
        val stamp=generation
        mutableState.value=old.copy(mutating=true,error=null)
        start {
            try {
                val result=action()
                if(stamp!=generation)return@start
                mutableState.value=old.copy(selected=result,rows=old.rows.map { if(it.id==result.id)result else it }.filter { old.query.matches(it) },form=null,reviewDraft=null,mutating=false,conflict=false,error=null)
                // A failed refresh must never turn an acknowledged mutation into an apparent failed submit.
                load(refreshOnline=false)
            }catch(e: CancellationException){throw e}
            catch(e: Exception){
                if(stamp!=generation)return@start
                val error=reason(e)
                if(error==RegistryError.CONFLICT && old.selected!=null) {
                    try { repository.refreshDetail(org.id,old.selected.id)
                        val latest=repository.get(org.id,old.selected.id)
                        if(stamp==generation)mutableState.value=old.copy(selected=latest,
                            rows=old.rows.map { if(it.id==latest.id)latest else it }.filter { old.query.matches(it) },
                            form=null,reviewDraft=old.form,mutating=false,conflict=true,error=null)
                    }catch(c: CancellationException){throw c}catch(f: Exception){if(stamp==generation)mutableState.value=old.copy(selected=null,form=null,reviewDraft=old.form,mutating=false,conflict=true,error=reason(f),reloadId=old.selected.id)}
                } else if(error==RegistryError.FORBIDDEN || error==RegistryError.EXPIRED || error==RegistryError.UNAVAILABLE) {
                    mutableState.value=old.copy(rows=emptyList(),selected=null,form=null,reviewDraft=null,types=emptyList(),organization=null,mutating=false,error=error)
                } else mutableState.value=old.copy(mutating=false,error=error)
            }
        }
    }
}
