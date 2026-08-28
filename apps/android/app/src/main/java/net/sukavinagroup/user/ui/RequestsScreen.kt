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
import androidx.compose.ui.unit.Density
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
import androidx.compose.ui.window.DialogProperties
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
private enum class RequestDurationUnit(val title: String, val maximumValue: Int) {
    MINUTES("Phút", 60),
    HOURS("Giờ", 24),
}

val requestKinds = listOf(
    RequestKindUi("leave", "Nghỉ phép", Icons.Default.EventAvailable, Color(0xFF007AFF)),
    RequestKindUi("late", "Đi trễ", Icons.Default.Schedule, Color(0xFFFF9500)),
    RequestKindUi("early", "Về sớm", Icons.AutoMirrored.Filled.ExitToApp, Color(0xFFE63885)),
    RequestKindUi("overtime", "Làm thêm giờ", Icons.Default.DarkMode, Color(0xFF5266F5)),
    RequestKindUi("business", "Công tác", Icons.Default.Flight, Color(0xFF008080)),
    RequestKindUi("attendance", "Xác nhận giờ công", Icons.Default.CheckCircle, Color(0xFF34C759)),
    RequestKindUi("gate", "Ra cổng", Icons.AutoMirrored.Filled.ExitToApp, Color(0xFF8E63D2)),
)
fun requestKind(key: String) = requestKinds.firstOrNull { it.key == key } ?: requestKinds.first()
fun requestStatus(status: String) = when (status) { "pending" -> "Chờ duyệt" to Color(0xFFFF9500); "approved" -> "Đã duyệt" to Color(0xFF34C759); "rejected" -> "Từ chối" to SukavinaRed; else -> "Đã hủy" to Color(0xFF8E8E93) }

/**
 * Neutral request-form surface.  Do not rely on tonal elevation here: on some
 * Android/Material combinations it resolves to a red-tinted container in dark
 * mode, which makes the time cards look like an error state.
 */
@Composable
private fun requestFormFieldSurfaceColor(): Color =
    if (isSukavinaDarkTheme()) Color(0xFF292A30) else MaterialTheme.colorScheme.surface

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
    val density = LocalDensity.current
    // Let request content follow the user's larger font preference, while
    // capping the dense title/filter strip before it can consume the screen.
    val compactDensity = remember(density.density, density.fontScale) {
        Density(density.density, density.fontScale.coerceAtMost(1.2f))
    }
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
        // Keep the page title and filter controls out of the status-bar and
        // display-cutout area on Android 15+.
        contentWindowInsets = WindowInsets.safeDrawing,
        containerColor = Color.Transparent,
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            CompositionLocalProvider(LocalDensity provides compactDensity) {
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
    reviewing?.let { request: EmployeeRequest ->
        RequestDecisionDialog(
            request = request,
            working = state.working,
            dismiss = { reviewing = null },
            decide = { approved: Boolean, note: String ->
                session.decideRequest(request.id, approved, note) { completed: Boolean ->
                    if (completed) reviewing = null
                }
            },
        )
    }
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
    val density = LocalDensity.current
    // Request cards remain readable at a larger system font.  Their flexible
    // rows grow vertically, and the cap prevents metadata from crowding out
    // the actual request content on small displays.
    val cardDensity = remember(density.density, density.fontScale) {
        Density(density.density, density.fontScale.coerceAtMost(1.2f))
    }
    CompositionLocalProvider(LocalDensity provides cardDensity) {
        Card(
            onClick = onClick,
            modifier = Modifier.fillMaxWidth().iosCardShadow(cardShape),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
            shape = cardShape,
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(13.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                Surface(Modifier.size(46.dp), appShape(15.dp, AppShapeRole.LARGE), color = kind.color.copy(alpha = .16f)) { Icon(kind.icon, null, tint = kind.color, modifier = Modifier.padding(12.dp)) }
                Column(Modifier.padding(start = 12.dp).weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(request.employee?.fullName ?: "Đơn của tôi", fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Surface(shape = CircleShape, color = kind.color.copy(alpha = .14f)) { Text(kind.title, color = kind.color, fontSize = 11.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp)) }
                }
                Surface(shape = CircleShape, color = status.second.copy(alpha = .14f)) { Text(status.first, color = status.second, fontSize = 11.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp)) }
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                Icon(
                    Icons.Default.Schedule,
                    null,
                    tint = SukavinaMuted,
                    modifier = Modifier.padding(top = 3.dp).size(17.dp),
                )
                Column(
                    modifier = Modifier.padding(start = 7.dp).weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text("Từ: ${request.startsAt.toDateTimeLabel()}", color = SukavinaMuted, fontSize = 13.sp)
                    Text("Đến: ${request.endsAt.toDateTimeLabel()}", color = SukavinaMuted, fontSize = 13.sp)
                }
            }
            Text(request.reason, lineHeight = 20.sp)
            request.decisionNote?.takeIf { it.isNotBlank() }?.let { Text(it, color = SukavinaMuted, fontSize = 12.sp) }
            if (canCancel) TextButton(onClick = onCancel, modifier = Modifier.align(Alignment.End)) { Text("Hủy đơn", color = MaterialTheme.colorScheme.error) }
            }
        }
    }
}

