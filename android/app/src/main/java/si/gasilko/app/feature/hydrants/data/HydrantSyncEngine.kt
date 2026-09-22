package si.gasilko.app.feature.hydrants.data

import androidx.room.withTransaction
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.domain.*

// The app uses default, single-process WorkManager. Also serialize refreshes so a stale
// pre-upload snapshot cannot replace a newly acknowledged row. Local writes remain independent.
internal val hydrantRemoteAccess = Mutex()

/** Default WorkManager and manual callers share one process-wide upload lock. */
class HydrantSyncEngine(
    private val database: RegistryDatabase,
    private val online: HydrantRepository,
    private val account: String,
    private val checkContext: () -> Unit,
) {
    suspend fun sync(organization: String) = hydrantRemoteAccess.withLock {
        checkContext()
        val org = online.organizations().find { it.id == organization && it.active }
            ?: throw RegistryFailure(RegistryError.FORBIDDEN)
        val dao = database.registry()
        while(true) {
            currentCoroutineContext().ensureActive()
            checkContext()
            val operation = dao.nextChange(account, organization) ?: break
            // Preserve strict order. M3.4 must explicitly unblock conflicts; never skip/rebase them.
            if(operation.state != "PENDING") break
            if(operation.operation in listOf("UPDATE", "SET_ACTIVE") && !org.role.manages)
                throw RegistryFailure(RegistryError.FORBIDDEN)
            val acknowledged = dao.acknowledgedVersion(account, organization, operation.entityId, operation.sequence)
            val version = maxOf(operation.baseVersion ?: 0, acknowledged ?: 0)
            val payload = Json.parseToJsonElement(operation.payload).jsonObject
            checkContext()
            val server = try {
                when(operation.operation) {
                    "CREATE" -> online.create(organization, operation.entityId, payload.fields())
                    "UPDATE" -> online.update(organization, operation.entityId, payload.fields(), version)
                    "CHANGE_STATUS" -> online.changeStatus(organization, operation.entityId,
                        HydrantStatus.valueOf(payload.getValue("status").jsonPrimitive.content), version)
                    "SET_ACTIVE" -> online.setActive(organization, operation.entityId,
                        payload.getValue("active").jsonPrimitive.boolean, version)
                    else -> throw RegistryFailure(RegistryError.VALIDATION)
                }
            } catch(e: RegistryFailure) {
                if(e.reason != RegistryError.CONFLICT) throw e // PENDING survives failures/cancellation.
                dao.conflict(account, organization, operation.sequence)
                break
            }
            require(server.id == operation.entityId && server.organization == organization && server.version > 0)
            // Atomic acknowledgement + cache update. Later local edits can arrive during upload;
            // replay their immutable payloads over authoritative metadata instead of erasing them.
            database.withTransaction {
                check(dao.acknowledge(account, organization, operation.sequence, server.version) == 1)
                var visible = server
                dao.remainingChanges(account, organization, server.id)
                    .forEach { visible = it.applyTo(visible) }
                dao.upsertHydrants(listOf(HydrantEntity.from(account, visible)))
            }
        }
    }
}

private fun JsonObject.fields() = HydrantFields(
    getValue("hydrant_type_id").jsonPrimitive.content,
    this["latitude"]?.jsonPrimitive?.doubleOrNull, this["longitude"]?.jsonPrimitive?.doubleOrNull,
    this["address"]?.jsonPrimitive?.contentOrNull, this["location_description"]?.jsonPrimitive?.contentOrNull,
    this["notes"]?.jsonPrimitive?.contentOrNull, this["inspection_interval_months"]?.jsonPrimitive?.intOrNull,
    this["status"]?.jsonPrimitive?.contentOrNull?.let(HydrantStatus::valueOf) ?: HydrantStatus.UNKNOWN,
)

private fun PendingHydrantChange.applyTo(row: Hydrant): Hydrant {
    val p = Json.parseToJsonElement(payload).jsonObject
    return when(operation) {
        "UPDATE" -> p.fields().let { row.copy(type = it.type, latitude = it.latitude, longitude = it.longitude,
            address = it.address, description = it.description, notes = it.notes, interval = it.interval) }
        "CHANGE_STATUS" -> row.copy(status = HydrantStatus.valueOf(p.getValue("status").jsonPrimitive.content))
        "SET_ACTIVE" -> row.copy(active = p.getValue("active").jsonPrimitive.boolean)
        else -> throw RegistryFailure(RegistryError.VALIDATION)
    }
}
