@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package net.sukavinagroup.user.ui

import android.text.Html
import android.widget.TextView
import android.graphics.Bitmap
import android.Manifest
import android.app.Activity
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalDensity
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

private enum class MainTab(val label: String) { HOME("Trang chủ"), MENU("Thực đơn"), REQUESTS("Đơn từ"), NOTIFICATIONS("Thông báo"), PROFILE("Tài khoản") }
private enum class LegalPage { PRIVACY, SUPPORT, DELETION }
private enum class AppShapeRole { MEDIUM, LARGE, EXTRA_LARGE }

@Composable
private fun appShape(standard: Dp, role: AppShapeRole = AppShapeRole.MEDIUM): Shape {
    if (!LocalSukavinaExpressive.current) return RoundedCornerShape(standard)
    return when (role) {
        AppShapeRole.MEDIUM -> MaterialTheme.shapes.medium
        AppShapeRole.LARGE -> MaterialTheme.shapes.large
        AppShapeRole.EXTRA_LARGE -> MaterialTheme.shapes.extraLarge
    }
}

@Composable fun SukavinaApp(state: SessionUiState, session: SessionViewModel) = SukavinaTheme {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        when {
            state.restoring -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            state.token == null -> LoginScreen(state, session::signIn, session::biometricSignIn, session::dismissError)
            state.profile?.accountType == "CANTEEN" -> CanteenScannerScreen(state, session)
            else -> MainScreen(state, session)
        }
    }
}

@Composable private fun LoginScreen(
    state: SessionUiState,
    signIn: (String, String) -> Unit,
    biometricSignIn: () -> Unit = {},
    dismissError: () -> Unit = {},
) {
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
        Button(onClick = { signIn(login, password) }, enabled = login.isNotBlank() && password.isNotBlank() && !state.working,
            modifier = Modifier.fillMaxWidth().padding(top = 18.dp).height(54.dp), shape = appShape(16.dp, AppShapeRole.LARGE)) {
            if (state.working) CircularProgressIndicator(Modifier.size(22.dp), color = Color.White, strokeWidth = 2.dp)
            else Text("Đăng nhập", fontWeight = FontWeight.Bold)
        }
        if (state.biometricEnabled) OutlinedButton(onClick = { activity?.authenticateBiometric(biometricSignIn) }, modifier = Modifier.fillMaxWidth().padding(top = 10.dp).height(52.dp), shape = appShape(16.dp, AppShapeRole.LARGE)) { Icon(Icons.Default.Fingerprint, null); Spacer(Modifier.width(8.dp)); Text("Đăng nhập bằng sinh trắc học") }
    }
    state.error?.takeIf(String::isConnectionError)?.let {
        InternetConnectionAlert(dismissError)
    }
    state.error?.takeUnless(String::isConnectionError)?.let { message ->
        SukavinaAlert(
            title = "Sai thông tin đăng nhập",
            eyebrow = "KHÔNG THỂ ĐĂNG NHẬP",
            icon = Icons.Default.Lock,
            confirmText = "Đã hiểu",
            onConfirm = dismissError,
            onDismiss = dismissError,
            danger = true,
        ) {
            Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant, lineHeight = 21.sp)
        }
    }
}

@Composable private fun InternetConnectionAlert(dismiss: () -> Unit) {
    SukavinaAlert(
        title = "Kiểm tra kết nối Internet",
        eyebrow = "MẤT KẾT NỐI",
        icon = Icons.Default.WifiOff,
        confirmText = "Đóng",
        onConfirm = dismiss,
        onDismiss = dismiss,
    ) {
        Text(
            "Không thể kết nối đến máy chủ. Hãy kiểm tra Wi-Fi hoặc dữ liệu di động rồi thử lại.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            lineHeight = 21.sp,
        )
    }
}

@Composable
private fun SukavinaAlert(
    title: String,
    eyebrow: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    confirmText: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    dismissText: String? = null,
    danger: Boolean = false,
    confirmEnabled: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val tone = if (danger) MaterialTheme.colorScheme.error else SukavinaRed
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = appShape(30.dp, AppShapeRole.EXTRA_LARGE),
            color = MaterialTheme.colorScheme.surface.copy(alpha = .97f),
            tonalElevation = 10.dp,
            shadowElevation = 24.dp,
            border = androidx.compose.foundation.BorderStroke(1.dp, tone.copy(alpha = .2f)),
        ) {
            Column(Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Surface(
                        Modifier.size(54.dp),
                        appShape(18.dp, AppShapeRole.LARGE),
                        color = tone.copy(alpha = .14f),
                    ) {
                        Icon(icon, null, tint = tone, modifier = Modifier.padding(14.dp))
                    }
                    Column(Modifier.padding(start = 14.dp).weight(1f)) {
                        Text(eyebrow, color = tone, fontSize = 11.sp, fontWeight = FontWeight.Black, letterSpacing = 1.4.sp)
                        Text(title, fontSize = 21.sp, lineHeight = 25.sp, fontWeight = FontWeight.ExtraBold)
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    dismissText?.let {
                        OutlinedButton(
                            onClick = onDismiss,
                            modifier = Modifier.weight(1f).height(50.dp),
                        ) { Text(it, fontWeight = FontWeight.Bold) }
                    }
                    Button(
                        onClick = onConfirm,
                        enabled = confirmEnabled,
                        modifier = Modifier.weight(if (dismissText == null) 1f else 1.25f).height(50.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = tone, contentColor = Color.White),
                    ) { Text(confirmText, fontWeight = FontWeight.Bold) }
                }
            }
        }
    }
}

private fun String.isConnectionError() =
    contains("kết nối", ignoreCase = true) &&
        (contains("Internet", ignoreCase = true) || contains("máy chủ", ignoreCase = true))