@Composable fun RequestComposer(session: SessionViewModel, working: Boolean, dismiss: () -> Unit, submit: (String, String, String, String, String?, String?, Double?, Double?) -> Unit) {
    var kind by remember { mutableStateOf(requestKinds.first()) }
    var reason by remember { mutableStateOf("") }
    var destination by remember { mutableStateOf("") }
    var transport by remember { mutableStateOf("personal_vehicle") }
    var distance by remember { mutableStateOf("") }
    var expense by remember { mutableStateOf("") }
    var from by remember { mutableStateOf(LocalDateTime.now()) }
    var to by remember { mutableStateOf(LocalDateTime.now().plusHours(8)) }
    var durationValue by remember { mutableIntStateOf(30) }
    var durationUnit by remember { mutableStateOf(RequestDurationUnit.MINUTES) }
    var attendance by remember { mutableStateOf<AttendanceDay?>(null) }
    var attendanceDate by remember { mutableStateOf(LocalDate.now()) }
    val formScrollState = rememberScrollState()
    val scope = rememberCoroutineScope()
    val usesDurationInput = kind.key in setOf("late", "early", "overtime")
    val durationMinutes = if (durationUnit == RequestDurationUnit.HOURS) durationValue * 60 else durationValue
    val submittedFrom = when (kind.key) {
        "leave", "late", "early", "overtime" -> from.toLocalDate().atStartOfDay()
        else -> from
    }
    val submittedTo = when (kind.key) {
        "leave" -> from.toLocalDate().atTime(23, 59, 59)
        "late", "early", "overtime" -> submittedFrom.plusMinutes(durationMinutes.toLong())
        else -> to
    }
    val submittedReason = if (usesDurationInput) {
        "${kind.title}: $durationValue ${durationUnit.title.lowercase()}. ${reason.trim()}"
    } else reason.trim()
    fun scheduledAttendanceTime(value: String?, fallbackHour: Int, fallbackMinute: Int): LocalDateTime {
        val parts = value?.split(":")?.mapNotNull { it.toIntOrNull() }.orEmpty()
        val hour = parts.getOrNull(0)?.takeIf { it in 0..23 } ?: fallbackHour
        val minute = parts.getOrNull(1)?.takeIf { it in 0..59 } ?: fallbackMinute
        return attendanceDate.atTime(hour, minute)
    }
    LaunchedEffect(kind.key, attendanceDate) {
        if (kind.key == "attendance") {
            attendance = null
            scope.launch {
                session.attendance(attendanceDate.format(DateTimeFormatter.ofPattern("yyyy-MM"))).onSuccess { month ->
                    val day = month.days.firstOrNull { it.date == attendanceDate.toString() }
                    attendance = day
                    from = day?.checkIn?.let { runCatching { Instant.parse(it).atZone(ZoneId.of("Asia/Ho_Chi_Minh")).toLocalDateTime() }.getOrNull() }
                        ?: scheduledAttendanceTime(day?.startTime ?: month.startTime, fallbackHour = 7, fallbackMinute = 30)
                    to = day?.checkOut?.let { runCatching { Instant.parse(it).atZone(ZoneId.of("Asia/Ho_Chi_Minh")).toLocalDateTime() }.getOrNull() }
                        ?: scheduledAttendanceTime(day?.endTime ?: month.endTime, fallbackHour = 16, fallbackMinute = 30)
                }
            }
        }
    }
    Dialog(
        onDismissRequest = { if (!working) dismiss() },
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            // Let Compose receive and animate the IME inset for this dialog
            // instead of the platform resizing its window in a single jump.
            decorFitsSystemWindows = false,
        ),
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxSize()
                // Insets are handled inside Compose and animate with the IME.
                // The surface is therefore moved as one sheet rather than
                // being abruptly re-laid out by the platform dialog window.
                .safeDrawingPadding()
                .imePadding()
                .padding(horizontal = 20.dp, vertical = 16.dp),
            contentAlignment = Alignment.BottomCenter,
        ) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    // maxHeight is the visible area after IME resize. Keep the
                    // sheet within it, while the middle section scrolls and the
                    // action row remains available above the keyboard.
                    .heightIn(max = minOf(maxHeight, 680.dp))
                    .fillMaxHeight(),
                shape = RoundedCornerShape(28.dp),
                color = if (isSukavinaDarkTheme()) Color(0xFF2A2A2E) else MaterialTheme.colorScheme.surface,
                tonalElevation = 6.dp,
                shadowElevation = 18.dp,
            ) {
            Column(Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 24.dp, top = 20.dp, end = 12.dp, bottom = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Tạo đơn mới", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                        Text("Điền thông tin rõ ràng để đơn được xử lý nhanh hơn.", color = SukavinaMuted, fontSize = 12.sp)
                    }
                    IconButton(
                        enabled = !working,
                        onClick = dismiss,
                        modifier = Modifier.size(44.dp),
                    ) { Icon(Icons.Default.Close, contentDescription = "Đóng") }
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .55f))
                Column(
                    Modifier
                        .weight(1f)
                        .verticalScroll(formScrollState)
                        .padding(horizontal = 20.dp, vertical = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
            val density = LocalDensity.current
            val kindSelectorDensity = remember(density.density, density.fontScale) {
                Density(density.density, density.fontScale.coerceAtMost(1.2f))
            }
            CompositionLocalProvider(LocalDensity provides kindSelectorDensity) {
                requestKinds.chunked(2).forEach { row ->
                    Row(
                        modifier = Modifier.fillMaxWidth().height(IntrinsicSize.Min),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        row.forEach { item ->
                            FilterChip(
                                selected = kind == item,
                                onClick = {
                                    kind = item
                                    val now = LocalDateTime.now()
                                    when (item.key) {
                                        "business", "gate" -> {
                                            from = now
                                            to = now.plusHours(1)
                                        }
                                        "late", "early", "overtime" -> {
                                            durationValue = 30
                                            durationUnit = RequestDurationUnit.MINUTES
                                            from = now.toLocalDate().atStartOfDay()
                                            to = from.plusMinutes(30)
                                        }
                                    }
                                },
                                label = { Text(item.title, maxLines = 2) },
                                leadingIcon = { Icon(item.icon, null, Modifier.size(17.dp), tint = item.color) },
                                modifier = Modifier.weight(1f).fillMaxHeight().heightIn(min = 44.dp),
                            )
                        }
                        if (row.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
            if (kind.key == "attendance") {
                DateOnlyField("Ngày đối chiếu", attendanceDate) { selected ->
                    attendanceDate = selected
                }
                Text("Chọn ngày để đối chiếu giờ chấm công. Ngày mặc định là ngày tạo đơn.", color = SukavinaMuted, fontSize = 12.sp)
                val timeFormatter = DateTimeFormatter.ofPattern("HH:mm")
                val checkIn = attendance?.checkIn?.let { value -> runCatching { Instant.parse(value).atZone(ZoneId.of("Asia/Ho_Chi_Minh")).toLocalDateTime() }.getOrNull() }
                val checkOut = attendance?.checkOut?.let { value -> runCatching { Instant.parse(value).atZone(ZoneId.of("Asia/Ho_Chi_Minh")).toLocalDateTime() }.getOrNull() }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Surface(
                        shape = MaterialTheme.shapes.medium,
                        color = requestFormFieldSurfaceColor(),
                        tonalElevation = 0.dp,
                        modifier = Modifier.weight(1f),
                    ) {
                        Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
                            Text("GIỜ VÀO", fontSize = 11.sp, color = SukavinaMuted, fontWeight = FontWeight.SemiBold)
                            Text(checkIn?.format(timeFormatter) ?: "Thiếu", color = if (checkIn == null) Color(0xFFFF9500) else Color(0xFF34C759), fontWeight = FontWeight.Bold)
                        }
                    }
                    Surface(
                        shape = MaterialTheme.shapes.medium,
                        color = requestFormFieldSurfaceColor(),
                        tonalElevation = 0.dp,
                        modifier = Modifier.weight(1f),
                    ) {
                        Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
                            Text("GIỜ RA", fontSize = 11.sp, color = SukavinaMuted, fontWeight = FontWeight.SemiBold)
                            Text(checkOut?.format(timeFormatter) ?: "Thiếu", color = if (checkOut == null) Color(0xFFFF9500) else Color(0xFF34C759), fontWeight = FontWeight.Bold)
                        }
                    }
                }
                if (checkIn == null) TimeInputField("Nhập giờ vào", from) { from = it }
                if (checkOut == null) TimeInputField("Nhập giờ ra", to) { to = it }
                Text("Giờ bổ sung chỉ được cập nhật sau khi đơn được duyệt.", color = SukavinaMuted, fontSize = 12.sp)
            } else if (kind.key == "leave") {
                DateOnlyField("Từ ngày", from.toLocalDate()) { selected ->
                    from = selected.atStartOfDay()
                    if (to.toLocalDate().isBefore(selected)) to = selected.atTime(23, 59, 59)
                }
                DateOnlyField("Đến ngày", to.toLocalDate()) { selected ->
                    to = selected.atTime(23, 59, 59)
                }
            } else if (!usesDurationInput) {
                DateTimeField("Bắt đầu", from) { selected ->
                    from = selected
                    if (to.isBefore(selected)) to = selected.plusHours(1)
                }
                DateTimeField("Kết thúc", to) { to = it }
            }
            if (usesDurationInput) {
                DurationRequestFields(
                    kindTitle = kind.title,
                    kindColor = kind.color,
                    value = durationValue,
                    unit = durationUnit,
                    onValueChanged = { durationValue = it },
                    onUnitChanged = { unit ->
                        durationUnit = unit
                        durationValue = if (unit == RequestDurationUnit.HOURS) 1 else durationValue.coerceAtMost(unit.maximumValue)
                    },
                )
            }
            if (kind.key == "business") {
                OutlinedTextField(destination, { destination = it }, label = { Text("Nơi đến") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Text("Phương tiện", color = SukavinaMuted, fontSize = 12.sp)
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    listOf("personal_vehicle" to "Xe cá nhân", "grab" to "Grab", "company_vehicle" to "Xe công ty").forEach { (key,label) ->
                        FilterChip(
                            selected = transport == key,
                            onClick = { transport = key },
                            label = { Text(label, maxLines = 1) },
                            modifier = Modifier.heightIn(min = 40.dp),
                        )
                    }
                }
                if (transport == "personal_vehicle") OutlinedTextField(distance, { distance = it }, label = { Text("Số km") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(expense, { expense = it }, label = { Text("Chi phí (VNĐ)") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true, modifier = Modifier.fillMaxWidth())
                Text("Đơn công tác không cần nhập lý do.", color = SukavinaMuted, fontSize = 12.sp)
            } else if (kind.key != "business") {
                OutlinedTextField(
                    value = reason,
                    onValueChange = { reason = it },
                    label = { Text(if (kind.key == "attendance") "Nội dung đơn" else "Lý do") },
                    placeholder = {
                        if (kind.key == "attendance") {
                            Text("Mô tả phần giờ công cần xác nhận hoặc lưu ý cho người duyệt...")
                        }
                    },
                    // Keep the editor viewport stable. Long text scrolls in
                    // this field instead of changing the parent form height.
                    minLines = 4,
                    maxLines = 4,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text("Tối thiểu 10 ký tự", color = if (reason.trim().length >= 10) Color(0xFF55D881) else SukavinaMuted, fontSize = 11.sp)
            }
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .55f))
                val validBusiness = destination.trim().length >= 2 &&
                    (transport != "personal_vehicle" || (distance.toDoubleOrNull() ?: 0.0) > 0)
                val canSubmit = !working &&
                    (kind.key == "business" && validBusiness || reason.trim().length >= 10) &&
                    !submittedTo.isBefore(submittedFrom)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 14.dp)
                        .navigationBarsPadding(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    OutlinedButton(
                        enabled = !working,
                        onClick = dismiss,
                        modifier = Modifier.weight(1f),
                    ) { Text("Hủy") }
                    Button(
                        enabled = canSubmit,
                        onClick = {
                            submit(
                                kind.key,
                                submittedFrom.atZone(ZoneId.systemDefault()).toInstant().toString(),
                                submittedTo.atZone(ZoneId.systemDefault()).toInstant().toString(),
                                if (kind.key == "business") "" else submittedReason,
                                destination.trim().ifBlank { null },
                                transport.takeIf { kind.key == "business" },
                                distance.toDoubleOrNull(),
                                expense.toDoubleOrNull(),
                            )
                        },
                        modifier = Modifier.weight(1.25f),
                    ) { Text(if (working) "Đang gửi..." else "Gửi đơn") }
                }
            }
        }
        }
    }
}

