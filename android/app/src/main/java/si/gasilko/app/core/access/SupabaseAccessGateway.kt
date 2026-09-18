package si.gasilko.app.core.access
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.json.*
class SupabaseAccessGateway(private val client:SupabaseClient):AccessGateway {
    private fun JsonElement.value(key:String)=jsonObject[key]?.jsonPrimitive?.content.orEmpty()
    override suspend fun countries()=client.from("countries").select(Columns.list("id","name")){filter{eq("active",true)};order("id",Order.ASCENDING);limit(250)}.decodeAs<JsonArray>().map{Choice(it.value("id"),it.value("name"))}
    override suspend fun areas(country:String,parent:String?,after:String?)=client.from("administrative_areas").select(Columns.list("id","name")){
        filter{eq("country_id",country);eq("active",true);if(parent==null)exact("parent_id",null)else eq("parent_id",parent);if(after!=null)gt("id",after)};order("id",Order.ASCENDING);limit(50)
    }.decodeAs<JsonArray>().map{Choice(it.value("id"),it.value("name"))}
    override suspend fun organizations(country:String,area:String?,after:String?)=client.postgrest.rpc("discover_organizations",buildJsonObject{put("country",country);put("area",area);put("after_id",after)}).decodeAs<JsonArray>().map{Organization(it.value("id"),it.value("name"),it.value("code"))}
    override suspend fun history(last:AccessRequest?)=client.postgrest.rpc("list_my_access_requests",buildJsonObject{put("before_time",last?.requestedAt);put("before_id",last?.id)}).decodeAs<JsonArray>().map{AccessRequest(it.value("id"),it.value("organization_name"),it.value("requested_role"),it.value("status"),it.value("requested_at"))}
    override suspend fun submit(organization:String,role:String)=client.postgrest.rpc("request_organization_access",buildJsonObject{put("organization",organization);put("desired_role",role)}).decodeAs<JsonObject>()["result"]?.jsonPrimitive?.content?:"ERROR"
}