@Composable
private fun CanteenScannerScreen(state: SessionUiState, session: SessionViewModel) {
    val context = LocalContext.current
    var cameraAllowed by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var scanning by remember { mutableStateOf(true) }
    var result by remember { mutableStateOf<MealScanResponse?>(null) }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        cameraAllowed = it
    }
    LaunchedEffect(Unit) {
        if (!cameraAllowed) permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    Column(
        Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("NHÀ ĂN SUKAVINA", color = SukavinaRed, fontSize = 12.sp, fontWeight = FontWeight.Black, letterSpacing = 1.4.sp)
                Text("Quét mã nhận món", fontSize = 27.sp, fontWeight = FontWeight.ExtraBold)
            }
            TextButton(onClick = session::signOut) { Text("Đăng xuất", color = SukavinaRed, fontWeight = FontWeight.Bold) }
        }

        result?.let { scan ->
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = appShape(26.dp, AppShapeRole.EXTRA_LARGE),
                color = MaterialTheme.colorScheme.surface,
                tonalElevation = 4.dp,
            ) {
                Column(Modifier.padding(22.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Icon(
                        if (scan.alreadyReceived) Icons.Default.Warning else Icons.Default.Verified,
                        null,
                        tint = if (scan.alreadyReceived) Color(0xFFFFA83D) else Color(0xFF38B978),
                        modifier = Modifier.size(58.dp),
                    )
                    Text(
                        if (scan.alreadyReceived) "Suất ăn đã được xác nhận" else "Xác nhận suất ăn thành công",
                        fontSize = 21.sp,
                        fontWeight = FontWeight.ExtraBold,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                    Surface(shape = appShape(18.dp, AppShapeRole.LARGE), color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .55f)) {
                        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            CanteenResultLine("Nhân viên", scan.fullName)
                            CanteenResultLine("MSNV", scan.employeeCode)
                            CanteenResultLine("Phòng ban", scan.department.ifBlank { "Chưa cập nhật" })
                            CanteenResultLine("Món đã đặt", if (scan.choice == "water") "Món nước" else "Món chay")
                        }
                    }
                    Button(
                        onClick = { result = null; scanning = true },
                        modifier = Modifier.fillMaxWidth().height(54.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = SukavinaRed),
                    ) { Icon(Icons.Default.QrCodeScanner, null); Spacer(Modifier.width(9.dp)); Text("Quét mã tiếp theo", fontWeight = FontWeight.Bold) }
                }
            }
        } ?: run {
            if (cameraAllowed) {
                Box(
                    Modifier.fillMaxWidth().weight(1f).clip(appShape(26.dp, AppShapeRole.EXTRA_LARGE)).background(Color.Black),
                ) {
                    CanteenCameraPreview(scanning, Modifier.fillMaxSize()) { code ->
                        scanning = false
                        session.scanMealQr(code) { response ->
                            if (response != null) result = response else scanning = true
                        }
                    }
                    Box(
                        Modifier.fillMaxSize().padding(36.dp).border(2.dp, SukavinaRed.copy(alpha = .8f), appShape(24.dp, AppShapeRole.LARGE)),
                    )
                    if (state.working) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .25f)), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = Color.White)
                    }
                }
                Text("Đưa camera vào mã QR trên điện thoại của người nhận món.", color = SukavinaMuted, textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.fillMaxWidth())
            } else {
                Surface(Modifier.fillMaxWidth(), shape = appShape(24.dp, AppShapeRole.EXTRA_LARGE), color = MaterialTheme.colorScheme.surface) {
                    Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        Icon(Icons.Default.NoPhotography, null, tint = SukavinaRed, modifier = Modifier.size(52.dp))
                        Text("Cần quyền Camera để quét mã nhận món.", fontWeight = FontWeight.Bold, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                        Button(onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) }) { Text("Cho phép Camera") }
                    }
                }
            }
        }
    }

    state.error?.let { message ->
        SukavinaAlert(
            title = "Chưa thể xác nhận",
            eyebrow = "MÃ QR KHÔNG HỢP LỆ",
            icon = Icons.Default.Warning,
            confirmText = "Quét lại",
            onConfirm = { session.dismissError(); scanning = true },
            onDismiss = { session.dismissError(); scanning = true },
            danger = true,
        ) { Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun CanteenResultLine(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.weight(1f))
        Text(value, fontWeight = FontWeight.Bold, textAlign = androidx.compose.ui.text.style.TextAlign.End)
    }
}

@Composable
private fun CanteenCameraPreview(active: Boolean, modifier: Modifier = Modifier, onCode: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val previewView = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }
    val executor = remember { Executors.newSingleThreadExecutor() }
    val handled = remember { AtomicBoolean(false) }
    LaunchedEffect(active) { if (active) handled.set(false) }

    AndroidView(factory = { previewView }, modifier = modifier)
    DisposableEffect(lifecycleOwner, active) {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        val listener = Runnable {
            val provider = providerFuture.get()
            provider.unbindAll()
            if (!active) return@Runnable
            val preview = CameraPreview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
            val options = BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
            val scanner = BarcodeScanning.getClient(options)
            val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
            analysis.setAnalyzer(executor) { imageProxy ->
                val mediaImage = imageProxy.image
                if (mediaImage == null || handled.get()) {
                    imageProxy.close()
                    return@setAnalyzer
                }
                scanner.process(InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees))
                    .addOnSuccessListener { barcodes ->
                        val value = barcodes.firstOrNull()?.rawValue
                        if (!value.isNullOrBlank() && handled.compareAndSet(false, true)) onCode(value)
                    }
                    .addOnCompleteListener { imageProxy.close() }
            }
            provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
        }
        providerFuture.addListener(listener, ContextCompat.getMainExecutor(context))
        onDispose { runCatching { providerFuture.get().unbindAll() } }
    }
    DisposableEffect(Unit) { onDispose { executor.shutdown() } }
}