@Composable
private fun DurationRequestFields(
    kindTitle: String,
    kindColor: Color,
    value: Int,
    unit: RequestDurationUnit,
    onValueChanged: (Int) -> Unit,
    onUnitChanged: (RequestDurationUnit) -> Unit,
) {
    var valueMenuOpen by remember { mutableStateOf(false) }
    var unitMenuOpen by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Thời lượng", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
        Text("Chọn thời lượng $kindTitle để gửi yêu cầu.", color = SukavinaMuted, fontSize = 12.sp)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.weight(1f)) {
                OutlinedButton(
                    onClick = { valueMenuOpen = true },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
                ) {
                    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("SỐ LƯỢNG", color = SukavinaMuted, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                        Text(value.toString(), fontWeight = FontWeight.SemiBold)
                    }
                    Icon(Icons.Default.ExpandMore, null)
                }
                DropdownMenu(expanded = valueMenuOpen, onDismissRequest = { valueMenuOpen = false }) {
                    (1..unit.maximumValue).forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option.toString()) },
                            onClick = {
                                onValueChanged(option)
                                valueMenuOpen = false
                            },
                        )
                    }
                }
            }
            Box(Modifier.weight(1f)) {
                OutlinedButton(
                    onClick = { unitMenuOpen = true },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
                ) {
                    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("ĐƠN VỊ", color = SukavinaMuted, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                        Text(unit.title, fontWeight = FontWeight.SemiBold)
                    }
                    Icon(Icons.Default.ExpandMore, null)
                }
                DropdownMenu(expanded = unitMenuOpen, onDismissRequest = { unitMenuOpen = false }) {
                    RequestDurationUnit.values().forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option.title) },
                            onClick = {
                                onUnitChanged(option)
                                unitMenuOpen = false
                            },
                        )
                    }
                }
            }
        }
        Text(
            "Thời lượng đã chọn: $value ${unit.title.lowercase()}.",
            color = kindColor,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
        )
    }
}

