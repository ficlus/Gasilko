package si.gasilko.app.core.security.deviceproof

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/** Strict wire-format helpers, not a nonce issuer, signature authority or server verifier. */
internal object DeviceProofEncoding {
    private val parameters: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").apply {init(ECGenParameterSpec("secp256r1"))}
            .getParameterSpec(ECParameterSpec::class.java)
    }
    // RFC5480 id-ecPublicKey + namedCurve prime256v1 + uncompressed point, exactly91 bytes.
    private val spkiPrefix="3059301306072a8648ce3d020106082a8648ce3d03010703420004"
        .chunked(2).map {it.toInt(16).toByte()}.toByteArray()
    fun sha256(bytes: ByteArray): String=crypto {
        proofRequire(bytes.size<=16_384)
        val hex="0123456789abcdef"
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {
            val n=it.toInt() and 255
            ""+hex[n ushr 4]+hex[n and 15]
        }
    }
    fun base64Url(bytes: ByteArray): String {
        proofRequire(bytes.size<=16_384)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }
    fun nonce(value: String): ByteArray {
        proofRequire(Regex("[A-Za-z0-9_-]{43}").matches(value),DeviceProofError.INVALID_ENCODING)
        val bytes=try {Base64.getUrlDecoder().decode(value)}
            catch(_: IllegalArgumentException){throw DeviceProofException(DeviceProofError.INVALID_ENCODING)}
        proofRequire(bytes.size==32 && base64Url(bytes)==value,DeviceProofError.INVALID_ENCODING)
        return bytes
    }
    fun publicKey(spkiDer: ByteArray): ECPublicKey=crypto {
        proofRequire(spkiDer.size==91,DeviceProofError.INVALID_ENCODING)
        val bytes=spkiDer.copyOf()
        proofRequire(bytes.take(spkiPrefix.size).toByteArray().contentEquals(spkiPrefix),DeviceProofError.INVALID_ENCODING)
        val key=KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(bytes)) as? ECPublicKey
            ?: throw DeviceProofException(DeviceProofError.INVALID_ENCODING)
        val p=parameters
        proofRequire(key.params.curve==p.curve && key.params.generator==p.generator &&
            key.params.order==p.order && key.params.cofactor==p.cofactor &&
            key.encoded.contentEquals(bytes),DeviceProofError.INVALID_ENCODING)
        val field=(p.curve.field as? ECFieldFp)?.p
            ?: throw DeviceProofException(DeviceProofError.CRYPTO_UNAVAILABLE)
        val x=key.w.affineX ?: throw DeviceProofException(DeviceProofError.INVALID_ENCODING)
        val y=key.w.affineY ?: throw DeviceProofException(DeviceProofError.INVALID_ENCODING)
        proofRequire(x.signum()>=0 && y.signum()>=0 &&
            x<field && y<field,DeviceProofError.INVALID_ENCODING)
        proofRequire(y.modPow(BigInteger.valueOf(2),field)==
            (x.modPow(BigInteger.valueOf(3),field)+p.curve.a*x+p.curve.b).mod(field),DeviceProofError.INVALID_ENCODING)
        key
    }
    /** JCA SHA256withECDSA DER -> WebCrypto/P1363 unsigned r[32] || s[32]. */
    fun derToRaw(signatureDer: ByteArray): ByteArray=crypto {
        proofRequire(signatureDer.size in 8..72,DeviceProofError.INVALID_ENCODING)
        val der=signatureDer.copyOf();var at=0
        fun octet(): Int {
            proofRequire(at<der.size,DeviceProofError.INVALID_ENCODING)
            return der[at++].toInt() and 255
        }
        proofRequire(octet()==0x30 && octet()==der.size-2,DeviceProofError.INVALID_ENCODING)
        fun scalar(): ByteArray {
            proofRequire(octet()==0x02,DeviceProofError.INVALID_ENCODING)
            val length=octet()
            proofRequire(length in 1..33 && at+length<=der.size,DeviceProofError.INVALID_ENCODING)
            val encoded=der.copyOfRange(at,at+length);at+=length
            proofRequire((encoded[0].toInt() and 128)==0,DeviceProofError.INVALID_ENCODING)
            if(length>1 && encoded[0]==0.toByte())
                proofRequire((encoded[1].toInt() and 128)!=0,DeviceProofError.INVALID_ENCODING)
            val value=BigInteger(1,encoded)
            proofRequire(value.signum()>0 && value<parameters.order,DeviceProofError.INVALID_ENCODING)
            val magnitude=if(encoded[0]==0.toByte())encoded.copyOfRange(1,encoded.size) else encoded
            proofRequire(magnitude.size<=32,DeviceProofError.INVALID_ENCODING)
            return ByteArray(32-magnitude.size)+magnitude
        }
        val raw=scalar()+scalar()
        proofRequire(at==der.size,DeviceProofError.INVALID_ENCODING)
        raw
    }
    fun rawToDer(signatureRaw: ByteArray): ByteArray=crypto {
        proofRequire(signatureRaw.size==64,DeviceProofError.INVALID_ENCODING)
        val raw=signatureRaw.copyOf()
        fun scalar(start: Int): ByteArray {
            val input=raw.copyOfRange(start,start+32)
            val value=BigInteger(1,input)
            proofRequire(value.signum()>0 && value<parameters.order,DeviceProofError.INVALID_ENCODING)
            // BigInteger supplies the minimal positive DER INTEGER, including sign padding.
            val bytes=value.toByteArray()
            return byteArrayOf(0x02,bytes.size.toByte())+bytes
        }
        val body=scalar(0)+scalar(32)
        byteArrayOf(0x30,body.size.toByte())+body
    }
    private inline fun <T> crypto(block: ()->T): T=try {block()}
        catch(e: DeviceProofException){throw e}
        catch(_: java.security.GeneralSecurityException){throw DeviceProofException(DeviceProofError.CRYPTO_UNAVAILABLE)}
        catch(_: java.security.ProviderException){throw DeviceProofException(DeviceProofError.CRYPTO_UNAVAILABLE)}
        catch(_: IllegalArgumentException){throw DeviceProofException(DeviceProofError.INVALID_ENCODING)}
}
