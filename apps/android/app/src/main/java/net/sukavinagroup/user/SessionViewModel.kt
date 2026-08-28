package net.sukavinagroup.user

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.google.firebase.messaging.FirebaseMessaging
import net.sukavinagroup.user.data.*
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import kotlin.random.Random

data class SessionUiState(
    val restoring: Boolean = true, val token: String? = null, val profile: Profile? = null,
    val dashboard: Dashboard? = null, val working: Boolean = false, val error: String? = null,
    val unreadCount: Int = 0, val requests: List<EmployeeRequest> = emptyList(),
    val approvals: List<EmployeeRequest> = emptyList(),
    val requestNotifications: List<RequestNotification> = emptyList(),
    val biometricEnabled: Boolean = false,
    val hiddenArticleIds: Set<String> = emptySet(),
    val todayMenu: TodayMenu? = null,
    val attendanceRevision: Long = 0L,
)

class SessionViewModel(application: Application) : AndroidViewModel(application) {
    private enum class RefreshResult { SUCCESS, UNAUTHORIZED, DEFERRED }

    private val api = ApiClient()
    private val preferences = application.getSharedPreferences(
        "sukavina-session-metadata",
        Context.MODE_PRIVATE,
    )
    private val secureStore = SecureSessionStore(application)
    private val _state = MutableStateFlow(SessionUiState())
    val state = _state.asStateFlow()
    private var events: EventSource? = null
    private var eventRefreshJob: Job? = null
    private val pendingRealtimeEvents = mutableSetOf<String>()
    private var sessionRefreshJob: Job? = null
    private val refreshMutex = Mutex()
    private var knownArticles = emptySet<String>()
    private var hiddenArticles = emptySet<String>()

    init {
        LegacySecureSessionMigration.migrate(application, preferences, secureStore)
        knownArticles = preferences.getStringSet("known_articles", emptySet()).orEmpty()
        hiddenArticles = preferences.getStringSet("hidden_notification_articles", emptySet()).orEmpty()
        val biometricEnabled = preferences.getBoolean("biometric_enabled", false) &&
            !secureStore.getString("biometric_refresh_token").isNullOrBlank()
        _state.value = _state.value.copy(biometricEnabled = biometricEnabled, hiddenArticleIds = hiddenArticles)
        restore()
    }

    private fun restore() = viewModelScope.launch {
        val token = secureStore.getString("token")
        if (token == null) return@launch update(restoring = false)
        _state.value = _state.value.copy(restoring = false, token = token)
        runCatching {
            val profile = api.get<Profile>("auth/me", token)
            if (secureStore.getString("refresh_token").isNullOrBlank() ||
                secureStore.getString("widget_token").isNullOrBlank()
            ) {
                val upgraded = api.post<LoginResponse, EmptyBody>("auth/session/upgrade", EmptyBody(), token)
                saveSession(upgraded)
                _state.value = _state.value.copy(token = upgraded.accessToken)
            }
            profile.copy(
                mustChangePassword = profile.mustChangePassword ||
                    preferences.getBoolean("must_change_password", false),
            )
        }
            .onSuccess { profile ->
                _state.value = _state.value.copy(profile = profile, error = null)
                if (!profile.mustChangePassword) startAccountServices()
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
                preferences.edit { putString("last_login", loginId.trim()) }
                _state.value = SessionUiState(
                    restoring = false, token = response.accessToken,
                    profile = response.toProfile(),
                )
                if (!response.user.mustChangePassword) startAccountServices()
            }.onFailure { error ->
                val message = if (
                    error is ApiException &&
                    error.statusCode in listOf(401, 403) &&
                    error.message == "Invalid credentials"
                ) {
                    "MSNV hoặc mật khẩu không chính xác."
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
            val attendanceChanged = notifyNewAttendance(dashboard)
            val ids = dashboard.contentItems.map { it.id }.toSet()
            val unread = if (knownArticles.isEmpty()) 0 else (ids - knownArticles).size
            val guardedProfile = profile.copy(
                mustChangePassword = profile.mustChangePassword ||
                    preferences.getBoolean("must_change_password", false),
            )
            _state.value = _state.value.copy(
                profile = guardedProfile,
                dashboard = dashboard,
                working = false,
                unreadCount = unread,
                error = null,
                attendanceRevision = if (attendanceChanged) _state.value.attendanceRevision + 1 else _state.value.attendanceRevision,
            )
            AttendanceWidgetStore.update(getApplication(), dashboard)
            if (unread > 0) NotificationHelper.showArticleNotification(getApplication(), dashboard.contentItems.first().title, unread)
        }.onFailure { update(working = false, error = it.message) }
    }

    private fun notifyNewAttendance(dashboard: Dashboard): Boolean {
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

        preferences.edit { putStringSet(preferenceKey, currentIds) }
        return !hasBaseline || currentIds != knownIds
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

    fun createRequest(kind: String, startsAt: String, endsAt: String, reason: String, businessDestination: String? = null, businessTransport: String? = null, businessDistanceKm: Double? = null, businessExpense: Double? = null, done: (Boolean) -> Unit = {}) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        update(working = true, error = null)
        runCatching { api.post<EmployeeRequest, CreateRequestBody>("me/requests", CreateRequestBody(kind, startsAt, endsAt, reason, businessDestination, businessTransport, businessDistanceKm, businessExpense), token) }
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
        preferences.edit { putStringSet("hidden_notification_articles", hiddenArticles) }
        _state.value = _state.value.copy(hiddenArticleIds = hiddenArticles)
    }

    fun clearNotifications() = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        runCatching { api.delete<UpdateCount>("me/requests/notifications", token) }
        hiddenArticles = hiddenArticles + _state.value.dashboard?.contentItems.orEmpty().map { it.id }
        preferences.edit { putStringSet("hidden_notification_articles", hiddenArticles) }
        _state.value = _state.value.copy(hiddenArticleIds = hiddenArticles, requestNotifications = emptyList())
        markArticlesRead(); refreshRequests()
    }

