package si.gasilko.app.core.database

import androidx.room.*
import si.gasilko.app.feature.teams.*

@Entity(tableName="inspection_teams",primaryKeys=["account","organization","id"])
data class TeamEntity(val account: String, @Embedded val value: InspectionTeam)
@Entity(tableName="inspection_team_members",primaryKeys=["account","organization","teamId","userId"])
data class TeamMemberEntity(val account: String, @Embedded val value: TeamMember)
@Entity(tableName="team_people",primaryKeys=["account","organization","id"])
data class TeamPersonEntity(val account: String, val organization: String, @Embedded val value: TeamPerson)
@Dao interface TeamDao {
    @Upsert suspend fun teams(rows: List<TeamEntity>)
    @Upsert suspend fun members(rows: List<TeamMemberEntity>)
    @Upsert suspend fun people(rows: List<TeamPersonEntity>)
    @Query("SELECT * FROM inspection_teams WHERE account=:account AND organization=:organization ORDER BY active DESC,name COLLATE NOCASE,id")
    suspend fun teams(account: String, organization: String): List<TeamEntity>
    @Query("SELECT * FROM inspection_team_members WHERE account=:account AND organization=:organization ORDER BY teamId,active DESC,userId")
    suspend fun members(account: String, organization: String): List<TeamMemberEntity>
    @Query("SELECT * FROM team_people WHERE account=:account AND organization=:organization ORDER BY displayName COLLATE NOCASE,id")
    suspend fun people(account: String, organization: String): List<TeamPersonEntity>
    @Query("DELETE FROM team_people WHERE account=:account AND organization=:organization")
    suspend fun clearPeople(account: String, organization: String)
}
