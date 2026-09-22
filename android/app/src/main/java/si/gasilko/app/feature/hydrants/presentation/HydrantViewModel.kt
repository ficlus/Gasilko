package si.gasilko.app.feature.hydrants.presentation

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import si.gasilko.app.feature.hydrants.domain.*
import java.util.UUID

data class RegistryState(
    val organizations: List<RegistryOrganization> = emptyList(), val organization: RegistryOrganization? = null,
    val rows: List<Hydrant> = emptyList(), val types: List<HydrantType> = emptyList(), val selected: Hydrant? = null,
    val form: HydrantForm? = null, val reviewDraft: HydrantForm? = null,
    val loading: Boolean = false, val mutating: Boolean = false,
    val query: HydrantQuery = HydrantQuery(), val filterDraft: HydrantQuery = HydrantQuery(),
    val more: Boolean = false, val error: RegistryError? = null, val conflict: Boolean = false,
    val confirmDeactivate: Boolean = false, val reloadId: String? = null,
) { val manages get() = organization?.role?.manages == true; val writable get() = organization?.active == true }

class HydrantViewModel(private val repository: HydrantRepository, private val injectedScope: CoroutineScope? = null): ViewModel() {
    private val scope get() = injectedScope ?: viewModelScope
    private val mutableState = MutableStateFlow(RegistryState())
    val state = mutableState.asStateFlow()
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
                                mutableState.value = state.value.copy(rows = rows, more = page.size == 100, selected = selected)
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
    fun clear() { generation++; job?.cancel(); repository.setActiveOrganization(null); mutableSync.value=RegistrySyncState(); mutableState.value=RegistryState() }
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
    fun refresh() = load(refreshOnline=true)
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
        if(state.value.mutating || state.value.form!=null || state.value.loading) return
        val org=state.value.organizations.find { it.id==id } ?: return
        generation++; job?.cancel()
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
        val old=state.value;val org=old.organization?:return
        if(old.loading || old.mutating)return
        mutableState.value=old.copy(loading=true,error=null);val stamp=generation
        start { try { val h=repository.get(org.id,id);if(stamp==generation)mutableState.value=old.copy(selected=h,loading=false,conflict=false,error=null) }
        catch(e: CancellationException){throw e}catch(e: Exception){if(stamp==generation)mutableState.value=old.copy(error=reason(e))} }
    }
    fun back() { if(!state.value.mutating && !state.value.loading)mutableState.value=state.value.copy(selected=null,form=null,reviewDraft=null,error=null,conflict=false,confirmDeactivate=false,reloadId=null) }
    fun add() { if(state.value.writable && !state.value.loading && !state.value.mutating)mutableState.value=state.value.copy(form=HydrantForm(UUID.randomUUID().toString()),reviewDraft=null,error=null,conflict=false) }
    fun edit() { val s=state.value; if(s.manages && s.writable && !s.loading && !s.mutating) s.selected?.let { mutableState.value=s.copy(form=HydrantForm.from(it),error=null,conflict=false) } }
    fun changeForm(form: HydrantForm) { if(!state.value.mutating && form.id==state.value.form?.id) mutableState.value=state.value.copy(form=form,error=null) }
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
