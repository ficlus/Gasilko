package si.gasilko.app.feature.incidents

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*
import si.gasilko.app.core.database.IncidentSyncCursor

internal class FieldProtocolFailure(val code: String): IllegalStateException(code)
internal data class ReconciledField(val incidents: List<JsonObject>,val cursors: List<IncidentSyncCursor>,val caughtUp: Boolean)

/** Bounded protocol helper for the existing repository, not a scheduler or local store. */
internal class IncidentReconciliation(
    private val account: String,private val org: String,
    private val call: suspend (String,JsonObject)->JsonObject,
    private val revokeIncident: suspend (String)->Unit
) {
    private fun fail(code: String): Nothing=throw FieldProtocolFailure(code)
    private fun checkProtocol(value: Boolean) { if(!value)fail("PROTOCOL") }
    private fun number(value: String): Long=value.toLongOrNull()?.takeIf { it>=0 } ?: fail("PROTOCOL")
    private fun args(id: String?=null,extra: JsonObjectBuilder.()->Unit={}): JsonObject=buildJsonObject {
        put("p_acting_organization_id",org);if(id!=null)put("p_incident_id",id);extra()
    }
    private fun identity(row: JsonObject,id: String?=null) {
        checkProtocol(row.text("account")==account && row.text("organization")==org &&
            row.text("schema_version")=="1" && (id==null || row.text("incident_id")==id))
    }
    private fun payload(row: JsonObject,id: String,revision: Long,sequence: Long) {
        checkProtocol(row.text("id")==id && number(row.text("revision"))==revision &&
            number(row.text("timeline_sequence"))==sequence &&
            row["units"] is JsonArray && row["assignments"] is JsonArray && row["history"] is JsonArray)
        checkProtocol(row.rows("units").size<=100 && row.rows("assignments").size<=1000 && row.rows("history").size<=100)
        checkProtocol(row.toString().toByteArray(Charsets.UTF_8).size<=3_145_728)
        for(kind in listOf("units","assignments")) {
            val rows=row.rows(kind)
            checkProtocol(rows.size==(row[kind] as JsonArray).size && rows.all { canonicalUuid(it.text("id")) && number(it.text("version"))>0 } &&
                rows.map { it.text("id") }.distinct().size==rows.size)
        }
    }
    private suspend fun directory(): List<JsonObject> {
        val data=call("incident_field_directory",args());identity(data)
        checkProtocol(data["incidents"] is JsonArray)
        val rows=data.rows("incidents")
        checkProtocol(rows.size<=50 && rows.map { it.text("id") }.distinct().size==rows.size &&
            rows.all { canonicalUuid(it.text("id")) && it.text("scope_fingerprint").length==32 })
        return rows
    }
    private suspend fun snapshot(id: String): Pair<JsonObject,IncidentSyncCursor> {
        // One bounded restart for manifest expiry; never mix pages from attempts.
        for(attempt in 0..1) {
            try {
                val manifest=call("incident_snapshot_manifest",args(id));identity(manifest,id)
                val token=manifest.text("manifest_id");val revision=number(manifest.text("snapshot_revision"))
                val sequence=number(manifest.text("timeline_sequence"));val fingerprint=manifest.text("scope_fingerprint")
                checkProtocol(canonicalUuid(token) && fingerprint.length==32)
                val limits=mapOf("core" to 1,"units" to 100,"assignments" to 1000,"history" to 100)
                val collections=mutableMapOf<String,List<JsonObject>>()
                var bytes=0;var pages=0
                for((kind,limit) in limits) {
                    val expected=number(manifest.obj("collections").text(kind))
                    checkProtocol(expected<=limit && (kind!="core" || expected==1L))
                    val rows=mutableListOf<JsonObject>();var ordinal=0L
                    // Fetch even an empty collection to validate the pinned identity.
                    do {
                        if(++pages>52)fail("PROTOCOL")
                        val page=call("incident_snapshot_page",args(id) {
                            put("p_manifest_id",token);put("p_collection",kind);put("p_after_ordinal",ordinal);put("p_limit",25)
                        })
                        identity(page,id)
                        checkProtocol(page.text("manifest_id")==token && page.text("snapshot_revision")==revision.toString() &&
                            page.text("timeline_sequence")==sequence.toString() && page.text("scope_fingerprint")==fingerprint &&
                            page.text("collection")==kind && page["items"] is JsonArray)
                        val items=page.rows("items")
                        checkProtocol(items.size<=25 && (items.isNotEmpty() || ordinal==expected))
                        for(item in items) {
                            checkProtocol(number(item.text("ordinal"))==ordinal+1 && item["payload"] is JsonObject)
                            val value=item.obj("payload");bytes+=value.toString().toByteArray(Charsets.UTF_8).size
                            if(bytes>3_145_728)fail("SNAPSHOT_TOO_LARGE")
                            rows+=value;ordinal++
                        }
                        checkProtocol(ordinal<=expected && page.flag("complete")==(ordinal==expected))
                        if(ordinal<expected)checkProtocol(page.text("next_cursor")==ordinal.toString())
                        else checkProtocol(page.text("next_cursor").isEmpty())
                    } while(ordinal<expected)
                    checkProtocol(rows.size.toLong()==expected)
                    collections[kind]=rows
                }
                val core=collections.getValue("core").single()
                val assembled=JsonObject(core+mapOf(
                    "units" to JsonArray(collections.getValue("units")),
                    "assignments" to JsonArray(collections.getValue("assignments")),
                    "history" to JsonArray(collections.getValue("history"))))
                payload(assembled,id,revision,sequence)
                Log.d("IncidentSync","snapshot pages=$pages bytes=$bytes")
                return assembled to IncidentSyncCursor(account,org,id,token,revision,Int.MAX_VALUE,sequence,fingerprint,1,System.currentTimeMillis())
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                if(attempt==0 && e.message.orEmpty().let { "MANIFEST_EXPIRED" in it || "MANIFEST_NOT_FOUND" in it })continue
                throw e
            }
        }
        fail("MANIFEST_EXPIRED")
    }
    private suspend fun changes(id: String,old: JsonObject,cursor: IncidentSyncCursor): Pair<JsonObject,IncidentSyncCursor>? {
        val feed=call("incident_change_feed",args(id) {
            put("p_scope_fingerprint",cursor.fingerprint);put("p_after_revision",cursor.revision)
            put("p_after_ordinal",cursor.ordinal);put("p_limit",100)
        })
        identity(feed,id)
        if(feed.flag("reset_required")) {
            revokeIncident(id)
            Log.d("IncidentSync","feed reset required")
            return null
        }
        checkProtocol(feed.text("scope_fingerprint")==cursor.fingerprint &&
            feed.text("from_revision")==cursor.revision.toString() && feed.text("from_ordinal")==cursor.ordinal.toString())
        val current=number(feed.text("current_revision"))
        Log.d("IncidentSync","feed lag="+(current-cursor.revision).coerceAtLeast(0))
        checkProtocol(current>=cursor.revision && feed["changes"] is JsonArray)
        var previousRevision=cursor.revision;var previousOrdinal=cursor.ordinal
        val changes=feed.rows("changes");checkProtocol(changes.size<=100)
        for(change in changes) {
            val revision=number(change.text("revision"));val ordinal=number(change.text("ordinal"))
            checkProtocol(revision<=current && ordinal in 1L..Int.MAX_VALUE.toLong() &&
                (revision>previousRevision || (revision==previousRevision && ordinal>previousOrdinal)) &&
                change.text("entity_id")==id && change.text("entity_version")==revision.toString())
            previousRevision=revision;previousOrdinal=ordinal.toInt()
            if(change.text("operation")!="UPSERT" || change.text("entity_kind")!="FIELD_COLLECTIONS") {
                revokeIncident(id);return null
            }
        }
        checkProtocol(feed.text("next_revision")==previousRevision.toString() && feed.text("next_ordinal")==previousOrdinal.toString())
        if(feed.flag("has_more")) { revokeIncident(id);return null } // Unknown later descriptors require a safe reset.
        if(changes.isEmpty()) {
            checkProtocol(current==cursor.revision && number(feed.text("timeline_sequence"))==cursor.timelineSequence)
            return old to cursor.copy(syncedAt=System.currentTimeMillis())
        }
        val result=call("incident_field_entities",args(id) {
            put("p_scope_fingerprint",cursor.fingerprint);put("p_expected_revision",current)
        })
        identity(result,id)
        checkProtocol(result.text("scope_fingerprint")==cursor.fingerprint && number(result.text("revision"))==current)
        val sequence=number(result.text("timeline_sequence"));checkProtocol(sequence>=cursor.timelineSequence)
        val row=result.obj("payload");payload(row,id,current,sequence)
        // Full authorized collection replacement removes vanished rows and cannot
        // mix entity versions. It supersedes every descriptor through this boundary.
        return row to cursor.copy(manifest=null,revision=current,ordinal=Int.MAX_VALUE,
            timelineSequence=sequence,syncedAt=System.currentTimeMillis())
    }
    suspend fun reconcile(previous: List<JsonObject>,saved: List<IncidentSyncCursor>): ReconciledField {
        val entries=directory();val ids=entries.map { it.text("id") }.toSet()
        for(old in previous)if(old.text("id") !in ids)revokeIncident(old.text("id"))
        val result=mutableListOf<JsonObject>();val cursors=mutableListOf<IncidentSyncCursor>()
        for(entry in entries) {
            val id=entry.text("id");val old=previous.find { it.text("id")==id }
            val cursor=saved.find { it.incident==id && it.account==account && it.organization==org }
            val compatible=old!=null && cursor!=null && cursor.schemaVersion==1 &&
                old.text("revision")==cursor.revision.toString() && entry.text("scope_fingerprint")==cursor.fingerprint
            if(old!=null && !compatible)revokeIncident(id)
            try {
                var pair=if(compatible)changes(id,old!!,cursor!!) else null
                if(pair==null) {
                    pair=snapshot(id)
                    // Catch mutations after the pinned snapshot; bounded retries, no endless loop.
                    pair=changes(id,pair.first,pair.second) ?: snapshot(id)
                }
                if(cursor!=null)checkProtocol(pair.second.revision>=cursor.revision)
                if(old!=null)for(kind in listOf("units","assignments")) {
                    val versions=old.rows(kind).associate { it.text("id") to number(it.text("version")) }
                    checkProtocol(pair.first.rows(kind).all { row ->
                        number(row.text("version")) >= (versions[row.text("id")] ?: 0L)
                    })
                }
                result+=pair.first;cursors+=pair.second
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                if(e.message.orEmpty().let { "NOT_AUTHORIZED" in it || "SCOPE_CHANGED" in it })revokeIncident(id)
                throw e
            }
        }
        if(result.sumOf { it.toString().toByteArray(Charsets.UTF_8).size.toLong() }>3_145_728)fail("SNAPSHOT_TOO_LARGE")
        // Revalidate the complete scope immediately before the repository transaction.
        val final=directory()
        val finalIds=final.map { it.text("id") }.toSet()
        for(cursor in cursors) {
            val fresh=final.find { it.text("id")==cursor.incident }
            if(fresh==null || fresh.text("scope_fingerprint")!=cursor.fingerprint) {
                revokeIncident(cursor.incident);fail("MANIFEST_SCOPE_CHANGED")
            }
        }
        val caughtUp=ids==finalIds && cursors.all { c ->
            final.find { it.text("id")==c.incident }?.text("revision")==c.revision.toString()
        }
        return ReconciledField(result,cursors,caughtUp)
    }
}
