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


@Composable fun ProfileScreen(state: SessionUiState, session: SessionViewModel) {
    var deleteOpen by remember { mutableStateOf(false) }; var biometricPasswordOpen by remember { mutableStateOf(false) }; var biometricPassword by remember { mutableStateOf("") }; var passwordChangeOpen by remember { mutableStateOf(false) }
    var legalPage by remember { mutableStateOf<LegalPage?>(null) }
    var signOutConfirmation by remember { mutableStateOf(false) }
    var biometricError by remember { mutableStateOf<String?>(null) }
    val activity = LocalActivity.current as? MainActivity
    val profile = state.profile
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp).padding(bottom = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        PortalPageTitle("Tài khoản", Modifier.fillMaxWidth())
        Spacer(Modifier.height(14.dp))
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            shape = appShape(26.dp, AppShapeRole.EXTRA_LARGE),
        ) {
            Column(Modifier.fillMaxWidth().padding(22.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Surface(Modifier.size(88.dp), CircleShape, color = SukavinaRed.copy(alpha = .14f)) {
                    Box(contentAlignment = Alignment.Center) { Text(profile?.name.initials(), color = SukavinaRed, fontSize = 26.sp, fontWeight = FontWeight.Bold) }
                }
                Text(profile?.name ?: "Nhân viên", fontSize = 24.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 13.dp))
                Text(profile?.employeeCode.orEmpty(), color = SukavinaMuted, fontSize = 14.sp)
                Surface(shape = CircleShape, color = SukavinaRed.copy(alpha = .10f), modifier = Modifier.padding(top = 10.dp)) {
                    Text(profile?.role ?: "Nhân viên", color = SukavinaRed, fontSize = 12.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
                }
            }
        }
        ProfileSectionTitle("THÔNG TIN TÀI KHOẢN")
        Card(Modifier.fillMaxWidth().padding(top = 24.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) { Column { ProfileLine("Vai trò", profile?.role.orEmpty()); HorizontalDivider(); ProfileLine("Loại tài khoản", profile?.accountType.accountLabel()); HorizontalDivider(); Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Default.Fingerprint, null, tint = SukavinaRed); Text("Đăng nhập sinh trắc học", Modifier.padding(start = 10.dp).weight(1f)); Switch(state.biometricEnabled, onCheckedChange = { enabled -> if (enabled) activity?.authenticateBiometric(onSuccess = { biometricPasswordOpen = true }, onError = { biometricError = it }) else session.enableBiometric("", false) }) } } }
        ProfileSectionTitle("QUYỀN RIÊNG TƯ & HỖ TRỢ")
        Card(Modifier.fillMaxWidth().padding(top = 14.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
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
        Text("BẢO MẬT", modifier = Modifier.fillMaxWidth().padding(top = 24.dp, start = 2.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.4.sp)
        Column(
            modifier = Modifier.fillMaxWidth().padding(top = 18.dp),
        ) {
            ProfileActionCard(
                title = "Đổi mật khẩu",
                subtitle = if (profile?.accountType == "DEMO" || profile?.employeeCode.equals("DEMO", ignoreCase = true))
                    "Xác nhận bằng mật khẩu hiện tại · Không giới hạn số lần đổi"
                else "Xác minh OTP và thiết lập mật khẩu mới",
                icon = Icons.Default.Key,
                onClick = { passwordChangeOpen = true },
            )
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .55f))
            ProfileActionCard(
                title = "Đăng xuất",
                subtitle = "Kết thúc phiên đăng nhập trên thiết bị này",
                icon = Icons.AutoMirrored.Filled.Logout,
                onClick = { signOutConfirmation = true },
            )
        }
        if ((profile?.employeeCode == "DEMO" || profile?.protected != true) && profile?.accountType != "SUPER_ADMIN") {
            Text(
                "VÙNG NGUY HIỂM",
                modifier = Modifier.fillMaxWidth().padding(top = 34.dp, start = 8.dp, bottom = 8.dp),
                color = MaterialTheme.colorScheme.error,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 1.3.sp,
            )
            ProfileActionCard(
                title = "Yêu cầu xóa tài khoản",
                subtitle = "Xóa vĩnh viễn tài khoản và dữ liệu cá nhân",
                icon = Icons.Default.DeleteForever,
                danger = true,
                onClick = { deleteOpen = true },
            )
        }
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
        onConfirm = { session.deleteAccount(); deleteOpen = false },
    ) {
        Text("Tài khoản, dữ liệu cá nhân, đơn từ và lựa chọn món liên quan sẽ bị xóa.", fontWeight = FontWeight.SemiBold)
        Text("Thao tác này không thể hoàn tác. Hồ sơ chấm công hoặc hồ sơ lao động bắt buộc có thể vẫn được lưu theo chính sách Công ty.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (biometricPasswordOpen) AlertDialog(onDismissRequest = { biometricPasswordOpen = false }, title = { Text("Bật đăng nhập sinh trắc học") }, text = { OutlinedTextField(biometricPassword, { biometricPassword = it }, label = { Text("Nhập mật khẩu hiện tại") }, visualTransformation = PasswordVisualTransformation()) }, confirmButton = { Button(onClick = { session.enableBiometric(biometricPassword, true) { if (it) biometricPasswordOpen = false } }) { Text("Xác nhận") } }, dismissButton = { TextButton(onClick = { biometricPasswordOpen = false }) { Text("Hủy") } })
    biometricError?.let { message ->
        SukavinaAlert(
            title = "Không thể bật sinh trắc học",
            eyebrow = "BẢO MẬT THIẾT BỊ",
            icon = Icons.Default.Fingerprint,
            confirmText = "Đã hiểu",
            onConfirm = { biometricError = null },
            onDismiss = { biometricError = null },
            danger = true,
        ) { Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant, lineHeight = 21.sp) }
    }
    if (passwordChangeOpen) PasswordChangeDialog(state, session) { passwordChangeOpen = false }
    legalPage?.let { page -> NativeLegalSheet(page) { legalPage = null } }
    if (signOutConfirmation) SukavinaAlert(
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
        Text("Dữ liệu tài khoản vẫn được giữ nguyên và bạn có thể đăng nhập lại bất cứ lúc nào.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ProfileSectionTitle(title: String) {
    Text(
        title,
        modifier = Modifier.fillMaxWidth().padding(top = 24.dp, start = 2.dp),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontSize = 12.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 1.4.sp,
    )
}

@Composable
private fun ProfileActionCard(
    title: String,
    subtitle: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    danger: Boolean = false,
    onClick: () -> Unit,
) {
    val accent = if (danger) MaterialTheme.colorScheme.error else SukavinaRed
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(appShape(16.dp, AppShapeRole.LARGE))
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = accent, modifier = Modifier.size(24.dp))
        Column(
            modifier = Modifier.padding(start = 14.dp).weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(title, color = if (danger) accent else MaterialTheme.colorScheme.onSurface, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
            Text(subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp, lineHeight = 16.sp)
        }
        Icon(Icons.Default.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .62f), modifier = Modifier.size(20.dp))
    }
}

