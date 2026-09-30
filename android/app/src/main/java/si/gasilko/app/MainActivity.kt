package si.gasilko.app
import android.os.Bundle
import android.content.Intent
import androidx.lifecycle.ViewModelProvider
import si.gasilko.app.feature.auth.AuthViewModel
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import si.gasilko.app.core.ui.GasilkoTheme
import si.gasilko.app.feature.auth.AuthScreen
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge(
            statusBarStyle=SystemBarStyle.light(android.graphics.Color.TRANSPARENT,android.graphics.Color.TRANSPARENT),
            navigationBarStyle=SystemBarStyle.light(android.graphics.Color.TRANSPARENT,android.graphics.Color.TRANSPARENT))
        if (savedInstanceState == null) intent.dataString?.let { ViewModelProvider(this)[AuthViewModel::class.java].googleCallback(it) }
        setContent { GasilkoTheme { AuthScreen() } }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); intent.dataString?.let { ViewModelProvider(this)[AuthViewModel::class.java].googleCallback(it) } }
}
