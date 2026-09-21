package si.gasilko.app

import androidx.room.Room
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.data.RoomHydrantRepository
import si.gasilko.app.feature.hydrants.domain.*

class RegistryDatabaseTest {
    private lateinit var db: RegistryDatabase
    private lateinit var server: Server
    private lateinit var repo: RoomHydrantRepository
    private var account = "account-a"
    private val a = "00000000-0000-0000-0000-000000000001"
    private val b = "00000000-0000-0000-0000-000000000002"
    private val row = Hydrant("10000000-0000-0000-0000-000000000001", a, null, "type-1",
        HydrantStatus.WORKING, 46.05, 14.5, "Šolska ulica", "North %_ gate", "note", 18,
        version = 42, createdBy = "creator", createdAt = "2026-09-01T10:00:00Z",
        updatedAt = "2026-09-02T10:00:00Z", updatedBy = "editor")

    @Before fun setup() {
        db = Room.inMemoryDatabaseBuilder(InstrumentationRegistry.getInstrumentation().targetContext,
            RegistryDatabase::class.java).build()
        server = Server()
        repo = RoomHydrantRepository(db, server) { account }
    }
    @After fun close() = db.close()
    private suspend fun hydrate() { repo.refreshOrganizations(); repo.refresh(a) }

    @Test fun storesAllFieldsAndUpsertsByUuidNotNullableCode() = runBlocking {
        hydrate()
        assertEquals(row, repo.get(a, row.id))
        server.rows = listOf(row.copy(code = "A-H-000042", version = 43))
        repo.refresh(a)
        assertEquals(server.rows.single(), repo.get(a, row.id))
        assertEquals(1, repo.list(HydrantQuery(a)).size)
    }

    @Test fun listAndDetailAreOrganizationAndAccountScoped() = runBlocking {
        server.rows = listOf(row, row.copy(id = "20000000-0000-0000-0000-000000000001", organization = b))
        hydrate(); repo.refresh(b)
        assertEquals(listOf(row.id), repo.list(HydrantQuery(a)).map { it.id })
        assertNull(db.registry().get(account, b, row.id))
        assertEquals(b, repo.list(HydrantQuery(b)).single().organization)
        account = "account-b"
        assertTrue(repo.organizations().isEmpty())
        assertNull(db.registry().get(account, a, row.id))
    }

    @Test fun literalSearchFiltersAndUuidCursorRunInRoom() = runBlocking {
        val inactive = row.copy(id = "10000000-0000-0000-0000-000000000002", code = "CODE-2",
            type = "type-2", status = HydrantStatus.UNKNOWN, active = false)
        server.rows = listOf(row, inactive)
        hydrate()
        assertEquals(row, repo.list(HydrantQuery(a, search = " ŠOLSKA ")).single())
        assertEquals(row, repo.list(HydrantQuery(a, search = "%_", type = "type-1",
            status = HydrantStatus.WORKING)).single())
        assertEquals(inactive, repo.list(HydrantQuery(a, search = "code-2", type = "type-2",
            status = HydrantStatus.UNKNOWN, active = ActiveFilter.INACTIVE)).single())
        assertTrue(repo.list(HydrantQuery(a, search = "x%")).isEmpty())
        assertEquals(listOf(row.id, inactive.id), repo.list(HydrantQuery(a, active = ActiveFilter.ALL)).map { it.id })
        assertEquals(inactive, repo.list(HydrantQuery(a, active = ActiveFilter.ALL), row.id).single())
    }

    @Test fun successfulRefreshReplacesSnapshotAndSubsequentReadsAreLocal() = runBlocking {
        hydrate()
        server.fail = true
        assertEquals(row, repo.get(a, row.id))
        assertEquals(row, repo.list(HydrantQuery(a)).single())
        assertEquals("type-1", repo.types(a).single().id)
        server.fail = false
        server.rows = emptyList()
        repo.refresh(a)
        assertTrue(repo.list(HydrantQuery(a)).isEmpty())
    }

    @Test fun failedLaterPageKeepsExistingHydrantsAndTypes() = runBlocking {
        hydrate()
        server.rows = (1..100).map { row.copy(id = "30000000-0000-0000-0000-${it.toString().padStart(12, '0')}") }
        server.failLaterPage = true
        try { repo.refresh(a); fail("Refresh must fail") }
        catch(e: RegistryFailure) { assertEquals(RegistryError.NETWORK, e.reason) }
        assertEquals(row, repo.list(HydrantQuery(a)).single())
        assertEquals("type-1", repo.types(a).single().id)
    }

    @Test fun existingOnlineWriteAcknowledgementIsPersistedBeforeLocalRead() = runBlocking {
        hydrate()
        val result = repo.changeStatus(a, row.id, HydrantStatus.NOT_WORKING, row.version)
        server.fail = true
        assertEquals(43L, result.version)
        assertEquals(HydrantStatus.NOT_WORKING, repo.get(a, row.id).status)
        assertEquals(result, repo.list(HydrantQuery(a)).single())
    }

    private inner class Server : HydrantRepository {
        var rows = listOf(row)
        var fail = false
        var failLaterPage = false
        private fun check() { if(fail) throw RegistryFailure(RegistryError.NETWORK) }
        override suspend fun organizations(): List<RegistryOrganization> {
            check(); return listOf(RegistryOrganization(a, "A", RegistryRole.MANAGER), RegistryOrganization(b, "B", RegistryRole.MANAGER))
        }
        override suspend fun types(organization: String): List<HydrantType> {
            check(); return listOf(HydrantType("type-1", null, "GLOBAL", "Global", true))
        }
        override suspend fun list(query: HydrantQuery, after: String?): List<Hydrant> {
            check(); if(failLaterPage && after != null) throw RegistryFailure(RegistryError.NETWORK)
            return rows.filter { query.matches(it) && (after == null || it.id > after) }.sortedBy { it.id }.take(100)
        }
        override suspend fun get(organization: String, id: String): Hydrant {
            check(); return rows.single { it.organization == organization && it.id == id }
        }
        override suspend fun changeStatus(organization: String, id: String, status: HydrantStatus, version: Long): Hydrant {
            val updated = get(organization, id).copy(status = status, version = version + 1)
            rows = rows.map { if(it.id == id) updated else it }; return updated
        }
        override suspend fun create(organization: String, id: String, fields: HydrantFields): Hydrant = error("Unused")
        override suspend fun update(organization: String, id: String, fields: HydrantFields, version: Long): Hydrant = error("Unused")
        override suspend fun setActive(organization: String, id: String, active: Boolean, version: Long): Hydrant = error("Unused")
    }
}
