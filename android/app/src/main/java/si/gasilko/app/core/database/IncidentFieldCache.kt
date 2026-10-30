package si.gasilko.app.core.database

import androidx.room.*
import kotlinx.coroutines.flow.Flow

/** Authorized read projection; per-incident protocol cursors commit in the same transaction. */
@Entity(tableName="incident_field_cache", primaryKeys=["account","organization"])
data class IncidentFieldCache(val account: String,val organization: String,val payload: String,
    val verifiedAt: Long,val elapsed: Long,val boot: Int)

/** Dispatch metadata extends the existing durable operation, never another scheduler. */
@Entity(tableName="incident_operation_dispatch")
data class IncidentDispatch(@PrimaryKey val sequence: Long,val parent: Long?,val request: String?,
    val result: String?=null,val error: String?=null)

data class FieldOperation(@Embedded val operation: PendingHydrantChange,
    val parent: Long?,val request: String?,val result: String?,val error: String?)

@Entity(tableName="incident_sync_cursor",primaryKeys=["account","organization","incident"])
data class IncidentSyncCursor(val account: String,val organization: String,val incident: String,
    val manifest: String?,val revision: Long,val ordinal: Int,val timelineSequence: Long,
    val fingerprint: String,val schemaVersion: Int,val syncedAt: Long)

@Dao
interface IncidentFieldDao {
    @Query("SELECT * FROM incident_field_cache WHERE account=:account AND organization=:org")
    fun observe(account: String,org: String): Flow<IncidentFieldCache?>
    @Query("SELECT * FROM incident_field_cache WHERE account=:account AND organization=:org")
    suspend fun snapshot(account: String,org: String): IncidentFieldCache?
    @Upsert suspend fun save(row: IncidentFieldCache)
    @Query("DELETE FROM incident_field_cache WHERE account=:account AND organization=:org")
    suspend fun revoke(account: String,org: String)
    @Query("SELECT * FROM incident_sync_cursor WHERE account=:account AND organization=:org")
    suspend fun cursors(account: String,org: String): List<IncidentSyncCursor>
    @Upsert suspend fun saveCursors(rows: List<IncidentSyncCursor>)
    @Query("DELETE FROM incident_sync_cursor WHERE account=:account AND organization=:org")
    suspend fun clearCursors(account: String,org: String)
    @Query("DELETE FROM incident_sync_cursor WHERE account=:account AND organization=:org AND incident=:incident")
    suspend fun removeCursor(account: String,org: String,incident: String)
    @Insert suspend fun dispatch(row: IncidentDispatch)
    @Query("""SELECT q.*,d.parent,d.request,d.result,d.error FROM pending_hydrant_changes q
        JOIN incident_operation_dispatch d ON d.sequence=q.sequence
        WHERE q.account=:account AND q.organization=:org AND q.operation='INCIDENT_TASK'
        ORDER BY q.sequence""")
    fun observeOperations(account: String,org: String): Flow<List<FieldOperation>>
    @Query("""SELECT q.*,d.parent,d.request,d.result,d.error FROM pending_hydrant_changes q
        JOIN incident_operation_dispatch d ON d.sequence=q.sequence
        WHERE q.account=:account AND q.organization=:org AND q.operation='INCIDENT_TASK'
        ORDER BY q.sequence""")
    suspend fun operations(account: String,org: String): List<FieldOperation>
    @Query("UPDATE incident_operation_dispatch SET request=:request WHERE sequence=:sequence AND request IS NULL")
    suspend fun prepare(sequence: Long,request: String)
    @Query("UPDATE incident_operation_dispatch SET result=:result,error=:error WHERE sequence=:sequence")
    suspend fun outcome(sequence: Long,result: String?,error: String?)
    @Query("""UPDATE pending_hydrant_changes SET state=:state WHERE account=:account AND organization=:org
        AND sequence=:sequence AND operation='INCIDENT_TASK'""")
    suspend fun state(account: String,org: String,sequence: Long,state: String)
}
