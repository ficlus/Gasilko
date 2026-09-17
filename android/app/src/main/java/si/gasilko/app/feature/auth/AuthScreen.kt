package si.gasilko.app.feature.auth

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import si.gasilko.app.R
import si.gasilko.app.core.auth.*

@Composable
fun AuthScreen(model: AuthViewModel = viewModel()) {
    val state by model.state.collectAsStateWithLifecycle()
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { model.refresh() }
    AuthContent(state, model::signIn, model::signUp, model::refresh, model::signOut)
}
@Composable
fun AuthContent(state: AuthState, signIn: (String,String)->Unit, signUp: (String,String,String,String)->Unit, refresh: ()->Unit, signOut: ()->Unit) {
    Scaffold { padding -> Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineMedium)
        when (state.route) {
            AuthRoute.LOADING -> { CircularProgressIndicator(); Text(stringResource(R.string.auth_loading)) }
            AuthRoute.UNAUTHENTICATED -> {
                var signup by remember { mutableStateOf(false) }; var email by remember { mutableStateOf("") }
                // Passwords are ephemeral Compose state, never SavedStateHandle/rememberSaveable/disk.
                var password by remember { mutableStateOf("") }; var name by remember { mutableStateOf("") }; var language by remember { mutableStateOf("sl") }
                Text(stringResource(if (signup) R.string.auth_sign_up else R.string.auth_sign_in))
                OutlinedTextField(email, { email = it }, label = { Text(stringResource(R.string.auth_email)) }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email))
                OutlinedTextField(password, { password = it }, label = { Text(stringResource(R.string.auth_password)) }, singleLine = true, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                if (signup) {
                    OutlinedTextField(name, { name = it.take(120) }, label = { Text(stringResource(R.string.auth_display_name)) }, singleLine = true)
                    Text(stringResource(R.string.auth_language))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(selected = language == "sl", onClick = { language = "sl" }, label = { Text(stringResource(R.string.auth_slovenian)) })
                        FilterChip(selected = language == "de", onClick = { language = "de" }, label = { Text(stringResource(R.string.auth_german)) })
                    }
                }
                Button(enabled = email.isNotBlank() && password.isNotEmpty() && (!signup || name.isNotBlank()), onClick = {
                    if (signup) signUp(email, password, name, language) else signIn(email, password)
                    password = ""
                }) { Text(stringResource(if (signup) R.string.auth_sign_up else R.string.auth_sign_in)) }
                TextButton(onClick = { signup = !signup; password = "" }) { Text(stringResource(if (signup) R.string.auth_sign_in else R.string.auth_sign_up)) }
            }
            else -> {
                val text = when (state.route) {
                    AuthRoute.ACTIVE -> R.string.auth_active
                    AuthRoute.PENDING_APPROVAL -> R.string.auth_pending
                    AuthRoute.SUSPENDED -> R.string.auth_suspended
                    AuthRoute.REJECTED -> R.string.auth_rejected
                    else -> R.string.auth_profile_unavailable
                }
                Text(stringResource(text))
                if (state.route == AuthRoute.ACTIVE) Text(stringResource(R.string.auth_authorization_notice))
                if (state.message != AuthMessage.CONFIGURATION) {
                    Button(onClick = refresh) { Text(stringResource(R.string.auth_refresh_status)) }
                    TextButton(onClick = signOut) { Text(stringResource(R.string.auth_sign_out)) }
                }
            }
        }
        if (state.message != AuthMessage.NONE) Text(stringResource(when (state.message) {
            AuthMessage.INVALID_CREDENTIALS -> R.string.auth_invalid_credentials
            AuthMessage.CONFIRM_EMAIL -> R.string.auth_confirm_email
            AuthMessage.SIGNUP_NOTICE -> R.string.auth_signup_notice
            AuthMessage.WEAK_PASSWORD -> R.string.auth_weak_password
            AuthMessage.PROFILE_UNAVAILABLE -> R.string.auth_profile_unavailable
            AuthMessage.EXPIRED -> R.string.auth_session_expired
            AuthMessage.CONFIGURATION -> R.string.auth_configuration
            else -> R.string.auth_auth_error
        }))
    } }
}
