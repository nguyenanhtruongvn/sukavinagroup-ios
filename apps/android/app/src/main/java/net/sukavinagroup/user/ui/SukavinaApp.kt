@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package net.sukavinagroup.user.ui

import android.text.Html
import android.widget.TextView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.launch
import net.sukavinagroup.user.SessionUiState
import net.sukavinagroup.user.SessionViewModel
import net.sukavinagroup.user.data.*
import java.time.*
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

private enum class MainTab(val label: String) { HOME("Trang chủ"), NEWS("Bài viết"), PROFILE("Tài khoản") }

@Composable fun SukavinaApp(state: SessionUiState, session: SessionViewModel) = SukavinaTheme {
    Surface(Modifier.fillMaxSize(), color = SukavinaInk) {
        when {
            state.restoring -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            state.token == null -> LoginScreen(state, session::signIn)
            else -> MainScreen(state, session)
        }
    }
}

@Composable private fun LoginScreen(state: SessionUiState, signIn: (String, String) -> Unit) {
    var login by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    Column(
        Modifier.fillMaxSize().imePadding().padding(horizontal = 26.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Surface(shape = CircleShape, color = SukavinaRed.copy(alpha = .16f), modifier = Modifier.size(64.dp)) {
            Icon(Icons.Default.Workspaces, null, tint = SukavinaRed, modifier = Modifier.padding(17.dp))
        }
        Spacer(Modifier.height(24.dp))
        Text("SUKAVINA PORTAL", color = SukavinaRed, fontWeight = FontWeight.Bold, letterSpacing = 2.sp)
        Text("Đăng nhập tài khoản", fontSize = 36.sp, fontWeight = FontWeight.Black, lineHeight = 41.sp)
        Text("Thông tin nội bộ, bài viết và chấm công trong một ứng dụng native.", color = SukavinaMuted, modifier = Modifier.padding(vertical = 14.dp))
        OutlinedTextField(login, { login = it }, label = { Text("Mã nhân viên hoặc số điện thoại") },
            leadingIcon = { Icon(Icons.Default.Badge, null) }, singleLine = true, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(password, { password = it }, label = { Text("Mật khẩu") },
            leadingIcon = { Icon(Icons.Default.Lock, null) }, visualTransformation = PasswordVisualTransformation(),
            singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth())
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 10.dp)) }
        Button(onClick = { signIn(login, password) }, enabled = login.isNotBlank() && password.isNotBlank() && !state.working,
            modifier = Modifier.fillMaxWidth().padding(top = 18.dp).height(54.dp), shape = RoundedCornerShape(16.dp)) {
            if (state.working) CircularProgressIndicator(Modifier.size(22.dp), color = Color.White, strokeWidth = 2.dp)
            else Text("Đăng nhập", fontWeight = FontWeight.Bold)
        }
    }
}

@Composable private fun MainScreen(state: SessionUiState, session: SessionViewModel) {
    var tab by rememberSaveable { mutableStateOf(MainTab.HOME) }
    var article by remember { mutableStateOf<ContentItem?>(null) }
    var attendanceOpen by remember { mutableStateOf(false) }
    BackHandler(article != null || attendanceOpen) { article = null; attendanceOpen = false }
    if (article != null) return ArticleDetail(article!!) { article = null }
    if (attendanceOpen) return AttendanceScreen(session) { attendanceOpen = false }

    Scaffold(bottomBar = {
        NavigationBar(containerColor = Color(0xFF18181D)) {
            MainTab.entries.forEach { item ->
                NavigationBarItem(selected = tab == item, onClick = {
                    tab = item; if (item == MainTab.NEWS) session.markArticlesRead()
                }, icon = {
                    BadgedBox(badge = { if (item == MainTab.NEWS && state.unreadCount > 0) Badge { Text(state.unreadCount.toString()) } }) {
                        Icon(when(item) { MainTab.HOME -> Icons.Default.Home; MainTab.NEWS -> Icons.Default.Newspaper; MainTab.PROFILE -> Icons.Default.Person }, null)
                    }
                }, label = { Text(item.label) })
            }
        }
    }) { padding ->
        Box(Modifier.padding(padding)) {
            when (tab) {
                MainTab.HOME -> HomeScreen(state, session::refresh, { attendanceOpen = true }, { article = it })
                MainTab.NEWS -> NewsScreen(state.dashboard?.contentItems.orEmpty()) { article = it }
                MainTab.PROFILE -> ProfileScreen(state, session)
            }
        }
    }
}

