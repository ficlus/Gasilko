package si.gasilko.app.feature.teams

import androidx.room.withTransaction
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.domain.*

internal class RoomTeams(private val db: RegistryDatabase, private val online: TeamRepository,
    private val account: ()->String, private val authorize: suspend (String,String)->RegistryOrganization) {
    companion object { private val remote=Mutex() }
    private fun check(actor: String) { if(account()!=actor)throw RegistryFailure(RegistryError.EXPIRED) }
    private suspend fun access(actor: String, org: String, write: Boolean = false): RegistryOrganization {
        val authorized=authorize(actor,org)
        check(actor)
        if(!authorized.active || (write && !authorized.role.manages))throw RegistryFailure(RegistryError.FORBIDDEN)
        return authorized
    }
    fun observe(org: String): Flow<TeamData> = flow {
        val actor=account()
        emitAll(db.invalidationTracker.createFlow("inspection_teams","inspection_team_members","team_people","organizations").map {
            val role=access(actor,org).role
            db.withTransaction {
                TeamData(db.teams().teams(actor,org).map { it.value },db.teams().members(actor,org).map { it.value },
                    if(role.manages)db.teams().people(actor,org).map { it.value } else emptyList()).also { check(actor) }
            }
        }.distinctUntilChanged())
    }
    private suspend fun cache(actor: String, org: String, data: TeamData) {
        if(data.teams.any { it.organization!=org } || data.members.any { m ->
                m.organization!=org || data.teams.none { it.id==m.teamId } })
            throw RegistryFailure(RegistryError.VALIDATION)
        db.withTransaction {
            access(actor,org)
            db.teams().teams(data.teams.map { TeamEntity(actor,it) })
            db.teams().members(data.members.map { TeamMemberEntity(actor,it) })
            // Replace only the eligible picker cache after a complete successful response.
            db.teams().clearPeople(actor,org)
            db.teams().people(data.people.map { TeamPersonEntity(actor,org,it) })
            check(actor)
        }
    }
    suspend fun refresh(org: String) = remote.withLock {
        val actor=account();access(actor,org)
        val data=online.readTeams(org)
        access(actor,org);cache(actor,org,data)
    }
    suspend fun change(org: String, change: TeamChange): TeamData = remote.withLock {
        val actor=account();access(actor,org,true)
        val data=online.changeTeam(org,change)
        access(actor,org,true);cache(actor,org,data)
        data
    }
}
