package si.gasilko.app.core.database

import android.content.Context
import androidx.room.*
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import si.gasilko.app.feature.hydrants.domain.*
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
    // Append only: no replace, update or deletion API before a sync engine can acknowledge work.
    @Insert suspend fun enqueue(change: PendingHydrantChange)
    @Query("SELECT * FROM pending_hydrant_changes WHERE account = :account AND organization = :organization ORDER BY sequence")
    suspend fun pendingChanges(account: String, organization: String): List<PendingHydrantChange>
    @Query("SELECT DISTINCT entityId FROM pending_hydrant_changes WHERE account = :account AND organization = :organization AND state != 'SYNCED'")
    suspend fun pendingHydrantIds(account: String, organization: String): List<String>
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
        ORDER BY id ASC LIMIT 100""")
    suspend fun list(account: String, organization: String, search: String, type: String?,
        status: HydrantStatus?, active: Boolean?, after: String?): List<HydrantEntity>
    @Query("DELETE FROM organizations WHERE account = :account")
    suspend fun removeOrganizations(account: String)
    @Query("""DELETE FROM hydrants WHERE account = :account AND organization = :organization
        AND id NOT IN (SELECT entityId FROM pending_hydrant_changes
            WHERE account = :account AND organization = :organization AND state != 'SYNCED')""")
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
)

@Database(entities = [OrganizationEntity::class, TypeEntity::class, HydrantEntity::class, PendingHydrantChange::class], version = 2, exportSchema = true)
abstract class RegistryDatabase : RoomDatabase() {
    abstract fun registry(): RegistryDao
    companion object {
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
                "hydrant-registry.db").addMigrations(MIGRATION_1_2).build().also { instance = it }
        }
    }
}
