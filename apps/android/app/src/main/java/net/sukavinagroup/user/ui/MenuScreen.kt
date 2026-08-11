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
import androidx.compose.ui.graphics.Brush
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


@Composable fun TodayMenuScreen(state: SessionUiState, session: SessionViewModel) {
    LaunchedEffect(Unit) {
        session.refreshTodayMenu()
        while (true) {
            val now = ZonedDateTime.now(ZoneId.of("Asia/Ho_Chi_Minh"))
            val nextDay = now.toLocalDate().plusDays(1).atStartOfDay(now.zone)
            delay(maxOf(1_000L, Duration.between(now, nextDay).toMillis() + 500L))
            session.refreshTodayMenu()
        }
    }
    val menu = state.todayMenu
    var pendingChoice by remember { mutableStateOf<String?>(null) }
    if (pendingChoice != null) {
        val cancelling = pendingChoice == "cancel"
        val receiving = pendingChoice == "received"
        val title = if (pendingChoice == "water") "Món nước" else "Món chay"
        val detail = if (pendingChoice == "water") menu?.day?.featured else listOfNotNull(menu?.day?.vegetarianMain, menu?.day?.vegetarianSide).filter { it.isNotBlank() }.joinToString(" · ")
        AlertDialog(
            onDismissRequest = { pendingChoice = null },
            icon = {
                Surface(shape = appShape(18.dp, AppShapeRole.LARGE), color = (if (cancelling) Color(0xFFFF6F67) else if (pendingChoice == "water") Color(0xFF62C5F4) else Color(0xFF62D58B)).copy(alpha = .14f), modifier = Modifier.size(58.dp)) {
                    Icon(if (cancelling) Icons.Default.Cancel else if (receiving) Icons.Default.CheckCircle else if (pendingChoice == "water") Icons.Default.LocalDrink else Icons.Default.Eco, null, tint = if (cancelling) Color(0xFFFF6F67) else if (receiving) Color(0xFF42B878) else if (pendingChoice == "water") Color(0xFF62C5F4) else Color(0xFF62D58B), modifier = Modifier.padding(15.dp))
                }
            },
            title = { Text(if (cancelling) "Hủy lựa chọn hôm nay?" else if (receiving) "Bạn đã nhận món?" else "Xác nhận $title", fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(13.dp)) {
                    Text(if (cancelling) "Bạn có thể chọn lại món khác bất cứ lúc nào trong ngày." else if (receiving) "Xác nhận sau khi bạn đã nhận đúng phần ăn đã đặt." else "Kiểm tra món trước khi xác nhận đặt.", color = SukavinaMuted)
                    if (!cancelling && !receiving) Surface(shape = appShape(14.dp), color = MaterialTheme.colorScheme.surface) {
                        Column(Modifier.fillMaxWidth().padding(14.dp)) {
                            Text(title.uppercase(), color = SukavinaMuted, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = .8.sp)
                            Text(detail?.ifBlank { "..." } ?: "...", fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 5.dp))
                        }
                    }
                }
            },
            confirmButton = { Button(onClick = {
                pendingChoice?.let { choice ->
                    pendingChoice = null
                    when (choice) {
                        "cancel" -> session.cancelMealSelection()
                        "received" -> session.receiveMealSelection()
                        else -> session.selectMeal(choice)
                    }
                }
            }, colors = ButtonDefaults.buttonColors(containerColor = if (cancelling) MaterialTheme.colorScheme.error else if (receiving) Color(0xFF42B878) else SukavinaRed)) { Text(if (cancelling) "Xác nhận hủy" else if (receiving) "Xác nhận đã nhận" else "Đặt món") } },
            dismissButton = { TextButton(onClick = { pendingChoice = null }) { Text("Quay lại") } },
        )
    }
    LazyColumn(contentPadding = PaddingValues(start = 20.dp, top = 20.dp, end = 20.dp, bottom = 112.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            PortalPageTitle("Thực đơn")
            Text("BẾP ĂN SUKAVINA", color = SukavinaRed, fontWeight = FontWeight.Bold, letterSpacing = 1.5.sp, fontSize = 12.sp)
            Text("Thực đơn hôm nay", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Text(menu?.day?.dayName ?: "Đang cập nhật", color = SukavinaMuted)
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    MenuGroupCard("Món nước", Icons.Default.LocalDrink, Color(0xFF62C5F4), listOf(menu?.day?.featured), Modifier.weight(1f))
                    MenuGroupCard("Món thường", Icons.Default.Restaurant, Color(0xFFFFA568), listOf(menu?.day?.savoryMain, menu?.day?.savorySide, menu?.day?.vegetable, menu?.day?.soup), Modifier.weight(1f))
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    MenuGroupCard("Món chay", Icons.Default.Eco, Color(0xFF62D58B), listOf(menu?.day?.vegetarianMain, menu?.day?.vegetarianSide), Modifier.weight(1f))
                    MenuGroupCard("Tăng ca", Icons.Default.DarkMode, Color(0xFFB396F5), listOf(menu?.day?.overtime), Modifier.weight(1f))
                }
            }
        }
        item {
            Card(shape = appShape(22.dp, AppShapeRole.EXTRA_LARGE), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
                Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(11.dp)) {
                    if (menu?.selection != null) {
                        val water = menu.selection == "water"
                        val selectedDetail = if (water) menu.day.featured else listOf(menu.day.vegetarianMain, menu.day.vegetarianSide).filter { it.isNotBlank() }.joinToString(" · ")
                        Text("MÓN ĂN ĐÃ ĐẶT", color = SukavinaMuted, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(13.dp)) {
                            Surface(shape = appShape(15.dp), color = (if (water) Color(0xFF62C5F4) else Color(0xFF62D58B)).copy(alpha = .14f), modifier = Modifier.size(50.dp)) {
                                Icon(if (water) Icons.Default.LocalDrink else Icons.Default.Eco, null, tint = if (water) Color(0xFF62C5F4) else Color(0xFF62D58B), modifier = Modifier.padding(13.dp))
                            }
                            Column {
                                Text(if (water) "Món nước" else "Món chay", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                                Text(selectedDetail.ifBlank { "..." }, color = SukavinaMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            }
                        }
                        if (menu.receivedAt == null) {
                            TextButton(onClick = { pendingChoice = "cancel" }, enabled = menu.orderingOpen, modifier = Modifier.fillMaxWidth()) {
                                Icon(Icons.Default.Cancel, null, tint = MaterialTheme.colorScheme.error)
                                Spacer(Modifier.width(7.dp))
                                Text("Hủy lựa chọn món ăn", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.SemiBold)
                            }
                        }
                        MealQrAccessCard(session, state.working)
                    } else {
                        Text("LỰA CHỌN HÔM NAY", color = SukavinaMuted, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
                        Text("Bạn muốn dùng món nào?", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                        if (menu?.orderingOpen == false) {
                            Surface(shape = appShape(16.dp, AppShapeRole.LARGE), color = Color(0xFFF5A63D).copy(alpha = .11f), modifier = Modifier.fillMaxWidth()) {
                                Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Default.Schedule, null, tint = Color(0xFFF5A63D))
                                    Spacer(Modifier.width(10.dp))
                                    Column {
                                        Text("Đã khóa đặt món", color = Color(0xFFF5A63D), fontWeight = FontWeight.Bold)
                                        Text("Vui lòng đặt món trước ${menu.orderingCutoff}.", color = SukavinaMuted, fontSize = 12.sp)
                                    }
                                }
                            }
                        } else {
                            MealChoiceButton("Món nước", menu?.day?.featured, Icons.Default.LocalDrink, Color(0xFF62C5F4), false, state.working) { pendingChoice = "water" }
                            MealChoiceButton("Món chay", listOfNotNull(menu?.day?.vegetarianMain, menu?.day?.vegetarianSide).filter { it.isNotBlank() }.joinToString(" · "), Icons.Default.Eco, Color(0xFF62D58B), false, state.working) { pendingChoice = "vegetarian" }
                        }
                    }
                }
            }
        }
    }
}

