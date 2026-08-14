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
import androidx.compose.ui.window.DialogProperties
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


@Composable fun LoginScreen(
    state: SessionUiState,
    signIn: (String, String) -> Unit,
    biometricSignIn: () -> Unit = {},
    dismissError: () -> Unit = {},
    session: SessionViewModel? = null,
) {
    val activity = LocalActivity.current as? MainActivity
    var login by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var forgotOpen by remember { mutableStateOf(false) }
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
        SukavinaPasswordField(password, { password = it }, label = { Text("Mật khẩu") },
            leadingIcon = { Icon(Icons.Default.Lock, null) }, autoFillPassword = true,
            modifier = Modifier.fillMaxWidth())
        Button(onClick = { signIn(login, password) }, enabled = login.isNotBlank() && password.isNotBlank() && !state.working,
            elevation = SukavinaButtonElevation,
            modifier = Modifier.fillMaxWidth().padding(top = 18.dp).height(54.dp), shape = appShape(16.dp, AppShapeRole.LARGE)) {
            if (state.working) CircularProgressIndicator(Modifier.size(22.dp), color = Color.White, strokeWidth = 2.dp)
            else Text("Đăng nhập", fontWeight = FontWeight.Bold)
        }
        if (session != null) {
            TextButton(
                onClick = { forgotOpen = true },
                modifier = Modifier.align(Alignment.End),
            ) {
                Icon(Icons.Default.LockReset, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(7.dp))
                Text("Quên mật khẩu?", fontWeight = FontWeight.SemiBold)
            }
        }
        if (state.biometricEnabled) OutlinedButton(onClick = { activity?.authenticateBiometric(biometricSignIn) }, modifier = Modifier.fillMaxWidth().padding(top = 10.dp).height(52.dp), shape = appShape(16.dp, AppShapeRole.LARGE)) { Icon(Icons.Default.Fingerprint, null); Spacer(Modifier.width(8.dp)); Text("Đăng nhập bằng sinh trắc học") }
    }
    if (forgotOpen && session != null) ForgotPasswordDialog(state, session, login) { forgotOpen = false }
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

@Composable private fun ForgotPasswordDialog(state: SessionUiState, session: SessionViewModel, initialCode: String, dismiss: () -> Unit) {
    var employeeCode by remember { mutableStateOf(initialCode) }; var otpSent by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf("") }; var password by remember { mutableStateOf("") }; var confirmation by remember { mutableStateOf("") }
    var attempted by remember { mutableStateOf(false) }; var formError by remember { mutableStateOf<String?>(null) }
    val passwordError = when {
        password.length < 6 -> "Mật khẩu phải có ít nhất 6 ký tự."
        password.none(Char::isLetter) -> "Mật khẩu phải có ít nhất một chữ cái."
        password.none(Char::isDigit) -> "Mật khẩu phải có ít nhất một chữ số."
        else -> null
    }
    val confirmationError = if (confirmation != password) "Mật khẩu nhập lại không khớp." else null
    AlertDialog(
        onDismissRequest = dismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).widthIn(max = 520.dp),
        icon = { Icon(Icons.Default.LockReset, null, tint = SukavinaRed) },
        title = { Text("Khôi phục mật khẩu", fontWeight = FontWeight.Bold) },
        text = { Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("OTP sẽ được gửi đến email đã liên kết với mã nhân viên.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(employeeCode, { employeeCode = it; formError = null }, enabled = !otpSent, label = { Text("Mã nhân viên") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            if (otpSent) {
                OutlinedTextField(code, { code = it.filter(Char::isDigit).take(6); formError = null }, label = { Text("Mã OTP") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), isError = attempted && code.length != 6, supportingText = { if (attempted && code.length != 6) Text("Mã OTP phải gồm đủ 6 chữ số.") }, modifier = Modifier.fillMaxWidth())
                SukavinaPasswordField(password, { password = it; formError = null }, label = { Text("Mật khẩu mới") }, isError = attempted && passwordError != null, supportingText = { if (attempted) passwordError?.let { Text(it) } }, modifier = Modifier.fillMaxWidth())
                SukavinaPasswordField(confirmation, { confirmation = it; formError = null }, label = { Text("Nhập lại mật khẩu") }, isError = attempted && confirmationError != null, supportingText = { if (attempted) confirmationError?.let { Text(it) } }, modifier = Modifier.fillMaxWidth())
            }
            formError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        } },
        confirmButton = { Button(enabled = !state.working, onClick = {
            attempted = true; formError = null
            if (employeeCode.isBlank()) { formError = "Vui lòng nhập mã nhân viên."; return@Button }
            if (!otpSent) session.requestForgotPassword(employeeCode) { response, error ->
                formError = error ?: if (response?.maskedEmail.isNullOrBlank()) "Tài khoản chưa có email liên kết. Vui lòng liên hệ Nhân sự để cập nhật email." else null
                if (response?.maskedEmail?.isNotBlank() == true) { otpSent = true; attempted = false }
            } else {
                if (code.length != 6 || passwordError != null || confirmationError != null) return@Button
                session.confirmForgotPassword(employeeCode, code, password) { success, error -> if (success) dismiss() else formError = error }
            }
        }) { Text(if (otpSent) "Đặt lại mật khẩu" else "Gửi OTP") } },
        dismissButton = { TextButton(onClick = dismiss) { Text("Hủy") } },
    )
}

