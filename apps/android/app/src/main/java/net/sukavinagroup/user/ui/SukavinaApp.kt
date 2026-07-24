@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package net.sukavinagroup.user.ui

import android.text.Html
import android.widget.TextView
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import net.sukavinagroup.user.MainActivity
import net.sukavinagroup.user.data.*
import java.time.*
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

private enum class MainTab(val label: String) { HOME("Trang chủ"), REQUESTS("Đơn từ"), NOTIFICATIONS("Thông báo"), PROFILE("Tài khoản") }

@Composable fun SukavinaApp(state: SessionUiState, session: SessionViewModel) = SukavinaTheme {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        when {
            state.restoring -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            state.token == null -> LoginScreen(state, session::signIn, session::biometricSignIn)
            else -> MainScreen(state, session)
        }
    }
}

@Composable private fun LoginScreen(state: SessionUiState, signIn: (String, String) -> Unit, biometricSignIn: () -> Unit = {}) {
    val activity = LocalActivity.current as? MainActivity
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
        if (state.biometricEnabled) OutlinedButton(onClick = { activity?.authenticateBiometric(biometricSignIn) }, modifier = Modifier.fillMaxWidth().padding(top = 10.dp).height(52.dp), shape = RoundedCornerShape(16.dp)) { Icon(Icons.Default.Fingerprint, null); Spacer(Modifier.width(8.dp)); Text("Đăng nhập bằng sinh trắc học") }
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
        NavigationBar(containerColor = MaterialTheme.colorScheme.surface) {
            MainTab.entries.forEach { item ->
                NavigationBarItem(selected = tab == item, onClick = {
                    tab = item
                }, icon = {
                    val notificationCount = state.unreadCount + state.requestNotifications.count { !it.read }
                    BadgedBox(badge = { if (item == MainTab.NOTIFICATIONS && notificationCount > 0) Badge { Text(notificationCount.toString()) } }) {
                        Icon(when(item) { MainTab.HOME -> Icons.Default.Home; MainTab.REQUESTS -> Icons.Default.Description; MainTab.NOTIFICATIONS -> Icons.Default.Notifications; MainTab.PROFILE -> Icons.Default.Person }, null)
                    }
                }, label = { Text(item.label) })
            }
        }
    }) { padding ->
        Box(Modifier.padding(padding)) {
            when (tab) {
                MainTab.HOME -> HomeScreen(state, session::refresh, { attendanceOpen = true }, { article = it })
                MainTab.REQUESTS -> RequestsScreen(state, session)
                MainTab.NOTIFICATIONS -> NotificationsScreen(state, session) { article = it }
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
                MetricCard(state.requests.count { it.status == "pending" }.toString(), "Đơn đang chờ", Icons.Default.Description, Modifier.weight(1f))
            }
        }
        item { AttendanceTodayCard(dashboard, openAttendance) }
        item { OutlinedButton(onClick = refresh, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Default.Refresh, null); Spacer(Modifier.width(8.dp)); Text("Làm mới dữ liệu") } }
    }
}

@Composable private fun MetricCard(value: String, label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, modifier: Modifier) {
    Card(modifier) { Column(Modifier.padding(18.dp)) { Icon(icon, null, tint = SukavinaRed); Spacer(Modifier.height(16.dp)); Text(value, fontSize = 25.sp, fontWeight = FontWeight.Bold); Text(label, color = SukavinaMuted) } }
}

