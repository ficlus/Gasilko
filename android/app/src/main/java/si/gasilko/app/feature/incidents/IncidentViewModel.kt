package si.gasilko.app.feature.incidents

import androidx.lifecycle.ViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import si.gasilko.app.core.notifications.NotificationTap
import kotlinx.serialization.json.JsonObject

class IncidentViewModel(val repository: IncidentRepository,val organization: String,private val scope: CoroutineScope): ViewModel() {
    val syncFailure=repository.syncFailure
    val state=repository.observe(organization).stateIn(scope,SharingStarted.WhileSubscribed(5_000),IncidentFieldState())
    private val working=MutableStateFlow(false)
    val busy=working.asStateFlow()
    private val commandFailure=MutableStateFlow<String?>(null)
    val commandError=commandFailure.asStateFlow()
    private val failed=MutableStateFlow(false)
    val error=failed.asStateFlow()
    private val offline=MutableStateFlow(false)
    val stale=offline.asStateFlow()
    private val definitions=MutableStateFlow<List<JsonObject>>(emptyList())
    val catalog=definitions.asStateFlow()
    /** Called only inside repeatOnLifecycle(STARTED). Conflation retains a trailing hint. */
    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun foreground() {
        merge(flow { while(true) { emit(Unit);delay(30_000) } },NotificationTap.hints.map { Unit },
            UnsupportedIncidentRealtime.hints(repository.account,organization))
            .conflate().collect {
                try { repository.refresh(organization);offline.value=false }
                catch(e: CancellationException) { throw e }
                catch(_: Exception) { offline.value=true }
            }
    }
    private fun action(block: suspend ()->Unit) {
        if(working.value)return
        working.value=true;failed.value=false;commandFailure.value=null
        scope.launch {
            try { block() } catch(e: CancellationException) { throw e }
            catch(e: Exception) { failed.value=true;commandFailure.value=leaderError(e.message) }
            finally { working.value=false }
        }
    }
    fun sync() { repository.syncNow(organization);NotificationTap.hint() }
    fun transition(incident: String,assignment: String,status: String,reason: String)=action {
        repository.transition(organization,incident,assignment,status,reason)
    }
    fun returnUnit(incident: String,unit: String,operation: String)=action {
        if(!repository.returnUnit(organization,incident,unit,operation))failed.value=true
    }
    fun loadCatalog()=action { definitions.value=repository.catalog(organization) }
    fun issue(incident: String,operation: String,payload: JsonObject,done: ()->Unit)=action {
        if(repository.issue(organization,incident,operation,payload))done() else failed.value=true
    }

    fun prepareLeader(incident: String,unit: String,rpc: String,operation: String,payload: JsonObject,candidateQuery: String="",done: (String)->Unit)=action {
        done(repository.prepareLeader(organization,incident,unit,rpc,operation,payload,candidateQuery))
    }
    fun confirmLeader(incident: String,unit: String,operation: String,done: ()->Unit={})=action {
        val result=repository.confirmLeader(organization,incident,unit,operation)
        if(result.operation.state=="SERVER_CONFIRMED")done()
        else { failed.value=true;commandFailure.value=result.error ?: result.operation.state }
    }
    fun searchCrew(incident: String,unit: String,query: String,done: (List<JsonObject>)->Unit)=action {
        done(repository.crewCandidates(organization,incident,unit,query))
    }
}
