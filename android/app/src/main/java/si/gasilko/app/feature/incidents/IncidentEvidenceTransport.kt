package si.gasilko.app.feature.incidents

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import si.gasilko.app.BuildConfig
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import java.io.ByteArrayOutputStream

internal class EvidenceFailure(val code: String,val status: Int): Exception(code)
/** Existing platform HTTPS + session, not another SDK/client/credential store.
 * Downloads are online-only, bounded memory, no signed URL/cache persistence. */
internal suspend fun evidenceRequest(client: SupabaseClient,body: JsonObject): ByteArray {
    val token=client.auth.currentSessionOrNull()?.accessToken ?: throw EvidenceFailure("EXPIRED",401)
    return withContext(Dispatchers.IO) {
        val connection=URL(BuildConfig.SUPABASE_URL.trimEnd('/')+"/functions/v1/incident-evidence").openConnection() as HttpsURLConnection
        connection.requestMethod="POST";connection.connectTimeout=20_000;connection.readTimeout=100_000
        connection.instanceFollowRedirects=false;connection.useCaches=false;connection.doOutput=true
        connection.setRequestProperty("Authorization","Bearer "+token)
        connection.setRequestProperty("apikey",BuildConfig.SUPABASE_PUBLISHABLE_KEY)
        connection.setRequestProperty("Content-Type","application/json")
        val bytes=body.toString().toByteArray();connection.setFixedLengthStreamingMode(bytes.size)
        try {
            connection.outputStream.use { it.write(bytes) }
            currentCoroutineContext().ensureActive()
            val status=connection.responseCode
            val output=ByteArrayOutputStream()
            (if(status in 200..299)connection.inputStream else connection.errorStream)?.use { input ->
                val buffer=ByteArray(8192);val cap=if(status in 200..299)EVIDENCE_MAX else 8192
                while(true){currentCoroutineContext().ensureActive();val n=input.read(buffer);if(n<0)break
                    require(output.size()+n<=cap);output.write(buffer,0,n)}
            }
            if(status !in 200..299) {
                val code=runCatching { parse(output.toString("UTF-8")).text("error") }.getOrDefault("STORAGE_TEMPORARILY_UNAVAILABLE")
                throw EvidenceFailure(code,status)
            }
            output.toByteArray()
        } finally { connection.disconnect() }
    }
}