@Composable private fun AttendanceTodayCard(dashboard: Dashboard?, onClick: () -> Unit) {
    val records = dashboard?.attendanceRecords.orEmpty()
    Card(onClick = onClick, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
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

private data class RequestKindUi(val key: String, val title: String, val icon: androidx.compose.ui.graphics.vector.ImageVector, val color: Color)
private val requestKinds = listOf(
    RequestKindUi("leave", "Nghỉ phép", Icons.Default.EventAvailable, Color(0xFF5EA7FF)),
    RequestKindUi("late", "Đi trễ", Icons.Default.Schedule, Color(0xFFFFB34F)),
    RequestKindUi("early", "Về sớm", Icons.Default.ExitToApp, Color(0xFFC49AFF)),
    RequestKindUi("overtime", "Làm thêm giờ", Icons.Default.DarkMode, Color(0xFF8C82FF)),
    RequestKindUi("business", "Công tác", Icons.Default.Flight, Color(0xFF55D4C1)),
)
private fun requestKind(key: String) = requestKinds.firstOrNull { it.key == key } ?: requestKinds.first()
private fun requestStatus(status: String) = when (status) { "pending" -> "Chờ duyệt" to Color(0xFFFFB34F); "approved" -> "Đã duyệt" to Color(0xFF55D881); "rejected" -> "Từ chối" to Color(0xFFFF6F67); else -> "Đã hủy" to Color(0xFFAAB1BD) }

@Composable private fun RequestsScreen(state: SessionUiState, session: SessionViewModel) {
    var filter by rememberSaveable { mutableStateOf("all") }
    var composing by remember { mutableStateOf(false) }
    var reviewing by remember { mutableStateOf<EmployeeRequest?>(null) }
    var cancelling by remember { mutableStateOf<EmployeeRequest?>(null) }
    val approvalIds = state.approvals.map { it.id }.toSet()
    val merged = (state.approvals + state.requests).distinctBy { it.id }.sortedByDescending { it.createdAt }
    val visible = merged.filter { filter == "all" || it.status == filter }
    Scaffold(floatingActionButton = { FloatingActionButton(onClick = { composing = true }, containerColor = SukavinaRed) { Icon(Icons.Default.Add, "Tạo đơn", tint = Color.White) } }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Text("Đơn từ", fontSize = 29.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(18.dp, 20.dp, 18.dp, 10.dp))
            androidx.compose.foundation.lazy.LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(listOf("all" to "Tất cả", "pending" to "Chờ duyệt", "approved" to "Đã duyệt", "rejected" to "Từ chối", "cancelled" to "Đã hủy")) { item ->
                    FilterChip(selected = filter == item.first, onClick = { filter = item.first }, label = { Text(item.second) })
                }
            }
            LazyColumn(contentPadding = PaddingValues(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(visible, key = { it.id }) { request ->
                    RequestCard(request, canCancel = request.status == "pending" && request.id !in approvalIds,
                        onCancel = { cancelling = request }, onClick = { if (request.status == "pending" && request.id in approvalIds) reviewing = request })
                }
                if (visible.isEmpty()) item { Text("Chưa có đơn trong mục này.", color = SukavinaMuted, modifier = Modifier.padding(top = 45.dp)) }
            }
        }
    }
    if (composing) RequestComposer(state.working, { composing = false }) { kind, from, to, reason -> session.createRequest(kind, from, to, reason) { if (it) composing = false } }
    reviewing?.let { request -> RequestDecisionDialog(request, state.working, { reviewing = null }) { approved, note -> session.decideRequest(request.id, approved, note) { if (it) reviewing = null } } }
    cancelling?.let { request ->
        AlertDialog(
            onDismissRequest = { if (!state.working) cancelling = null },
            title = { Text("Hủy đơn này?") },
            text = { Text("Đơn ${requestKind(request.kind).title} sẽ chuyển sang trạng thái đã hủy và người quản lý sẽ nhận được thông báo. Thao tác không thể hoàn tác.") },
            confirmButton = {
                TextButton(
                    enabled = !state.working,
                    onClick = {
                        session.cancelRequest(request.id)
                        cancelling = null
                    },
                ) { Text("Xác nhận hủy", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(enabled = !state.working, onClick = { cancelling = null }) { Text("Giữ lại") } },
        )
    }
}

@Composable private fun RequestCard(request: EmployeeRequest, canCancel: Boolean, onCancel: () -> Unit, onClick: () -> Unit = {}) {
    val kind = requestKind(request.kind); val status = requestStatus(request.status)
    Card(onClick = onClick, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface), border = androidx.compose.foundation.BorderStroke(1.dp, kind.color.copy(alpha = .32f))) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(11.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(Modifier.size(44.dp), RoundedCornerShape(14.dp), color = kind.color.copy(alpha = .16f)) { Icon(kind.icon, null, tint = kind.color, modifier = Modifier.padding(11.dp)) }
                Column(Modifier.padding(start = 12.dp).weight(1f)) { Text(request.employee?.fullName ?: "Đơn của tôi", fontWeight = FontWeight.Bold); Surface(shape = CircleShape, color = kind.color.copy(alpha = .14f)) { Text(kind.title, color = kind.color, fontSize = 11.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp)) } }
                Text(status.first, color = status.second, fontSize = 11.sp, fontWeight = FontWeight.Bold)
            }
            Text("${request.startsAt.toDateTimeLabel()} – ${request.endsAt.toDateTimeLabel()}", color = SukavinaMuted, fontSize = 13.sp)
            Text(request.reason)
            request.decisionNote?.takeIf { it.isNotBlank() }?.let { Text(it, color = SukavinaMuted, fontSize = 12.sp) }
            if (canCancel) TextButton(onClick = onCancel, modifier = Modifier.align(Alignment.End)) { Text("Hủy đơn", color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable private fun RequestComposer(working: Boolean, dismiss: () -> Unit, submit: (String, String, String, String) -> Unit) {
    var kind by remember { mutableStateOf(requestKinds.first()) }; var reason by remember { mutableStateOf("") }
    var from by remember { mutableStateOf(LocalDateTime.now()) }; var to by remember { mutableStateOf(LocalDateTime.now().plusHours(8)) }
    AlertDialog(onDismissRequest = { if (!working) dismiss() }, title = { Text("Tạo đơn mới") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { items(requestKinds) { item -> FilterChip(selected = kind == item, onClick = { kind = item }, label = { Text(item.title) }, leadingIcon = { Icon(item.icon, null, Modifier.size(17.dp), tint = item.color) }) } }
            DateTimeField("Bắt đầu", from) { from = it }; DateTimeField("Kết thúc", to) { to = it }
            OutlinedTextField(reason, { reason = it }, label = { Text("Lý do") }, minLines = 3, modifier = Modifier.fillMaxWidth())
            Text("Tối thiểu 10 ký tự", color = if (reason.trim().length >= 10) Color(0xFF55D881) else SukavinaMuted, fontSize = 11.sp)
        }
    }, confirmButton = { Button(enabled = !working && reason.trim().length >= 10 && !to.isBefore(from), onClick = { submit(kind.key, from.atZone(ZoneId.systemDefault()).toInstant().toString(), to.atZone(ZoneId.systemDefault()).toInstant().toString(), reason.trim()) }) { Text(if (working) "Đang gửi..." else "Gửi đơn") } }, dismissButton = { TextButton(onClick = dismiss) { Text("Đóng") } })
}

@Composable private fun DateTimeField(label: String, value: LocalDateTime, changed: (LocalDateTime) -> Unit) {
    val context = LocalContext.current
    OutlinedButton(onClick = {
        android.app.DatePickerDialog(context, { _, y, m, d -> android.app.TimePickerDialog(context, { _, h, min -> changed(LocalDateTime.of(y, m + 1, d, h, min)) }, value.hour, value.minute, true).show() }, value.year, value.monthValue - 1, value.dayOfMonth).show()
    }, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Default.CalendarMonth, null); Spacer(Modifier.width(8.dp)); Text("$label: ${value.format(DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm"))}") }
}

@Composable private fun RequestDecisionDialog(request: EmployeeRequest, working: Boolean, dismiss: () -> Unit, decide: (Boolean, String) -> Unit) {
    var rejected by remember { mutableStateOf(false) }; var note by remember { mutableStateOf("") }
    AlertDialog(onDismissRequest = { if (!working) dismiss() }, title = { Text("Xử lý ${requestKind(request.kind).title.lowercase()}") }, text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { Text(request.employee?.fullName.orEmpty(), fontWeight = FontWeight.Bold); Text(request.reason); SingleChoiceSegmentedButtonRow { SegmentedButton(!rejected, { rejected = false }, SegmentedButtonDefaults.itemShape(0,2)) { Text("Duyệt") }; SegmentedButton(rejected, { rejected = true }, SegmentedButtonDefaults.itemShape(1,2)) { Text("Từ chối") } }; OutlinedTextField(note, { note = it }, label = { Text(if (rejected) "Lý do từ chối" else "Ghi chú (tùy chọn)") }, minLines = 3) } }, confirmButton = { Button(enabled = !working && (!rejected || note.trim().length >= 5), onClick = { decide(!rejected, note.trim()) }, colors = ButtonDefaults.buttonColors(containerColor = if (rejected) MaterialTheme.colorScheme.error else Color(0xFF238D4A))) { Text(if (working) "Đang xử lý..." else if (rejected) "Xác nhận từ chối" else "Duyệt đơn") } }, dismissButton = { TextButton(onClick = dismiss) { Text("Đóng") } })
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

@Composable private fun NotificationsScreen(state: SessionUiState, session: SessionViewModel, openArticle: (ContentItem) -> Unit) {
    var selected by remember { mutableStateOf<EmployeeRequest?>(null) }
    var reviewing by remember { mutableStateOf<EmployeeRequest?>(null) }
    var confirmClear by remember { mutableStateOf(false) }
    val requests = (state.requests + state.approvals).associateBy { it.id }
    val visibleArticles = state.dashboard?.contentItems.orEmpty().filterNot { it.id in state.hiddenArticleIds }
    val unread = state.unreadCount + state.requestNotifications.count { !it.read }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(18.dp, 20.dp, 18.dp, 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) { Text("Thông báo", fontSize = 29.sp, fontWeight = FontWeight.ExtraBold); Text(if (unread > 0) "$unread thông báo chưa đọc" else "Bạn đã đọc tất cả", color = SukavinaMuted) }
            if (state.requestNotifications.isNotEmpty() || visibleArticles.isNotEmpty()) TextButton(onClick = { confirmClear = true }) { Text("Xóa tất cả", color = MaterialTheme.colorScheme.error) }
        }
        LazyColumn(contentPadding = PaddingValues(18.dp), verticalArrangement = Arrangement.spacedBy(11.dp)) {
            items(state.requestNotifications, key = { it.id }) { item ->
                val request = item.requestId?.let(requests::get); val kind = request?.let { requestKind(it.kind) }
                val tone = kind?.color ?: when { item.type.contains("rejected") -> Color(0xFFFF6F67); item.type.contains("cancelled") -> Color(0xFFAAB1BD); else -> Color(0xFF55D881) }
                Card(onClick = { session.openNotification(item.id); if (request != null) { if (item.type == "request_pending" && request.status == "pending" && state.approvals.any { it.id == request.id }) reviewing = request else selected = request } }, colors = CardDefaults.cardColors(containerColor = if (item.read) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.surfaceVariant), border = androidx.compose.foundation.BorderStroke(1.dp, if (item.read) Color.Transparent else tone.copy(alpha = .35f))) {
                    Row(Modifier.padding(15.dp), verticalAlignment = Alignment.Top) {
                        Surface(Modifier.size(44.dp), RoundedCornerShape(14.dp), color = tone.copy(alpha = .16f)) { Icon(kind?.icon ?: if (item.type.contains("rejected")) Icons.Default.Cancel else if (item.type.contains("cancelled")) Icons.Default.RemoveCircle else Icons.Default.CheckCircle, null, tint = tone, modifier = Modifier.padding(11.dp)) }
                        Column(Modifier.padding(horizontal = 12.dp).weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) { Text(item.title, fontWeight = FontWeight.Bold); kind?.let { Text(it.title, color = it.color, fontSize = 11.sp, fontWeight = FontWeight.Bold) }; Text(item.message, color = SukavinaMuted, fontSize = 13.sp); Text(item.createdAt.toDateTimeLabel(), color = tone, fontSize = 11.sp) }
                        if (!item.read) Surface(Modifier.size(8.dp), CircleShape, color = SukavinaRed) {}
                    }
                }
            }
            items(visibleArticles, key = { "article-${it.id}" }) { item ->
                Card(onClick = { session.markArticlesRead(); openArticle(item) }) { Row(Modifier.padding(15.dp)) { Surface(Modifier.size(44.dp), RoundedCornerShape(14.dp), color = SukavinaRed.copy(alpha = .16f)) { Icon(Icons.Default.Campaign, null, tint = SukavinaRed, modifier = Modifier.padding(11.dp)) }; Column(Modifier.padding(start = 12.dp)) { Text(item.title, fontWeight = FontWeight.Bold); Text(item.body.plainText(), color = SukavinaMuted, maxLines = 2, overflow = TextOverflow.Ellipsis) } } }
            }
            if (state.requestNotifications.isEmpty() && visibleArticles.isEmpty()) item { Text("Chưa có thông báo.", color = SukavinaMuted, modifier = Modifier.padding(top = 50.dp)) }
        }
    }
    if (confirmClear) AlertDialog(onDismissRequest = { confirmClear = false }, title = { Text("Xóa tất cả thông báo?") }, text = { Text("Danh sách thông báo sẽ được dọn khỏi tài khoản này.") }, confirmButton = { TextButton(onClick = { session.clearNotifications(); confirmClear = false }) { Text("Xóa tất cả", color = MaterialTheme.colorScheme.error) } }, dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Hủy") } })
    selected?.let { request -> AlertDialog(onDismissRequest = { selected = null }, title = { Text("Chi tiết đơn") }, text = { RequestCard(request, false, {}, {}) }, confirmButton = { TextButton(onClick = { selected = null }) { Text("Đóng") } }) }
    reviewing?.let { request -> RequestDecisionDialog(request, state.working, { reviewing = null }) { approved, note -> session.decideRequest(request.id, approved, note) { if (it) reviewing = null } } }
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
    var deleteOpen by remember { mutableStateOf(false) }; var password by remember { mutableStateOf("") }; var biometricPasswordOpen by remember { mutableStateOf(false) }; var biometricPassword by remember { mutableStateOf("") }; var passwordChangeOpen by remember { mutableStateOf(false) }
    val activity = LocalActivity.current as? MainActivity
    val profile = state.profile
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(22.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(30.dp)); Surface(Modifier.size(92.dp), CircleShape, color = SukavinaRed.copy(alpha = .15f)) { Box(contentAlignment = Alignment.Center) { Text(profile?.name.initials(), color = SukavinaRed, fontSize = 26.sp, fontWeight = FontWeight.Bold) } }
        Text(profile?.name ?: "Nhân viên", fontSize = 25.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 14.dp)); Text(profile?.employeeCode.orEmpty(), color = SukavinaMuted)
        Card(Modifier.fillMaxWidth().padding(top = 24.dp)) { Column { ProfileLine("Vai trò", profile?.role.orEmpty()); HorizontalDivider(); ProfileLine("Loại tài khoản", profile?.accountType.accountLabel()); HorizontalDivider(); Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Default.Fingerprint, null, tint = SukavinaRed); Text("Đăng nhập sinh trắc học", Modifier.padding(start = 10.dp).weight(1f)); Switch(state.biometricEnabled, onCheckedChange = { enabled -> if (enabled) activity?.authenticateBiometric { biometricPasswordOpen = true } else session.enableBiometric("", false) }) } } }
        Card(Modifier.fillMaxWidth().padding(top = 14.dp)) {
            Column {
                TextButton(
                    onClick = { activity?.openNotificationSettings() },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                ) {
                    Icon(Icons.Default.Notifications, null)
                    Text("Cài đặt thông báo", Modifier.padding(start = 12.dp).weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Start)
                    Icon(Icons.Default.ChevronRight, null)
                }
                HorizontalDivider()
                TextButton(
                    onClick = { activity?.openUrl("https://sukavinagroup.net/privacy-policy") },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                ) {
                    Icon(Icons.Default.PrivacyTip, null)
                    Text("Chính sách quyền riêng tư", Modifier.padding(start = 12.dp).weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Start)
                    Icon(Icons.Default.OpenInNew, null)
                }
                HorizontalDivider()
                TextButton(
                    onClick = { activity?.openUrl("https://sukavinagroup.net/support") },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                ) {
                    Icon(Icons.Default.SupportAgent, null)
                    Text("Hỗ trợ người dùng", Modifier.padding(start = 12.dp).weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Start)
                    Icon(Icons.Default.OpenInNew, null)
                }
                HorizontalDivider()
                TextButton(
                    onClick = { activity?.openUrl("https://sukavinagroup.net/account-deletion") },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                ) {
                    Icon(Icons.Default.ManageAccounts, null)
                    Text("Hướng dẫn xóa tài khoản", Modifier.padding(start = 12.dp).weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Start)
                    Icon(Icons.Default.OpenInNew, null)
                }
            }
        }
        OutlinedButton(onClick = session::signOut, modifier = Modifier.fillMaxWidth().padding(top = 20.dp).height(52.dp)) { Icon(Icons.Default.Logout, null); Spacer(Modifier.width(8.dp)); Text("Đăng xuất") }
        OutlinedButton(onClick = { passwordChangeOpen = true }, modifier = Modifier.fillMaxWidth().padding(top = 10.dp).height(52.dp)) { Icon(Icons.Default.Key, null); Spacer(Modifier.width(8.dp)); Text("Đổi mật khẩu") }
        if (profile?.protected != true && profile?.accountType != "SUPER_ADMIN") TextButton(onClick = { deleteOpen = true }, modifier = Modifier.padding(top = 10.dp)) { Text("Yêu cầu xóa tài khoản", color = MaterialTheme.colorScheme.error) }
    }
    if (deleteOpen) AlertDialog(onDismissRequest = { deleteOpen = false }, title = { Text("Xóa tài khoản vĩnh viễn?") }, text = { OutlinedTextField(password, { password = it }, label = { Text("Mật khẩu") }, visualTransformation = PasswordVisualTransformation()) }, confirmButton = { TextButton(onClick = { session.deleteAccount(password); deleteOpen = false }) { Text("Xóa vĩnh viễn", color = MaterialTheme.colorScheme.error) } }, dismissButton = { TextButton(onClick = { deleteOpen = false }) { Text("Hủy") } })
    if (biometricPasswordOpen) AlertDialog(onDismissRequest = { biometricPasswordOpen = false }, title = { Text("Bật đăng nhập sinh trắc học") }, text = { OutlinedTextField(biometricPassword, { biometricPassword = it }, label = { Text("Nhập mật khẩu hiện tại") }, visualTransformation = PasswordVisualTransformation()) }, confirmButton = { Button(onClick = { session.enableBiometric(biometricPassword, true) { if (it) biometricPasswordOpen = false } }) { Text("Xác nhận") } }, dismissButton = { TextButton(onClick = { biometricPasswordOpen = false }) { Text("Hủy") } })
    if (passwordChangeOpen) PasswordChangeDialog(state, session) { passwordChangeOpen = false }
}