@Composable private fun MainScreen(state: SessionUiState, session: SessionViewModel) {
    var tab by rememberSaveable { mutableStateOf(MainTab.HOME) }
    var article by remember { mutableStateOf<ContentItem?>(null) }
    var attendanceOpen by remember { mutableStateOf(false) }
    var demoScannerOpen by rememberSaveable { mutableStateOf(false) }
    BackHandler(article != null || attendanceOpen) { article = null; attendanceOpen = false }

    val haptics = LocalHapticFeedback.current
    Scaffold(bottomBar = {
        val dark = isSystemInDarkTheme()
        val glassColor = if (dark) {
            MaterialTheme.colorScheme.surface.copy(alpha = .82f)
        } else {
            Color.White.copy(alpha = .78f)
        }
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 12.dp, vertical = 8.dp)
                .height(78.dp),
            shape = appShape(30.dp, AppShapeRole.EXTRA_LARGE),
            color = glassColor,
            contentColor = MaterialTheme.colorScheme.onSurface,
            tonalElevation = 8.dp,
            shadowElevation = 14.dp,
            border = androidx.compose.foundation.BorderStroke(
                1.dp,
                if (dark) Color.White.copy(alpha = .14f) else Color.White.copy(alpha = .86f),
            ),
        ) {
            NavigationBar(
                containerColor = Color.Transparent,
                tonalElevation = 0.dp,
                windowInsets = WindowInsets(0, 0, 0, 0),
            ) {
                MainTab.entries.forEach { item ->
                    val selected = tab == item
                    val notificationCount = state.unreadCount +
                        state.requestNotifications.count { !it.read }
                    NavigationBarItem(
                        selected = selected,
                        onClick = {
                            if (tab != item) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            article = null
                            attendanceOpen = false
                            tab = item
                        },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = MaterialTheme.colorScheme.onPrimary,
                            selectedTextColor = MaterialTheme.colorScheme.primary,
                            indicatorColor = MaterialTheme.colorScheme.primary,
                            unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
                        ),
                        icon = {
                            BadgedBox(
                                badge = {
                                    if (item == MainTab.NOTIFICATIONS && notificationCount > 0) {
                                        Badge { Text(notificationCount.toString()) }
                                    }
                                },
                            ) {
                                Icon(
                                    when (item) {
                                        MainTab.HOME -> Icons.Default.Home
                                        MainTab.REQUESTS -> Icons.Default.Description
                                        MainTab.MENU -> Icons.Default.Restaurant
                                        MainTab.NOTIFICATIONS -> Icons.Default.Notifications
                                        MainTab.PROFILE -> Icons.Default.Person
                                    },
                                    item.label,
                                )
                            }
                        },
                        label = {
                            Text(
                                item.label,
                                fontSize = 11.sp,
                                fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                                maxLines = 1,
                            )
                        },
                    )
                }
            }
        }
    }, floatingActionButton = {
        if (state.profile?.employeeCode == "DEMO" && tab == MainTab.MENU) {
            FloatingActionButton(
                onClick = { demoScannerOpen = true },
                shape = CircleShape,
                containerColor = Color(0xFF42B878),
                contentColor = Color.White,
                modifier = Modifier.size(58.dp),
            ) {
                Icon(Icons.Default.QrCodeScanner, contentDescription = "Quét mã QR")
            }
        }
    }) { padding ->
        if (demoScannerOpen) {
            Dialog(onDismissRequest = { demoScannerOpen = false }) {
                Surface(
                    modifier = Modifier.fillMaxWidth().fillMaxHeight(.92f),
                    shape = appShape(28.dp, AppShapeRole.EXTRA_LARGE),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    CanteenScannerScreen(state, session)
                }
            }
        }
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        AnimatedContent(
            targetState = tab,
            modifier = Modifier.fillMaxWidth().widthIn(max = 840.dp).fillMaxHeight().padding(top = padding.calculateTopPadding()),
            transitionSpec = {
                val forward = targetState.ordinal > initialState.ordinal
                (slideInHorizontally(spring(stiffness = 520f, dampingRatio = .86f)) {
                    if (forward) it / 5 else -it / 5
                } + fadeIn()) togetherWith
                    (slideOutHorizontally(spring(stiffness = 620f, dampingRatio = .9f)) {
                        if (forward) -it / 7 else it / 7
                    } + fadeOut())
            },
            label = "main-tab-transition",
        ) { activeTab ->
            when {
                attendanceOpen -> AttendanceScreen(session) { attendanceOpen = false }
                article != null -> ArticleDetail(article!!) { article = null }
                else -> when (activeTab) {
                    MainTab.HOME -> HomeScreen(state, { attendanceOpen = true }, { article = it })
                    MainTab.MENU -> TodayMenuScreen(state, session)
                    MainTab.REQUESTS -> RequestsScreen(state, session)
                    MainTab.NOTIFICATIONS -> NotificationsScreen(state, session) { article = it }
                    MainTab.PROFILE -> ProfileScreen(state, session)
                }
            }
        }
        }
    }
}

