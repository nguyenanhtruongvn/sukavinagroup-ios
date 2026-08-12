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


@Composable
fun CanteenScannerScreen(state: SessionUiState, session: SessionViewModel) {
    val context = LocalContext.current
    var cameraAllowed by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var scanning by remember { mutableStateOf(true) }
    var result by remember { mutableStateOf<MealScanResponse?>(null) }
    var signOutConfirmation by remember { mutableStateOf(false) }
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
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("NHÀ ĂN SUKAVINA", color = SukavinaRed, fontSize = 12.sp, fontWeight = FontWeight.Black, letterSpacing = 1.4.sp)
                Text("Quét mã nhận món", fontSize = 27.sp, fontWeight = FontWeight.ExtraBold)
            }
            if (!state.profile?.employeeCode.equals("DEMO", ignoreCase = true)) {
                OutlinedButton(
                    onClick = { signOutConfirmation = true },
                    modifier = Modifier.heightIn(min = 44.dp),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                ) {
                    Icon(Icons.AutoMirrored.Filled.Logout, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Đăng xuất", fontWeight = FontWeight.Bold, maxLines = 1)
                }
            }
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
                    Surface(shape = appShape(18.dp, AppShapeRole.LARGE), color = MaterialTheme.colorScheme.surface) {
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
    if (signOutConfirmation && !state.profile?.employeeCode.equals("DEMO", ignoreCase = true)) SukavinaAlert(
        title = "Xác nhận đăng xuất?",
        eyebrow = "BẢO MẬT TÀI KHOẢN",
        icon = Icons.AutoMirrored.Filled.Logout,
        confirmText = "Đăng xuất",
        dismissText = "Giữ lại",
        danger = true,
        onDismiss = { signOutConfirmation = false },
        onConfirm = { signOutConfirmation = false; session.signOut() },
    ) {
        Text("Phiên đăng nhập trên thiết bị này sẽ kết thúc.", fontWeight = FontWeight.SemiBold)
        Text("Dữ liệu tài khoản vẫn được giữ nguyên.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun CanteenResultLine(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.weight(1f))
        Text(value, fontWeight = FontWeight.Bold, textAlign = androidx.compose.ui.text.style.TextAlign.End)
    }
}

@Composable
@androidx.annotation.OptIn(markerClass = [androidx.camera.core.ExperimentalGetImage::class])
fun CanteenCameraPreview(active: Boolean, modifier: Modifier = Modifier, onCode: (String) -> Unit) {
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