@Composable fun NativeLegalSheet(page: LegalPage, dismiss: () -> Unit) {
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
                LegalSection("Xóa trong ứng dụng", "Quay lại tab Tài khoản, chọn “Yêu cầu xóa tài khoản” ở cuối trang, đọc cảnh báo rủi ro và xác nhận.")
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

@Composable fun LegalSection(title: String, content: String) {
    Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Text(title, fontWeight = FontWeight.Bold, fontSize = 17.sp)
            Text(content, color = SukavinaMuted, lineHeight = 21.sp)
        }
    }
}

@Composable fun PasswordChangeDialog(state: SessionUiState, session: SessionViewModel, dismiss: () -> Unit) {
    var email by remember { mutableStateOf("") }; var otpSent by remember { mutableStateOf(false) }; var code by remember { mutableStateOf("") }
    var currentPassword by remember { mutableStateOf("") }; var newPassword by remember { mutableStateOf("") }; var confirmPassword by remember { mutableStateOf("") }; var completed by remember { mutableStateOf(false) }
    val isDemo = state.profile?.accountType == "DEMO" || state.profile?.employeeCode.equals("DEMO", ignoreCase = true)
    val validPassword = newPassword.length >= 6 && newPassword.any(Char::isLetter) && newPassword.any(Char::isDigit)
    val currentPasswordError = state.error?.takeIf {
        isDemo && it.contains("Mật khẩu hiện tại", ignoreCase = true)
    }
    val reusedPasswordError = state.error?.takeIf { isDemo && it.contains("Mật khẩu mới phải khác", ignoreCase = true) }
    AlertDialog(
        onDismissRequest = dismiss,
        modifier = Modifier.fillMaxWidth(.9f).widthIn(max = 460.dp),
        shape = appShape(28.dp, AppShapeRole.EXTRA_LARGE),
        icon = {
            Surface(shape = CircleShape, color = SukavinaRed.copy(alpha = .11f), modifier = Modifier.size(48.dp)) {
                Box(contentAlignment = Alignment.Center) { Icon(Icons.Default.Key, null, tint = SukavinaRed) }
            }
        },
        title = { Text(if (completed) "Đổi mật khẩu thành công" else "Đổi mật khẩu", fontWeight = FontWeight.Bold) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (completed) Text("Mật khẩu đã được thay đổi thành công.")
            else if (!otpSent && !isDemo) Text("Mã OTP sẽ được gửi tới email liên kết. Tài khoản chưa có email cần liên hệ Nhân sự để cập nhật.")
            else if (isDemo) {
                Text(
                    "Tài khoản Demo không dùng OTP. Nhập mật khẩu hiện tại để xác nhận thay đổi.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    lineHeight = 20.sp,
                )
                OutlinedTextField(
                    currentPassword,
                    { currentPassword = it; if (currentPasswordError != null) session.clearError() },
                    label = { Text("Mật khẩu hiện tại") },
                    supportingText = { currentPasswordError?.let { Text(it) } },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    isError = currentPasswordError != null,
                )
                OutlinedTextField(
                    newPassword,
                    { newPassword = it; if (reusedPasswordError != null) session.clearError() },
                    label = { Text("Mật khẩu mới") },
                    supportingText = { Text(reusedPasswordError ?: "Ít nhất 6 ký tự, gồm chữ cái và chữ số") },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    isError = (newPassword.isNotEmpty() && !validPassword) || reusedPasswordError != null,
                )
                OutlinedTextField(
                    confirmPassword,
                    { confirmPassword = it },
                    label = { Text("Xác nhận mật khẩu mới") },
                    supportingText = { if (confirmPassword.isNotEmpty() && confirmPassword != newPassword) Text("Mật khẩu xác nhận chưa khớp") },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    isError = confirmPassword.isNotEmpty() && confirmPassword != newPassword,
                )
            }
            else { Text("Mã OTP đã được gửi tới $email", color = SukavinaRed, fontWeight = FontWeight.SemiBold)
                OutlinedTextField(
                    code,
                    { code = it.filter(Char::isDigit).take(6) },
                    label = { Text("Mã OTP gồm 6 số") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.SmsOtpCode },
                )
                OutlinedTextField(newPassword, { newPassword = it }, label = { Text("Mật khẩu mới, ít nhất 6 ký tự gồm chữ và số") }, visualTransformation = PasswordVisualTransformation())
                OutlinedTextField(confirmPassword, { confirmPassword = it }, label = { Text("Nhập lại mật khẩu mới") }, visualTransformation = PasswordVisualTransformation()) }
        } },
        confirmButton = { when { completed -> Button(onClick = dismiss) { Text("Hoàn tất") }
            isDemo -> Button(onClick = { session.confirmPasswordChange(currentPassword = currentPassword, newPassword = newPassword) { if (it) completed = true } }, enabled = currentPassword.isNotEmpty() && validPassword && newPassword == confirmPassword && !state.working) { Text("Xác nhận") }
            !otpSent -> Button(onClick = { session.requestPasswordChange { if (it != null) { email = it.email; otpSent = true } } }, enabled = !state.working) { Text("Gửi mã OTP") }
            else -> Button(onClick = { session.confirmPasswordChange(code = code, newPassword = newPassword) { if (it) completed = true } }, enabled = code.length == 6 && validPassword && newPassword == confirmPassword && !state.working) { Text("Xác nhận") } } },
        dismissButton = { if (!completed) TextButton(onClick = dismiss) { Text("Hủy") } },
    )
}

