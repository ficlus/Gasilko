package si.gasilko.app.core.sync

import android.content.Context
import androidx.work.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import si.gasilko.app.core.auth.AuthFailure
import si.gasilko.app.core.auth.AuthMessage
import si.gasilko.app.core.auth.SupabaseAuthGateway
import si.gasilko.app.feature.hydrants.domain.*

/** Selection contains identifiers only; credentials remain in the existing SDK/Keystore adapter. */
class HydrantSyncScheduler(context: Context) {
    private val prefs = context.getSharedPreferences("hydrant_sync", Context.MODE_PRIVATE)
    private val work = WorkManager.getInstance(context.applicationContext)
    fun selected(account: String, organization: String) = prefs.getString("scope", null) == "$account/$organization"
    fun select(account: String?, organization: String?) {
        val scope = if(account != null && organization != null) "$account/$organization" else null
        if(prefs.getString("scope", null) != scope) {
            prefs.edit().putString("scope", scope).apply()
            work.cancelUniqueWork(NAME)
        }
    }
    fun enqueue(account: String, organization: String) {
        if(!selected(account, organization)) return
        val request = OneTimeWorkRequestBuilder<HydrantSyncWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setInputData(workDataOf("account" to account, "organization" to organization)).build()
        // Appending avoids losing a write queued while the current worker is finishing its drain.
        work.enqueueUniqueWork(NAME, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }
    companion object { private const val NAME = "hydrant-sync" }
}

class HydrantSyncWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val account = inputData.getString("account") ?: return Result.failure()
        val organization = inputData.getString("organization") ?: return Result.failure()
        if(!HydrantSyncScheduler(applicationContext).selected(account, organization)) return Result.success()
        val sessionScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val gateway = SupabaseAuthGateway.create(applicationContext, sessionScope)
        if(gateway == null) { sessionScope.cancel(); return Result.failure() }
        return try {
            gateway.synchronizeHydrants(applicationContext, account, organization)
            Result.success()
        } catch(e: CancellationException) { throw e }
        catch(e: RegistryFailure) {
            when(e.reason) {
                RegistryError.NETWORK, RegistryError.SERVER -> Result.retry()
                else -> Result.failure() // History remains; fresh authorization/manual action may reschedule.
            }
        } catch(e: AuthFailure) { if(e.reason == AuthMessage.ERROR) Result.retry() else Result.failure() }
        catch(_: Exception) { Result.failure() }
        finally { sessionScope.cancel(); gateway.close() }
    }
}
