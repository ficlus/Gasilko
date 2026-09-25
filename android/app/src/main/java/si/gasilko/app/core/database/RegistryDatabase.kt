package si.gasilko.app.core.database

import android.content.Context
import androidx.room.*
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.inspections.domain.Inspection
import java.util.Locale

// Account is a cache partition; the server UUID remains the domain identity.
@Entity(tableName = "organizations", primaryKeys = ["account", "id"])
data class OrganizationEntity(val account: String, @Embedded val value: RegistryOrganization)

// Scope also partitions global type visibility by the refreshed organization.
@Entity(tableName = "hydrant_types", primaryKeys = ["account", "scope", "id"])
data class TypeEntity(val account: String, val scope: String, @Embedded val value: HydrantType)

@Entity(tableName = "hydrants", primaryKeys = ["account", "id"],
    indices = [Index(value = ["account", "organization", "id"])])
data class HydrantEntity(
    val account: String, @Embedded val value: Hydrant,
    val codeSearch: String, val addressSearch: String, val descriptionSearch: String,
) {
    companion object {
        fun from(account: String, value: Hydrant) = HydrantEntity(account, value,
            fold(value.code), fold(value.address), fold(value.description))
        fun fold(value: String?) = value.orEmpty().lowercase(Locale.ROOT)
    }
}

