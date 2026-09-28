package si.gasilko.app.feature.teams

import kotlinx.coroutines.flow.*
import si.gasilko.app.feature.hydrants.domain.*

data class InspectionTeam(val id: String, val organization: String, val name: String, val active: Boolean,
    val createdBy: String, val createdAt: String, val updatedAt: String)
data class TeamMember(val teamId: String, val organization: String, val userId: String, val active: Boolean,
    val addedBy: String, val createdAt: String, val updatedAt: String, val displayName: String?)
data class TeamPerson(val id: String, val displayName: String?)
data class TeamData(val teams: List<InspectionTeam> = emptyList(), val members: List<TeamMember> = emptyList(),
    val people: List<TeamPerson> = emptyList())
enum class TeamOperation { CREATE, RENAME, ACTIVE, ADD, REMOVE }
data class TeamChange(val id: String, val operation: TeamOperation, val name: String? = null,
    val active: Boolean? = null, val member: String? = null, val initialMembers: List<String> = emptyList())
interface TeamRepository {
    fun observeTeamData(organization: String): Flow<TeamData> = flowOf(TeamData())
    fun observeTeams(organization: String) = observeTeamData(organization).map { it.teams }
    fun observeTeamMembers(organization: String, team: String) =
        observeTeamData(organization).map { it.members.filter { member -> member.teamId==team } }
    suspend fun refreshTeams(organization: String) {}
    /** Online-only management; the returned authoritative snapshot is cached before completion. */
    suspend fun changeTeam(organization: String, change: TeamChange): TeamData = throw RegistryFailure(RegistryError.UNAVAILABLE)
    suspend fun readTeams(organization: String): TeamData = throw RegistryFailure(RegistryError.UNAVAILABLE)
    suspend fun createTeam(org: String, id: String, name: String, members: List<String>) =
        changeTeam(org,TeamChange(id,TeamOperation.CREATE,name=name,initialMembers=members))
    suspend fun renameTeam(org: String, id: String, name: String) = changeTeam(org,TeamChange(id,TeamOperation.RENAME,name=name))
    suspend fun setTeamActive(org: String, id: String, active: Boolean) = changeTeam(org,TeamChange(id,TeamOperation.ACTIVE,active=active))
    suspend fun addTeamMember(org: String, id: String, user: String) = changeTeam(org,TeamChange(id,TeamOperation.ADD,member=user))
    suspend fun removeTeamMember(org: String, id: String, user: String) = changeTeam(org,TeamChange(id,TeamOperation.REMOVE,member=user))
}
