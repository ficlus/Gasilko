package si.gasilko.app.core.access
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class Choice(val id:String,val name:String)
data class Organization(val id:String,val name:String,val code:String)
data class AccessRequest(val id:String,val organizationName:String,val role:String,val status:String,val requestedAt:String)
interface AccessGateway {
    suspend fun countries():List<Choice>
    suspend fun areas(country:String,parent:String?,after:String?):List<Choice>
    suspend fun organizations(country:String,area:String?,after:String?):List<Organization>
    suspend fun history(last:AccessRequest?):List<AccessRequest>
    suspend fun submit(organization:String,role:String):String
}
data class AccessState(val busy:Boolean=false,val countries:List<Choice> = emptyList(),val country:String?=null,val trail:List<Choice> = emptyList(),val areas:List<Choice> = emptyList(),val organizations:List<Organization> = emptyList(),val history:List<AccessRequest> = emptyList(),val moreAreas:Boolean=false,val moreOrganizations:Boolean=false,val moreHistory:Boolean=false,val result:String?=null)
class AccessRepository(private val gateway:AccessGateway?) {
    private val mutableState=MutableStateFlow(AccessState());val state=mutableState.asStateFlow();private val lock=Mutex()
    private suspend fun operation(block:suspend(AccessGateway)->Unit) = lock.withLock {
        val client=gateway?:return@withLock;mutableState.value=mutableState.value.copy(busy=true,result=null)
        try { block(client) } catch(e:CancellationException){throw e} catch(_:Exception){mutableState.value=mutableState.value.copy(result="ERROR")} finally {mutableState.value=mutableState.value.copy(busy=false)}
    }
    suspend fun load()=operation { g ->
        // A failed reload after an account switch must never retain another user's history.
        mutableState.value=AccessState(busy=true)
        val countries=g.countries();val history=g.history(null)
        mutableState.value=AccessState(busy=true,countries=countries,history=history,moreHistory=history.size==50)
    }
    suspend fun browse(country:String,trail:List<Choice>)=operation { g ->
        mutableState.value=mutableState.value.copy(country=country,trail=trail,areas=emptyList(),organizations=emptyList(),moreAreas=false,moreOrganizations=false)
        val areas=g.areas(country,trail.lastOrNull()?.id,null);val organizations=g.organizations(country,trail.lastOrNull()?.id,null)
        mutableState.value=mutableState.value.copy(areas=areas,organizations=organizations,moreAreas=areas.size==50,moreOrganizations=organizations.size==50)
    }
    suspend fun more(kind:String)=operation { g -> val s=mutableState.value
        when(kind){
            "history"->{val rows=g.history(s.history.lastOrNull());mutableState.value=s.copy(history=s.history+rows,moreHistory=rows.size==50)}
            "areas"->{val rows=g.areas(s.country?:return@operation,s.trail.lastOrNull()?.id,s.areas.lastOrNull()?.id);mutableState.value=s.copy(areas=s.areas+rows,moreAreas=rows.size==50)}
            "organizations"->{val rows=g.organizations(s.country?:return@operation,s.trail.lastOrNull()?.id,s.organizations.lastOrNull()?.id);mutableState.value=s.copy(organizations=s.organizations+rows,moreOrganizations=rows.size==50)}
        }
    }
    suspend fun submit(organization:String,role:String)=operation { g ->
        if(role !in listOf("FIREFIGHTER","MANAGER")){mutableState.value=mutableState.value.copy(result="INVALID_ROLE");return@operation}
        val result=g.submit(organization,role);val rows=g.history(null)
        mutableState.value=mutableState.value.copy(result=result,history=rows,moreHistory=rows.size==50)
    }
}
