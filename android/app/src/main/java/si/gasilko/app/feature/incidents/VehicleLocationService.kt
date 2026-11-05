package si.gasilko.app.feature.incidents

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.*
import android.os.*
import androidx.core.content.ContextCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import si.gasilko.app.R
import si.gasilko.app.core.security.deviceproof.*
import java.math.BigDecimal
import java.math.RoundingMode

/** One process-only collector. No coordinate survives STOP/process death. */
internal class VehicleLocationTicket(val repository: VehicleLocationRepository,val incident: String,val label: String,
    val session: JsonObject,val keys: LocalDeviceProofKeys,val credential: LocalDeviceCredential,val armedStop: JsonObject) {
    val nonce=newVehicleOperation()
    @Volatile var stopped=false
    var deadline=deadline(session)
    var sequence=session.text("acceptedSequence").toLongOrNull() ?: 0L
    fun current()=!stopped && VehicleLocationRuntime.active===this && repository.current() && SystemClock.elapsedRealtime()<deadline
    override fun toString()="VehicleLocationTicket(redacted)"
    companion object {
        fun deadline(value: JsonObject): Long {
            val server=java.time.OffsetDateTime.parse(value.text("serverTime")).toInstant().toEpochMilli()
            val expires=java.time.OffsetDateTime.parse(value.text("leaseExpiresAt")).toInstant().toEpochMilli()
            val trip=(SystemClock.elapsedRealtime()-(value.text("_requestStart").toLongOrNull() ?: 0)).coerceAtLeast(0)
            return SystemClock.elapsedRealtime()+(expires-server-trip).coerceIn(0,90000)
        }
    }
}
internal object VehicleLocationRuntime {
    @Volatile var active: VehicleLocationTicket?=null
    private val stoppedSessions=java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    fun stopped(session: String)=stoppedSessions.contains(session)
    private val pendingStops=java.util.concurrent.ConcurrentHashMap<String,JsonObject>()
    fun pendingFor(account: String)=pendingStops[account]
    fun restoreWithdrawal(original: JsonObject) {
        stoppedSessions.add(original.obj("args").text("session"))
        val account=original.text("account")
        val old=pendingStops.putIfAbsent(account,original)
        check(old==null || old==original) {"PENDING_WITHDRAWAL_EXISTS"}
        if(active==null)state.value="STOP_PENDING_SERVER"
    }
    fun acknowledge(account: String,operation: String) {
        val value=pendingStops[account]
        if(value?.text("operation")==operation)pendingStops.remove(account,value)
    }
    @Volatile var ownerScope: String?=null
    @Volatile var release: (() -> Unit)?=null
    private val epoch=java.util.concurrent.atomic.AtomicLong(0)
    val generation: Long get()=epoch.get()
    fun invalidateIdentity() {stopNow("LOGOUT");epoch.incrementAndGet()}
    val permissionRequest=MutableStateFlow<VehicleLocationTicket?>(null)
    val state=MutableStateFlow("STOPPED")
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    val withdrawals=Mutex()
    @Synchronized fun select(account: String?,org: String?) {
        val next=if(account!=null && org!=null)"$account/$org" else null
        if(ownerScope!=next)invalidateIdentity()
        ownerScope=next
    }
    @Synchronized fun begin(ticket: VehicleLocationTicket) {
        check(active==null && pendingFor(ticket.repository.account)==null && ownerScope==ticket.repository.account+"/"+ticket.repository.organization)
        check(ticket.repository.current() && SystemClock.elapsedRealtime()<ticket.deadline)
        active=ticket;state.value="ACQUIRING_FIX"
    }
    @Synchronized fun stopIfCurrent(ticket: VehicleLocationTicket,reason: String) {
        if(active===ticket)stopNow(reason)
    }
    /** Synchronous local denial comes before disk/network work. */
    @Synchronized fun stopNow(reason: String) {
        val old=active ?: return
        old.stopped=true;stoppedSessions.add(old.session.text("session"));old.repository.revokeLocal();permissionRequest.value=null
        val original=JsonObject(old.armedStop+("args" to buildJsonObject {put("session",old.session.text("session"));put("reason",reason)}))
        pendingStops.putIfAbsent(old.repository.account,original)
        active=null
        release?.invoke();release=null
        state.value="STOP_PENDING_SERVER"
        scope.launch {
            withdrawals.withLock {
                try {
                    if(pendingFor(old.repository.account)?.text("operation")!=original.text("operation"))return@withLock
                    old.repository.persistWithdrawal(original)
                    old.repository.flushStopLocked();if(active==null && pendingFor(old.repository.account)==null)state.value="STOPPED"
                } catch(e: CancellationException){throw e}
                catch(_: Exception){if(active==null)state.value="STOP_PENDING_SERVER"}
            }
        }
    }
}
class VehicleLocationService: Service(),LocationListener {
    private val jobs=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    private var ticket: VehicleLocationTicket?=null
    private var inFlight=false
    private lateinit var manager: LocationManager
    override fun onBind(intent: Intent?)=null
    override fun onCreate() {super.onCreate();manager=getSystemService(LocationManager::class.java)}
    override fun onStartCommand(intent: Intent?,flags: Int,startId: Int): Int {
        if(intent?.action=="STOP"){
            val original=VehicleLocationRuntime.active
            if(original!=null && intent.getStringExtra("nonce")==original.nonce)
                VehicleLocationRuntime.stopIfCurrent(original,"USER_STOP")
            if(ticket==null)stopSelf(startId)
            return START_NOT_STICKY // A delayed old notification must not stop a newer session/service.
        }
        val current=VehicleLocationRuntime.active
        if(current==null || intent?.getStringExtra("nonce")!=current.nonce || !current.current()) {
            if(ticket==null)stopSelf(startId)
            return START_NOT_STICKY
        }
        if(ticket!=null) {
            if(ticket!==current)VehicleLocationRuntime.stopIfCurrent(current,"ERROR")
            return START_NOT_STICKY
        }
        ticket=current
        VehicleLocationRuntime.release={
            runCatching {manager.removeUpdates(this)}
            jobs.cancel()
            stopForeground(STOP_FOREGROUND_REMOVE);stopSelf()
        }
        try {
            if(ContextCompat.checkSelfPermission(this,Manifest.permission.ACCESS_FINE_LOCATION)!=PackageManager.PERMISSION_GRANTED)
                throw SecurityException()
            if(Build.VERSION.SDK_INT>=33 && ContextCompat.checkSelfPermission(this,Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)
                throw SecurityException()
            if(!getSystemService(NotificationManager::class.java).areNotificationsEnabled())throw SecurityException()
            if(!manager.isProviderEnabled(LocationManager.GPS_PROVIDER))throw IllegalStateException()
            val channel=NotificationChannel("vehicle_location",getString(R.string.gps_title),NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
            if(getSystemService(NotificationManager::class.java).getNotificationChannel("vehicle_location").importance==NotificationManager.IMPORTANCE_NONE)
                throw SecurityException()
            val stop=PendingIntent.getService(this,0,Intent(this,VehicleLocationService::class.java).setAction("STOP")
                .setData(android.net.Uri.parse("gasilko-vehicle-stop:"+current.nonce)).putExtra("nonce",current.nonce),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val notification=Notification.Builder(this,"vehicle_location").setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setContentTitle(getString(R.string.gps_sharing_vehicle,current.label))
                .setContentText(getString(R.string.gps_notification)).setOngoing(true).setVisibility(Notification.VISIBILITY_PRIVATE)
                .addAction(Notification.Action.Builder(null,getString(R.string.gps_stop),stop).build()).build()
            if(Build.VERSION.SDK_INT>=29)startForeground(7401,notification,ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            else startForeground(7401,notification)
            VehicleLocationRuntime.state.value="ACQUIRING_FIX"
            manager.requestLocationUpdates(LocationManager.GPS_PROVIDER,
                (current.session.text("intervalSeconds").toLong().coerceIn(20,120))*1000,current.session.text("movementMetres").toFloat(),this,Looper.getMainLooper())
            jobs.launch {
                while(isActive) {
                    delay(1000)
                    if(!current.current() || ContextCompat.checkSelfPermission(this@VehicleLocationService,Manifest.permission.ACCESS_FINE_LOCATION)!=PackageManager.PERMISSION_GRANTED ||
                        !getSystemService(NotificationManager::class.java).areNotificationsEnabled() ||
                        (getSystemService(NotificationManager::class.java).getNotificationChannel("vehicle_location")?.importance ?: NotificationManager.IMPORTANCE_NONE)==NotificationManager.IMPORTANCE_NONE ||
                        (Build.VERSION.SDK_INT>=33 && ContextCompat.checkSelfPermission(this@VehicleLocationService,Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)) {
                        VehicleLocationRuntime.stopIfCurrent(current,"PERMISSION_REVOKED");break
                    }
                }
            }
            jobs.launch {
                while(isActive && current.current()) {
                    delay(current.session.text("intervalSeconds").toLong().coerceIn(20,120)*1000)
                    try {
                        val renewed=current.repository.request("renew",current.incident,newVehicleOperation(),buildJsonObject {put("session",current.session.text("session"))})
                        if(current.current())current.deadline=VehicleLocationTicket.deadline(renewed)
                    } catch(e: CancellationException){throw e}
                    catch(e: VehicleLocationFailure) {
                        if(e.code !in listOf("BACKEND_UNAVAILABLE","OUTCOME_UNKNOWN","RATE_LIMITED"))VehicleLocationRuntime.stopIfCurrent(current,"ERROR")
                        else if(current.current())VehicleLocationRuntime.state.value="OFFLINE"
                    } catch(_: Exception){if(current.current())VehicleLocationRuntime.state.value="OFFLINE"}
                }
            }
        } catch(_: SecurityException){VehicleLocationRuntime.stopIfCurrent(current,"PERMISSION_REVOKED")}
        catch(_: Exception){VehicleLocationRuntime.stopIfCurrent(current,"ERROR")}
        return START_NOT_STICKY
    }
    override fun onLocationChanged(location: Location) {
        val t=ticket ?: return
        if(!t.current() || inFlight)return
        val age=SystemClock.elapsedRealtimeNanos()-location.elapsedRealtimeNanos
        val mock=if(Build.VERSION.SDK_INT>=31)location.isMock else @Suppress("DEPRECATION") location.isFromMockProvider
        val accuracy=location.accuracy
        if(location.provider!=LocationManager.GPS_PROVIDER || mock || age !in 0..20_000_000_000L || !location.hasAccuracy() ||
            !accuracy.isFinite() || accuracy<=0f || accuracy*100>t.session.text("accuracyCm").toInt() ||
            !location.latitude.isFinite() || !location.longitude.isFinite() || location.latitude !in -90.0..90.0 || location.longitude !in -180.0..180.0) {
            VehicleLocationRuntime.state.value="POOR_ACCURACY";return
        }
        val lat=BigDecimal.valueOf(location.latitude).movePointRight(7).setScale(0,RoundingMode.HALF_UP).toPlainString()
        val lon=BigDecimal.valueOf(location.longitude).movePointRight(7).setScale(0,RoundingMode.HALF_UP).toPlainString()
        if(t.sequence==Long.MAX_VALUE){VehicleLocationRuntime.stopIfCurrent(t,"ERROR");return}
        val sequence=++t.sequence
        val sample=DeviceLocationSampleV1(listOf(DeviceLocationSampleV1.sampleId(t.session.text("session"),sequence),t.session.text("session"),t.repository.account,t.repository.organization,
            t.incident,t.session.text("deployment"),t.session.text("vehicle"),t.credential.id,t.session.text("generation"),
            t.session.text("policyVersion"),t.session.text("bindingGeneration"),sequence.toString(),location.time.toString(),lat,lon,
            kotlin.math.ceil(accuracy.toDouble()*100).toInt().coerceAtLeast(1).toString(),"ANDROID_REAL_GNSS",t.session.text("context")))
        inFlight=true
        jobs.launch {
            try {
                val signature=t.keys.signLocationSample(t.credential,sample)
                if(t.current()) {
                    t.repository.request("sample",t.incident,sample.fields[0],buildJsonObject {put("sample",sample.json());put("signature",signature.vehicleHex())})
                    if(t.current())VehicleLocationRuntime.state.value="SHARING"
                }
            } catch(e: CancellationException){throw e}
            catch(e: VehicleLocationFailure) {
                if(!t.current())return@launch
                if(e.code=="INVALID_LOCATION")VehicleLocationRuntime.state.value="POOR_ACCURACY"
                else if(e.code=="RATE_LIMITED")VehicleLocationRuntime.state.value="RATE_LIMITED"
                else if(e.code in listOf("BACKEND_UNAVAILABLE","OUTCOME_UNKNOWN"))VehicleLocationRuntime.state.value="OFFLINE"
                else VehicleLocationRuntime.stopIfCurrent(t,"ERROR")
            } catch(_: Exception){VehicleLocationRuntime.stopIfCurrent(t,"ERROR")}
            finally {inFlight=false} // Drop unknown samples; NEVER enqueue/replay a trip.
        }
    }
    override fun onProviderDisabled(provider: String) {if(provider==LocationManager.GPS_PROVIDER)ticket?.let {VehicleLocationRuntime.stopIfCurrent(it,"ERROR")}}
    override fun onProviderEnabled(provider: String) {}
    @Deprecated("Legacy platform callback") override fun onStatusChanged(provider: String?,status: Int,extras: Bundle?) {}
    override fun onDestroy() {
        runCatching {manager.removeUpdates(this)}
        jobs.cancel()
        ticket?.let {VehicleLocationRuntime.stopIfCurrent(it,"ERROR")}
        ticket=null;super.onDestroy()
    }
}
