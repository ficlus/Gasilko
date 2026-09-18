package si.gasilko.app.core.auth
import java.net.URI
import java.net.URLDecoder
object OAuthCallback {
    fun code(url: String, scheme: String): String? = try {
        val uri=URI(url)
        if(uri.scheme!=scheme || uri.host!="auth-callback" || uri.path !in listOf("","/") || uri.fragment!=null || uri.userInfo!=null || uri.port!=-1) null
        else {
            val pairs=(uri.rawQuery?:"").split("&").map { it.split("=",limit=2) }
            val codes=pairs.filter { it[0]=="code" }
            if(pairs.any{it[0]=="error"} || codes.size!=1 || codes[0].size!=2) null
            else URLDecoder.decode(codes[0][1],"UTF-8").takeIf { it.isNotBlank() && it.length<=4096 }
        }
    } catch (_: Exception) { null }
}