@Composable private fun PasswordChangeDialog(state: SessionUiState, session: SessionViewModel, dismiss: () -> Unit) {
    var email by remember { mutableStateOf("") }; var otpSent by remember { mutableStateOf(false) }; var code by remember { mutableStateOf("") }
    var newPassword by remember { mutableStateOf("") }; var confirmPassword by remember { mutableStateOf("") }; var completed by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = dismiss, icon = { Icon(Icons.Default.Key, null, tint = SukavinaRed) },
        title = { Text(if (completed) "Đổi mật khẩu thành công" else "Đổi mật khẩu") },
        text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (completed) Text("Bạn có thể đổi lại vào tháng tiếp theo. Đăng nhập sinh trắc học đã được tắt để bảo vệ tài khoản.")
            else if (!otpSent) Text("Mã OTP sẽ được gửi tới email liên kết. Tài khoản chưa có email cần liên hệ Nhân sự để cập nhật.")
            else { Text("Mã OTP đã được gửi tới $email", color = SukavinaRed, fontWeight = FontWeight.SemiBold)
                OutlinedTextField(code, { code = it.filter(Char::isDigit).take(6) }, label = { Text("Mã OTP gồm 6 số") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                OutlinedTextField(newPassword, { newPassword = it }, label = { Text("Mật khẩu mới, ít nhất 6 ký tự") }, visualTransformation = PasswordVisualTransformation())
                OutlinedTextField(confirmPassword, { confirmPassword = it }, label = { Text("Nhập lại mật khẩu mới") }, visualTransformation = PasswordVisualTransformation()) }
        } },
        confirmButton = { when { completed -> Button(onClick = dismiss) { Text("Hoàn tất") }
            !otpSent -> Button(onClick = { session.requestPasswordChange { if (it != null) { email = it.email; otpSent = true } } }, enabled = !state.working) { Text("Gửi mã OTP") }
            else -> Button(onClick = { session.confirmPasswordChange(code, newPassword) { if (it) completed = true } }, enabled = code.length == 6 && newPassword.length >= 6 && newPassword == confirmPassword && !state.working) { Text("Xác nhận") } } },
        dismissButton = { if (!completed) TextButton(onClick = dismiss) { Text("Hủy") } })
}

@Composable private fun ProfileLine(label: String, value: String) = Row(Modifier.fillMaxWidth().padding(18.dp)) { Text(label, color = SukavinaMuted); Spacer(Modifier.weight(1f)); Text(value, fontWeight = FontWeight.Medium) }

private fun String?.toTime(): String { if (this.isNullOrBlank()) return "--:--"; return runCatching { OffsetDateTime.parse(this).atZoneSameInstant(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("HH:mm")) }.getOrDefault("--:--") }
private fun String.toDateLabel() = runCatching { OffsetDateTime.parse(this).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale("vi", "VN"))) }.getOrDefault("")
private fun String.toDateTimeLabel() = runCatching { OffsetDateTime.parse(this).atZoneSameInstant(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm")) }.getOrDefault(this)
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
