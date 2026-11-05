package si.gasilko.app.feature.incidents

import android.content.Context
import android.os.SystemClock
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import si.gasilko.app.BuildConfig
import si.gasilko.app.core.auth.KeystoreSessionManager
import si.gasilko.app.core.security.deviceproof.*
import si.gasilko.app.core.sync.HydrantSyncScheduler
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import java.util.UUID

internal class VehicleLocationFailure(val code: String): IllegalStateException(code)
internal fun newVehicleOperation()=UUID.randomUUID().toString()
internal fun ByteArray.vehicleHex()=joinToString(""){"%02x".format(it.toInt() and 255)}
internal data class VehicleFix(val vehicle: String,val deployment: String,val session: String,val label: String,val latE7: Int,val lonE7: Int,
    val accuracyCm: Int,val observed: Long,val serverNow: Long,val receivedElapsed: Long,val deadline: Long) {
    override fun toString()="VehicleFix(redacted)"
    fun age()=((serverNow-observed)+(SystemClock.elapsedRealtime()-receivedElapsed)).coerceAtLeast(0)/1000
    fun usable()=SystemClock.elapsedRealtime()<deadline && age()<900
}
internal class VehicleLocationRepository(private val context: Context,private val client: SupabaseClient,
    val account: String,val organization: String,private val authorize: suspend ()->Unit) {
    private val secure=KeystoreSessionManager(context)
    private val scheduler=HydrantSyncScheduler(context)
    private val epoch=java.util.concurrent.atomic.AtomicLong(-1)
    @Volatile private var access: LocalDeviceProofAccess?=null
    @Volatile private var incidentScope: String?=null
    private val ceremony=java.util.concurrent.atomic.AtomicLong(0)
    private val scopeGeneration=java.util.concurrent.atomic.AtomicLong(0)
    @Synchronized fun selectIncident(incident: String,fingerprint: String) {
        val next=incident+"/"+fingerprint
        if(incidentScope!=next) {
            scopeGeneration.incrementAndGet();ceremony.incrementAndGet();revokeLocal()
            VehicleLocationRuntime.active?.let {t->
                if(t.incident!=incident || (t.repository.incidentScope!=null && t.repository.incidentScope!=next))VehicleLocationRuntime.stopIfCurrent(t,"ERROR")
            }
            incidentScope=next
        }
    }
    fun cancelCeremony() {ceremony.incrementAndGet();if(VehicleLocationRuntime.active?.repository!==this)revokeLocal()}
    private fun liveDispatch(action: String,args: JsonObject) {
        if(action!="sample" && action!="renew")return
        val t=VehicleLocationRuntime.active ?: throw CancellationException()
        val id=if(action=="sample")args.obj("sample").text("sessionId") else args.text("session")
        if(t.repository!==this || !t.current() || t.session.text("session")!=id)throw CancellationException()
    }
    fun revokeLocal() { access?.revoke();access=null }
    private suspend fun guard(withdraw: Boolean=false) {
        currentCoroutineContext().ensureActive()
        if(client.auth.currentUserOrNull()?.id!=account)throw CancellationException()
        if(!withdraw) {
            if(!scheduler.selected(account,organization) || VehicleLocationRuntime.ownerScope!=account+"/"+organization)throw CancellationException()
            val generation=VehicleLocationRuntime.generation
            epoch.compareAndSet(-1,generation)
            if(epoch.get()!=generation)throw CancellationException()
            authorize()
            if(epoch.get()!=VehicleLocationRuntime.generation || client.auth.currentUserOrNull()?.id!=account || !scheduler.selected(account,organization))throw CancellationException()
        }
    }
    internal suspend fun request(action: String,incident: String,operation: String,args: JsonObject,
        org: String=organization,withdraw: Boolean=false): JsonObject {
        val originalCeremony=ceremony.get()
        val originalScope=scopeGeneration.get()
        val enrollment=action in setOf("register","issue","confirm","consent","start")
        fun sameOrigin()=originalScope==scopeGeneration.get() && (!enrollment || originalCeremony==ceremony.get())
        guard(withdraw)
        if(!withdraw && incidentScope?.substringBefore("/")!=incident)throw CancellationException()
        liveDispatch(action,args)
        val session=client.auth.currentSessionOrNull() ?: throw VehicleLocationFailure("NOT_AUTHORIZED")
        if(session.user?.id!=account)throw CancellationException()
        val token=session.accessToken
        val envelope=buildJsonObject {put("action",action);put("organization",org);put("incident",incident);put("operation",operation);put("args",args)}
        val requestStart=SystemClock.elapsedRealtime()
        val response=try {withContext(Dispatchers.IO) {
            val connection=URL(BuildConfig.SUPABASE_URL.trimEnd('/')+"/functions/v1/vehicle-location").openConnection() as HttpsURLConnection
            try {
                connection.instanceFollowRedirects=false;connection.requestMethod="POST";connection.connectTimeout=8000;connection.readTimeout=8000
                connection.setRequestProperty("X-Gasilko-Account",account)
                connection.setRequestProperty("Authorization","Bearer "+token);connection.setRequestProperty("apikey",BuildConfig.SUPABASE_PUBLISHABLE_KEY)
                connection.setRequestProperty("Content-Type","application/json");connection.setRequestProperty("Cache-Control","no-store")
                currentCoroutineContext().ensureActive()
                if(!withdraw && !sameOrigin())throw CancellationException()
                liveDispatch(action,args)
                connection.doOutput=true;connection.outputStream.use {out->
                    currentCoroutineContext().ensureActive()
                    if(!withdraw && !sameOrigin())throw CancellationException()
                    liveDispatch(action,args)
                    out.write(envelope.toString().toByteArray())
                }
                val stream=if(connection.responseCode in 200..299)connection.inputStream else connection.errorStream
                val bytes=stream?.use {input->
                    val out=java.io.ByteArrayOutputStream();val buffer=ByteArray(4096)
                    while(true){val n=input.read(buffer);if(n<0)break;if(out.size()+n>131072)throw VehicleLocationFailure("BACKEND_UNAVAILABLE");out.write(buffer,0,n)}
                    out.toByteArray()
                } ?: throw VehicleLocationFailure("BACKEND_UNAVAILABLE")
                if(bytes.size>131072)throw VehicleLocationFailure("BACKEND_UNAVAILABLE")
                parse(bytes.toString(Charsets.UTF_8))
            } finally {connection.disconnect()}
        }} catch(_: java.io.IOException){throw VehicleLocationFailure("OUTCOME_UNKNOWN")}
        guard(withdraw)
        if(!withdraw && !sameOrigin())throw CancellationException()
        if(!response.flag("ok"))throw VehicleLocationFailure(response.text("code").ifEmpty {"BACKEND_UNAVAILABLE"})
        return JsonObject(response.obj("result")+("_requestStart" to JsonPrimitive(requestStart)))
    }
    internal suspend fun flushStop()=VehicleLocationRuntime.withdrawals.withLock {flushStopLocked()}
    internal suspend fun flushStopLocked() {
        guard(true)
        var original=secure.loadVehicleStop(account)?.let(::parse)
        if(original==null) {
            val armed=journal().obj("armedStop")
            if(armed.isNotEmpty() && VehicleLocationRuntime.active?.session?.text("session")!=armed.obj("args").text("session")) {
                original=VehicleLocationRuntime.pendingFor(account) ?: armed
                secure.saveVehicleStop(account,original.toString())
            }
        }
        original ?: return
        VehicleLocationRuntime.restoreWithdrawal(original)
        request("stop",original.text("incident"),original.text("operation"),original.obj("args"),original.text("organization"),true)
        secure.clearVehicleStop(account)
        if(original.obj("args").text("reason")=="LEFT_VEHICLE")secure.clearVehicleState(account,original.text("credential")) else afterStop(original.text("credential"))
        VehicleLocationRuntime.acknowledge(account,original.text("operation"))
    }
    internal suspend fun persistWithdrawal(original: JsonObject) {
        require(original.text("account")==account && original.text("organization")==organization)
        secure.saveVehicleStop(account,original.toString())
    }
    suspend fun context(incident: String,fingerprint: String): JsonObject {
        flushStop()
        val data=request("context",incident,newVehicleOperation(),buildJsonObject {})
        if(data.text("account")!=account || data.text("organization")!=organization || data.text("incident")!=incident ||
            data.text("fieldFingerprint")!=fingerprint)throw VehicleLocationFailure("SCOPE_CHANGED")
        val vehicles=data.rows("vehicles")
        if(data["vehicles"] !is JsonArray || vehicles.size!=(data["vehicles"] as JsonArray).size || vehicles.size>100 ||
            vehicles.any {v->listOf("deployment","vehicle","authorityEpisode","unit").any {key->!canonicalUuid(v.text(key))}} ||
            vehicles.map {it.text("deployment")+"/"+it.text("vehicle")+"/"+it.text("authorityEpisode")}.distinct().size!=vehicles.size)
            throw VehicleLocationFailure("BACKEND_UNAVAILABLE")
        return data
    }
    suspend fun positions(incident: String,fingerprint: String): List<VehicleFix> {
        val data=request("positions",incident,newVehicleOperation(),buildJsonObject {})
        require(data.text("account")==account && data.text("organization")==organization && data.text("incident")==incident &&
            data.text("fieldFingerprint")==fingerprint) {"SCOPE_CHANGED"}
        val elapsed=SystemClock.elapsedRealtime()
        val trip=(elapsed-(data.text("_requestStart").toLongOrNull() ?: elapsed)).coerceAtLeast(0)
        val server=java.time.OffsetDateTime.parse(data.text("serverTime")).toInstant().toEpochMilli()+trip
        return data.rows("positions").take(100).mapNotNull {x->runCatching {
            val lat=x.text("latitudeE7").toInt();val lon=x.text("longitudeE7").toInt()
            require(lat in -900000000..900000000 && lon in -1800000000..1800000000 && x.text("source")=="ANDROID_REAL_GNSS" &&
                canonicalUuid(x.text("vehicle")) && canonicalUuid(x.text("deployment")) && canonicalUuid(x.text("session")))
            val observed=java.time.OffsetDateTime.parse(x.text("observedAt")).toInstant().toEpochMilli()
            val ttl=(java.time.OffsetDateTime.parse(x.text("validUntil")).toInstant().toEpochMilli()-server).coerceIn(0,15000)
            VehicleFix(x.text("vehicle"),x.text("deployment"),x.text("session"),x.text("label"),lat,lon,x.text("accuracyCm").toInt(),
                observed,server,elapsed,elapsed+ttl)
        }.getOrNull()}
    }
    private suspend fun journal(): JsonObject {
        guard(true)
        return secure.loadVehicleState(account)?.let(::parse) ?: buildJsonObject {}
    }
    private suspend fun save(value: JsonObject) {guard();secure.saveVehicleState(account,value.toString(),current={current()})}
    private suspend fun mutate(key: String,value: JsonElement): JsonObject =
        JsonObject(journal()+(key to value)).also {save(it)}
    internal suspend fun frozen(key: String): String {
        val current=journal().text(key)
        if(current.isNotEmpty())return current
        return newVehicleOperation().also {mutate(key,JsonPrimitive(it))}
    }
    private suspend fun keyOwner(scope: DeviceProofScope,policy: JsonObject): LocalDeviceProofKeys {
        guard()
        access?.revoke()
        val owner=LocalDeviceProofAccess(scope,policy.text("audience"),policy.text("recoveryEpoch"));access=owner
        val generation=epoch.get()
        return LocalDeviceProofKeys(owner,{access?.takeIf {generation==VehicleLocationRuntime.generation &&
            client.auth.currentUserOrNull()?.id==account && scheduler.selected(account,organization)}})
    }
    internal suspend fun keys(): Pair<LocalDeviceProofKeys,LocalDeviceCredential> {
        guard()
        val j=journal();require(j.text("account")==account && j.text("organization")==organization)
        val s=j.obj("scope");val scope=DeviceProofScope(account,organization,j.text("incident"),s.text("deployment"),s.text("vehicle"),s.text("authorityEpisode"))
        val keys=keyOwner(scope,j.obj("policy"))
        return keys to keys.openExisting(j.text("credential"),j.text("keyHash"))
    }
    suspend fun enroll(incident: String,vehicle: JsonObject,policy: JsonObject): JsonObject {
        guard()
        var j=journal()
        if(j.isNotEmpty() && (j.text("organization")!=organization || j.text("incident")!=incident ||
            j.obj("scope").text("deployment")!=vehicle.text("deployment") || j.obj("scope").text("vehicle")!=vehicle.text("vehicle") ||
            j.obj("scope").text("authorityEpisode")!=vehicle.text("authorityEpisode") || j.obj("scope").text("unit")!=vehicle.text("unit") || j.obj("policy")!=policy))throw VehicleLocationFailure("SCOPE_CHANGED")
        if(j.isEmpty()) {
            val scope=DeviceProofScope(account,organization,incident,vehicle.text("deployment"),vehicle.text("vehicle"),vehicle.text("authorityEpisode"))
            val keys=keyOwner(scope,policy);val credential=keys.createNew()
            j=buildJsonObject {put("account",account);put("organization",organization);put("incident",incident);put("scope",vehicle);put("policy",policy)
                put("credential",credential.id);put("keyHash",credential.publicKeySha256);put("spki",credential.publicSpkiDer().vehicleHex())}
            save(j) // Persist identity before dispatch; retry opens, never regenerates.
        }
        request("register",incident,frozen("registerOperation"),buildJsonObject {
            put("credential",j.text("credential"));put("deployment",vehicle.text("deployment"));put("vehicle",vehicle.text("vehicle"));put("spki",j.text("spki"))
        })
        val confirm=frozen("confirmOperation")
        val challenge=request("issue",incident,frozen("issueOperation"),buildJsonObject {put("credential",j.text("credential"));put("confirmOperation",confirm)})
        val s=challenge.obj("scope")
        val c=DeviceProofChallengeV1(challenge.text("audience"),challenge.text("recoveryEpoch"),
            DeviceProofScope(s.text("account"),s.text("organization"),s.text("incident"),s.text("deployment"),s.text("vehicle"),s.text("authorityEpisode")),
            challenge.text("credentialId"),challenge.text("publicKeySha256"),challenge.text("policyVersion"),challenge.text("policyDocumentSha256"),
            challenge.text("preciseAudienceSha256"),challenge.text("issueOperationId"),challenge.text("confirmOperationId"),challenge.text("challengeId"),
            challenge.text("nonceBase64Url"),challenge.text("issuedAtSeconds").toLong(),challenge.text("expiresAtSeconds").toLong(),
            challenge.text("expectedIncidentVersion").toLong(),challenge.text("expectedDeploymentVersion").toLong(),
            challenge.text("expectedVehicleVersion").toLong(),challenge.text("reservedGeneration").toLong())
        val (keys,credential)=keys()
        var signature=journal().text("proofSignature")
        if(signature.isEmpty()) {signature=keys.prepareProof(credential,c).rawSignature().vehicleHex();mutate("proofSignature",JsonPrimitive(signature))}
        val receipt=request("confirm",incident,confirm,buildJsonObject {put("challenge",c.challengeId);put("signature",signature)})
        mutate("binding",JsonPrimitive(receipt.text("binding")))
        return receipt
    }
    suspend fun consent(incident: String,policy: JsonObject): JsonObject {
        val j=journal()
        return request("consent",incident,frozen("consentOperation"),buildJsonObject {
            put("binding",j.text("binding"));put("policy",policy.text("id"));put("noticeHash",policy.text("noticeHash"));put("accepted",true)
        }).also {mutate("consent",JsonPrimitive(it.text("consent")))}
    }
    internal fun current()=epoch.get()==VehicleLocationRuntime.generation && client.auth.currentUserOrNull()?.id==account && scheduler.selected(account,organization)
    suspend fun start(incident: String): JsonObject {
        flushStop();val j=journal()
        if(j.text("incident")!=incident || j.text("organization")!=organization)throw VehicleLocationFailure("SCOPE_CHANGED")
        return request("start",incident,frozen("startOperation"),buildJsonObject {put("binding",j.text("binding"));put("consent",j.text("consent"))}).also {session->
            if(session.text("state")!="SHARING" || !canonicalUuid(session.text("session")) ||
                session.text("binding")!=j.text("binding") || session.text("credential")!=j.text("credential") ||
                session.text("vehicle")!=j.obj("scope").text("vehicle") || session.text("deployment")!=j.obj("scope").text("deployment") ||
                !Regex("[A-Za-z0-9_-]{43}").matches(session.text("context")))throw VehicleLocationFailure("SCOPE_CHANGED")
            val saved=journal().obj("armedStop")
            val armed=if(saved.obj("args").text("session")==session.text("session"))saved else buildJsonObject {
                put("account",account);put("organization",organization);put("incident",incident);put("credential",j.text("credential"));put("operation",newVehicleOperation())
                put("args",buildJsonObject {put("session",session.text("session"));put("reason","ERROR")})
            }
            mutate("armedStop",armed)
        }
    }
    suspend fun revokeDevice() {
        flushStop()
        val j=journal();if(j.isEmpty())return
        request("revoke",j.text("incident"),frozen("revokeOperation"),buildJsonObject {
            put("credential",j.text("credential"));put("reason","OWNER_REQUEST")
        },j.text("organization"),true)
        revokeLocal();secure.clearVehicleState(account,j.text("credential"))
    }
    internal suspend fun armedStop()=journal().obj("armedStop")
    suspend fun afterStop(expectedCredential: String) {
        val j=journal()
        if(j.text("credential")!=expectedCredential)return
        // START/consent are new explicit ceremonies after a stop; enrollment IDs stay frozen.
        guard(true);secure.saveVehicleState(account,JsonObject(j-setOf("startOperation","consentOperation","consent","armedStop")).toString(),
            current={client.auth.currentUserOrNull()?.id==account},expectedCredential=expectedCredential)
    }
}