    fun enableBiometric(password: String, enabled: Boolean, done: (Boolean) -> Unit = {}) = viewModelScope.launch {
        if (!enabled) {
            clearBiometricCredentials()
            _state.value = _state.value.copy(biometricEnabled = false); done(true); return@launch
        }
        val login = preferences.getString("last_login", null).orEmpty()
        if (login.isBlank()) {
            update(error = "Không tìm thấy MSNV đã đăng nhập. Vui lòng đăng nhập lại.")
            done(false)
            return@launch
        }
        runCatching { api.post<LoginResponse, LoginBody>("auth/login", LoginBody(login, password)) }
            .onSuccess { response ->
                if (response.refreshToken.isBlank()) {
                    update(error = "Máy chủ chưa cấp phiên đăng nhập sinh trắc học. Vui lòng thử lại.")
                    done(false)
                    return@onSuccess
                }
                if (!secureStore.putString("biometric_refresh_token", response.refreshToken)) {
                    update(error = "Không thể bảo vệ phiên sinh trắc học trên thiết bị này.")
                    done(false)
                    return@onSuccess
                }
                preferences.edit { putBoolean("biometric_enabled", true) }
                saveSession(response)
                _state.value = _state.value.copy(
                    token = response.accessToken,
                    profile = response.toProfile(),
                    biometricEnabled = true,
                    error = null,
                )
                if (!response.user.mustChangePassword) startAccountServices()
                done(true)
            }
            .onFailure { update(error = "Mật khẩu không chính xác."); done(false) }
    }

    fun biometricSignIn() = viewModelScope.launch {
        val refreshToken = secureStore.getString("biometric_refresh_token")
        if (refreshToken.isNullOrBlank()) {
            clearBiometricCredentials()
            update(biometricEnabled = false, error = "Đăng nhập sinh trắc học đã hết hiệu lực. Vui lòng đăng nhập bằng MSNV.")
            return@launch
        }
        update(working = true, error = null)
        runCatching {
            api.post<LoginResponse, RefreshSessionBody>("auth/refresh", RefreshSessionBody(refreshToken))
        }.onSuccess { response ->
            saveSession(response)
            _state.value = SessionUiState(
                restoring = false,
                token = response.accessToken,
                profile = response.toProfile(),
                biometricEnabled = true,
                hiddenArticleIds = hiddenArticles,
            )
            if (!response.user.mustChangePassword) startAccountServices()
        }.onFailure { error ->
            if ((error as? ApiException)?.statusCode in listOf(401, 403)) {
                clearBiometricCredentials()
                update(working = false, biometricEnabled = false, error = "Phiên sinh trắc học đã hết hạn. Vui lòng đăng nhập lại bằng MSNV.")
            } else {
                update(working = false, error = error.message ?: "Không thể đăng nhập bằng sinh trắc học.")
            }
        }
    }