@Composable fun MealQrAccessCard(session: SessionViewModel, working: Boolean) {
    var issued by remember { mutableStateOf<MealQrIssueResponse?>(null) }
    var seconds by remember { mutableIntStateOf(0) }
    LaunchedEffect(issued) {
        while (issued != null && seconds > 0) { delay(1_000); seconds-- }
    }
    Card(shape = appShape(18.dp, AppShapeRole.LARGE), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            val activeIssue = issued?.takeIf { seconds > 0 }
            if (activeIssue != null) {
                val bitmap = remember(activeIssue.token) { createQrBitmap(activeIssue.token) }
                Image(bitmap = bitmap.asImageBitmap(), contentDescription = "Mã QR nhận món", modifier = Modifier.size(190.dp).background(Color.White).padding(10.dp))
                Text("Mã tự ẩn sau ${seconds}s", color = if (seconds <= 5) MaterialTheme.colorScheme.error else SukavinaMuted, fontWeight = FontWeight.Bold)
            } else {
                Text("MÃ QR NHẬN MÓN", color = SukavinaMuted, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
                Button(onClick = { session.issueMealQr { result -> issued = result; seconds = if (result == null) 0 else 30 } }, enabled = !working, modifier = Modifier.fillMaxWidth(), elevation = SukavinaButtonElevation, colors = ButtonDefaults.buttonColors(containerColor = SukavinaRed)) {
                    Icon(Icons.Default.QrCode, null); Spacer(Modifier.width(8.dp)); Text("Lấy mã nhận món", fontWeight = FontWeight.Bold)
                }
                Text("Mỗi mã chỉ có hiệu lực trong 30 giây.", color = SukavinaMuted, fontSize = 12.sp)
            }
        }
    }
}

