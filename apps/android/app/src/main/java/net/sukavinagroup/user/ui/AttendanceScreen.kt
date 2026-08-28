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
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.Density
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


@Composable fun AttendanceScreen(
    session: SessionViewModel,
    displayMode: AttendanceMonthDisplayMode,
    back: () -> Unit,
) {
    val sessionState by session.state.collectAsState()
    val activity = LocalActivity.current
    val containerWidth = with(LocalDensity.current) {
        LocalWindowInfo.current.containerSize.width.toDp()
    }
    var innerFoldOpen by remember { mutableStateOf(false) }
    val useTwoPane = innerFoldOpen || containerWidth >= 840.dp
    val months = remember { listOf(YearMonth.now().minusMonths(1), YearMonth.now()) }
    val pagerState = rememberPagerState(initialPage = months.lastIndex, pageCount = { months.size })
    val scope = rememberCoroutineScope()
    val cache = remember { mutableStateMapOf<YearMonth, AttendanceMonth>() }
    val errors = remember { mutableStateMapOf<YearMonth, String>() }
    val selectedDates = remember { mutableStateMapOf<YearMonth, String>() }

    LaunchedEffect(activity) {
        val host = activity ?: return@LaunchedEffect
        WindowInfoTracker.getOrCreate(host).windowLayoutInfo(host).collect { layout ->
            innerFoldOpen = layout.displayFeatures
                .filterIsInstance<FoldingFeature>()
                .any {
                    // Some Fold devices continue reporting a stale feature for
                    // a short time while moving the app to the cover display.
                    // A real inner-display hinge must occupy visible bounds.
                    !it.bounds.isEmpty &&
                    it.orientation == FoldingFeature.Orientation.VERTICAL &&
                        (it.isSeparating || it.state == FoldingFeature.State.FLAT)
                }
        }
    }

    LaunchedEffect(sessionState.attendanceRevision) {
        cache.clear()
        errors.clear()
        months.forEach { month ->
            launch {
                session.attendance(month.toString())
                    .onSuccess { data ->
                        cache[month] = data
                        errors.remove(month)
                        selectedDates[month] = data.days.firstOrNull { it.date == LocalDate.now().toString() }?.date
                            ?: data.days.lastOrNull()?.date.orEmpty()
                    }
                    .onFailure { errors[month] = it.message ?: "Không thể tải bảng chấm công." }
            }
        }
    }

    Scaffold(
        // Do not opt out of safe drawing: Android 15 draws the app behind
        // system bars by default, including display cutouts.
        contentWindowInsets = WindowInsets.safeDrawing,
        containerColor = Color.Transparent,
        topBar = {
            Surface(color = Color.Transparent) {
                Row(
                    Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = 48.dp).padding(horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = back, modifier = Modifier.size(44.dp)) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Quay lại")
                    }
                    Text(
                        "Bảng chấm công",
                        fontSize = 19.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 2,
                        modifier = Modifier.padding(start = 4.dp),
                    )
                }
            }
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Box(Modifier.fillMaxWidth()) {
            if (!useTwoPane) Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
                    .clip(appShape(18.dp, AppShapeRole.LARGE))
                    .background(MaterialTheme.colorScheme.surface).padding(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(
                    onClick = { scope.launch { pagerState.animateScrollToPage(pagerState.currentPage - 1) } },
                    enabled = pagerState.currentPage > 0,
                ) { Icon(Icons.Default.ChevronLeft, "Tháng trước") }
                Text(
                    "Tháng ${months[pagerState.currentPage].monthValue} / ${months[pagerState.currentPage].year}",
                    modifier = Modifier.weight(1f),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    fontWeight = FontWeight.ExtraBold,
                    maxLines = 2,
                )
                IconButton(
                    onClick = { scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) } },
                    enabled = pagerState.currentPage < months.lastIndex,
                ) { Icon(Icons.Default.ChevronRight, "Tháng sau") }
            }
            }

            Box(Modifier.fillMaxSize()) {
                if (useTwoPane) {
                    Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        months.forEach { month ->
                            AttendanceMonthPage(month, cache[month], errors[month], selectedDates[month], { selectedDates[month] = it }, displayMode, Modifier.weight(1f), showTitle = true)
                        }
                    }
                } else {
                    HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize(), beyondViewportPageCount = 1, pageSpacing = 0.dp) { page ->
                        val month = months[page]
                        AttendanceMonthPage(month, cache[month], errors[month], selectedDates[month], { selectedDates[month] = it }, displayMode, Modifier.fillMaxWidth(), showTitle = false)
                    }
                }
            }
        }
    }
}