@Composable fun ProfileLine(label: String, value: String) = Row(Modifier.fillMaxWidth().padding(18.dp)) { Text(label, color = SukavinaMuted); Spacer(Modifier.weight(1f)); Text(value, fontWeight = FontWeight.Medium) }

fun String?.toTime(): String { if (this.isNullOrBlank()) return "--:--"; return runCatching { OffsetDateTime.parse(this).atZoneSameInstant(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("HH:mm")) }.getOrDefault("--:--") }
fun String.toDateLabel() = runCatching { OffsetDateTime.parse(this).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.forLanguageTag("vi-VN"))) }.getOrDefault("")
fun String.toDateTimeLabel() = runCatching { OffsetDateTime.parse(this).atZoneSameInstant(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm")) }.getOrDefault(this)
fun String.toDayLabel() = runCatching { LocalDate.parse(this).format(DateTimeFormatter.ofPattern("EEEE, dd/MM", Locale.forLanguageTag("vi-VN"))) }.getOrDefault(this)
fun String.plainText() = Html.fromHtml(take(750_000), Html.FROM_HTML_MODE_LEGACY).toString().replace(Regex("\\s+"), " ").trim()
fun String?.initials() = this.orEmpty().split(" ").filter { it.isNotBlank() }.takeLast(2).joinToString("") { it.take(1).uppercase() }.ifBlank { "NV" }
fun String?.accountLabel() = when (this) { "SUPER_ADMIN" -> "Quản trị viên tổng"; "ADMIN" -> "Quản trị viên"; else -> "Nhân viên" }