@Composable private fun TodayMenuScreen(state: SessionUiState, session: SessionViewModel) {
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
                    if (!cancelling && !receiving) Surface(shape = appShape(14.dp), color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .55f)) {
                        Column(Modifier.fillMaxWidth().padding(14.dp)) {
                            Text(title.uppercase(), color = SukavinaMuted, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = .8.sp)
                            Text(detail?.ifBlank { "..." } ?: "...", fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 5.dp))
                        }
                    }
                }
            },
            confirmButton = { Button(onClick = { val choice = pendingChoice!!; pendingChoice = null; if (choice == "cancel") session.cancelMealSelection() else if (choice == "received") session.receiveMealSelection() else session.selectMeal(choice) }, colors = ButtonDefaults.buttonColors(containerColor = if (cancelling) MaterialTheme.colorScheme.error else if (receiving) Color(0xFF42B878) else SukavinaRed)) { Text(if (cancelling) "Xác nhận hủy" else if (receiving) "Xác nhận đã nhận" else "Đặt món") } },
            dismissButton = { TextButton(onClick = { pendingChoice = null }) { Text("Quay lại") } },
        )
    }
    LazyColumn(contentPadding = PaddingValues(start = 18.dp, top = 18.dp, end = 18.dp, bottom = 112.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            Text("BẾP ĂN SUKAVINA", color = SukavinaRed, fontWeight = FontWeight.Bold, letterSpacing = 1.5.sp, fontSize = 12.sp)
            Text("Thực đơn hôm nay", fontSize = 30.sp, fontWeight = FontWeight.ExtraBold)
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
            Card(shape = appShape(22.dp, AppShapeRole.EXTRA_LARGE)) {
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

@Composable private fun MealQrAccessCard(session: SessionViewModel, working: Boolean) {
    var issued by remember { mutableStateOf<MealQrIssueResponse?>(null) }
    var seconds by remember { mutableIntStateOf(0) }
    LaunchedEffect(issued) {
        while (issued != null && seconds > 0) { delay(1_000); seconds-- }
    }
    Card(shape = appShape(18.dp, AppShapeRole.LARGE)) {
        Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (issued != null && seconds > 0) {
                val bitmap = remember(issued!!.token) { createQrBitmap(issued!!.token) }
                Image(bitmap = bitmap.asImageBitmap(), contentDescription = "Mã QR nhận món", modifier = Modifier.size(190.dp).background(Color.White).padding(10.dp))
                Text("Mã tự ẩn sau ${seconds}s", color = if (seconds <= 5) MaterialTheme.colorScheme.error else SukavinaMuted, fontWeight = FontWeight.Bold)
            } else {
                Text("MÃ QR NHẬN MÓN", color = SukavinaMuted, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
                Button(onClick = { session.issueMealQr { result -> issued = result; seconds = if (result == null) 0 else 30 } }, enabled = !working, modifier = Modifier.fillMaxWidth(), colors = ButtonDefaults.buttonColors(containerColor = SukavinaRed)) {
                    Icon(Icons.Default.QrCode, null); Spacer(Modifier.width(8.dp)); Text("Lấy mã nhận món", fontWeight = FontWeight.Bold)
                }
                Text("Mỗi mã chỉ có hiệu lực trong 30 giây.", color = SukavinaMuted, fontSize = 12.sp)
            }
        }
    }
}

private fun createQrBitmap(value: String): Bitmap {
    val hints = mapOf(EncodeHintType.MARGIN to 1)
    val matrix: BitMatrix = MultiFormatWriter().encode(value, BarcodeFormat.QR_CODE, 512, 512, hints)
    return Bitmap.createBitmap(512, 512, Bitmap.Config.ARGB_8888).also { bitmap ->
        for (x in 0 until 512) for (y in 0 until 512) bitmap.setPixel(x, y, if (matrix[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
    }
}

@Composable private fun MenuGroupCard(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, color: Color, lines: List<String?>, modifier: Modifier = Modifier) {
    Card(modifier.fillMaxWidth().height(148.dp), shape = appShape(19.dp, AppShapeRole.LARGE), border = androidx.compose.foundation.BorderStroke(1.dp, color.copy(alpha = .18f))) {
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

@Composable private fun MealChoiceButton(title: String, detail: String?, icon: androidx.compose.ui.graphics.vector.ImageVector, color: Color, selected: Boolean, disabled: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        enabled = !disabled,
        shape = appShape(17.dp, AppShapeRole.LARGE),
        color = if (selected) color.copy(alpha = .12f) else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .45f),
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

@Composable private fun HomeScreen(state: SessionUiState, openAttendance: () -> Unit, openArticle: (ContentItem) -> Unit) {
    val dashboard = state.dashboard
    LazyColumn(contentPadding = PaddingValues(start = 20.dp, top = 20.dp, end = 20.dp, bottom = 112.dp), verticalArrangement = Arrangement.spacedBy(15.dp)) {
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

@Composable private fun TimeBox(label: String, value: String, modifier: Modifier) = Surface(modifier, shape = appShape(14.dp), color = Color.White.copy(alpha = .06f)) {
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
    var refreshing by remember { mutableStateOf(false) }
    val refreshScope = rememberCoroutineScope()
    val filterOptions = remember { listOf("all" to "Tất cả", "pending" to "Chờ duyệt", "approved" to "Đã duyệt", "rejected" to "Từ chối", "cancelled" to "Đã hủy") }
    val filterIndex = filterOptions.indexOfFirst { it.first == filter }.coerceAtLeast(0)
    val pagerState = rememberPagerState(initialPage = filterIndex, pageCount = { filterOptions.size })
    val approvalIds = state.approvals.map { it.id }.toSet()
    val merged = (state.approvals + state.requests).distinctBy { it.id }.sortedByDescending { it.createdAt }
    LaunchedEffect(pagerState.currentPage) {
        filter = filterOptions[pagerState.currentPage].first
    }
    Scaffold(
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { composing = true },
                modifier = Modifier.padding(bottom = 104.dp),
                containerColor = SukavinaRed,
                contentColor = Color.White,
                icon = { Icon(Icons.Default.Add, null) },
                text = { Text("Tạo đơn mới", fontWeight = FontWeight.Bold) },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Text("Đơn từ", fontSize = 29.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(18.dp, 20.dp, 18.dp, 10.dp))
            ScrollableTabRow(
                selectedTabIndex = filterIndex,
                edgePadding = 18.dp,
                divider = {},
                containerColor = Color.Transparent,
            ) {
                filterOptions.forEachIndexed { index, item ->
                    Tab(
                        selected = filterIndex == index,
                        onClick = { refreshScope.launch { pagerState.animateScrollToPage(index) } },
                        text = { Text(item.second, maxLines = 1) },
                    )
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
                        contentPadding = PaddingValues(start = 18.dp, top = 18.dp, end = 18.dp, bottom = 112.dp),
                        verticalArrangement = Arrangement.Top,
                    ) {
                        items(visible, key = { it.id }) { request ->
                            RequestCard(request, canCancel = request.status == "pending" && request.id !in approvalIds,
                                onCancel = { cancelling = request }, onClick = { if (request.status == "pending" && request.id in approvalIds) reviewing = request })
                        }
                        if (visible.isEmpty()) item { Text("Chưa có đơn trong mục này.", color = SukavinaMuted, modifier = Modifier.padding(top = 45.dp)) }
                    }
                }
            }
        }
    }
    if (composing) RequestComposer(state.working, { composing = false }) { kind, from, to, reason -> session.createRequest(kind, from, to, reason) { if (it) composing = false } }
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

@Composable private fun RequestCard(request: EmployeeRequest, canCancel: Boolean, onCancel: () -> Unit, onClick: () -> Unit = {}) {
    val kind = requestKind(request.kind); val status = requestStatus(request.status)
    Card(onClick = onClick, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface), border = androidx.compose.foundation.BorderStroke(1.dp, kind.color.copy(alpha = .26f)), shape = appShape(22.dp, AppShapeRole.EXTRA_LARGE)) {
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
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .48f)),
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

@Composable
private fun SwipeDeleteItem(
    onDelete: () -> Unit,
    content: @Composable () -> Unit,
) {
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    val actionWidth = with(density) { 88.dp.toPx() }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    var rowWidth by remember { mutableFloatStateOf(1f) }
    val visualOffset by animateFloatAsState(
        targetValue = dragOffset,
        animationSpec = spring(stiffness = 560f, dampingRatio = .86f),
        label = "swipe-delete-offset",
    )
    Box(
        Modifier
            .fillMaxWidth()
            .clip(appShape(22.dp, AppShapeRole.EXTRA_LARGE))
            .background(MaterialTheme.colorScheme.error),
        contentAlignment = Alignment.CenterEnd,
    ) {
        Column(
            modifier = Modifier
                .width(88.dp)
                .fillMaxHeight()
                .clickable {
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    onDelete()
                },
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(Icons.Default.Delete, "Xóa", tint = Color.White)
            Text("Xóa", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .onSizeChanged { rowWidth = it.width.toFloat() }
                .offset { IntOffset(visualOffset.roundToInt(), 0) }
                .pointerInput(rowWidth, actionWidth) {
                    detectHorizontalDragGestures(
                        onHorizontalDrag = { _, amount ->
                            dragOffset = (dragOffset + amount).coerceIn(-rowWidth, 0f)
                        },
                        onDragEnd = {
                            when {
                                dragOffset <= -rowWidth * .55f -> {
                                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                    dragOffset = -rowWidth
                                    onDelete()
                                }
                                dragOffset <= -actionWidth * .45f -> {
                                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                    dragOffset = -actionWidth
                                }
                                else -> dragOffset = 0f
                            }
                        },
                        onDragCancel = { dragOffset = 0f },
                    )
                },
        ) {
            content()
        }
    }
}

@Composable private fun NotificationsScreen(state: SessionUiState, session: SessionViewModel, openArticle: (ContentItem) -> Unit) {
    var selected by remember { mutableStateOf<EmployeeRequest?>(null) }
    var reviewing by remember { mutableStateOf<EmployeeRequest?>(null) }
    var confirmClear by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    val refreshScope = rememberCoroutineScope()
    val requests = (state.requests + state.approvals).associateBy { it.id }
    val visibleArticles = state.dashboard?.contentItems.orEmpty().filterNot { it.id in state.hiddenArticleIds }
    val unread = state.unreadCount + state.requestNotifications.count { !it.read }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(18.dp, 20.dp, 18.dp, 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) { Text("Thông báo", fontSize = 29.sp, fontWeight = FontWeight.ExtraBold); Text(if (unread > 0) "$unread thông báo chưa đọc" else "Bạn đã đọc tất cả", color = SukavinaMuted) }
            if (state.requestNotifications.isNotEmpty() || visibleArticles.isNotEmpty()) TextButton(onClick = { confirmClear = true }) { Text("Xóa tất cả", color = MaterialTheme.colorScheme.error) }
        }
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                refreshing = true
                session.refresh()
                session.refreshRequests()
                refreshScope.launch { delay(850); refreshing = false }
            },
            modifier = Modifier.fillMaxSize(),
        ) {
        LazyColumn(contentPadding = PaddingValues(start = 18.dp, top = 18.dp, end = 18.dp, bottom = 112.dp), verticalArrangement = Arrangement.spacedBy(11.dp)) {
            items(state.requestNotifications, key = { it.id }) { item ->
                val request = item.requestId?.let(requests::get); val kind = request?.let { requestKind(it.kind) }
                val tone = kind?.color ?: when { item.type.contains("rejected") -> Color(0xFFFF6F67); item.type.contains("cancelled") -> Color(0xFFAAB1BD); else -> Color(0xFF55D881) }
                SwipeDeleteItem(onDelete = { session.deleteNotification(item.id) }) {
                    Surface(
                        onClick = { session.openNotification(item.id); if (request != null) { if (item.type == "request_pending" && request.status == "pending" && state.approvals.any { it.id == request.id }) reviewing = request else selected = request } },
                        shape = appShape(20.dp, AppShapeRole.EXTRA_LARGE),
                        color = if (item.read) MaterialTheme.colorScheme.surface else tone.copy(alpha = .20f),
                        border = androidx.compose.foundation.BorderStroke(if (item.read) 1.dp else 1.5.dp, if (item.read) Color.Transparent else tone.copy(alpha = .58f)),
                        shadowElevation = if (item.read) 0.dp else 7.dp,
                    ) {
                        Row(Modifier.padding(15.dp), verticalAlignment = Alignment.Top) {
                            Surface(Modifier.size(44.dp), appShape(14.dp), color = tone.copy(alpha = .16f)) { Icon(kind?.icon ?: if (item.type.contains("rejected")) Icons.Default.Cancel else if (item.type.contains("cancelled")) Icons.Default.RemoveCircle else Icons.Default.CheckCircle, null, tint = tone, modifier = Modifier.padding(11.dp)) }
                            Column(Modifier.padding(horizontal = 12.dp).weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) { Text(item.title, fontWeight = FontWeight.Bold); kind?.let { Text(it.title, color = it.color, fontSize = 11.sp, fontWeight = FontWeight.Bold) }; Text(item.message, color = SukavinaMuted, fontSize = 13.sp); Text(item.createdAt.toDateTimeLabel(), color = tone, fontSize = 11.sp) }
                            if (!item.read) Surface(shape = CircleShape, color = tone.copy(alpha = .18f)) { Text("Mới", color = tone, fontSize = 10.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp)) }
                        }
                    }
                }
            }
            itemsIndexed(visibleArticles, key = { _, item -> "article-${item.id}" }) { index, item ->
                val isUnread = index < state.unreadCount
                SwipeDeleteItem(onDelete = { session.hideArticleNotification(item.id) }) {
                    Surface(
                        onClick = { session.markArticlesRead(); openArticle(item) },
                        shape = appShape(20.dp, AppShapeRole.EXTRA_LARGE),
                        color = if (isUnread) SukavinaRed.copy(alpha = .20f) else MaterialTheme.colorScheme.surface,
                        border = androidx.compose.foundation.BorderStroke(if (isUnread) 1.5.dp else 1.dp, if (isUnread) SukavinaRed.copy(alpha = .58f) else Color.Transparent),
                        shadowElevation = if (isUnread) 7.dp else 0.dp,
                    ) { Row(Modifier.padding(15.dp), verticalAlignment = Alignment.Top) { Surface(Modifier.size(44.dp), appShape(14.dp), color = SukavinaRed.copy(alpha = .16f)) { Icon(Icons.Default.Campaign, null, tint = SukavinaRed, modifier = Modifier.padding(11.dp)) }; Column(Modifier.padding(start = 12.dp).weight(1f)) { Text(item.title, fontWeight = FontWeight.Bold); Text(item.body.plainText(), color = SukavinaMuted, maxLines = 2, overflow = TextOverflow.Ellipsis) }; if (isUnread) Surface(shape = CircleShape, color = SukavinaRed.copy(alpha = .18f)) { Text("Mới", color = SukavinaRed, fontSize = 10.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp)) } } }
                }
            }
            if (state.requestNotifications.isEmpty() && visibleArticles.isEmpty()) item { Text("Chưa có thông báo.", color = SukavinaMuted, modifier = Modifier.padding(top = 50.dp)) }
        }
        }
    }
    if (confirmClear) SukavinaAlert(
        title = "Xóa tất cả thông báo?",
        eyebrow = "DỌN HỘP THÔNG BÁO",
        icon = Icons.Default.DeleteSweep,
        confirmText = "Xóa tất cả",
        dismissText = "Hủy",
        danger = true,
        onDismiss = { confirmClear = false },
        onConfirm = { session.clearNotifications(); confirmClear = false },
    ) {
        Text("Danh sách thông báo sẽ được dọn khỏi tài khoản này.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("Bạn cũng có thể vuốt từng thông báo sang trái để xóa riêng.", color = SukavinaRed, fontWeight = FontWeight.SemiBold)
    }
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
    val activity = LocalContext.current as? Activity
    var innerFoldOpen by remember { mutableStateOf(false) }
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
                    it.orientation == FoldingFeature.Orientation.VERTICAL &&
                        (it.isSeparating || it.state == FoldingFeature.State.FLAT)
                }
        }
    }

    LaunchedEffect(Unit) {
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
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            Surface(color = MaterialTheme.colorScheme.background) {
                Row(
                    Modifier.fillMaxWidth().statusBarsPadding().height(48.dp).padding(horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = back, modifier = Modifier.size(44.dp)) {
                        Icon(Icons.Default.ArrowBack, "Quay lại")
                    }
                    Text(
                        "Bảng chấm công",
                        fontSize = 19.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(start = 4.dp),
                    )
                }
            }
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            BoxWithConstraints(Modifier.fillMaxWidth()) {
            if (!innerFoldOpen) Row(
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
                )
                IconButton(
                    onClick = { scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) } },
                    enabled = pagerState.currentPage < months.lastIndex,
                ) { Icon(Icons.Default.ChevronRight, "Tháng sau") }
            }
            }

            BoxWithConstraints(Modifier.fillMaxSize()) {
                if (innerFoldOpen) {
                    Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        months.forEach { month ->
                            AttendanceMonthPage(month, cache[month], errors[month], selectedDates[month], { selectedDates[month] = it }, Modifier.weight(1f), showTitle = true)
                        }
                    }
                } else {
                    HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize(), beyondViewportPageCount = 1, pageSpacing = 0.dp) { page ->
                        val month = months[page]
                        AttendanceMonthPage(month, cache[month], errors[month], selectedDates[month], { selectedDates[month] = it }, Modifier.fillMaxWidth(), showTitle = false)
                    }
                }
            }
        }
    }
}