@Composable fun AttendanceMonthPage(month: YearMonth, data: AttendanceMonth?, error: String?, selectedDate: String?, select: (String) -> Unit, displayMode: AttendanceMonthDisplayMode, modifier: Modifier, showTitle: Boolean) {
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = LocalBottomNavigationClearance.current), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (showTitle) Text("Tháng ${month.monthValue} / ${month.year}", fontSize = 21.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(top = 8.dp))
        when {
            data != null -> {
                AttendanceSummary(data)
                AttendanceCalendar(data, selectedDate, select, displayMode)
                if (displayMode == AttendanceMonthDisplayMode.COMPACT) {
                    data.days.firstOrNull { it.date == selectedDate }?.let { AttendanceDayDetail(data, it) }
                }
            }
            error != null -> Text(error, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(18.dp))
            else -> Box(Modifier.fillMaxWidth().height(260.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        }
    }
}

data class AttendanceMetric(val key: String, val title: String, val color: Color, val count: Int)
private val FullAttendanceCellHeight = 80.dp

@Composable fun AttendanceSummary(month: AttendanceMonth) {
    val metrics = listOf(
        Triple("present", "Ngày công", Color(0xFF43B86B)),
        Triple("late", "Đi trễ", requestKind("late").color),
        Triple("early", "Về sớm", requestKind("early").color),
        Triple("leave", "Nghỉ phép", requestKind("leave").color),
        Triple("absent", "Vắng", Color(0xFFFF6F67)),
        Triple("overtime", "Làm thêm", requestKind("overtime").color),
    ).map { item -> AttendanceMetric(item.first, item.second, item.third, month.days.count { item.first in it.allStatuses() }) }
        .filter { it.count > 0 }
    if (metrics.isEmpty()) return
    val density = LocalDensity.current
    val summaryDensity = remember(density.density, density.fontScale) {
        Density(density.density, density.fontScale.coerceAtMost(1.15f))
    }
    CompositionLocalProvider(LocalDensity provides summaryDensity) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        metrics.forEach { metric ->
            Surface(
                modifier = Modifier.weight(1f).heightIn(min = 56.dp),
                shape = appShape(14.dp, AppShapeRole.LARGE),
                color = MaterialTheme.colorScheme.surface,
            ) {
                Column(
                    modifier = Modifier.fillMaxSize().padding(horizontal = 2.dp, vertical = 7.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Text(metric.count.toString(), color = metric.color, fontSize = 16.sp, fontWeight = FontWeight.ExtraBold)
                    Text(metric.title, color = SukavinaMuted, fontSize = 9.sp, maxLines = 1, softWrap = false)
                }
            }
        }
        }
    }
}

@Composable fun AttendanceCalendar(month: AttendanceMonth, selectedDate: String?, select: (String) -> Unit, displayMode: AttendanceMonthDisplayMode) {
    val days = month.days
    val leading = days.firstOrNull()?.date?.let { LocalDate.parse(it).dayOfWeek.value - 1 } ?: 0
    val cells: List<AttendanceDay?> = List(leading) { null } + days
    Card(
        shape = appShape(22.dp, AppShapeRole.EXTRA_LARGE),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            Text("Lịch chấm công", fontSize = 18.sp, fontWeight = FontWeight.ExtraBold)
            Row(Modifier.fillMaxWidth()) {
                listOf("T2", "T3", "T4", "T5", "T6", "T7", "CN").forEach {
                    Text(it, Modifier.weight(1f), color = SukavinaMuted, fontSize = 11.sp, fontWeight = FontWeight.Bold, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                }
            }
            cells.chunked(7).forEach { week ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    repeat(7) { index ->
                        AttendanceDayCell(week.getOrNull(index), selectedDate, select, displayMode)
                    }
                }
            }
        }
    }
}

