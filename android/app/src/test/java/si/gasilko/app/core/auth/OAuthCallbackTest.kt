package si.gasilko.app.core.auth
import org.junit.Assert.*
import org.junit.Test
class OAuthCallbackTest {
 @Test fun validCodeAccepted(){assertEquals("fixture-code",OAuthCallback.code("si.gasilko.app://auth-callback?code=fixture-code","si.gasilko.app"))}
 @Test fun wrongSchemeRejected(){assertNull(OAuthCallback.code("https://auth-callback?code=fixture","si.gasilko.app"))}
 @Test fun wrongHostRejected(){assertNull(OAuthCallback.code("si.gasilko.app://attacker?code=fixture","si.gasilko.app"))}
 @Test fun implicitTokensRejected(){assertNull(OAuthCallback.code("si.gasilko.app://auth-callback#access_token=fixture","si.gasilko.app"))}
 @Test fun providerErrorRejected(){assertNull(OAuthCallback.code("si.gasilko.app://auth-callback?error=access_denied","si.gasilko.app"))}
 @Test fun duplicateCodeRejected(){assertNull(OAuthCallback.code("si.gasilko.app://auth-callback?code=a&code=b","si.gasilko.app"))}
 @Test fun unrelatedPathRejected(){assertNull(OAuthCallback.code("si.gasilko.app://auth-callback/admin?code=a","si.gasilko.app"))}
 @Test fun malformedLinkRejected(){assertNull(OAuthCallback.code("not a uri","si.gasilko.app"))}
}