@Composable private fun HomeScreen(state: SessionUiState, refresh: () -> Unit, openAttendance: () -> Unit, openArticle: (ContentItem) -> Unit) {
    val dashboard = state.dashboard
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(15.dp)) {
        item {
            Text("Xin chào,", color = SukavinaMuted)
            Text(dashboard?.name ?: state.profile?.name ?: "Nhân viên", fontSize = 29.sp, fontWeight = FontWeight.ExtraBold)
            Text("${dashboard?.role.orEmpty()} · ${dashboard?.employeeCode.orEmpty()}", color = SukavinaMuted)
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                MetricCard("${dashboard?.remainingLeaveDays ?: 0}", "Ngày phép", Icons.Default.EventAvailable, Modifier.weight(1f))
                MetricCard((dashboard?.contentItems?.size ?: 0).toString(), "Bài viết", Icons.Default.Article, Modifier.weight(1f))
            }
        }
        item { AttendanceTodayCard(dashboard, openAttendance) }
        item { Text("Mới nhất", fontSize = 21.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 5.dp)) }
        items(dashboard?.contentItems?.take(3).orEmpty(), key = { it.id }) { NewsCard(it) { openArticle(it) } }
        item { OutlinedButton(onClick = refresh, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Default.Refresh, null); Spacer(Modifier.width(8.dp)); Text("Làm mới dữ liệu") } }
    }
}

@Composable private fun MetricCard(value: String, label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, modifier: Modifier) {
    Card(modifier) { Column(Modifier.padding(18.dp)) { Icon(icon, null, tint = SukavinaRed); Spacer(Modifier.height(16.dp)); Text(value, fontSize = 25.sp, fontWeight = FontWeight.Bold); Text(label, color = SukavinaMuted) } }
}

@Composable private fun AttendanceTodayCard(dashboard: Dashboard?, onClick: () -> Unit) {
    val records = dashboard?.attendanceRecords.orEmpty()
    Card(onClick = onClick, colors = CardDefaults.cardColors(containerColor = Color(0xFF4A2024))) {
        Column(Modifier.padding(20.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Schedule, null, tint = SukavinaRed); Spacer(Modifier.width(10.dp))
                Text("Chấm công hôm nay", fontWeight = FontWeight.Bold); Spacer(Modifier.weight(1f)); Icon(Icons.Default.ChevronRight, null)
            }
            Spacer(Modifier.height(17.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TimeBox("Giờ vào", records.lastOrNull()?.punchedAt.toTime(), Modifier.weight(1f))
                TimeBox("Giờ ra", if (records.size > 1) records.first().punchedAt.toTime() else "--:--", Modifier.weight(1f))
            }
        }
    }
}

@Composable private fun TimeBox(label: String, value: String, modifier: Modifier) = Surface(modifier, shape = RoundedCornerShape(14.dp), color = Color.White.copy(alpha = .06f)) {
    Column(Modifier.padding(14.dp)) { Text(label, color = SukavinaMuted, fontSize = 12.sp); Text(value, fontSize = 22.sp, fontWeight = FontWeight.Bold) }
}