@Composable fun InternetConnectionAlert(dismiss: () -> Unit) {
    SukavinaAlert(
        title = "Kiểm tra kết nối Internet",
        eyebrow = "MẤT KẾT NỐI",
        icon = Icons.Default.WifiOff,
        confirmText = "Đóng",
        onConfirm = dismiss,
        onDismiss = dismiss,
        tone = Color(0xFF3978D4),
    ) {
        Text(
            "Không thể kết nối đến máy chủ. Hãy kiểm tra Wi-Fi hoặc dữ liệu di động rồi thử lại.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            lineHeight = 21.sp,
        )
    }
}

@Composable
fun SukavinaAlert(
    title: String,
    eyebrow: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    confirmText: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    dismissText: String? = null,
    danger: Boolean = false,
    tone: Color? = null,
    confirmEnabled: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val accent = tone ?: if (danger) Color(0xFFD92D3A) else SukavinaRed
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).widthIn(max = 440.dp),
            shape = appShape(28.dp, AppShapeRole.EXTRA_LARGE),
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 2.dp,
            shadowElevation = 18.dp,
            border = androidx.compose.foundation.BorderStroke(1.dp, accent.copy(alpha = .14f)),
        ) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Surface(
                        Modifier.size(48.dp),
                        appShape(16.dp, AppShapeRole.LARGE),
                        color = accent.copy(alpha = .12f),
                    ) {
                        Icon(icon, null, tint = accent, modifier = Modifier.padding(12.dp))
                    }
                    Column(Modifier.padding(start = 13.dp).weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(eyebrow, color = accent, fontSize = 10.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 1.2.sp)
                        Text(title, fontSize = 20.sp, lineHeight = 24.sp, fontWeight = FontWeight.Bold)
                    }
                    IconButton(onClick = onDismiss, modifier = Modifier.size(38.dp)) {
                        Icon(Icons.Default.Close, contentDescription = "Đóng", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = appShape(17.dp, AppShapeRole.LARGE),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .42f),
                ) {
                    Column(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalArrangement = Arrangement.spacedBy(9.dp),
                        content = content,
                    )
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    dismissText?.let {
                        FilledTonalButton(
                            onClick = onDismiss,
                            modifier = Modifier.weight(1f).height(50.dp),
                            shape = appShape(15.dp, AppShapeRole.LARGE),
                        ) { Text(it, fontWeight = FontWeight.Bold) }
                    }
                    Button(
                        onClick = onConfirm,
                        enabled = confirmEnabled,
                        modifier = Modifier.weight(if (dismissText == null) 1f else 1.25f).height(50.dp),
                        shape = appShape(15.dp, AppShapeRole.LARGE),
                        elevation = SukavinaButtonElevation,
                        colors = ButtonDefaults.buttonColors(containerColor = accent, contentColor = Color.White),
                    ) { Text(confirmText, fontWeight = FontWeight.Bold) }
                }
            }
        }
    }
}

fun String.isConnectionError() =
    contains("kết nối", ignoreCase = true) &&
        (contains("Internet", ignoreCase = true) || contains("máy chủ", ignoreCase = true))