@Composable
private fun SukavinaDatePickerSheet(
    title: String,
    initialDate: LocalDate,
    dismiss: () -> Unit,
    confirm: (LocalDate) -> Unit,
) {
    var displayedMonth by remember(initialDate) { mutableStateOf(YearMonth.from(initialDate)) }
    var selectedDate by remember(initialDate) { mutableStateOf(initialDate) }
    val firstDayOffset = displayedMonth.atDay(1).dayOfWeek.value - 1
    val calendarCells = List(firstDayOffset) { null } + (1..displayedMonth.lengthOfMonth()).toList()
    // Pad the final row in place.  Appending a padded copy would render the
    // last calendar week twice for months that do not end on Sunday.
    val calendarRows = calendarCells.chunked(7).map { row ->
        row + List(7 - row.size) { null }
    }

    ModalBottomSheet(
        onDismissRequest = dismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(title, fontSize = 21.sp, fontWeight = FontWeight.Bold)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { displayedMonth = displayedMonth.minusMonths(1) }) {
                    Icon(Icons.Default.ChevronLeft, contentDescription = "Tháng trước")
                }
                Text(
                    displayedMonth.format(DateTimeFormatter.ofPattern("'Tháng' M 'năm' yyyy", Locale.forLanguageTag("vi"))),
                    modifier = Modifier.weight(1f),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    fontWeight = FontWeight.SemiBold,
                )
                IconButton(onClick = { displayedMonth = displayedMonth.plusMonths(1) }) {
                    Icon(Icons.Default.ChevronRight, contentDescription = "Tháng sau")
                }
            }
            Row(Modifier.fillMaxWidth()) {
                listOf("T2", "T3", "T4", "T5", "T6", "T7", "CN").forEach { weekday ->
                    Text(
                        weekday,
                        modifier = Modifier.weight(1f),
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            calendarRows.forEach { row ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    row.forEach { day ->
                        if (day == null) {
                            Spacer(Modifier.weight(1f).height(42.dp))
                        } else {
                            val date = displayedMonth.atDay(day)
                            val selected = date == selectedDate
                            Surface(
                                modifier = Modifier.weight(1f).height(42.dp).clip(CircleShape).clickable { selectedDate = date },
                                shape = CircleShape,
                                color = if (selected) SukavinaRed else Color.Transparent,
                                contentColor = if (selected) Color.White else MaterialTheme.colorScheme.onSurface,
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Text(day.toString(), fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium)
                                }
                            }
                        }
                    }
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(
                    onClick = {
                        selectedDate = LocalDate.now()
                        displayedMonth = YearMonth.now()
                    },
                    modifier = Modifier.weight(1f),
                ) { Text("Hôm nay") }
                TextButton(onClick = dismiss) { Text("Hủy") }
                Button(onClick = { confirm(selectedDate) }) { Text("Xong") }
            }
        }
    }
}

