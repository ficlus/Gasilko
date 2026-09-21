package si.gasilko.app.feature.hydrants.data

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.postgrest.exception.PostgrestRestException
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*
import si.gasilko.app.feature.hydrants.domain.*
import java.io.IOException

interface RegistryTransport {
    fun actor(): String
    suspend fun rows(table: String, filters: Map<String,String?>, after: String? = null): JsonArray
    suspend fun rpc(name: String, arguments: JsonObject): JsonElement
}
class SupabaseRegistryTransport(private val client: SupabaseClient): RegistryTransport {
    override fun actor() = client.auth.currentUserOrNull()?.id ?: throw RegistryFailure(RegistryError.EXPIRED)
    override suspend fun rows(table: String, filters: Map<String,String?>, after: String?) = client.from(table).select {
        filter { filters.forEach { (key,value) -> if(value == null) exact(key,null) else eq(key,value) }; if(after != null) gt(if(table == "user_organizations") "organization_id" else "id",after) }
        // Membership rows have a composite key, but own memberships are ordered by organization_id.
        order(if(table == "user_organizations") "organization_id" else "id",Order.ASCENDING)
        limit(100)
    }.decodeAs<JsonArray>()
    override suspend fun rpc(name: String, arguments: JsonObject) = client.postgrest.rpc(name,arguments).decodeAs<JsonElement>()
}
fun registryError(code: String?, message: String?, http: Int? = null): RegistryError = when {
    http == 401 || code in listOf("PGRST301","PGRST303") -> RegistryError.EXPIRED
    code == "P0001" && message == "HYDRANT_VERSION_CONFLICT" -> RegistryError.CONFLICT
    code == "42501" || http == 403 -> RegistryError.FORBIDDEN
    code?.startsWith("22") == true || code?.startsWith("23") == true -> RegistryError.VALIDATION
    else -> RegistryError.SERVER
}
fun HydrantFields.payload(creation: Boolean) = buildJsonObject {
    if(!creation) put("hydrant_type_id",type)
    put("latitude",latitude); put("longitude",longitude); put("address",address)
    put("location_description",description); put("notes",notes); put("inspection_interval_months",interval)
    if(creation) put("status",status.name) // Editing status always uses its dedicated RPC.
}
private fun JsonElement.text(key: String) = jsonObject[key]?.jsonPrimitive?.contentOrNull
fun decodeHydrant(value: JsonElement): Hydrant {
    val row = if(value is JsonArray) value.single() else value
    return Hydrant(row.text("id")!!,row.text("organization_id")!!,row.text("code"),row.text("hydrant_type_id")!!,
        HydrantStatus.valueOf(row.text("status")!!),row.text("latitude")?.toDouble(),row.text("longitude")?.toDouble(),
        row.text("address"),row.text("location_description"),row.text("notes"),row.text("inspection_interval_months")?.toInt(),
        row.text("active").toBoolean(),row.text("version")!!.toLong(),row.text("created_by").orEmpty())
}
class OnlineHydrantRepository(private val wire: RegistryTransport, private val diagnostic: (String,RegistryError)->Unit = {_,_->}): HydrantRepository {
    private suspend fun <T> request(operation: String, block: suspend ()->T): T = try { block() }
    catch(e: CancellationException) { throw e }
    catch(e: Exception) {
        val reason = when(e) {
            is RegistryFailure -> e.reason
            is PostgrestRestException -> registryError(e.code,e.error,e.statusCode)
            is RestException -> registryError(null,e.error,e.statusCode)
            is IOException -> RegistryError.NETWORK
            is io.ktor.client.plugins.HttpRequestTimeoutException -> RegistryError.NETWORK
            else -> RegistryError.SERVER
        }
        diagnostic(operation,reason) // Bounded operation/category only; never log provider exceptions.
        throw RegistryFailure(reason)
    }
    private suspend fun all(table: String, filters: Map<String,String?>): List<JsonElement> {
        val rows=mutableListOf<JsonElement>(); var after: String?=null
        do { val page=wire.rows(table,filters,after); rows.addAll(page); after=page.lastOrNull()?.text("id")
        } while(page.size==100)
        return rows
    }
    override suspend fun organizations() = request("organizations") {
        val actor=wire.actor()
        // A user may have >100 memberships: explicit organization cursor, no roster enumeration.
        val memberships=mutableListOf<JsonElement>(); var cursor: String?=null
        do { val page=wire.rows("user_organizations",mapOf("user_id" to actor),cursor)
            memberships.addAll(page); cursor=page.lastOrNull()?.text("organization_id")
        } while(page.size==100)
        val roles=memberships.associate { it.text("organization_id") to RegistryRole.valueOf(it.text("role")!!) }
        all("organizations",emptyMap()).mapNotNull { row -> roles[row.text("id")]?.let {
            RegistryOrganization(row.text("id")!!,row.text("name")!!,it,row.text("active").toBoolean())
        } }
    }
    override suspend fun types(organization: String) = request("types") {
        (all("hydrant_types",mapOf("organization_id" to null)) + all("hydrant_types",mapOf("organization_id" to organization)))
            .map { HydrantType(it.text("id")!!,it.text("organization_id"),it.text("code")!!,it.text("name")!!,it.text("active").toBoolean()) }
    }
    override suspend fun list(query: HydrantQuery, after: String?) = request("list") {
        wire.rpc("search_hydrants",buildJsonObject {
            put("organization",query.organization);put("search_text",query.search.trim());put("type_id",query.type)
            put("status_filter",query.status?.name);put("active_filter",query.active.name.lowercase())
            put("after_id",after);put("page_size",100)
        }).jsonArray.map(::decodeHydrant)
    }
    override suspend fun get(organization: String, id: String) = request("detail") {
        wire.rows("hydrants",mapOf("organization_id" to organization,"id" to id)).singleOrNull()?.let(::decodeHydrant)
            ?: throw RegistryFailure(RegistryError.UNAVAILABLE)
    }
    override suspend fun create(organization: String, id: String, fields: HydrantFields): Hydrant = request("create") {
        val actor=wire.actor()
        // Before retrying the same client UUID, reconcile only an own, readable creation.
        val prior=wire.rows("hydrants",mapOf("organization_id" to organization,"id" to id)).singleOrNull()?.let(::decodeHydrant)
        if(prior != null) {
            if(prior.createdBy != actor) throw RegistryFailure(RegistryError.FORBIDDEN)
            prior
        } else decodeHydrant(wire.rpc("create_hydrant",buildJsonObject {
            put("organization",organization);put("hydrant_id",id);put("hydrant_type",fields.type);put("fields",fields.payload(true))
        }))
    }
    private fun args(organization: String,id: String,version: Long,extra: JsonObject) = buildJsonObject {
        put("organization",organization);put("hydrant_id",id);put("expected_version",version);extra.forEach { (k,v)->put(k,v) }
    }
    override suspend fun changeStatus(organization: String,id: String,status: HydrantStatus,version: Long) = request("status") {
        decodeHydrant(wire.rpc("change_hydrant_status",args(organization,id,version,buildJsonObject { put("new_status",status.name) })))
    }
    override suspend fun update(organization: String,id: String,fields: HydrantFields,version: Long) = request("update") {
        decodeHydrant(wire.rpc("update_hydrant",args(organization,id,version,buildJsonObject { put("changes",fields.payload(false)) })))
    }
    override suspend fun setActive(organization: String,id: String,active: Boolean,version: Long) = request("active") {
        decodeHydrant(wire.rpc("set_hydrant_active",args(organization,id,version,buildJsonObject { put("is_active",active) })))
    }
}
