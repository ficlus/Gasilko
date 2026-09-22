package si.gasilko.app.core.auth

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*
import si.gasilko.app.feature.hydrants.domain.*

/** Authorization only: never authenticates a password or restores a signed-out session. */
class OfflineAuthorization(private val context: Context) {
    private val secure = KeystoreSessionManager(context)
    private fun boot() = Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)
    suspend fun clear() = secure.clearAuthorization()
    suspend fun save(account: String, organizations: List<RegistryOrganization>) {
        secure.saveAuthorization(buildJsonObject {
            put("account", account); put("last_online_verification_at", System.currentTimeMillis())
            put("elapsed", SystemClock.elapsedRealtime()); put("boot", boot())
            put("organizations", JsonArray(organizations.filter { it.active }.map { org -> buildJsonObject {
                put("id", org.id); put("name", org.name); put("role", org.role.name)
            } }))
        }.toString())
    }
    suspend fun read(account: String): Pair<List<RegistryOrganization>, Long> {
        try {
            val snapshot = Json.parseToJsonElement(secure.loadAuthorization() ?: throw AuthFailure(AuthMessage.EXPIRED)).jsonObject
            if(snapshot.getValue("account").jsonPrimitive.content != account) throw AuthFailure(AuthMessage.EXPIRED)
            val elapsed = SystemClock.elapsedRealtime() - snapshot.getValue("elapsed").jsonPrimitive.long
            val wall = System.currentTimeMillis() - snapshot.getValue("last_online_verification_at").jsonPrimitive.long
            val remaining = 30 * DAY - maxOf(elapsed, wall)
            // A reboot loses the monotonic anchor; do not trust adjustable wall time alone.
            if(boot() < 0 || snapshot.getValue("boot").jsonPrimitive.int != boot() || elapsed < 0 || wall < 0 || remaining <= 0) {
                clear(); throw AuthFailure(AuthMessage.EXPIRED)
            }
            val organizations = snapshot.getValue("organizations").jsonArray.map { it.jsonObject.let { org ->
                RegistryOrganization(org.getValue("id").jsonPrimitive.content, org.getValue("name").jsonPrimitive.content,
                    RegistryRole.valueOf(org.getValue("role").jsonPrimitive.content))
            } }
            return organizations to remaining
        } catch(e: CancellationException) { throw e }
        catch(e: AuthFailure) { throw e }
        catch(_: Exception) { throw AuthFailure(AuthMessage.EXPIRED) }
    }
    companion object { const val DAY = 86_400_000L }
}
