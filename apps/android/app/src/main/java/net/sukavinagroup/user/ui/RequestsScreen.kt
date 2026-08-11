@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package net.sukavinagroup.user.ui

import android.text.Html
import android.widget.TextView
import android.graphics.Bitmap
import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview as CameraPreview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat
import androidx.core.graphics.createBitmap
import androidx.core.graphics.set
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import net.sukavinagroup.user.SessionUiState
import net.sukavinagroup.user.SessionViewModel
import net.sukavinagroup.user.MainActivity
import net.sukavinagroup.user.data.*
import java.time.*
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatWriter
import com.google.zxing.common.BitMatrix


data class RequestKindUi(val key: String, val title: String, val icon: androidx.compose.ui.graphics.vector.ImageVector, val color: Color)
val requestKinds = listOf(
    RequestKindUi("leave", "Nghỉ phép", Icons.Default.EventAvailable, Color(0xFF007AFF)),
    RequestKindUi("late", "Đi trễ", Icons.Default.Schedule, Color(0xFFFF9500)),
    RequestKindUi("early", "Về sớm", Icons.AutoMirrored.Filled.ExitToApp, Color(0xFFE63885)),
    RequestKindUi("overtime", "Làm thêm giờ", Icons.Default.DarkMode, Color(0xFF5266F5)),
    RequestKindUi("business", "Công tác", Icons.Default.Flight, Color(0xFF008080)),
)
fun requestKind(key: String) = requestKinds.firstOrNull { it.key == key } ?: requestKinds.first()
fun requestStatus(status: String) = when (status) { "pending" -> "Chờ duyệt" to Color(0xFFFF9500); "approved" -> "Đã duyệt" to Color(0xFF34C759); "rejected" -> "Từ chối" to SukavinaRed; else -> "Đã hủy" to Color(0xFF8E8E93) }