    suspend fun attendance(month: String): Result<AttendanceMonth> {
        val token = _state.value.token ?: return Result.failure(ApiException("Phiên đăng nhập đã hết hạn"))
        return runCatching { api.get("me/attendance?month=$month", token) }
    }

    fun markArticlesRead() {
        knownArticles = _state.value.dashboard?.contentItems?.map { it.id }?.toSet().orEmpty()
        preferences.edit { putStringSet("known_articles", knownArticles) }
        update(unreadCount = 0)
        NotificationHelper.clear(getApplication())
    }

    fun deleteAccount() = viewModelScope.launch {
        val token = _state.value.token ?: return@launch
        update(working = true, error = null)
        runCatching { api.delete<MessageResponse>("auth/me", DeleteAccountBody(confirmation = "XOA TAI KHOAN"), token) }
            .onSuccess { clearBiometricCredentials(); signOut() }.onFailure { update(working = false, error = it.message) }
    }

    fun requestPasswordChange(done: (PasswordChangeRequestResponse?) -> Unit) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch done(null)
        update(working = true, error = null)
        runCatching { api.post<PasswordChangeRequestResponse, MessageResponse>("auth/password-change/request", MessageResponse(), token) }
            .onSuccess { update(working = false); done(it) }
            .onFailure { update(working = false, error = it.message); done(null) }
    }

    fun requestForgotPassword(employeeCode: String, done: (ForgotPasswordRequestResponse?, String?) -> Unit) = viewModelScope.launch {
        update(working = true, error = null)
        runCatching { api.post<ForgotPasswordRequestResponse, ForgotPasswordRequestBody>("auth/forgot-password/request", ForgotPasswordRequestBody(employeeCode.trim())) }
            .onSuccess { update(working = false); done(it, null) }
            .onFailure { update(working = false); done(null, it.message ?: "Không thể gửi mã OTP.") }
    }

    fun confirmForgotPassword(employeeCode: String, code: String, newPassword: String, done: (Boolean, String?) -> Unit) = viewModelScope.launch {
        update(working = true, error = null)
        runCatching { api.post<MessageResponse, ForgotPasswordConfirmBody>("auth/forgot-password/confirm", ForgotPasswordConfirmBody(employeeCode.trim(), code, newPassword)) }
            .onSuccess { update(working = false); done(true, null) }
            .onFailure { update(working = false); done(false, it.message ?: "Không thể đặt lại mật khẩu.") }
    }

    fun confirmPasswordChange(code: String = "", currentPassword: String? = null, newPassword: String, done: (Boolean) -> Unit) = viewModelScope.launch {
        val token = _state.value.token ?: return@launch done(false)
        update(working = true, error = null)
        runCatching { api.post<MessageResponse, PasswordChangeConfirmBody>("auth/password-change/confirm", PasswordChangeConfirmBody(code, currentPassword, newPassword), token) }
            .onSuccess {
                preferences.edit { putBoolean("must_change_password", false) }
                _state.value = _state.value.copy(
                    working = false,
                    profile = _state.value.profile?.copy(mustChangePassword = false),
                )
                startAccountServices()
                done(true)
            }
            .onFailure { update(working = false, error = it.message); done(false) }
    }

    fun clearError() = update(error = null)
    fun signOut() {
        events?.cancel(); events = null
        eventRefreshJob?.cancel(); eventRefreshJob = null
        pendingRealtimeEvents.clear()
        sessionRefreshJob?.cancel(); sessionRefreshJob = null
        secureStore.remove("token", "refresh_token", "widget_token")
        preferences.edit { remove("must_change_password") }
        AttendanceWidgetStore.clear(getApplication())
        BackgroundAccountSync.cancel(getApplication())
        _state.value = SessionUiState(restoring = false, biometricEnabled = preferences.getBoolean("biometric_enabled", false), hiddenArticleIds = hiddenArticles)
    }

    private fun startEvents() {
        events?.cancel()
        events = api.events(object : EventSourceListener() {
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                if (events !== eventSource) return
                scheduleRealtimeRefresh(data)
            }
            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                if (events !== eventSource) return
                events = null
                viewModelScope.launch {
                    delay(Random.nextLong(2_000, 5_001))
                    if (_state.value.token != null && events == null) startEvents()
                }
            }
        })
    }

    private fun scheduleRealtimeRefresh(data: String) {
        if (!data.contains("_changed")) return
        viewModelScope.launch {
            if (data.contains("attendance_changed")) pendingRealtimeEvents += "attendance_changed"
            if (data.contains("request_changed")) pendingRealtimeEvents += "request_changed"
            if (data.contains("meal_changed")) pendingRealtimeEvents += "meal_changed"
            if (data.contains("content_changed")) pendingRealtimeEvents += "content_changed"
            if (pendingRealtimeEvents.isEmpty() || eventRefreshJob?.isActive == true) return@launch
            eventRefreshJob = launch {
                // Keep updates near-instant while smoothing a broadcast burst
                // from hundreds of simultaneously connected devices.
                delay(Random.nextLong(250, 751))
                val eventTypes = pendingRealtimeEvents.toSet()
                pendingRealtimeEvents.clear()
                eventRefreshJob = null
                if (eventTypes.contains("request_changed")) refreshRequests()
                if (
                    eventTypes.contains("attendance_changed") ||
                    eventTypes.contains("request_changed") ||
                    eventTypes.contains("content_changed")
                ) {
                    refresh()
                }
                if (eventTypes.contains("meal_changed")) refreshTodayMenu()
            }
        }
    }

    private fun saveSession(response: LoginResponse) {
        secureStore.putString("token", response.accessToken)
        preferences.edit { putBoolean("must_change_password", response.user.mustChangePassword) }
        if (response.refreshToken.isNotBlank()) secureStore.putString("refresh_token", response.refreshToken)
        if (response.widgetToken.isNotBlank()) secureStore.putString("widget_token", response.widgetToken)
        if (preferences.getBoolean("biometric_enabled", false) && response.refreshToken.isNotBlank()) {
            secureStore.putString("biometric_refresh_token", response.refreshToken)
        }
    }

    private fun clearBiometricCredentials() {
        preferences.edit {
            putBoolean("biometric_enabled", false)
        }
        secureStore.remove("biometric_refresh_token")
    }

    private fun LoginResponse.toProfile() = Profile(
        employeeCode = user.employeeCode,
        name = user.name,
        role = user.role,
        accountType = user.accountType,
        permissions = user.permissions,
        protected = user.protected,
        mustChangePassword = user.mustChangePassword,
    )

    private suspend fun refreshSession(): RefreshResult {
        return refreshMutex.withLock {
            val refreshToken = secureStore.getString("refresh_token") ?: return@withLock RefreshResult.UNAUTHORIZED
            runCatching {
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
        registerPushToken()
        BackgroundAccountSync.schedule(getApplication())
        if (_state.value.profile?.accountType == "CANTEEN") {
            events?.cancel()
            events = null
            return
        }
        refresh()
        refreshRequests()
        startEvents()
    }

    private fun registerPushToken() {
        if (_state.value.token.isNullOrBlank()) return
        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { fcmToken ->
                getApplication<Application>()
                    .getSharedPreferences(SukavinaFirebaseMessagingService.PUSH_PREFERENCES, Context.MODE_PRIVATE)
                    .edit()
                    .putString(SukavinaFirebaseMessagingService.PUSH_TOKEN_KEY, fcmToken)
                    .apply()
                PushTokenSync.enqueue(getApplication())
            }
    }

    private fun update(
        restoring: Boolean = _state.value.restoring, working: Boolean = _state.value.working,
        error: String? = _state.value.error, unreadCount: Int = _state.value.unreadCount,
        biometricEnabled: Boolean = _state.value.biometricEnabled,
    ) {
        _state.value = _state.value.copy(
            restoring = restoring,
            working = working,
            error = error,
            unreadCount = unreadCount,
            biometricEnabled = biometricEnabled,
        )
    }
}