@Dao
interface RegistryDao {
    @Insert suspend fun insertInspection(row: InspectionEntity)
    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun cacheInspections(rows: List<InspectionEntity>)
    @Query("SELECT * FROM inspections WHERE account = :account AND organization = :organization AND id = :id")
    suspend fun inspection(account: String, organization: String, id: String): InspectionEntity?
    @Query("SELECT * FROM inspections WHERE account = :account AND organization = :organization AND hydrantId = :hydrantId ORDER BY completedAt DESC, id DESC")
    suspend fun inspectionHistory(account: String, organization: String, hydrantId: String): List<InspectionEntity>
    // Completed content is immutable. Only authoritative receipt metadata changes after acknowledgement.
    @Query("UPDATE inspections SET createdAt = :createdAt, hydrantVersionBefore = :before, hydrantVersionAfter = :after, acknowledgedAt = :time WHERE account = :account AND organization = :organization AND id = :id AND inspectorId = :account")
    suspend fun acknowledgeInspection(account: String, organization: String, id: String, createdAt: Long,
        before: Long, after: Long, time: Long): Int
    // Payload/history stay immutable; only the sync engine records acknowledgement or conflict.
    @Insert suspend fun enqueue(change: PendingHydrantChange): Long
    @Query("SELECT * FROM pending_hydrant_changes WHERE account = :account AND organization = :organization ORDER BY sequence")
    suspend fun pendingChanges(account: String, organization: String): List<PendingHydrantChange>
    @Query("SELECT DISTINCT entityId FROM pending_hydrant_changes WHERE account = :account AND organization = :organization AND state NOT IN ('SYNCED','RESOLVED')")
    suspend fun pendingHydrantIds(account: String, organization: String): List<String>
    @Query("SELECT * FROM pending_hydrant_changes WHERE account = :account AND organization = :organization AND state NOT IN ('SYNCED','RESOLVED') ORDER BY COALESCE(orderSequence, sequence), sequence LIMIT 1")
    suspend fun nextChange(account: String, organization: String): PendingHydrantChange?
    @Query("SELECT * FROM pending_hydrant_changes WHERE account = :account AND organization = :organization AND entityId = :id AND state NOT IN ('SYNCED','RESOLVED') ORDER BY COALESCE(orderSequence, sequence), sequence")
    suspend fun remainingChanges(account: String, organization: String, id: String): List<PendingHydrantChange>
    @Query("SELECT acknowledgedVersion FROM pending_hydrant_changes WHERE account = :account AND organization = :organization AND entityId = :id AND COALESCE(orderSequence, sequence) < :before AND state = 'SYNCED' ORDER BY COALESCE(orderSequence, sequence) DESC, sequence DESC LIMIT 1")
    suspend fun acknowledgedVersion(account: String, organization: String, id: String, before: Long): Long?
    @Query("UPDATE pending_hydrant_changes SET state = 'SYNCED', acknowledgedVersion = :version WHERE account = :account AND organization = :organization AND sequence = :sequence AND state = 'PENDING'")
    suspend fun acknowledge(account: String, organization: String, sequence: Long, version: Long?): Int
    @Query("UPDATE pending_hydrant_changes SET state = 'CONFLICT' WHERE account = :account AND organization = :organization AND sequence = :sequence AND state = 'PENDING'")
    suspend fun conflict(account: String, organization: String, sequence: Long)
    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun captureConflict(conflict: HydrantConflictEntity)
    @Query("SELECT * FROM hydrant_conflicts WHERE account = :account AND organization = :organization AND sequence = :sequence")
    suspend fun conflictInfo(account: String, organization: String, sequence: Long): HydrantConflictEntity?
    @Query("UPDATE hydrant_conflicts SET serverState = :server WHERE account = :account AND organization = :organization AND sequence = :sequence AND serverState IS NULL AND resolution IS NULL")
    suspend fun captureServer(account: String, organization: String, sequence: Long, server: String)
    @Query("UPDATE hydrant_conflicts SET resolution = :strategy, resolvedAt = :time, resolvedBy = :account, resolutionServerState = :server, resolutionVersion = :version, replacementSequence = :replacement WHERE account = :account AND organization = :organization AND sequence = :sequence AND resolution IS NULL")
    suspend fun resolve(account: String, organization: String, sequence: Long, strategy: String, time: Long, server: String, version: Long, replacement: Long?): Int
    @Query("UPDATE pending_hydrant_changes SET state = 'RESOLVED' WHERE account = :account AND organization = :organization AND sequence = :sequence AND state = 'CONFLICT'")
    suspend fun resolveOperation(account: String, organization: String, sequence: Long): Int
    @Upsert suspend fun upsertOrganizations(rows: List<OrganizationEntity>)
    @Upsert suspend fun upsertTypes(rows: List<TypeEntity>)
    @Upsert suspend fun upsertHydrants(rows: List<HydrantEntity>)
    @Insert suspend fun insertHydrant(row: HydrantEntity)
    @Query("SELECT * FROM organizations WHERE account = :account ORDER BY id")
    suspend fun organizations(account: String): List<OrganizationEntity>
    @Query("SELECT * FROM hydrant_types WHERE account = :account AND scope = :organization ORDER BY id")
    suspend fun types(account: String, organization: String): List<TypeEntity>
    @Query("SELECT * FROM hydrants WHERE account = :account AND organization = :organization AND id = :id")
    suspend fun get(account: String, organization: String, id: String): HydrantEntity?
    @Query("""SELECT * FROM hydrants WHERE account = :account AND organization = :organization
        AND (:after IS NULL OR id > :after) AND (:type IS NULL OR type = :type)
        AND (:status IS NULL OR status = :status) AND (:active IS NULL OR active = :active)
        AND (:search = '' OR instr(codeSearch, :search) > 0 OR instr(addressSearch, :search) > 0
            OR instr(descriptionSearch, :search) > 0)
        ORDER BY id ASC LIMIT :limit""")
    suspend fun list(account: String, organization: String, search: String, type: String?,
        status: HydrantStatus?, active: Boolean?, after: String?, limit: Int = 100): List<HydrantEntity>
    @Query("DELETE FROM organizations WHERE account = :account")
    suspend fun removeOrganizations(account: String)
    @Query("""DELETE FROM hydrants WHERE account = :account AND organization = :organization
        AND id NOT IN (SELECT entityId FROM pending_hydrant_changes
            WHERE account = :account AND organization = :organization AND state NOT IN ('SYNCED','RESOLVED'))""")
    suspend fun removeHydrants(account: String, organization: String)
    @Query("DELETE FROM hydrant_types WHERE account = :account AND scope = :organization")
    suspend fun removeTypes(account: String, organization: String)
}