fun createQrBitmap(value: String): Bitmap {
    val hints = mapOf(EncodeHintType.MARGIN to 1)
    val matrix: BitMatrix = MultiFormatWriter().encode(value, BarcodeFormat.QR_CODE, 512, 512, hints)
    return createBitmap(512, 512, Bitmap.Config.ARGB_8888).also { bitmap ->
        for (x in 0 until 512) for (y in 0 until 512) bitmap[x, y] = if (matrix[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE
    }
}

@Composable fun MenuGroupCard(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, color: Color, lines: List<String?>, modifier: Modifier = Modifier) {
    val cardShape = appShape(19.dp, AppShapeRole.LARGE)
    Card(modifier.fillMaxWidth().height(148.dp).background(Brush.linearGradient(listOf(color.copy(alpha = .13f), MaterialTheme.colorScheme.surface)), cardShape), shape = cardShape, colors = CardDefaults.cardColors(containerColor = Color.Transparent), border = androidx.compose.foundation.BorderStroke(1.dp, color.copy(alpha = .18f))) {
        Row(Modifier.fillMaxWidth().padding(15.dp), verticalAlignment = Alignment.Top) {
            Surface(shape = appShape(14.dp), color = color.copy(alpha = .14f), modifier = Modifier.size(46.dp)) {
                Icon(icon, null, tint = color, modifier = Modifier.padding(11.dp))
            }
            Column(Modifier.padding(start = 13.dp).weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(title.uppercase(), color = color, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = .8.sp)
                lines.forEach { value ->
                    Text(
                        value?.ifBlank { "..." } ?: "...",
                        fontSize = 14.sp,
                        lineHeight = 19.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable fun MealChoiceButton(title: String, detail: String?, icon: androidx.compose.ui.graphics.vector.ImageVector, color: Color, selected: Boolean, disabled: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        enabled = !disabled,
        shape = appShape(17.dp, AppShapeRole.LARGE),
        color = if (selected) color.copy(alpha = .12f) else MaterialTheme.colorScheme.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, if (selected) color.copy(alpha = .45f) else MaterialTheme.colorScheme.outline.copy(alpha = .15f)),
    ) {
        Row(Modifier.fillMaxWidth().padding(13.dp), verticalAlignment = Alignment.CenterVertically) {
            Surface(shape = appShape(14.dp), color = color.copy(alpha = .14f), modifier = Modifier.size(44.dp)) { Icon(icon, null, tint = color, modifier = Modifier.padding(11.dp)) }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) { Text(title, fontWeight = FontWeight.Bold); Text(detail?.ifBlank { "..." } ?: "...", color = SukavinaMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            Icon(if (selected) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked, null, tint = if (selected) color else SukavinaMuted)
        }
    }
}
