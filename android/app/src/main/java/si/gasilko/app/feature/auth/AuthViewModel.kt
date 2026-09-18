package si.gasilko.app.feature.auth

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch
import si.gasilko.app.core.auth.AuthRepository
import si.gasilko.app.core.auth.SupabaseAuthGateway

class AuthViewModel(application: Application) : AndroidViewModel(application) {
    private val gateway = SupabaseAuthGateway.create(application, viewModelScope)
    private val repository = AuthRepository(gateway, viewModelScope)
    override fun onCleared() { gateway?.close(); super.onCleared() }
    val access = si.gasilko.app.core.access.AccessRepository(gateway?.accessGateway())
    fun google() { viewModelScope.launch { repository.google() } }
    fun googleCallback(url: String) { viewModelScope.launch { repository.googleCallback(si.gasilko.app.core.auth.OAuthCallback.code(url, si.gasilko.app.BuildConfig.AUTH_REDIRECT_SCHEME)) } }
    val state = repository.state
    fun refresh() { viewModelScope.launch { repository.refresh() } }
    fun signIn(email: String, password: String) { viewModelScope.launch { repository.signIn(email, password) } }
    fun signUp(email: String, password: String, name: String, language: String) { viewModelScope.launch { repository.signUp(email, password, name, language) } }
    fun signOut() { viewModelScope.launch { repository.signOut() } }
}