@Composable fun RowScope.AttendanceDayCell(
    day: AttendanceDay?,
    selectedDate: String?,
    select: (String) -> Unit,
    displayMode: AttendanceMonthDisplayMode,
) {
    val full = displayMode == AttendanceMonthDisplayMode.FULL
    if (day == null) {
        Spacer(Modifier.weight(1f).then(if (full) Modifier.height(FullAttendanceCellHeight) else Modifier.aspectRatio(0.92f)))
        return
    }
    val statuses = day.allStatuses()
    val shape = appShape(11.dp)
    Box(
        Modifier.weight(1f).then(if (full) Modifier.height(FullAttendanceCellHeight) else Modifier.aspectRatio(0.92f)).clip(shape)
            .then(if (day.date == selectedDate) Modifier.border(2.dp, MaterialTheme.colorScheme.primary, shape) else Modifier)
            .clickable { select(day.date) }
            .semantics {
                contentDescription = "Ngày ${LocalDate.parse(day.date).dayOfMonth}. Giờ vào ${day.checkIn.toTime()}, giờ ra ${day.checkOut.toTime()}"
            },
        contentAlignment = Alignment.Center,
    ) {
        if ("late" in statuses && "early" in statuses) {
            Row(Modifier.matchParentSize()) {
                Box(Modifier.weight(1f).fillMaxHeight().background(requestKind("late").color.copy(alpha = .28f)))
                Box(Modifier.weight(1f).fillMaxHeight().background(requestKind("early").color.copy(alpha = .28f)))
            }
        } else {
            Box(Modifier.matchParentSize().background(attendanceColor(statuses.firstOrNull()).copy(alpha = .22f)))
        }
        if (full) {
            val density = LocalDensity.current
            val calendarDensity = remember(density.density, density.fontScale) {
                Density(density.density, density.fontScale.coerceAtMost(1.2f))
            }
            val timeColor = if (isSukavinaDarkTheme()) Color(0xFFD0CDD4) else Color(0xFF4B4D55)
            CompositionLocalProvider(LocalDensity provides calendarDensity) {
                Column(
                    modifier = Modifier.fillMaxSize().padding(start = 1.dp, top = 4.dp, end = 1.dp, bottom = 2.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(1.dp, Alignment.Top),
                ) {
                    Text(
                        LocalDate.parse(day.date).dayOfMonth.toString(),
                        modifier = Modifier.heightIn(min = 20.dp),
                        fontSize = 12.sp,
                        fontWeight = if (day.date == selectedDate) FontWeight.ExtraBold else FontWeight.Medium,
                        maxLines = 1,
                    )
                    AttendanceCalendarTime(day.checkIn.toTime(), timeColor)
                    AttendanceCalendarTime(day.checkOut.toTime(), timeColor)
                }
            }
        } else {
            Text(LocalDate.parse(day.date).dayOfMonth.toString(), fontWeight = if (day.date == selectedDate) FontWeight.ExtraBold else FontWeight.Medium)
        }
    }
}

@Composable private fun AttendanceCalendarTime(time: String, color: Color) {
    Text(
        time,
        modifier = Modifier.fillMaxWidth().height(18.dp),
        color = color,
        fontSize = 10.sp,
        fontWeight = FontWeight.SemiBold,
        maxLines = 1,
        softWrap = false,
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
    )
}

@Composable fun AttendanceDayDetail(month: AttendanceMonth, day: AttendanceDay) = Card(
    shape = appShape(22.dp, AppShapeRole.EXTRA_LARGE),
    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
) {
    Column(Modifier.padding(17.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Chi tiết ngày ${LocalDate.parse(day.date).format(DateTimeFormatter.ofPattern("dd/MM/yyyy"))}", fontSize = 17.sp, fontWeight = FontWeight.ExtraBold)
        HorizontalDivider()
        AttendanceDetailLine("Giờ vào", day.checkIn.toTime())
        AttendanceDetailLine("Giờ ra", day.checkOut.toTime())
        AttendanceDetailLine("Trạng thái", day.allStatuses().joinToString(" · ") { attendanceTitle(it) })
        AttendanceDetailLine("Khung giờ ${month.department ?: "phòng ban"}", "${day.startTime ?: month.startTime ?: "--:--"} - ${day.endTime ?: month.endTime ?: "--:--"}")
    }
}

@Composable fun AttendanceDetailLine(label: String, value: String) = Row(Modifier.fillMaxWidth()) {
    Text(label, color = SukavinaMuted)
    Spacer(Modifier.weight(1f))
    Text(value, fontWeight = FontWeight.Bold)
}

fun AttendanceDay.allStatuses() = statuses.ifEmpty { listOfNotNull(status) }
fun attendanceColor(status: String?) = when (status) {
    "present" -> Color(0xFF43B86B)
    "late" -> requestKind("late").color
    "early" -> requestKind("early").color
    "leave" -> requestKind("leave").color
    "absent" -> Color(0xFFFF6F67)
    "overtime" -> requestKind("overtime").color
    "weekend" -> Color(0xFF9FA6B2)
    else -> Color(0xFF9FA6B2)
}
fun attendanceTitle(status: String) = when (status) {
    "present" -> "Đủ công"; "late" -> "Đi trễ"; "early" -> "Về sớm"
    "leave" -> "Nghỉ phép"; "absent" -> "Vắng"; "overtime" -> "Làm thêm giờ"
    "weekend" -> "Cuối tuần"; else -> "Chưa đến"
}