@Composable
private fun SukavinaTimePickerSheet(
    title: String,
    initialValue: LocalDateTime,
    dismiss: () -> Unit,
    confirm: (Int, Int) -> Unit,
) {
    var hour by remember(initialValue) { mutableIntStateOf(initialValue.hour) }
    var minute by remember(initialValue) { mutableIntStateOf(initialValue.minute) }
    ModalBottomSheet(
        onDismissRequest = dismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(title, fontSize = 21.sp, fontWeight = FontWeight.Bold)
            Text(
                String.format(Locale.US, "%02d:%02d", hour, minute),
                modifier = Modifier.fillMaxWidth(),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                color = SukavinaRed,
                fontSize = 34.sp,
                fontWeight = FontWeight.Black,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                SukavinaTimeWheel("Giờ", (0..23).toList(), hour, { hour = it }, Modifier.weight(1f))
                SukavinaTimeWheel("Phút", (0..59).toList(), minute, { minute = it }, Modifier.weight(1f))
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = dismiss) { Text("Hủy") }
                Button(onClick = { confirm(hour, minute) }, modifier = Modifier.padding(start = 8.dp)) { Text("Xong") }
            }
        }
    }
}

@Composable
private fun SukavinaTimeWheel(label: String, values: List<Int>, selected: Int, choose: (Int) -> Unit, modifier: Modifier = Modifier) {
    val state = rememberLazyListState(initialFirstVisibleItemIndex = values.indexOf(selected).coerceAtLeast(0))
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        LazyColumn(
            state = state,
            modifier = Modifier.height(176.dp).fillMaxWidth().clip(appShape(16.dp, AppShapeRole.LARGE)).background(requestFormFieldSurfaceColor()),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(2.dp),
            contentPadding = PaddingValues(vertical = 8.dp),
        ) {
            items(values, key = { it }) { number ->
                val isSelected = number == selected
                Surface(
                    modifier = Modifier.fillMaxWidth().height(40.dp).padding(horizontal = 8.dp).clip(appShape(12.dp)).clickable { choose(number) },
                    shape = appShape(12.dp),
                    color = if (isSelected) SukavinaRed else Color.Transparent,
                    contentColor = if (isSelected) Color.White else MaterialTheme.colorScheme.onSurface,
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Text(String.format(Locale.US, "%02d", number), fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium)
                    }
                }
            }
        }
    }
}

