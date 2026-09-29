package si.gasilko.app.feature.plans

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.*
import io.ktor.client.statement.bodyAsText
import io.ktor.http.*
import kotlinx.serialization.json.*
import si.gasilko.app.BuildConfig
import si.gasilko.app.feature.hydrants.domain.*

/** Only the authenticated application Edge endpoint is reachable here. Provider credentials stay on the server. */
internal object PlanRoutingRemote {
    private val http by lazy {
        HttpClient(OkHttp) {
            followRedirects=false
            install(HttpTimeout) { requestTimeoutMillis=115_000;connectTimeoutMillis=15_000;socketTimeoutMillis=115_000 }
        }
    }
    suspend fun calculate(client: SupabaseClient, arguments: JsonObject): JsonElement {
        val token=client.auth.currentSessionOrNull()?.accessToken ?: throw RegistryFailure(RegistryError.EXPIRED)
        val response=http.post(BuildConfig.SUPABASE_URL.trimEnd('/')+"/functions/v1/plan-routes") {
            header(HttpHeaders.Authorization,"Bearer "+token)
            header("apikey",BuildConfig.SUPABASE_PUBLISHABLE_KEY)
            contentType(ContentType.Application.Json)
            setBody(arguments.toString())
        }
        val body=response.bodyAsText()
        val value=runCatching { Json.parseToJsonElement(body) }.getOrNull()
        if(response.status.value !in 200..299) {
            val code=(value as? JsonObject)?.get("error")?.jsonPrimitive?.contentOrNull
            val error=when {
                response.status.value==401 -> RegistryError.EXPIRED
                response.status.value==403 -> RegistryError.FORBIDDEN
                code=="CONFLICT" -> RegistryError.CONFLICT
                code=="VALIDATION" -> RegistryError.VALIDATION
                code=="ROUTE_ASSIGNMENTS_REQUIRED" -> RegistryError.ROUTE_ASSIGNMENTS
                code=="ROUTE_COORDINATES_REQUIRED" -> RegistryError.ROUTE_COORDINATES
                code=="ROUTE_UNREACHABLE" -> RegistryError.ROUTE_UNREACHABLE
                code=="ROUTE_PROVIDER_LIMIT" -> RegistryError.ROUTE_LIMIT
                code=="ROUTE_NOT_CONFIGURED" -> RegistryError.ROUTE_CONFIGURATION
                else -> RegistryError.ROUTE_PROVIDER
            }
            throw RegistryFailure(error)
        }
        return value ?: throw RegistryFailure(RegistryError.SERVER)
    }
}