@Composable private fun AttendanceMonthPage(month: YearMonth, data: AttendanceMonth?, error: String?, selectedDate: String?, select: (String) -> Unit, modifier: Modifier, showTitle: Boolean) {
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 112.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (showTitle) Text("Tháng ${month.monthValue} / ${month.year}", fontSize = 21.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(top = 8.dp))
        when {
            data != null -> { AttendanceSummary(data); AttendanceCalendar(data, selectedDate, select); data.days.firstOrNull { it.date == selectedDate }?.let { AttendanceDayDetail(data, it) } }
            error != null -> Text(error, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(18.dp))
            else -> Box(Modifier.fillMaxWidth().height(260.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        }
    }
}

@Composable private fun AttendanceMonthSelector(months: List<YearMonth>, selected: YearMonth, select: (YearMonth) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(16.dp).clip(appShape(18.dp, AppShapeRole.LARGE))
            .background(MaterialTheme.colorScheme.surface).padding(6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        months.forEachIndexed { index, month ->
            FilterChip(
                selected = selected == month,
                onClick = { select(month) },
                label = { Text(if (index == 0) "Tháng này" else "Tháng trước", fontWeight = FontWeight.Bold) },
                modifier = Modifier.weight(1f),
            )
        }
    }
}

private data class AttendanceMetric(val key: String, val title: String, val color: Color, val count: Int)

@Composable private fun AttendanceSummary(month: AttendanceMonth) {
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
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        metrics.forEach { metric ->
            Surface(Modifier.weight(1f).heightIn(min = 68.dp), shape = appShape(14.dp, AppShapeRole.LARGE), color = MaterialTheme.colorScheme.surface) {
                Column(Modifier.fillMaxSize().padding(vertical = 10.dp, horizontal = 2.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    Text(metric.count.toString(), color = metric.color, fontSize = 18.sp, fontWeight = FontWeight.ExtraBold)
                    Text(metric.title, color = SukavinaMuted, fontSize = 9.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable private fun AttendanceCalendar(month: AttendanceMonth, selectedDate: String?, select: (String) -> Unit) {
    val days = month.days
    val leading = days.firstOrNull()?.date?.let { LocalDate.parse(it).dayOfWeek.value - 1 } ?: 0
    val cells: List<AttendanceDay?> = List(leading) { null } + days
    Card(shape = appShape(22.dp, AppShapeRole.EXTRA_LARGE)) {
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
                        AttendanceDayCell(week.getOrNull(index), selectedDate, select)
                    }
                }
            }
            AttendanceLegend(month)
        }
    }
}

@Composable private fun RowScope.AttendanceDayCell(day: AttendanceDay?, selectedDate: String?, select: (String) -> Unit) {
    if (day == null) {
        Spacer(Modifier.weight(1f).aspectRatio(0.92f))
        return
    }
    val statuses = day.allStatuses()
    val shape = appShape(11.dp)
    Box(
        Modifier.weight(1f).aspectRatio(0.92f).clip(shape)
            .then(if (day.date == selectedDate) Modifier.border(2.dp, MaterialTheme.colorScheme.primary, shape) else Modifier)
            .clickable { select(day.date) },
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
        Text(LocalDate.parse(day.date).dayOfMonth.toString(), fontWeight = if (day.date == selectedDate) FontWeight.ExtraBold else FontWeight.Medium)
    }
}

@Composable private fun AttendanceLegend(month: AttendanceMonth) {
    val values = listOf(
        "present" to "Đủ công", "late" to "Đi trễ", "early" to "Về sớm",
        "leave" to "Nghỉ phép", "absent" to "Vắng", "overtime" to "Làm thêm",
    ).filter { item -> month.days.any { item.first in it.allStatuses() } }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        values.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                row.forEach { item ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(9.dp).clip(RoundedCornerShape(3.dp)).background(attendanceColor(item.first).copy(alpha = .5f)))
                        Text(item.second, Modifier.padding(start = 4.dp), color = SukavinaMuted, fontSize = 10.sp)
                    }
                }
            }
        }
    }
}

