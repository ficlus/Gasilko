package si.gasilko.app.core.security.deviceproof

import kotlinx.serialization.json.*

/**20 lines, UTF-8 ASCII LF, exactly one trailing LF. E7 is precision, not accuracy. */
internal class DeviceLocationSampleV1(fields: List<String>) {
    val fields: List<String> = java.util.Collections.unmodifiableList(ArrayList(fields))
    init {
        proofRequire(fields.size==18)
        fields.take(8).forEach(::proofUuid)
        listOf(8,10,11,12).forEach {i->
            proofRequire(Regex("[1-9][0-9]{0,18}").matches(fields[i]) && fields[i].toLongOrNull()?.let {it>0}==true)
        }
        listOf(13 to 900000000L,14 to 1800000000L).forEach {(i,max)->
            proofRequire(Regex("0|-?[1-9][0-9]*").matches(fields[i]) && fields[i].toLongOrNull()?.let {it in -max..max}==true)
        }
        proofRequire(Regex("[A-Za-z0-9._-]{1,64}").matches(fields[9]))
        proofRequire(fields[15].toIntOrNull()?.let {it in 1..10000}==true && Regex("[1-9][0-9]*").matches(fields[15]))
        proofRequire(fields[16]=="ANDROID_REAL_GNSS" && Regex("[A-Za-z0-9_-]{43}").matches(fields[17]))
    }
    fun bytes()=(listOf("GASILKO-REAL-VEHICLE-LOCATION-SAMPLE-V1","1")+fields).joinToString("\n",postfix="\n").toByteArray(Charsets.UTF_8)
    fun json()=buildJsonObject {keys.zip(fields).forEach {(k,v)->put(k,v)}}
    override fun toString()="DeviceLocationSampleV1(redacted)"
    companion object {
        fun sampleId(session: String,sequence: Long): String {
            proofUuid(session);proofRequire(sequence>0)
            val bytes=java.security.MessageDigest.getInstance("SHA-256").digest(
                ("GASILKO-REAL-VEHICLE-SAMPLE-ID-V1\n"+session+"\n"+sequence+"\n").toByteArray(Charsets.UTF_8))
            bytes[6]=((bytes[6].toInt() and 15) or 128).toByte()
            bytes[8]=((bytes[8].toInt() and 63) or 128).toByte()
            val buffer=java.nio.ByteBuffer.wrap(bytes.copyOfRange(0,16))
            return java.util.UUID(buffer.long,buffer.long).toString()
        }
        val keys=listOf("sampleId","sessionId","account","organization","incident","deployment","vehicle","credentialId",
            "generation","policyVersion","bindingGeneration","sequence","observedAtMillis","latitudeE7","longitudeE7","accuracyCm","source","sessionContext")
    }
}