@Entity(tableName = "pending_hydrant_changes")
data class PendingHydrantChange(
    @PrimaryKey(autoGenerate = true) val sequence: Long = 0,
    val operationId: String, val account: String, val organization: String, val entityId: String,
    val operation: String, val payload: String, val baseVersion: Long?, val createdAt: Long,
    val state: String = "PENDING",
    val acknowledgedVersion: Long? = null,
    val orderSequence: Long? = null,
)

@Entity(tableName = "inspections", primaryKeys = ["account", "id"],
    indices = [Index(value = ["account", "organization", "hydrantId", "completedAt", "id"])])
data class InspectionEntity(val account: String, @Embedded val value: Inspection, val acknowledgedAt: Long? = null)

@Entity(tableName = "hydrant_conflicts")
data class HydrantConflictEntity(
    @PrimaryKey val sequence: Long, val logicalSequence: Long, val account: String, val organization: String,
    val entityId: String, val localState: String, val serverState: String? = null, val detectedAt: Long,
    val resolution: String? = null, val resolvedAt: Long? = null, val resolvedBy: String? = null,
    val resolutionServerState: String? = null, val resolutionVersion: Long? = null, val replacementSequence: Long? = null,
)

@Database(entities = [OrganizationEntity::class, TypeEntity::class, HydrantEntity::class, PendingHydrantChange::class, HydrantConflictEntity::class, InspectionEntity::class], version = 5, exportSchema = true)
abstract class RegistryDatabase : RoomDatabase() {
    abstract fun registry(): RegistryDao
    companion object {
        val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("""CREATE TABLE IF NOT EXISTS inspections (
                    account TEXT NOT NULL, id TEXT NOT NULL, hydrantId TEXT NOT NULL,
                    organization TEXT NOT NULL, inspectorId TEXT NOT NULL, mode TEXT NOT NULL,
                    result TEXT NOT NULL, startedAt INTEGER NOT NULL, completedAt INTEGER NOT NULL,
                    notes TEXT, pressureBar REAL, flowLMin REAL, createdAt INTEGER NOT NULL,
                    hydrantVersionBefore INTEGER, hydrantVersionAfter INTEGER, acknowledgedAt INTEGER,
                    PRIMARY KEY(account,id))""")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_inspections_account_organization_hydrantId_completedAt_id ON inspections(account,organization,hydrantId,completedAt,id)")
            }
        }
        val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE pending_hydrant_changes ADD COLUMN orderSequence INTEGER")
                db.execSQL("""CREATE TABLE IF NOT EXISTS hydrant_conflicts (
                    sequence INTEGER NOT NULL PRIMARY KEY, logicalSequence INTEGER NOT NULL,
                    account TEXT NOT NULL, organization TEXT NOT NULL, entityId TEXT NOT NULL,
                    localState TEXT NOT NULL, serverState TEXT, detectedAt INTEGER NOT NULL,
                    resolution TEXT, resolvedAt INTEGER, resolvedBy TEXT, resolutionServerState TEXT,
                    resolutionVersion INTEGER, replacementSequence INTEGER)""")
            }
        }
        val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE pending_hydrant_changes ADD COLUMN acknowledgedVersion INTEGER")
            }
        }
        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("""CREATE TABLE IF NOT EXISTS pending_hydrant_changes (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    operationId TEXT NOT NULL, account TEXT NOT NULL, organization TEXT NOT NULL,
                    entityId TEXT NOT NULL, operation TEXT NOT NULL, payload TEXT NOT NULL,
                    baseVersion INTEGER, createdAt INTEGER NOT NULL, state TEXT NOT NULL)""")
            }
        }
        @Volatile private var instance: RegistryDatabase? = null
        fun open(context: Context): RegistryDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(context.applicationContext, RegistryDatabase::class.java,
                "hydrant-registry.db").addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5).build().also { instance = it }
        }
    }
}