@Composable private fun AttendanceDayDetail(month: AttendanceMonth, day: AttendanceDay) = Card(shape = appShape(22.dp, AppShapeRole.EXTRA_LARGE)) {
    Column(Modifier.padding(17.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Chi tiết ngày ${LocalDate.parse(day.date).format(DateTimeFormatter.ofPattern("dd/MM/yyyy"))}", fontSize = 17.sp, fontWeight = FontWeight.ExtraBold)
        HorizontalDivider()
        AttendanceDetailLine("Giờ vào", day.checkIn.toTime())
        AttendanceDetailLine("Giờ ra", day.checkOut.toTime())
        AttendanceDetailLine("Trạng thái", day.allStatuses().joinToString(" · ") { attendanceTitle(it) })
        AttendanceDetailLine("Khung giờ ${month.department ?: "phòng ban"}", "${day.startTime ?: month.startTime ?: "--:--"} - ${day.endTime ?: month.endTime ?: "--:--"}")
    }
}

@Composable private fun AttendanceDetailLine(label: String, value: String) = Row(Modifier.fillMaxWidth()) {
    Text(label, color = SukavinaMuted)
    Spacer(Modifier.weight(1f))
    Text(value, fontWeight = FontWeight.Bold)
}

private fun AttendanceDay.allStatuses() = statuses.ifEmpty { listOfNotNull(status) }
private fun attendanceColor(status: String?) = when (status) {
    "present" -> Color(0xFF43B86B)
    "late" -> requestKind("late").color
    "early" -> requestKind("early").color
    "leave" -> requestKind("leave").color
    "absent" -> Color(0xFFFF6F67)
    "overtime" -> requestKind("overtime").color
    "weekend" -> Color(0xFF9FA6B2)
    else -> Color(0xFF9FA6B2)
}
private fun attendanceTitle(status: String) = when (status) {
    "present" -> "Đủ công"; "late" -> "Đi trễ"; "early" -> "Về sớm"
    "leave" -> "Nghỉ phép"; "absent" -> "Vắng"; "overtime" -> "Làm thêm giờ"
    "weekend" -> "Cuối tuần"; else -> "Chưa đến"
}

@Composable private fun ProfileScreen(state: SessionUiState, session: SessionViewModel) {
    var deleteOpen by remember { mutableStateOf(false) }; var biometricPasswordOpen by remember { mutableStateOf(false) }; var biometricPassword by remember { mutableStateOf("") }; var passwordChangeOpen by remember { mutableStateOf(false) }
    var legalPage by remember { mutableStateOf<LegalPage?>(null) }
    var signOutConfirmation by remember { mutableStateOf(false) }
    val activity = LocalActivity.current as? MainActivity
    val profile = state.profile
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(22.dp).padding(bottom = 90.dp),
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
                    onClick = { legalPage = LegalPage.PRIVACY },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                ) {
                    Icon(Icons.Default.PrivacyTip, null)
                    Text("Chính sách quyền riêng tư", Modifier.padding(start = 12.dp).weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Start)
                    Icon(Icons.Default.ChevronRight, null)
                }
                HorizontalDivider()
                TextButton(
                    onClick = { legalPage = LegalPage.SUPPORT },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                ) {
                    Icon(Icons.Default.SupportAgent, null)
                    Text("Hỗ trợ người dùng", Modifier.padding(start = 12.dp).weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Start)
                    Icon(Icons.Default.ChevronRight, null)
                }
                HorizontalDivider()
                TextButton(
                    onClick = { legalPage = LegalPage.DELETION },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                ) {
                    Icon(Icons.Default.ManageAccounts, null)
                    Text("Hướng dẫn xóa tài khoản", Modifier.padding(start = 12.dp).weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Start)
                    Icon(Icons.Default.ChevronRight, null)
                }
            }
        }
        OutlinedButton(
            onClick = { signOutConfirmation = true },
            modifier = Modifier.fillMaxWidth().padding(top = 20.dp).height(52.dp),
            colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
        ) { Icon(Icons.Default.Logout, null); Spacer(Modifier.width(8.dp)); Text("Đăng xuất") }
        OutlinedButton(onClick = { passwordChangeOpen = true }, modifier = Modifier.fillMaxWidth().padding(top = 10.dp).height(52.dp)) { Icon(Icons.Default.Key, null); Spacer(Modifier.width(8.dp)); Text("Đổi mật khẩu") }
        if (profile?.protected != true && profile?.accountType != "SUPER_ADMIN") TextButton(onClick = { deleteOpen = true }, modifier = Modifier.padding(top = 10.dp)) { Text("Yêu cầu xóa tài khoản", color = MaterialTheme.colorScheme.error) }
    }
    if (deleteOpen) SukavinaAlert(
        title = "Xóa tài khoản vĩnh viễn?",
        eyebrow = "HÀNH ĐỘNG KHÔNG THỂ HOÀN TÁC",
        icon = Icons.Default.Warning,
        confirmText = if (state.working) "Đang xử lý..." else "Xóa vĩnh viễn",
        dismissText = "Hủy",
        danger = true,
        confirmEnabled = !state.working,
        onDismiss = { if (!state.working) deleteOpen = false },
        onConfirm = { session.deleteAccount(""); deleteOpen = false },
    ) {
        Text("Tài khoản, dữ liệu cá nhân, đơn từ và lựa chọn món liên quan sẽ bị xóa.", fontWeight = FontWeight.SemiBold)
        Text("Thao tác này không thể hoàn tác. Hồ sơ chấm công hoặc hồ sơ lao động bắt buộc có thể vẫn được lưu theo chính sách Công ty.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (biometricPasswordOpen) AlertDialog(onDismissRequest = { biometricPasswordOpen = false }, title = { Text("Bật đăng nhập sinh trắc học") }, text = { OutlinedTextField(biometricPassword, { biometricPassword = it }, label = { Text("Nhập mật khẩu hiện tại") }, visualTransformation = PasswordVisualTransformation()) }, confirmButton = { Button(onClick = { session.enableBiometric(biometricPassword, true) { if (it) biometricPasswordOpen = false } }) { Text("Xác nhận") } }, dismissButton = { TextButton(onClick = { biometricPasswordOpen = false }) { Text("Hủy") } })
    if (passwordChangeOpen) PasswordChangeDialog(state, session) { passwordChangeOpen = false }
    legalPage?.let { page -> NativeLegalSheet(page) { legalPage = null } }
    if (signOutConfirmation) SukavinaAlert(
        title = "Xác nhận đăng xuất?",
        eyebrow = "BẢO MẬT TÀI KHOẢN",
        icon = Icons.Default.Logout,
        confirmText = "Đăng xuất",
        dismissText = "Giữ lại",
        danger = true,
        onDismiss = { signOutConfirmation = false },
        onConfirm = { signOutConfirmation = false; session.signOut() },
    ) {
        Text("Phiên đăng nhập trên thiết bị này sẽ kết thúc.", fontWeight = FontWeight.SemiBold)
        Text("Dữ liệu tài khoản vẫn được giữ nguyên và bạn có thể đăng nhập lại bất cứ lúc nào.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable private fun NativeLegalSheet(page: LegalPage, dismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = dismiss) {
        Column(
            Modifier.fillMaxWidth().fillMaxHeight(.92f).verticalScroll(rememberScrollState()).padding(horizontal = 22.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Surface(Modifier.size(62.dp), appShape(20.dp, AppShapeRole.EXTRA_LARGE), color = SukavinaRed.copy(alpha = .15f)) {
                Icon(
                    if (page == LegalPage.PRIVACY) Icons.Default.PrivacyTip else if (page == LegalPage.SUPPORT) Icons.Default.SupportAgent else Icons.Default.ManageAccounts,
                    null,
                    tint = SukavinaRed,
                    modifier = Modifier.padding(17.dp),
                )
            }
            Text(if (page == LegalPage.PRIVACY) "Chính sách quyền riêng tư" else if (page == LegalPage.SUPPORT) "Hỗ trợ người dùng" else "Hướng dẫn xóa tài khoản", fontSize = 26.sp, fontWeight = FontWeight.Black)
            Text(
                if (page == LegalPage.PRIVACY) "Cập nhật lần cuối: 29/07/2026" else if (page == LegalPage.SUPPORT) "Hỗ trợ dành riêng cho nhân viên Sukavina" else "Hướng dẫn dành cho tài khoản nội bộ",
                color = SukavinaMuted,
            )
            if (page == LegalPage.PRIVACY) {
                LegalSection("Ứng dụng nội bộ", "Sukavina chỉ dành cho nhân viên và người được Công ty ủy quyền. Tài khoản do Công ty tạo, cấp và quản lý; ứng dụng không có đăng ký công khai.")
                LegalSection("Dữ liệu được xử lý", "Hệ thống xử lý hồ sơ công việc, thông tin liên hệ, chấm công, đơn từ, lựa chọn suất ăn, thông báo và dữ liệu bảo mật cần thiết để vận hành.")
                LegalSection("Không quảng cáo hoặc theo dõi", "Sukavina không hiển thị quảng cáo, không bán dữ liệu và không theo dõi giữa các ứng dụng hoặc website. Camera chỉ được tài khoản Nhà ăn sử dụng khi quét mã QR nhận món; hình ảnh camera được xử lý trực tiếp trên thiết bị, không lưu hoặc tải lên máy chủ.")
                LegalSection("Sinh trắc học", "Sinh trắc học được hệ điều hành xử lý trên thiết bị. Sukavina chỉ nhận kết quả xác thực, không nhận hoặc lưu khuôn mặt, vân tay hay mẫu sinh trắc học.")
                LegalSection("Lưu trữ và quyền của nhân viên", "Dữ liệu được truyền qua HTTPS và giới hạn truy cập theo tài khoản. Nhân viên có thể yêu cầu xem, sửa hoặc xóa dữ liệu trong phạm vi cho phép; hồ sơ bắt buộc có thể được lưu theo quy định.")
            } else if (page == LegalPage.SUPPORT) {
                LegalSection("Liên hệ hỗ trợ", "Email: group@sukavina.com")
                LegalSection("Khi báo lỗi", "Vui lòng cung cấp mã nhân viên, mô tả sự cố, thời điểm xảy ra và ảnh chụp màn hình nếu có.")
                LegalSection("Bảo vệ tài khoản", "Không gửi mật khẩu hoặc mã OTP cho bất kỳ ai, kể cả khi yêu cầu hỗ trợ.")
                LegalSection("Xóa tài khoản", "Bạn có thể gửi yêu cầu trong tab Tài khoản. Nếu không thể đăng nhập, hãy gửi yêu cầu từ email đã liên kết tới group@sukavina.com.")
            } else {
                LegalSection("Xóa trong ứng dụng", "Quay lại tab Tài khoản, chọn “Yêu cầu xóa tài khoản” ở cuối trang, nhập mật khẩu và xác nhận.")
                LegalSection("Không thể đăng nhập", "Gửi yêu cầu từ email đã liên kết tới group@sukavina.com. Hãy cung cấp họ tên và mã nhân viên, không gửi mật khẩu hoặc mã OTP.")
                LegalSection("Dữ liệu được xử lý", "Tài khoản ứng dụng và dữ liệu không còn cần thiết sẽ bị xóa. Hồ sơ lao động, chấm công hoặc dữ liệu bắt buộc có thể được giữ theo chính sách Công ty và quy định áp dụng.")
                LegalSection("Lưu ý", "Xóa tài khoản là thao tác không thể hoàn tác. Hãy liên hệ Nhân sự nếu bạn chỉ cần sửa thông tin hồ sơ.")
            }
            Button(
                onClick = dismiss,
                modifier = Modifier.fillMaxWidth().height(52.dp),
                colors = ButtonDefaults.buttonColors(containerColor = SukavinaRed, contentColor = Color.White),
            ) { Text("Đóng", fontWeight = FontWeight.Bold) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable private fun LegalSection(title: String, content: String) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Text(title, fontWeight = FontWeight.Bold, fontSize = 17.sp)
            Text(content, color = SukavinaMuted, lineHeight = 21.sp)
        }
    }
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
                OutlinedTextField(
                    code,
                    { code = it.filter(Char::isDigit).take(6) },
                    label = { Text("Mã OTP gồm 6 số") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.SmsOtpCode },
                )
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
        openAttendance = {}, openArticle = {},
    )
}
