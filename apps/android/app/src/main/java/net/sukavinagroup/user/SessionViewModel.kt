package net.sukavinagroup.user

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import net.sukavinagroup.user.data.*
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener

data class SessionUiState(
    val restoring: Boolean = true, val token: String? = null, val profile: Profile? = null,
    val dashboard: Dashboard? = null, val working: Boolean = false, val error: String? = null,
    val unreadCount: Int = 0, val requests: List<EmployeeRequest> = emptyList(),
    val approvals: List<EmployeeRequest> = emptyList(),
    val requestNotifications: List<RequestNotification> = emptyList(),
    val biometricEnabled: Boolean = false,
    val hiddenArticleIds: Set<String> = emptySet(),
    val todayMenu: TodayMenu? = null,
)

class SessionViewModel(application: Application) : AndroidViewModel(application) {
    private enum class RefreshResult { SUCCESS, UNAUTHORIZED, DEFERRED }

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
    private var sessionRefreshJob: Job? = null
    private var knownArticles = preferences.getStringSet("known_articles", emptySet()).orEmpty()
    private var hiddenArticles = preferences.getStringSet("hidden_notification_articles", emptySet()).orEmpty()

    init {
        _state.value = _state.value.copy(biometricEnabled = preferences.getBoolean("biometric_enabled", false), hiddenArticleIds = hiddenArticles)
        restore()
    }

    private fun restore() = viewModelScope.launch {
        val token = preferences.getString("token", null)
        if (token == null) return@launch update(restoring = false)
        _state.value = _state.value.copy(restoring = false, token = token)
        runCatching {
            val profile = api.get<Profile>("auth/me", token)
            if (preferences.getString("refresh_token", null).isNullOrBlank() ||
                preferences.getString("widget_token", null).isNullOrBlank()
            ) {
                val upgraded = api.post<LoginResponse, EmptyBody>("auth/session/upgrade", EmptyBody(), token)
                saveSession(upgraded)
                _state.value = _state.value.copy(token = upgraded.accessToken)
            }
            profile
        }
            .onSuccess { profile ->
                _state.value = _state.value.copy(profile = profile, error = null)
                startAccountServices()
            }.onFailure { error ->
                if ((error as? ApiException)?.statusCode in listOf(401, 403)) {
                    viewModelScope.launch {
                        when (refreshSession()) {
                            RefreshResult.SUCCESS -> {
                                startAccountServices()
                            }
                            RefreshResult.UNAUTHORIZED -> signOut()
                            RefreshResult.DEFERRED -> {
                                update(restoring = false, error = "Không thể kết nối đến máy chủ. Hãy kiểm tra Wi-Fi hoặc dữ liệu di động rồi thử lại.")
                                startSessionRefresh()
                            }
                        }
                    }
                } else {
                    update(restoring = false, error = error.message)
                    startEvents()
                    startSessionRefresh()
                }
            }
    }

    fun signIn(loginId: String, password: String) = viewModelScope.launch {
        update(working = true, error = null)
        runCatching { api.post<LoginResponse, LoginBody>("auth/login", LoginBody(loginId.trim(), password)) }
            .onSuccess { response ->
                saveSession(response)
                preferences.edit().putString("last_login", loginId.trim()).apply()
                _state.value = SessionUiState(
                    restoring = false, token = response.accessToken,
                    profile = Profile(employeeCode = response.user.employeeCode, name = response.user.name,
                        role = response.user.role, accountType = response.user.accountType,
                        permissions = response.user.permissions, protected = response.user.protected),
                )
                startAccountServices()
            }.onFailure { error ->
                val message = if (
                    error is ApiException &&
                    error.statusCode in listOf(401, 403) &&
                    error.message == "Invalid credentials"
                ) {
                    "Mã nhân viên, số điện thoại hoặc mật khẩu không chính xác."
                } else {
                    error.message ?: "Đăng nhập không thành công. Vui lòng thử lại."
                }
                update(working = false, error = message)
            }
    }

    fun dismissError() {
        update(error = null)
    }

