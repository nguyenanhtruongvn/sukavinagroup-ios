package net.sukavinagroup.user.data

import kotlinx.serialization.Serializable

@Serializable data class LoginBody(val loginId: String, val password: String)
@Serializable data class DeleteAccountBody(val password: String, val confirmation: String = "XOA TAI KHOAN")
@Serializable data class MessageResponse(val message: String = "")
@Serializable data class UserSummary(
    val employeeCode: String = "", val name: String = "", val role: String = "",
    val accountType: String = "EMPLOYEE", val permissions: List<String> = emptyList(),
    val protected: Boolean = false,
)
@Serializable data class LoginResponse(val accessToken: String, val user: UserSummary)
@Serializable data class Profile(
    val id: String = "", val employeeCode: String = "", val name: String = "",
    val role: String = "", val accountType: String = "EMPLOYEE",
    val permissions: List<String> = emptyList(), val protected: Boolean = false,
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
)
@Serializable data class AttendanceMonth(val month: String, val days: List<AttendanceDay> = emptyList())
@Serializable data class ApiError(val message: String = "Yêu cầu không thành công")
