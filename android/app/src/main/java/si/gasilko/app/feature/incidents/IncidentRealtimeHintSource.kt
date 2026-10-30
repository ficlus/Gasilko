package si.gasilko.app.feature.incidents

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

/** Foreground refresh hints only. Never canonical data, authority or an acknowledgement.
 * Implementing a private SDK transport requires separate owner dependency approval. */
internal interface IncidentRealtimeHintSource {
    val available: Boolean
    fun hints(account: String,organization: String): Flow<Unit>
}
internal object UnsupportedIncidentRealtime : IncidentRealtimeHintSource {
    override val available=false
    override fun hints(account: String,organization: String): Flow<Unit> = emptyFlow()
}
