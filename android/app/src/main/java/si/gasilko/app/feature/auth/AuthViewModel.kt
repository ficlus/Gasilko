package si.gasilko.app.feature.auth

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch
import si.gasilko.app.core.auth.AuthRepository
import si.gasilko.app.core.auth.SupabaseAuthGateway

class AuthViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = AuthRepository(SupabaseAuthGateway.create(application, viewModelScope), viewModelScope)
    val state = repository.state
    fun refresh() { viewModelScope.launch { repository.refresh() } }
    fun signIn(email: String, password: String) { viewModelScope.launch { repository.signIn(email, password) } }
    fun signUp(email: String, password: String, name: String, language: String) { viewModelScope.launch { repository.signUp(email, password, name, language) } }
    fun signOut() { viewModelScope.launch { repository.signOut() } }
}
