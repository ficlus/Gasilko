package si.gasilko.app.feature.map

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import org.maplibre.android.MapLibre
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.offline.*

internal data class OfflineMapRegion(val id: Long, val name: String,
    val definition: OfflineTilePyramidRegionDefinition, val status: OfflineRegionStatus? = null,
    val downloading: Boolean = false, val failed: Boolean = false, val deleting: Boolean = false)
internal data class OfflineMapsState(val regions: List<OfflineMapRegion> = emptyList(),
    val busy: Boolean = false, val error: Boolean = false)

/** Main-thread, application-context owner of the SDK handles. No Room, credentials or location fixes.
 * Only explicit start calls activate downloads. Leaving the map pauses them; persisted SDK resources
 * survive process death. One owner prevents duplicate create requests/observers across navigation.
 */
internal class OfflineMaps private constructor(context: Context) {
    private val manager = OfflineManager.getInstance(context)
    private val mutable = MutableStateFlow(OfflineMapsState())
    val state = mutable.asStateFlow()
    private val handles = mutableMapOf<Long, OfflineRegion>()
    private var clients = 0
    private var loaded = false
    private var generation = 0

    fun attach() {
        clients++
        if(clients != 1) return
        if(!loaded) reload() else handles.values.forEach(::observe)
    }
    fun detach() {
        clients--
        if(clients != 0) return
        generation++
        handles.values.forEach { region ->
            region.setObserver(null)
            if(mutable.value.regions.none { it.id==region.id && it.deleting })
                region.setDownloadState(OfflineRegion.STATE_INACTIVE)
        }
        mutable.value=mutable.value.copy(regions=mutable.value.regions.map { it.copy(downloading=false) })
    }
    fun reload() {
        if(mutable.value.busy || clients==0) return
        if(loaded) { mutable.value=mutable.value.copy(error=false);return }
        mutable.value=mutable.value.copy(busy=true,error=false)
        manager.listOfflineRegions(object : OfflineManager.ListOfflineRegionsCallback {
            override fun onList(offlineRegions: Array<OfflineRegion>?) {
                handles.values.forEach { it.setObserver(null) }
                handles.clear()
                val rows=offlineRegions.orEmpty().mapNotNull { region ->
                    val metadata=runCatching { JSONObject(String(region.metadata,Charsets.UTF_8)) }.getOrNull()
                    val definition=region.definition as? OfflineTilePyramidRegionDefinition
                    if(metadata?.optString("owner")!="gasilko-offline-v1" || definition==null) return@mapNotNull null
                    handles[region.id]=region
                    region.setDownloadState(OfflineRegion.STATE_INACTIVE)
                    OfflineMapRegion(region.id,metadata.optString("name"),definition)
                }
                loaded=true
                mutable.value=OfflineMapsState(rows.sortedBy { it.id })
                if(clients>0) handles.values.forEach(::observe)
            }
            override fun onError(error: String) { mutable.value=mutable.value.copy(busy=false,error=true) }
        })
    }
    private fun update(id: Long, change: (OfflineMapRegion)->OfflineMapRegion) {
        mutable.value=mutable.value.copy(regions=mutable.value.regions.map { if(it.id==id) change(it) else it })
    }
    private fun observe(region: OfflineRegion) {
        if(mutable.value.regions.any { it.id==region.id && it.deleting }) return
        val epoch=generation
        var observedStatus=false
        fun live() = clients>0 && epoch==generation && handles[region.id]===region &&
            mutable.value.regions.any { it.id==region.id && !it.deleting }
        fun acceptStatus(value: OfflineRegionStatus) {
            if(!live()) return
            val exceeds=value.completedResourceSize>OfflineMapPolicy.MAX_BYTES && !value.isComplete
            if((value.isComplete || exceeds) && mutable.value.regions.any { it.id==region.id && it.downloading })
                region.setDownloadState(OfflineRegion.STATE_INACTIVE)
            update(region.id) { it.copy(status=value,downloading=it.downloading && !value.isComplete && !exceeds,
                failed=if(value.isComplete) false else it.failed || exceeds) }
        }
        region.setObserver(object : OfflineRegion.OfflineRegionObserver {
            override fun onStatusChanged(status: OfflineRegionStatus) { observedStatus=true;acceptStatus(status) }
            override fun onError(error: OfflineRegionError) { if(live()) fail(region) }
            override fun mapboxTileCountLimitExceeded(limit: Long) { if(live()) fail(region) }
        })
        region.getStatus(object : OfflineRegion.OfflineRegionStatusCallback {
            override fun onStatus(status: OfflineRegionStatus?) {
                if(observedStatus) return // A newer observer event supersedes this initial snapshot.
                if(status!=null) acceptStatus(status) else if(live()) fail(region)
            }
            override fun onError(error: String?) { if(!observedStatus && live()) fail(region) }
        })
    }
    private fun fail(region: OfflineRegion) {
        if(mutable.value.regions.any { it.id==region.id && it.status?.isComplete==true }) return
        region.setDownloadState(OfflineRegion.STATE_INACTIVE)
        update(region.id) { it.copy(downloading=false,failed=true) }
    }
    fun create(name: String, bounds: LatLngBounds, style: String, pixelRatio: Float) {
        if(clients==0 || !loaded || mutable.value.busy || name.isBlank() || !OfflineMapPolicy.supported(style) || !OfflineMapPolicy.valid(bounds)) return
        val duplicate=mutable.value.regions.any { it.definition.styleURL==style &&
            OfflineMapPolicy.sameArea(it.definition.bounds,bounds) }
        if(duplicate) { mutable.value=mutable.value.copy(error=true); return }
        mutable.value=mutable.value.copy(busy=true,error=false)
        val epoch=generation
        val definition=OfflineTilePyramidRegionDefinition(style,bounds,OfflineMapPolicy.MIN_ZOOM.toDouble(),
            OfflineMapPolicy.MAX_ZOOM.toDouble(),pixelRatio)
        val metadata=JSONObject().put("owner","gasilko-offline-v1").put("name",name.trim().take(80)).toString().toByteArray(Charsets.UTF_8)
        manager.createOfflineRegion(definition,metadata,object : OfflineManager.CreateOfflineRegionCallback {
            override fun onCreate(offlineRegion: OfflineRegion) {
                handles[offlineRegion.id]=offlineRegion
                mutable.value=mutable.value.copy(busy=false,regions=mutable.value.regions+
                    OfflineMapRegion(offlineRegion.id,name.trim().take(80),definition))
                if(clients>0) {
                    observe(offlineRegion)
                    if(epoch==generation) start(offlineRegion.id)
                }
                // Otherwise the SDK-created region stays inactive until an explicit resume.
            }
            override fun onError(error: String) { mutable.value=mutable.value.copy(busy=false,error=true) }
        })
    }
    fun start(id: Long) {
        val row=mutable.value.regions.find { it.id==id } ?: return
        if(clients==0 || row.deleting || row.downloading || row.status?.isComplete==true ||
            !OfflineMapPolicy.supported(row.definition.styleURL.orEmpty())) return
        if((row.status?.completedResourceSize ?: 0)>=OfflineMapPolicy.MAX_BYTES) return
        update(id) { it.copy(failed=false,downloading=true) }
        handles[id]?.setDownloadState(OfflineRegion.STATE_ACTIVE)
    }
    fun pause(id: Long) {
        handles[id]?.setDownloadState(OfflineRegion.STATE_INACTIVE)
        update(id) { it.copy(downloading=false) }
    }
    fun delete(id: Long) {
        val region=handles[id] ?: return
        if(mutable.value.regions.any { it.id==id && it.deleting }) return
        pause(id)
        region.setObserver(null)
        update(id) { it.copy(deleting=true) }
        region.delete(object : OfflineRegion.OfflineRegionDeleteCallback {
            override fun onDelete() {
                handles.remove(id)
                mutable.value=mutable.value.copy(regions=mutable.value.regions.filterNot { it.id==id })
            }
            override fun onError(error: String) {
                update(id) { it.copy(deleting=false,failed=true) }
                mutable.value=mutable.value.copy(error=true)
                if(clients>0) observe(region)
            }
        })
    }
    companion object {
        private var instance: OfflineMaps? = null
        fun get(context: Context): OfflineMaps {
            MapLibre.getInstance(context.applicationContext)
            return instance ?: OfflineMaps(context.applicationContext).also { instance=it }
        }
    }
}