@Composable
private fun DateOnlyField(label: String, value: LocalDate, changed: (LocalDate) -> Unit) {
    var pickerOpen by remember { mutableStateOf(false) }
    if (pickerOpen) SukavinaDatePickerSheet(
        title = label,
        initialDate = value,
        dismiss = { pickerOpen = false },
        confirm = { selected -> changed(selected); pickerOpen = false },
    )
    OutlinedButton(
        onClick = { pickerOpen = true },
        modifier = Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Icon(Icons.Default.CalendarMonth, null, Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                value.format(DateTimeFormatter.ofPattern("dd/MM/yyyy")),
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun TimeInputField(label: String, value: LocalDateTime, changed: (LocalDateTime) -> Unit) {
    var pickerOpen by remember { mutableStateOf(false) }
    if (pickerOpen) SukavinaTimePickerSheet(
        title = label,
        initialValue = value,
        dismiss = { pickerOpen = false },
        confirm = { hour, minute -> changed(value.withHour(hour).withMinute(minute)); pickerOpen = false },
    )
    OutlinedButton(
        onClick = { pickerOpen = true },
        modifier = Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Icon(Icons.Default.Schedule, null, Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(value.format(DateTimeFormatter.ofPattern("HH:mm")), fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable fun DateTimeField(label: String, value: LocalDateTime, changed: (LocalDateTime) -> Unit) {
    var showTimePicker by remember { mutableStateOf(false) }
    var showDatePicker by remember { mutableStateOf(false) }

    if (showDatePicker) SukavinaDatePickerSheet(
        title = "Chọn ngày ${label.lowercase()}",
        initialDate = value.toLocalDate(),
        dismiss = { showDatePicker = false },
        confirm = { date -> changed(LocalDateTime.of(date, value.toLocalTime())); showDatePicker = false },
    )
    if (showTimePicker) SukavinaTimePickerSheet(
        title = "Chọn giờ ${label.lowercase()}",
        initialValue = value,
        dismiss = { showTimePicker = false },
        confirm = { hour, minute -> changed(value.withHour(hour).withMinute(minute)); showTimePicker = false },
    )

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = appShape(17.dp, AppShapeRole.LARGE),
        colors = CardDefaults.cardColors(containerColor = requestFormFieldSurfaceColor()),
    ) {
        Column(Modifier.padding(13.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            Text(label.uppercase(), color = SukavinaMuted, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = .8.sp)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                OutlinedButton(
                    onClick = { showDatePicker = true },
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
