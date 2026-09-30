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
// Empty hydrantId marks a successful complete registry refresh. Other rows mark history coverage.
@Entity(tableName="plan_cache_coverage",primaryKeys=["account","organization","hydrantId"])
data class PlanCoverage(val account: String,val organization: String,val hydrantId: String,val version: Long,val refreshedAt: Long)
data class PlanInspectionLast(val hydrantId: String,val completedAt: Long?,val issues: Int)
@Dao interface PlanDao {
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