@Composable fun RequestsScreen(
    state: SessionUiState,
    session: SessionViewModel,
    initialFilter: String = "all",
) {
    var filter by rememberSaveable(initialFilter) { mutableStateOf(initialFilter) }
    var reviewing by remember { mutableStateOf<EmployeeRequest?>(null) }
    var cancelling by remember { mutableStateOf<EmployeeRequest?>(null) }
    var refreshing by remember { mutableStateOf(false) }
    val refreshScope = rememberCoroutineScope()
    val filterOptions = remember { listOf("all" to "Tất cả", "pending" to "Chờ duyệt", "approved" to "Đã duyệt", "rejected" to "Từ chối", "cancelled" to "Đã hủy") }
    val filterIndex = filterOptions.indexOfFirst { it.first == filter }.coerceAtLeast(0)
    val pagerState = rememberPagerState(initialPage = filterIndex, pageCount = { filterOptions.size })
    val filterListState = rememberLazyListState()
    val approvalIds = state.approvals.map { it.id }.toSet()
    val merged = (state.approvals + state.requests).distinctBy { it.id }.sortedByDescending { it.createdAt }
    LaunchedEffect(initialFilter) {
        val targetPage = filterOptions.indexOfFirst { it.first == initialFilter }.coerceAtLeast(0)
        if (pagerState.currentPage != targetPage) pagerState.scrollToPage(targetPage)
    }
    LaunchedEffect(pagerState.currentPage) {
        filter = filterOptions[pagerState.currentPage].first
        filterListState.animateScrollToItem(pagerState.currentPage)
    }
    Scaffold(
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        containerColor = Color.Transparent,
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            PortalPageTitle("Đơn từ", Modifier.padding(start = 20.dp, top = 20.dp, end = 20.dp, bottom = 10.dp))
            LazyRow(
                state = filterListState,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp),
                contentPadding = PaddingValues(horizontal = 18.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                itemsIndexed(filterOptions) { index, item ->
                    val selected = filterIndex == index
                    Surface(
                        onClick = { refreshScope.launch { pagerState.animateScrollToPage(index) } },
                        shape = CircleShape,
                        color = if (selected) SukavinaRed else MaterialTheme.colorScheme.surface,
                        contentColor = if (selected) Color.White else MaterialTheme.colorScheme.onSurface,
                        border = androidx.compose.foundation.BorderStroke(
                            1.dp,
                            if (selected) SukavinaRed else MaterialTheme.colorScheme.outline.copy(alpha = .24f),
                        ),
                        shadowElevation = if (selected) 3.dp else 0.dp,
                    ) {
                        Text(
                            item.second,
                            modifier = Modifier.padding(horizontal = 15.dp, vertical = 9.dp),
                            fontSize = 13.sp,
                            fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                            maxLines = 1,
                        )
                    }
                }
            }
            PullToRefreshBox(
                isRefreshing = refreshing,
                onRefresh = {
                    refreshing = true
                    session.refreshRequests()
                    refreshScope.launch { delay(850); refreshing = false }
                },
                modifier = Modifier.fillMaxSize(),
            ) {
                HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize(), beyondViewportPageCount = 1) { page ->
                    val pageFilter = filterOptions[page].first
                    val visible = merged.filter { pageFilter == "all" || it.status == pageFilter }
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(start = 18.dp, top = 18.dp, end = 18.dp, bottom = LocalBottomNavigationClearance.current),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        items(visible, key = { it.id }) { request ->
                            RequestCard(request, canCancel = request.status == "pending" && request.id !in approvalIds,
                                onCancel = { cancelling = request }, onClick = { if (request.status == "pending" && request.id in approvalIds) reviewing = request })
                        }
                        if (visible.isEmpty()) item { RequestEmptyState(pageFilter) }
                    }
                }
            }
        }
    }
    reviewing?.let { request -> RequestDecisionDialog(request, state.working, { reviewing = null }) { approved, note -> session.decideRequest(request.id, approved, note) { if (it) reviewing = null } } }
    cancelling?.let { request ->
        SukavinaAlert(
            title = "Hủy đơn này?",
            eyebrow = "THAO TÁC KHÔNG THỂ HOÀN TÁC",
            icon = Icons.Default.Warning,
            confirmText = if (state.working) "Đang xử lý..." else "Xác nhận hủy",
            dismissText = "Giữ lại",
            danger = true,
            confirmEnabled = !state.working,
            onDismiss = { if (!state.working) cancelling = null },
            onConfirm = {
                session.cancelRequest(request.id)
                cancelling = null
            },
        ) {
            Text("Đơn ${requestKind(request.kind).title} sẽ chuyển sang trạng thái đã hủy.", fontWeight = FontWeight.SemiBold)
            Text("Người quản lý sẽ nhận được thông báo ngay sau thao tác này.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun RequestEmptyState(filter: String) {
    val presentation = when (filter) {
        "pending" -> Triple(Icons.Default.Schedule, "Không có đơn chờ duyệt", Color(0xFFFF9500))
        "approved" -> Triple(Icons.Default.Verified, "Chưa có đơn được duyệt", Color(0xFF34C759))
        "rejected" -> Triple(Icons.Default.Cancel, "Không có đơn bị từ chối", SukavinaRed)
        "cancelled" -> Triple(Icons.Default.Inventory2, "Chưa có đơn đã hủy", Color(0xFF7E8794))
        else -> Triple(Icons.Default.Description, "Chưa có đơn từ", Color(0xFF4B78C2))
    }
    val description = when (filter) {
        "pending" -> "Các đơn cần xử lý sẽ xuất hiện tại đây."
        "approved" -> "Những đơn đã được quản lý chấp thuận sẽ được lưu tại đây."
        "rejected" -> "Hiện không có đơn nào bị từ chối."
        "cancelled" -> "Những đơn bạn chủ động hủy sẽ xuất hiện tại đây."
        else -> "Tạo đơn mới để theo dõi quá trình xét duyệt ngay trong ứng dụng."
    }
    Column(
        modifier = Modifier.fillMaxWidth().padding(top = 34.dp, start = 8.dp, end = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Surface(
            modifier = Modifier.size(66.dp),
            shape = appShape(22.dp, AppShapeRole.EXTRA_LARGE),
            color = presentation.third.copy(alpha = .12f),
            border = androidx.compose.foundation.BorderStroke(1.dp, presentation.third.copy(alpha = .16f)),
        ) {
            Icon(presentation.first, null, tint = presentation.third, modifier = Modifier.padding(18.dp))
        }
        Text(presentation.second, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text(
            description,
            modifier = Modifier.widthIn(max = 320.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 13.sp,
            lineHeight = 19.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }
}

@Composable fun RequestCard(request: EmployeeRequest, canCancel: Boolean, onCancel: () -> Unit, onClick: () -> Unit = {}) {
    val kind = requestKind(request.kind); val status = requestStatus(request.status)
    val cardShape = appShape(22.dp, AppShapeRole.EXTRA_LARGE)
    Card(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 3.dp),
        shape = cardShape,
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(13.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(Modifier.size(46.dp), appShape(15.dp, AppShapeRole.LARGE), color = kind.color.copy(alpha = .16f)) { Icon(kind.icon, null, tint = kind.color, modifier = Modifier.padding(12.dp)) }
                Column(Modifier.padding(start = 12.dp).weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(request.employee?.fullName ?: "Đơn của tôi", fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Surface(shape = CircleShape, color = kind.color.copy(alpha = .14f)) { Text(kind.title, color = kind.color, fontSize = 11.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp)) }
                }
                Surface(shape = CircleShape, color = status.second.copy(alpha = .14f)) { Text(status.first, color = status.second, fontSize = 11.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp)) }
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Schedule, null, tint = SukavinaMuted, modifier = Modifier.size(17.dp))
                Text("${request.startsAt.toDateTimeLabel()} – ${request.endsAt.toDateTimeLabel()}", color = SukavinaMuted, fontSize = 13.sp, modifier = Modifier.padding(start = 7.dp))
            }
            Text(request.reason, lineHeight = 20.sp)
            request.decisionNote?.takeIf { it.isNotBlank() }?.let { Text(it, color = SukavinaMuted, fontSize = 12.sp) }
            if (canCancel) TextButton(onClick = onCancel, modifier = Modifier.align(Alignment.End)) { Text("Hủy đơn", color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable fun RequestComposer(working: Boolean, dismiss: () -> Unit, submit: (String, String, String, String) -> Unit) {
    var kind by remember { mutableStateOf(requestKinds.first()) }; var reason by remember { mutableStateOf("") }
    var from by remember { mutableStateOf(LocalDateTime.now()) }; var to by remember { mutableStateOf(LocalDateTime.now().plusHours(8)) }
    AlertDialog(onDismissRequest = { if (!working) dismiss() }, title = { Text("Tạo đơn mới") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { items(requestKinds) { item -> FilterChip(selected = kind == item, onClick = { kind = item }, label = { Text(item.title) }, leadingIcon = { Icon(item.icon, null, Modifier.size(17.dp), tint = item.color) }) } }
            DateTimeField("Bắt đầu", from) { from = it }; DateTimeField("Kết thúc", to) { to = it }
            OutlinedTextField(reason, { reason = it }, label = { Text("Lý do") }, minLines = 3, modifier = Modifier.fillMaxWidth())
            Text("Tối thiểu 10 ký tự", color = if (reason.trim().length >= 10) Color(0xFF55D881) else SukavinaMuted, fontSize = 11.sp)
        }
    }, confirmButton = { Button(enabled = !working && reason.trim().length >= 10 && !to.isBefore(from), onClick = { submit(kind.key, from.atZone(ZoneId.systemDefault()).toInstant().toString(), to.atZone(ZoneId.systemDefault()).toInstant().toString(), reason.trim()) }, elevation = SukavinaButtonElevation) { Text(if (working) "Đang gửi..." else "Gửi đơn") } }, dismissButton = { TextButton(onClick = dismiss) { Text("Đóng") } })
}

@Composable fun DateTimeField(label: String, value: LocalDateTime, changed: (LocalDateTime) -> Unit) {
    val context = LocalContext.current
    var showTimePicker by remember { mutableStateOf(false) }

    if (showTimePicker) {
        val timeState = rememberTimePickerState(
            initialHour = value.hour,
            initialMinute = value.minute,
            is24Hour = true,
        )
        AlertDialog(
            onDismissRequest = { showTimePicker = false },
            icon = {
                Surface(
                    shape = CircleShape,
                    color = SukavinaRed.copy(alpha = .14f),
                    modifier = Modifier.size(46.dp),
                ) {
                    Icon(
                        Icons.Default.Schedule,
                        contentDescription = null,
                        tint = SukavinaRed,
                        modifier = Modifier.padding(11.dp),
                    )
                }
            },
            title = { Text("Chọn giờ ${label.lowercase()}") },
            text = {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(
                        "Chạm vào giờ hoặc phút, sau đó chọn trên mặt đồng hồ.",
                        color = SukavinaMuted,
                        fontSize = 13.sp,
                    )
                    TimePicker(state = timeState)
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        changed(value.withHour(timeState.hour).withMinute(timeState.minute))
                        showTimePicker = false
                    },
                ) {
                    Text("Xác nhận")
                }
            },
            dismissButton = {
                TextButton(onClick = { showTimePicker = false }) {
                    Text("Hủy")
                }
            },
        )
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = appShape(17.dp, AppShapeRole.LARGE),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(13.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            Text(label.uppercase(), color = SukavinaMuted, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = .8.sp)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                OutlinedButton(
                    onClick = {
                        android.app.DatePickerDialog(
                            context,
                            { _, year, month, day ->
                                changed(LocalDateTime.of(year, month + 1, day, value.hour, value.minute))
                            },
                            value.year,
                            value.monthValue - 1,
                            value.dayOfMonth,
                        ).show()
                    },
                    modifier = Modifier.weight(1.25f),
                    contentPadding = PaddingValues(horizontal = 11.dp, vertical = 10.dp),
                ) {
                    Icon(Icons.Default.CalendarMonth, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(7.dp))
                    Text(value.format(DateTimeFormatter.ofPattern("dd/MM/yyyy")), maxLines = 1)
                }
                OutlinedButton(
                    onClick = { showTimePicker = true },
                    modifier = Modifier.weight(.9f),
                    contentPadding = PaddingValues(horizontal = 11.dp, vertical = 10.dp),
                ) {
                    Icon(Icons.Default.Schedule, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(7.dp))
                    Text(value.format(DateTimeFormatter.ofPattern("HH:mm")), maxLines = 1)
                }
            }
        }
    }
}

@Composable fun RequestDecisionDialog(request: EmployeeRequest, working: Boolean, dismiss: () -> Unit, decide: (Boolean, String) -> Unit) {
    var rejected by remember { mutableStateOf(false) }; var note by remember { mutableStateOf("") }
    AlertDialog(onDismissRequest = { if (!working) dismiss() }, title = { Text("Xử lý ${requestKind(request.kind).title.lowercase()}") }, text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { Text(request.employee?.fullName.orEmpty(), fontWeight = FontWeight.Bold); Text(request.reason); SingleChoiceSegmentedButtonRow { SegmentedButton(!rejected, { rejected = false }, SegmentedButtonDefaults.itemShape(0,2)) { Text("Duyệt") }; SegmentedButton(rejected, { rejected = true }, SegmentedButtonDefaults.itemShape(1,2)) { Text("Từ chối") } }; OutlinedTextField(note, { note = it }, label = { Text(if (rejected) "Lý do từ chối" else "Ghi chú (tùy chọn)") }, minLines = 3) } }, confirmButton = { Button(enabled = !working && (!rejected || note.trim().length >= 5), onClick = { decide(!rejected, note.trim()) }, colors = ButtonDefaults.buttonColors(containerColor = if (rejected) MaterialTheme.colorScheme.error else Color(0xFF238D4A))) { Text(if (working) "Đang xử lý..." else if (rejected) "Xác nhận từ chối" else "Duyệt đơn") } }, dismissButton = { TextButton(onClick = dismiss) { Text("Đóng") } })
}