    fun refresh() = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        runCatching {
            val profile = api.get<Profile>("auth/me", token)
            val dashboard = api.get<Dashboard>("me/dashboard", token)
            profile to dashboard
        }.onSuccess { (profile, dashboard) ->
            notifyNewAttendance(dashboard)
            val ids = dashboard.contentItems.map { it.id }.toSet()
            val unread = if (knownArticles.isEmpty()) 0 else (ids - knownArticles).size
            _state.value = _state.value.copy(profile = profile, dashboard = dashboard, working = false, unreadCount = unread, error = null)
            AttendanceWidgetStore.update(getApplication(), dashboard)
            if (unread > 0) NotificationHelper.showArticleNotification(getApplication(), dashboard.contentItems.first().title, unread)
        }.onFailure { update(working = false, error = it.message) }
    }

    private fun notifyNewAttendance(dashboard: Dashboard) {
        val employeeCode = dashboard.employeeCode.ifBlank { _state.value.profile?.employeeCode.orEmpty() }
        val preferenceKey = "known_attendance_record_ids_$employeeCode"
        val currentIds = dashboard.attendanceRecords.map { it.id }.toSet()
        val hasBaseline = preferences.contains(preferenceKey)
        val knownIds = preferences.getStringSet(preferenceKey, emptySet()).orEmpty()

        if (hasBaseline) {
            val newRecord = dashboard.attendanceRecords
                .filterNot { it.id in knownIds }
                .maxByOrNull { it.punchedAt }
            if (newRecord != null) {
                val ordered = dashboard.attendanceRecords.sortedBy { it.punchedAt }
                val isCheckIn = (ordered.indexOfFirst { it.id == newRecord.id } + 1) % 2 == 1
                val time = runCatching {
                    java.time.OffsetDateTime.parse(newRecord.punchedAt)
                        .atZoneSameInstant(java.time.ZoneId.systemDefault())
                        .format(java.time.format.DateTimeFormatter.ofPattern("HH:mm"))
                }.getOrElse {
                    newRecord.punchedAt.substringAfter('T').take(5).ifBlank { "vừa xong" }
                }
                NotificationHelper.showAttendanceNotification(getApplication(), isCheckIn, time)
            }
        }

        preferences.edit().putStringSet(preferenceKey, currentIds).apply()
    }

    fun refreshTodayMenu() = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        runCatching { api.get<TodayMenu>("me/menu", token) }
            .onSuccess { _state.value = _state.value.copy(todayMenu = it) }
            .onFailure { update(error = it.message) }
    }

    fun selectMeal(choice: String) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        update(working = true, error = null)
        runCatching { api.patch<TodayMenu, MealSelectionBody>("me/menu/selection", MealSelectionBody(choice), token) }
            .onSuccess { _state.value = _state.value.copy(todayMenu = it, working = false) }
            .onFailure { update(working = false, error = it.message) }
    }

    fun issueMealQr(done: (MealQrIssueResponse?) -> Unit) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch done(null)
        update(working = true, error = null)
        runCatching { api.post<MealQrIssueResponse, EmptyBody>("me/menu/selection/qr", EmptyBody(), token) }
            .onSuccess { update(working = false); done(it) }
            .onFailure { update(working = false, error = it.message); done(null) }
    }

    fun scanMealQr(qrToken: String, done: (MealScanResponse?) -> Unit) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch done(null)
        update(working = true, error = null)
        runCatching {
            api.post<MealScanResponse, MealQrScanBody>("me/menu/scan", MealQrScanBody(qrToken), token)
        }.onSuccess {
            update(working = false, error = null)
            done(it)
        }.onFailure {
            update(working = false, error = it.message ?: "Không xác nhận được mã QR.")
            done(null)
        }
    }

    fun cancelMealSelection() = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        update(working = true, error = null)
        runCatching { api.delete<TodayMenu>("me/menu/selection", token) }
            .onSuccess { _state.value = _state.value.copy(todayMenu = it, working = false) }
            .onFailure { update(working = false, error = it.message) }
    }

    fun receiveMealSelection() = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        update(working = true, error = null)
        runCatching {
            api.patch<TodayMenu, EmptyBody>("me/menu/selection/received", EmptyBody(), token)
        }
            .onSuccess { _state.value = _state.value.copy(todayMenu = it, working = false) }
            .onFailure { update(working = false, error = it.message) }
    }

    fun refreshRequests() = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        runCatching {
            Triple(
                api.get<List<EmployeeRequest>>("me/requests", token),
                api.get<List<EmployeeRequest>>("me/requests/approvals", token),
                api.get<List<RequestNotification>>("me/requests/notifications", token),
            )
        }.onSuccess { (requests, approvals, notifications) ->
            _state.value = _state.value.copy(requests = requests, approvals = approvals, requestNotifications = notifications)
            val unread = notifications.count { !it.read }
            if (unread > 0) NotificationHelper.showRequestNotification(getApplication(), notifications.first { !it.read }.title, unread)
        }.onFailure { update(error = it.message) }
    }

    fun createRequest(kind: String, startsAt: String, endsAt: String, reason: String, done: (Boolean) -> Unit = {}) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        update(working = true, error = null)
        runCatching { api.post<EmployeeRequest, CreateRequestBody>("me/requests", CreateRequestBody(kind, startsAt, endsAt, reason), token) }
            .onSuccess { refreshRequests(); update(working = false); done(true) }
            .onFailure { update(working = false, error = it.message); done(false) }
    }

    fun cancelRequest(id: String) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        runCatching { api.delete<EmployeeRequest>("me/requests/$id", token) }
            .onSuccess { refreshRequests() }.onFailure { update(error = it.message) }
    }

    fun decideRequest(id: String, approved: Boolean, note: String, done: (Boolean) -> Unit = {}) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        update(working = true, error = null)
        runCatching { api.patch<EmployeeRequest, RequestDecisionBody>("me/requests/$id/decision", RequestDecisionBody(if (approved) "approved" else "rejected", note.ifBlank { null }), token) }
            .onSuccess { refreshRequests(); update(working = false); done(true) }
            .onFailure { update(working = false, error = it.message); done(false) }
    }

    fun openNotification(id: String) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        runCatching { api.patch<UpdateCount, MessageResponse>("me/requests/notifications/$id/read", null, token) }
        refreshRequests()
    }

    fun deleteNotification(id: String) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        _state.value = _state.value.copy(
            requestNotifications = _state.value.requestNotifications.filterNot { it.id == id },
        )
        runCatching { api.delete<UpdateCount>("me/requests/notifications/$id", token) }
            .onFailure {
                update(error = "Không thể xóa thông báo. Vui lòng thử lại.")
                refreshRequests()
            }
    }

    fun hideArticleNotification(id: String) {
        hiddenArticles = hiddenArticles + id
        preferences.edit().putStringSet("hidden_notification_articles", hiddenArticles).apply()
        _state.value = _state.value.copy(hiddenArticleIds = hiddenArticles)
    }

    fun clearNotifications() = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        runCatching { api.delete<UpdateCount>("me/requests/notifications", token) }
        hiddenArticles = hiddenArticles + _state.value.dashboard?.contentItems.orEmpty().map { it.id }
        preferences.edit().putStringSet("hidden_notification_articles", hiddenArticles).apply()
        _state.value = _state.value.copy(hiddenArticleIds = hiddenArticles, requestNotifications = emptyList())
        markArticlesRead(); refreshRequests()
    }

    fun enableBiometric(password: String, enabled: Boolean, done: (Boolean) -> Unit = {}) = viewModelScope.launch {
        if (!enabled) {
            preferences.edit().putBoolean("biometric_enabled", false).remove("biometric_password").apply()
            _state.value = _state.value.copy(biometricEnabled = false); done(true); return@launch
        }
        val login = preferences.getString("last_login", null).orEmpty()
        runCatching { api.post<LoginResponse, LoginBody>("auth/login", LoginBody(login, password)) }
            .onSuccess { preferences.edit().putBoolean("biometric_enabled", true).putString("biometric_password", password).apply(); _state.value = _state.value.copy(biometricEnabled = true); done(true) }
            .onFailure { update(error = "Mật khẩu không chính xác."); done(false) }
    }

    fun biometricSignIn() {
        val login = preferences.getString("last_login", null).orEmpty()
        val password = preferences.getString("biometric_password", null).orEmpty()
        if (login.isNotBlank() && password.isNotBlank()) signIn(login, password)
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

    fun requestPasswordChange(done: (PasswordChangeRequestResponse?) -> Unit) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch done(null)
        update(working = true, error = null)
        runCatching { api.post<PasswordChangeRequestResponse, MessageResponse>("auth/password-change/request", MessageResponse(), token) }
            .onSuccess { update(working = false); done(it) }
            .onFailure { update(working = false, error = it.message); done(null) }
    }

    fun confirmPasswordChange(code: String, newPassword: String, done: (Boolean) -> Unit) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch done(false)
        update(working = true, error = null)
        runCatching { api.post<MessageResponse, PasswordChangeConfirmBody>("auth/password-change/confirm", PasswordChangeConfirmBody(code, newPassword), token) }
            .onSuccess {
                preferences.edit().putBoolean("biometric_enabled", false).remove("biometric_password").apply()
                _state.value = _state.value.copy(working = false, biometricEnabled = false)
                done(true)
            }
            .onFailure { update(working = false, error = it.message); done(false) }
    }

    fun clearError() = update(error = null)
    fun signOut() {
        events?.cancel(); events = null
        sessionRefreshJob?.cancel(); sessionRefreshJob = null
        preferences.edit().remove("token").remove("refresh_token").remove("widget_token").apply()
        AttendanceWidgetStore.clear(getApplication())
        _state.value = SessionUiState(restoring = false, biometricEnabled = preferences.getBoolean("biometric_enabled", false), hiddenArticleIds = hiddenArticles)
    }

    private fun startEvents() {
        events?.cancel()
        events = api.events(object : EventSourceListener() {
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                if (data.contains("request_changed")) refreshRequests() else if (data.contains("_changed")) refresh()
            }
            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                events = null
                viewModelScope.launch {
                    delay(3_000)
                    if (_state.value.token != null && events == null) startEvents()
                }
            }
        })
    }

    private fun saveSession(response: LoginResponse) {
        preferences.edit()
            .putString("token", response.accessToken)
            .apply {
                if (response.refreshToken.isNotBlank()) putString("refresh_token", response.refreshToken)
                if (response.widgetToken.isNotBlank()) putString("widget_token", response.widgetToken)
            }
            .apply()
    }

    private suspend fun refreshSession(): RefreshResult {
        val refreshToken = preferences.getString("refresh_token", null) ?: return RefreshResult.UNAUTHORIZED
        return runCatching {
            api.post<LoginResponse, RefreshSessionBody>("auth/refresh", RefreshSessionBody(refreshToken))
        }.onSuccess { response ->
            saveSession(response)
            _state.value = _state.value.copy(token = response.accessToken, error = null)
            AttendanceWidgetProvider.renderAll(getApplication())
        }.fold(
            onSuccess = { RefreshResult.SUCCESS },
            onFailure = { error ->
                if ((error as? ApiException)?.statusCode in listOf(401, 403)) {
                    RefreshResult.UNAUTHORIZED
                } else {
                    RefreshResult.DEFERRED
                }
            },
        )
    }

    private fun startSessionRefresh() {
        sessionRefreshJob?.cancel()
        sessionRefreshJob = viewModelScope.launch {
            while (isActive) {
                delay(12 * 60 * 60 * 1000L)
                if (refreshSession() != RefreshResult.SUCCESS) continue
                if (_state.value.profile?.accountType != "CANTEEN") {
                    refresh()
                    refreshRequests()
                    startEvents()
                }
            }
        }
    }

    private fun startAccountServices() {
        startSessionRefresh()
        if (_state.value.profile?.accountType == "CANTEEN") {
            events?.cancel()
            events = null
            return
        }
        refresh()
        refreshRequests()
        startEvents()
    }

    private fun update(
        restoring: Boolean = _state.value.restoring, working: Boolean = _state.value.working,
        error: String? = _state.value.error, unreadCount: Int = _state.value.unreadCount,
    ) { _state.value = _state.value.copy(restoring = restoring, working = working, error = error, unreadCount = unreadCount) }
}
