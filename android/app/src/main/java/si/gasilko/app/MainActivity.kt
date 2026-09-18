package si.gasilko.app
import android.os.Bundle
import android.content.Intent
import androidx.lifecycle.ViewModelProvider
import si.gasilko.app.feature.auth.AuthViewModel
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.MaterialTheme
import si.gasilko.app.feature.auth.AuthScreen
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge()
        if (savedInstanceState == null) intent.dataString?.let { ViewModelProvider(this)[AuthViewModel::class.java].googleCallback(it) }
        setContent { MaterialTheme { AuthScreen() } }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); intent.dataString?.let { ViewModelProvider(this)[AuthViewModel::class.java].googleCallback(it) } }
}
