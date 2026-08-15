package net.sukavinagroup.user.data

import kotlinx.serialization.Serializable

@Serializable data class LoginBody(val loginId: String, val password: String)
@Serializable data class DeleteAccountBody(val password: String = "", val confirmation: String = "XOA TAI KHOAN")
@Serializable data class PasswordChangeConfirmBody(val code: String = "", val currentPassword: String? = null, val newPassword: String)
@Serializable data class PasswordChangeRequestResponse(val message: String = "", val email: String = "", val expiresInMinutes: Int = 10)
@Serializable data class MessageResponse(val message: String = "")
@Serializable data class ForgotPasswordRequestBody(val employeeCode: String)
@Serializable data class ForgotPasswordConfirmBody(val employeeCode: String, val code: String, val newPassword: String)
@Serializable data class ForgotPasswordRequestResponse(val message: String = "", val maskedEmail: String? = null, val expiresInMinutes: Int = 10)
@Serializable data class UserSummary(
    val employeeCode: String = "", val name: String = "", val role: String = "",
    val accountType: String = "EMPLOYEE", val permissions: List<String> = emptyList(),
    val protected: Boolean = false, val mustChangePassword: Boolean = false,
)
@Serializable data class LoginResponse(
    val accessToken: String,
    val refreshToken: String = "",
    val widgetToken: String = "",
    val user: UserSummary,
)
@Serializable data class RefreshSessionBody(val refreshToken: String)
@Serializable data class WidgetTokenBody(val widgetToken: String)
@Serializable data class Profile(
    val id: String = "", val employeeCode: String = "", val name: String = "",
    val role: String = "", val accountType: String = "EMPLOYEE",
    val permissions: List<String> = emptyList(), val protected: Boolean = false,
    val email: String? = null, val passwordChangedAt: String? = null,
    val mustChangePassword: Boolean = false,
)
@Serializable data class ContentItem(
    val id: String, val page: String = "", val key: String = "", val title: String,
    val body: String, val sortOrder: Int = 0, val published: Boolean = true,
    val createdAt: String = "",
)
@Serializable data class AttendanceRecord(
    val id: String, val punchedAt: String, val source: String = "",
    val originType: String? = null, val machineNo: Int = 0,
)
@Serializable data class Dashboard(
    val employeeCode: String = "", val fullName: String = "", val role: String = "",
    val remainingLeaveDays: Int = 0, val attendanceStatus: String = "",
    val payrollStatus: String = "", val name: String = "",
    val attendanceRecords: List<AttendanceRecord> = emptyList(),
    val contentItems: List<ContentItem> = emptyList(),
)
@Serializable data class AttendancePunch(
    val id: String, val punchedAt: String, val source: String = "", val machineNo: Int = 0,
)
@Serializable data class AttendanceDay(
    val date: String, val checkIn: String? = null, val checkOut: String? = null,
    val punchCount: Int = 0, val sources: List<String> = emptyList(),
    val punches: List<AttendancePunch> = emptyList(),
    val status: String? = null, val statuses: List<String> = emptyList(),
    val startTime: String? = null, val endTime: String? = null,
)
@Serializable data class AttendanceMonth(
    val month: String, val startTime: String? = null, val endTime: String? = null,
    val department: String? = null, val days: List<AttendanceDay> = emptyList(),
)
@Serializable data class ApiError(val message: String = "Yêu cầu không thành công")

@Serializable data class EmployeeSummary(val fullName: String = "", val employeeCode: String = "")
@Serializable data class EmployeeRequest(
    val id: String, val kind: String, val startsAt: String, val endsAt: String,
    val reason: String, val status: String, val createdAt: String, val dueAt: String = "",
    val decisionNote: String? = null, val autoApproved: Boolean = false,
    val employee: EmployeeSummary? = null,
)
@Serializable data class CreateRequestBody(val kind: String, val startsAt: String, val endsAt: String, val reason: String)
@Serializable data class RequestDecisionBody(val status: String, val note: String? = null)
@Serializable data class RequestNotification(
    val id: String, val type: String, val title: String, val message: String,
    val requestId: String? = null, val read: Boolean = false, val createdAt: String,
)
@Serializable data class UpdateCount(val count: Int = 0)
@Serializable data class MenuDay(
    val dayIndex: Int = 0, val dayName: String = "", val featured: String = "",
    val savoryMain: String = "", val savorySide: String = "", val vegetable: String = "",
    val soup: String = "", val vegetarianMain: String = "", val vegetarianSide: String = "",
    val overtime: String = "",
)
@Serializable data class TodayMenu(
    val date: String = "",
    val day: MenuDay = MenuDay(),
    val selection: String? = null,
    val receivedAt: String? = null,
    val orderingOpen: Boolean = true,
    val orderingCutoff: String = "09:00",
    val availableChoices: MealAvailability? = null,
)
@Serializable data class MealAvailability(
    val water: Boolean = false,
    val vegetarian: Boolean = false,
)
@Serializable data class MealSelectionBody(val choice: String)
@Serializable data class MealQrScanBody(val token: String)
@Serializable data class MealQrIssueResponse(val token: String = "", val expiresAt: String = "")
@Serializable data class MealScanResponse(
    val valid: Boolean = false,
    val alreadyReceived: Boolean = false,
    val employeeCode: String = "",
    val fullName: String = "",
    val department: String = "",
    val choice: String = "",
    val mealName: String? = null,
    val mealDate: String = "",
    val receivedAt: String = "",
)
@Serializable data class EmptyBody(val acknowledged: Boolean = true)
