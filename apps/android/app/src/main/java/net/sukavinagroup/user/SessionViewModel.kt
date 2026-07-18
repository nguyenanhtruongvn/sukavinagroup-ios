package net.sukavinagroup.user

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import net.sukavinagroup.user.data.*
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener

data class SessionUiState(
    val restoring: Boolean = true, val token: String? = null, val profile: Profile? = null,
    val dashboard: Dashboard? = null, val working: Boolean = false, val error: String? = null,
    val unreadCount: Int = 0,
)

class SessionViewModel(application: Application) : AndroidViewModel(application) {
    private val api = ApiClient()
    private val preferences = EncryptedSharedPreferences.create(
        application, "sukavina-secure-session",
        MasterKey.Builder(application).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )
    private val _state = MutableStateFlow(SessionUiState())
    val state = _state.asStateFlow()
    private var events: EventSource? = null
    private var knownArticles = preferences.getStringSet("known_articles", emptySet()).orEmpty()

    init { restore() }

    private fun restore() = viewModelScope.launch {
        val token = preferences.getString("token", null)
        if (token == null) return@launch update(restoring = false)
        runCatching { api.get<Profile>("auth/me", token) }
            .onSuccess { profile ->
                _state.value = _state.value.copy(restoring = false, token = token, profile = profile)
                refresh(); startEvents()
            }.onFailure { signOut() }
    }

    fun signIn(loginId: String, password: String) = viewModelScope.launch {
        update(working = true, error = null)
        runCatching { api.post<LoginResponse, LoginBody>("auth/login", LoginBody(loginId.trim(), password)) }
            .onSuccess { response ->
                preferences.edit().putString("token", response.accessToken).apply()
                _state.value = SessionUiState(
                    restoring = false, token = response.accessToken,
                    profile = Profile(employeeCode = response.user.employeeCode, name = response.user.name,
                        role = response.user.role, accountType = response.user.accountType,
                        permissions = response.user.permissions, protected = response.user.protected),
                )
                refresh(); startEvents()
            }.onFailure { update(working = false, error = it.message) }
    }

    fun refresh() = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        runCatching {
            val profile = api.get<Profile>("auth/me", token)
            val dashboard = api.get<Dashboard>("me/dashboard", token)
            profile to dashboard
        }.onSuccess { (profile, dashboard) ->
            val ids = dashboard.contentItems.map { it.id }.toSet()
            val unread = if (knownArticles.isEmpty()) 0 else (ids - knownArticles).size
            _state.value = _state.value.copy(profile = profile, dashboard = dashboard, working = false, unreadCount = unread, error = null)
            if (unread > 0) NotificationHelper.showArticleNotification(getApplication(), dashboard.contentItems.first().title, unread)
        }.onFailure { update(working = false, error = it.message) }
    }

    suspend fun attendance(month: String): Result<AttendanceMonth> {
        val token = _state.value.token ?: return Result.failure(ApiException("Phiên đăng nhập đã hết hạn"))
        return runCatching { api.get("me/attendance?month=$month", token) }
    }

    fun markArticlesRead() {
        knownArticles = _state.value.dashboard?.contentItems?.map { it.id }?.toSet().orEmpty()
        preferences.edit().putStringSet("known_articles", knownArticles).apply()
        update(unreadCount = 0)
        NotificationHelper.clear(getApplication())
    }

    fun deleteAccount(password: String) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        update(working = true, error = null)
        runCatching { api.delete<MessageResponse>("auth/me", DeleteAccountBody(password), token) }
            .onSuccess { signOut() }.onFailure { update(working = false, error = it.message) }
    }

    fun clearError() = update(error = null)
    fun signOut() {
        events?.cancel(); events = null
        preferences.edit().remove("token").apply()
        _state.value = SessionUiState(restoring = false)
    }

    private fun startEvents() {
        events?.cancel()
        events = api.events(object : EventSourceListener() {
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                if (data.contains("_changed")) refresh()
            }
            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                events = null
            }
        })
    }

    private fun update(
        restoring: Boolean = _state.value.restoring, working: Boolean = _state.value.working,
        error: String? = _state.value.error, unreadCount: Int = _state.value.unreadCount,
    ) { _state.value = _state.value.copy(restoring = restoring, working = working, error = error, unreadCount = unreadCount) }
}
