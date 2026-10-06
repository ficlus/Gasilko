package si.gasilko.app.core.notifications

import android.app.*
import android.content.*
import android.os.Build
import androidx.work.*
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.*
import si.gasilko.app.BuildConfig
import si.gasilko.app.MainActivity
import si.gasilko.app.R
import si.gasilko.app.core.auth.SupabaseAuthGateway
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Identifiers only. Tokens are managed by FCM; Supabase credentials retain the existing Keystore storage. */
object NotificationInstallation {
    private fun prefs(c: Context)=c.getSharedPreferences("notification-installation",Context.MODE_PRIVATE)
    @Synchronized fun id(c: Context): String=prefs(c).getString("id",null) ?: UUID.randomUUID().toString().also { prefs(c).edit().putString("id",it).commit() }
    fun account(c: Context)=prefs(c).getString("account",null)
    fun select(c: Context,account: String?) {
        if(NotificationInstallation.account(c)!=account) {
            c.getSystemService(NotificationManager::class.java).cancelAll()
            WorkManager.getInstance(c).cancelUniqueWork("notification-registration")
            prefs(c).edit().putString("account",account).commit()
        }
        if(account!=null)enqueue(c)
    }
    fun enqueue(c: Context) {
        val account=account(c) ?: return
        WorkManager.getInstance(c).enqueueUniqueWork("notification-registration",ExistingWorkPolicy.APPEND_OR_REPLACE,
            OneTimeWorkRequestBuilder<NotificationRegistrationWorker>()
                .setInputData(workDataOf("account" to account))
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL,30,TimeUnit.SECONDS).build())
    }
    fun firebase(c: Context): Boolean {
        if(BuildConfig.FIREBASE_APPLICATION_ID.isBlank() || BuildConfig.FIREBASE_PROJECT_ID.isBlank() ||
            BuildConfig.FIREBASE_SENDER_ID.isBlank() || BuildConfig.FIREBASE_API_KEY.isBlank())return false
        synchronized(this) {
            if(FirebaseApp.getApps(c).isEmpty())FirebaseApp.initializeApp(c,FirebaseOptions.Builder()
                .setApplicationId(BuildConfig.FIREBASE_APPLICATION_ID).setProjectId(BuildConfig.FIREBASE_PROJECT_ID)
                .setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID).setApiKey(BuildConfig.FIREBASE_API_KEY).build())
        }
        return true
    }
    fun channels(c: Context) {
        val manager=c.getSystemService(NotificationManager::class.java)
        listOf("ASSIGNMENT" to R.string.notifications_assignment,"ACTIVATION" to R.string.notifications_activation,
            "HYDRANT" to R.string.notifications_hydrant).forEach { (id,label)->
            manager.createNotificationChannel(NotificationChannel(id,c.getString(label),NotificationManager.IMPORTANCE_DEFAULT).apply {
                lockscreenVisibility=Notification.VISIBILITY_PRIVATE
                description=c.getString(R.string.notifications_privacy)
            })
        }
    }
}
class GasilkoApplication: Application() {
    override fun onCreate() { super.onCreate();NotificationInstallation.channels(this);NotificationInstallation.firebase(this) }
}
class NotificationRepository(private val client: SupabaseClient,private val context: Context) {
    suspend fun preferences(changes: Map<String,Boolean> = emptyMap()): Map<String,Boolean> {
        client.auth.awaitInitialization()
        val expected=client.auth.currentUserOrNull()?.id ?: error("SESSION")
        val value=client.postgrest.rpc("notification_preferences",buildJsonObject {
            put("request",buildJsonObject { changes.forEach { (key,value)->put(key,value) } })
        }).decodeAs<JsonObject>()
        check(client.auth.currentUserOrNull()?.id==expected)
        return value.mapValues { it.value.jsonPrimitive.boolean }
    }
    suspend fun register(expected: String) {
        client.auth.awaitInitialization()
        if(client.auth.currentUserOrNull()?.id!=expected || NotificationInstallation.account(context)!=expected)return
        if(!NotificationInstallation.firebase(context))return
        val messaging=FirebaseMessaging.getInstance();messaging.isAutoInitEnabled=true
        val token=suspendCancellableCoroutine<String> { continuation ->
            messaging.token.addOnCompleteListener { result -> if(continuation.isActive) {
                if(result.isSuccessful)continuation.resume(result.result) else continuation.resumeWithException(result.exception ?: IllegalStateException("TOKEN"))
            } }
        }
        if(client.auth.currentUserOrNull()?.id!=expected || NotificationInstallation.account(context)!=expected)return
        client.postgrest.rpc("register_notification_device",buildJsonObject {
            put("installation",NotificationInstallation.id(context));put("token",token);put("enabled",true)
        })
    }
    suspend fun detach() {
        NotificationInstallation.select(context,null)
        if(NotificationInstallation.firebase(context)) { FirebaseMessaging.getInstance().isAutoInitEnabled=false;FirebaseMessaging.getInstance().deleteToken() }
        try { withTimeout(5000) { client.postgrest.rpc("register_notification_device",buildJsonObject {
            put("installation",NotificationInstallation.id(context));put("token","");put("enabled",false)
        }) } } catch(e: CancellationException) { if(e !is TimeoutCancellationException)throw e } catch(_: Exception) { /* Local account gate drops stale delivery while offline. */ }
    }
}
class NotificationRegistrationWorker(c: Context,p: WorkerParameters): CoroutineWorker(c,p) {
    override suspend fun doWork(): Result {
        val account=inputData.getString("account") ?: return Result.failure()
        if(NotificationInstallation.account(applicationContext)!=account)return Result.success()
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
        val gateway=SupabaseAuthGateway.create(applicationContext,scope) ?: return Result.failure().also { scope.cancel() }
        return try { gateway.notifications(applicationContext).register(account);Result.success() }
        catch(e: CancellationException) { throw e }
        catch(_: Exception) { if(runAttemptCount<4)Result.retry() else Result.failure() }
        finally { gateway.close();scope.cancel() }
    }
}
data class NotificationDestination(val account: String,val organization: String,val entity: String,val kind: String,val event: String)
object NotificationTap {
    private val mutable=MutableStateFlow<NotificationDestination?>(null)
    val pending=mutable.asStateFlow()
    fun read(data: Map<String,String>): NotificationDestination? {
        fun id(key: String)=data[key]?.takeIf { runCatching { UUID.fromString(it).toString()==it }.getOrDefault(false) }
        val kind=data["entity_type"]?.takeIf { it in listOf("PLAN","HYDRANT") } ?: return null
        return NotificationDestination(id("account")?:return null,id("organization")?:return null,id("entity")?:return null,kind,id("event")?:return null)
    }
    fun accept(intent: Intent) { read(listOf("account","organization","entity","entity_type","event").associateWith { intent.getStringExtra("notification_$it").orEmpty() })?.let { mutable.value=it } }
    fun clear() { mutable.value=null }
}
class GasilkoMessagingService: FirebaseMessagingService() {
    override fun onNewToken(token: String) { NotificationInstallation.enqueue(this) }
    override fun onMessageReceived(message: RemoteMessage) {
        val destination=NotificationTap.read(message.data) ?: return
        if(NotificationInstallation.account(this)!=destination.account)return
        val category=message.data["category"]?.takeIf { it in listOf("ASSIGNMENT","ACTIVATION","HYDRANT") } ?: return
        val manager=getSystemService(NotificationManager::class.java)
        if(!manager.areNotificationsEnabled())return
        if(Build.VERSION.SDK_INT>=33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)!=android.content.pm.PackageManager.PERMISSION_GRANTED)return
        NotificationInstallation.channels(this)
        val intent=Intent(this,MainActivity::class.java).setAction("notification/"+destination.event)
        message.data.forEach { (k,v)->if(k in listOf("account","organization","entity","entity_type","event"))intent.putExtra("notification_$k",v) }
        val tap=PendingIntent.getActivity(this,0,intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val label=when(message.data["type"]) {
            "PLAN_ASSIGNED","PLAN_REASSIGNED"->R.string.notifications_assignment
            "PLAN_ACTIVATED"->R.string.notifications_activation
            "HYDRANT_NEEDS_ATTENTION","HYDRANT_NOT_WORKING"->R.string.notifications_hydrant
            else->R.string.notifications_title
        }
        val notification=Notification.Builder(this,category).setSmallIcon(R.drawable.ic_field_refresh)
            .setContentTitle(getString(label)).setContentText(getString(R.string.notifications_update))
            .setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true).setContentIntent(tap).build()
        manager.notify(destination.event,0,notification)
    }
}
