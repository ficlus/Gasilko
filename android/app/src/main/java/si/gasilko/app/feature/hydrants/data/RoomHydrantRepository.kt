package si.gasilko.app.feature.hydrants.data

import androidx.room.withTransaction
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.domain.*

/** M3.1: local reads and explicit server snapshot hydration. Writes still require the server. */
class RoomHydrantRepository(
    private val database: RegistryDatabase,
    private val online: HydrantRepository,
    private val currentAccount: () -> String,
) : HydrantRepository {
    private val dao = database.registry()
    private val changes = Mutex()
    private fun checkAccount(account: String) {
        if (currentAccount() != account) throw RegistryFailure(RegistryError.EXPIRED)
    }
    private suspend fun organization(account: String, id: String) = dao.organizations(account)
        .firstOrNull { it.value.id == id }?.value ?: throw RegistryFailure(RegistryError.FORBIDDEN)

    override suspend fun organizations(): List<RegistryOrganization> {
        val account = currentAccount()
        return dao.organizations(account).map { it.value }.also { checkAccount(account) }
    }
    override suspend fun types(organization: String): List<HydrantType> {
        val account = currentAccount()
        val org = organization(account, organization)
        return dao.types(account, organization).map { it.value }
            .filter { org.role.manages || it.active }.also { checkAccount(account) }
    }
    override suspend fun list(query: HydrantQuery, after: String?): List<Hydrant> {
        val account = currentAccount()
        val q = query.normalized(organization(account, query.organization).role)
        return dao.list(account, q.organization, HydrantEntity.fold(q.search), q.type, q.status,
            when(q.active) { ActiveFilter.ALL -> null; ActiveFilter.ACTIVE -> true; ActiveFilter.INACTIVE -> false }, after)
            .map { it.value }.also { checkAccount(account) }
    }
    override suspend fun get(organization: String, id: String): Hydrant {
        val account = currentAccount()
        val org = organization(account, organization)
        val row = dao.get(account, organization, id)?.value
        checkAccount(account)
        return row?.takeIf { it.active || org.role.manages } ?: throw RegistryFailure(RegistryError.UNAVAILABLE)
    }
    override suspend fun refreshOrganizations() = changes.withLock {
        val account = currentAccount()
        val rows = online.organizations()
        checkAccount(account)
        database.withTransaction {
            dao.removeOrganizations(account)
            dao.upsertOrganizations(rows.map { OrganizationEntity(account, it) })
        }
    }
    override suspend fun refresh(organization: String) = changes.withLock {
        val account = currentAccount()
        val org = organization(account, organization)
        val types = online.types(organization)
        val rows = mutableListOf<Hydrant>()
        val query = HydrantQuery(organization, active = if(org.role.manages) ActiveFilter.ALL else ActiveFilter.ACTIVE)
        var after: String? = null
        do {
            val page = online.list(query, after)
            require(page.all { it.organization == organization && (after == null || it.id > after!!) })
            rows.addAll(page)
            after = page.lastOrNull()?.id
        } while(page.size == 100)
        require(types.all { it.organization == null || it.organization == organization })
        checkAccount(account)
        // All pages must succeed before replacing this organization, in one atomic transaction.
        // M3.2 must preserve pending writes instead of replacing a server-only snapshot.
        database.withTransaction {
            dao.removeHydrants(account, organization)
            dao.removeTypes(account, organization)
            dao.upsertTypes(types.map { TypeEntity(account, organization, it) })
            dao.upsertHydrants(rows.map { HydrantEntity.from(account, it) })
        }
    }
    override suspend fun refreshDetail(organization: String, id: String) {
        write(organization) { online.get(organization, id) }
    }
    private suspend fun write(organization: String, action: suspend () -> Hydrant): Hydrant = changes.withLock {
        val account = currentAccount()
        organization(account, organization)
        val row = action()
        checkAccount(account)
        require(row.organization == organization)
        dao.upsertHydrants(listOf(HydrantEntity.from(account, row)))
        // Returned values also cross the same Room boundary as normal detail reads.
        val stored = dao.get(account, organization, row.id)!!.value
        checkAccount(account)
        stored
    }
    override suspend fun create(organization: String, id: String, fields: HydrantFields) =
        write(organization) { online.create(organization, id, fields) }
    override suspend fun changeStatus(organization: String, id: String, status: HydrantStatus, version: Long) =
        write(organization) { online.changeStatus(organization, id, status, version) }
    override suspend fun update(organization: String, id: String, fields: HydrantFields, version: Long) =
        write(organization) { online.update(organization, id, fields, version) }
    override suspend fun setActive(organization: String, id: String, active: Boolean, version: Long) =
        write(organization) { online.setActive(organization, id, active, version) }
}