@Composable private fun NewsScreen(items: List<ContentItem>, open: (ContentItem) -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    val filtered = remember(items, query) { items.filter { query.isBlank() || it.title.contains(query, true) || it.body.plainText().contains(query, true) } }
    Column(Modifier.fillMaxSize().padding(horizontal = 18.dp)) {
        Text("Bài viết nội bộ", fontSize = 28.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(top = 22.dp, bottom = 14.dp))
        OutlinedTextField(query, { query = it }, placeholder = { Text("Tìm bài viết") }, leadingIcon = { Icon(Icons.Default.Search, null) }, singleLine = true, modifier = Modifier.fillMaxWidth())
        LazyColumn(contentPadding = PaddingValues(vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            items(filtered, key = { it.id }) { NewsCard(it) { open(it) } }
            if (filtered.isEmpty()) item { Text("Không có bài viết phù hợp.", color = SukavinaMuted, modifier = Modifier.padding(top = 40.dp)) }
        }
    }
}

@Composable private fun NewsCard(item: ContentItem, onClick: () -> Unit) = Card(onClick = onClick) {
    Column(Modifier.padding(18.dp)) {
        Text(item.createdAt.toDateLabel(), color = SukavinaRed, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        Text(item.title, fontSize = 18.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(vertical = 7.dp))
        Text(item.body.plainText(), color = SukavinaMuted, maxLines = 3, overflow = TextOverflow.Ellipsis)
    }
}

@Composable private fun ArticleDetail(item: ContentItem, back: () -> Unit) {
    Scaffold(topBar = { TopAppBar(title = { Text("Bài viết") }, navigationIcon = { IconButton(onClick = back) { Icon(Icons.Default.ArrowBack, "Quay lại") } }) }) { padding ->
        LazyColumn(Modifier.padding(padding), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            item { Text(item.createdAt.toDateLabel(), color = SukavinaRed, fontWeight = FontWeight.Bold); Text(item.title, fontSize = 29.sp, lineHeight = 35.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(top = 7.dp)) }
            item {
                AndroidView(factory = { context -> TextView(context).apply { setTextColor(android.graphics.Color.rgb(241,238,234)); textSize = 17f; setLineSpacing(8f, 1f); setPadding(0,8,0,30) } },
                    update = { it.text = Html.fromHtml(item.body.take(750_000), Html.FROM_HTML_MODE_LEGACY) }, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

@Composable private fun AttendanceScreen(session: SessionViewModel, back: () -> Unit) {
    val months = remember { (0..1).map { YearMonth.now().minusMonths(it.toLong()) } }
    var selected by remember { mutableStateOf(months.first()) }
    var history by remember { mutableStateOf<AttendanceMonth?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(selected) { loading = true; session.attendance(selected.toString()).onSuccess { history = it; error = null }.onFailure { history = null; error = it.message }; loading = false }
    Scaffold(topBar = { TopAppBar(title = { Text("Bảng chấm công") }, navigationIcon = { IconButton(onClick = back) { Icon(Icons.Default.ArrowBack, "Quay lại") } }) }) { padding ->
        Column(Modifier.padding(padding).padding(horizontal = 18.dp)) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(vertical = 14.dp)) {
                months.forEachIndexed { index, month -> SegmentedButton(selected == month, { selected = month }, SegmentedButtonDefaults.itemShape(index, months.size)) { Text(month.format(DateTimeFormatter.ofPattern("MM/yyyy"))) } }
            }
            when {
                loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                error != null -> Text(error!!, color = MaterialTheme.colorScheme.error)
                else -> LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(bottom = 30.dp)) {
                    items(history?.days.orEmpty(), key = { it.date }) { day -> AttendanceRow(day) }
                    if (history?.days.isNullOrEmpty()) item { Text("Không có dữ liệu trong tháng này.", color = SukavinaMuted, modifier = Modifier.padding(top = 35.dp)) }
                }
            }
        }
    }
}

@Composable private fun AttendanceRow(day: AttendanceDay) = Card {
    Row(Modifier.fillMaxWidth().padding(17.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) { Text(day.date.toDayLabel(), fontWeight = FontWeight.Bold); Text("${day.punchCount} lượt ghi nhận", color = SukavinaMuted, fontSize = 12.sp) }
        Column(horizontalAlignment = Alignment.End) { Text("Vào", color = SukavinaMuted, fontSize = 11.sp); Text(day.checkIn.toTime(), fontWeight = FontWeight.Bold) }
        Spacer(Modifier.width(22.dp))
        Column(horizontalAlignment = Alignment.End) { Text("Ra", color = SukavinaMuted, fontSize = 11.sp); Text(day.checkOut.toTime(), fontWeight = FontWeight.Bold, color = SukavinaRed) }
    }
}

@Composable private fun ProfileScreen(state: SessionUiState, session: SessionViewModel) {
    var deleteOpen by remember { mutableStateOf(false) }; var password by remember { mutableStateOf("") }
    val profile = state.profile
    Column(Modifier.fillMaxSize().padding(22.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.height(30.dp)); Surface(Modifier.size(92.dp), CircleShape, color = SukavinaRed.copy(alpha = .15f)) { Box(contentAlignment = Alignment.Center) { Text(profile?.name.initials(), color = SukavinaRed, fontSize = 26.sp, fontWeight = FontWeight.Bold) } }
        Text(profile?.name ?: "Nhân viên", fontSize = 25.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 14.dp)); Text(profile?.employeeCode.orEmpty(), color = SukavinaMuted)
        Card(Modifier.fillMaxWidth().padding(top = 24.dp)) { Column { ProfileLine("Vai trò", profile?.role.orEmpty()); HorizontalDivider(); ProfileLine("Loại tài khoản", profile?.accountType.accountLabel()) } }
        OutlinedButton(onClick = session::signOut, modifier = Modifier.fillMaxWidth().padding(top = 20.dp).height(52.dp)) { Icon(Icons.Default.Logout, null); Spacer(Modifier.width(8.dp)); Text("Đăng xuất") }
        if (profile?.protected != true && profile?.accountType != "SUPER_ADMIN") TextButton(onClick = { deleteOpen = true }, modifier = Modifier.padding(top = 10.dp)) { Text("Yêu cầu xóa tài khoản", color = MaterialTheme.colorScheme.error) }
    }
    if (deleteOpen) AlertDialog(onDismissRequest = { deleteOpen = false }, title = { Text("Xóa tài khoản vĩnh viễn?") }, text = { OutlinedTextField(password, { password = it }, label = { Text("Mật khẩu") }, visualTransformation = PasswordVisualTransformation()) }, confirmButton = { TextButton(onClick = { session.deleteAccount(password); deleteOpen = false }) { Text("Xóa vĩnh viễn", color = MaterialTheme.colorScheme.error) } }, dismissButton = { TextButton(onClick = { deleteOpen = false }) { Text("Hủy") } })
}

@Composable private fun ProfileLine(label: String, value: String) = Row(Modifier.fillMaxWidth().padding(18.dp)) { Text(label, color = SukavinaMuted); Spacer(Modifier.weight(1f)); Text(value, fontWeight = FontWeight.Medium) }

private fun String?.toTime(): String { if (this.isNullOrBlank()) return "--:--"; return runCatching { OffsetDateTime.parse(this).atZoneSameInstant(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("HH:mm")) }.getOrDefault("--:--") }
private fun String.toDateLabel() = runCatching { OffsetDateTime.parse(this).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale("vi", "VN"))) }.getOrDefault("")
private fun String.toDayLabel() = runCatching { LocalDate.parse(this).format(DateTimeFormatter.ofPattern("EEEE, dd/MM", Locale("vi", "VN"))) }.getOrDefault(this)
private fun String.plainText() = Html.fromHtml(take(750_000), Html.FROM_HTML_MODE_LEGACY).toString().replace(Regex("\\s+"), " ").trim()
private fun String?.initials() = this.orEmpty().split(" ").filter { it.isNotBlank() }.takeLast(2).joinToString("") { it.take(1).uppercase() }.ifBlank { "NV" }
private fun String?.accountLabel() = when (this) { "SUPER_ADMIN" -> "Quản trị viên tổng"; "ADMIN" -> "Quản trị viên"; else -> "Nhân viên" }

@Preview(name = "Đăng nhập", showBackground = true, backgroundColor = 0xFF111115, widthDp = 390, heightDp = 844)
@Composable private fun LoginPreview() = SukavinaTheme {
    LoginScreen(SessionUiState(restoring = false), { _, _ -> })
}

@Preview(name = "Trang chủ nhân viên", showBackground = true, backgroundColor = 0xFF111115, widthDp = 390, heightDp = 844)
@Composable private fun DashboardPreview() = SukavinaTheme {
    HomeScreen(
        state = SessionUiState(
            restoring = false,
            profile = Profile(employeeCode = "SKV-001", name = "Nguyễn Văn A", role = "Nhân viên"),
            dashboard = Dashboard(
                employeeCode = "SKV-001", name = "Nguyễn Văn A", role = "Nhân sự vận hành",
                remainingLeaveDays = 8,
                attendanceRecords = listOf(
                    AttendanceRecord("1", "2026-07-18T08:01:00.000Z"),
                    AttendanceRecord("2", "2026-07-18T17:03:00.000Z"),
                ),
                contentItems = listOf(
                    ContentItem("1", title = "Thông báo lịch nghỉ", body = "Cập nhật lịch nghỉ và kế hoạch làm việc trong tuần mới.", createdAt = "2026-07-18T08:00:00Z"),
                    ContentItem("2", title = "Quy định nội bộ", body = "Những nội dung nhân viên cần lưu ý.", createdAt = "2026-07-17T08:00:00Z"),
                ),
            ),
        ),
        refresh = {}, openAttendance = {}, openArticle = {},
    )
}
