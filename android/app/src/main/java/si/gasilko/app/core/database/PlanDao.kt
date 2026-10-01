package si.gasilko.app.core.database

import androidx.room.*
import si.gasilko.app.feature.plans.*

@Entity(tableName="inspection_plans",primaryKeys=["account","organization","id"])
data class PlanEntity(val account: String,@Embedded val value: InspectionPlan)
@Entity(tableName="inspection_plan_teams",primaryKeys=["account","organization","planId","teamId"])
data class PlanTeamEntity(val account: String,@Embedded val value: PlanTeam)
@Entity(tableName="inspection_plan_items",primaryKeys=["account","organization","id"])
data class PlanItemEntity(val account: String,@Embedded val value: PlanItem)
@Entity(tableName="inspection_plan_routes",primaryKeys=["account","organization","planId","teamId"])
data class PlanRouteEntity(val account: String,@Embedded val value: PlanRoute)
// Online-only request journal and acknowledged history. Never used as a background upload queue.
@Entity(tableName="plan_reassignments",primaryKeys=["account","organization","id"])
data class PlanReassignmentRecord(val account: String,val organization: String,val id: String,val planId: String,
    val itemId: String,val payload: String?,val event: String?,val state: String)
// Empty hydrantId marks a successful complete registry refresh. Other rows mark history coverage.
@Entity(tableName="plan_cache_coverage",primaryKeys=["account","organization","hydrantId"])
data class PlanCoverage(val account: String,val organization: String,val hydrantId: String,val version: Long,val refreshedAt: Long)
data class PlanInspectionLast(val hydrantId: String,val completedAt: Long?,val issues: Int)
@Dao interface PlanDao {
    @Query("UPDATE inspection_plan_routes SET valid=0 WHERE account=:account AND organization=:org AND planId=:plan AND teamId=:team")
    suspend fun staleRoute(account: String,org: String,plan: String,team: String)
    @Upsert suspend fun reassignments(rows: List<PlanReassignmentRecord>)
    @Query("SELECT * FROM plan_reassignments WHERE account=:account AND organization=:org ORDER BY id")
    suspend fun reassignments(account: String,org: String): List<PlanReassignmentRecord>
    @Query("UPDATE plan_reassignments SET state='REJECTED' WHERE account=:account AND organization=:org AND id=:id AND state='REQUESTED'")
    suspend fun rejectReassignment(account: String,org: String,id: String)
    @Query("SELECT * FROM inspection_plan_items WHERE account=:account AND organization=:org AND planId=:plan AND id=:item")
    suspend fun item(account: String,org: String,plan: String,item: String): PlanItemEntity?
    @Upsert suspend fun plans(rows: List<PlanEntity>)
    @Upsert suspend fun teams(rows: List<PlanTeamEntity>)
    @Upsert suspend fun items(rows: List<PlanItemEntity>)
    @Upsert suspend fun routes(rows: List<PlanRouteEntity>)
    @Query("SELECT * FROM inspection_plan_routes WHERE account=:account AND organization=:org ORDER BY planId,teamId")
    suspend fun routes(account: String,org: String): List<PlanRouteEntity>
    @Upsert suspend fun coverage(rows: List<PlanCoverage>)
    @Query("SELECT * FROM inspection_plans WHERE account=:account AND organization=:org ORDER BY createdAt DESC,id")
    suspend fun plans(account: String,org: String): List<PlanEntity>
    @Query("SELECT * FROM inspection_plan_teams WHERE account=:account AND organization=:org ORDER BY planId,teamId")
    suspend fun teams(account: String,org: String): List<PlanTeamEntity>
    @Query("SELECT * FROM inspection_plan_items WHERE account=:account AND organization=:org ORDER BY planId,hydrantId")
    suspend fun items(account: String,org: String): List<PlanItemEntity>
    @Query("SELECT * FROM plan_cache_coverage WHERE account=:account AND organization=:org")
    suspend fun coverage(account: String,org: String): List<PlanCoverage>
    @Query("""SELECT hydrantId,MAX(completedAt) AS completedAt,
        SUM(CASE WHEN syncIssue IS NULL THEN 0 ELSE 1 END) AS issues FROM inspections
        WHERE account=:account AND organization=:org GROUP BY hydrantId""")
    suspend fun lastInspections(account: String,org: String): List<PlanInspectionLast>
}

