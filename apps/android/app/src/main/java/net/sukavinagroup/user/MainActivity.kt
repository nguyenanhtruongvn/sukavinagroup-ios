package net.sukavinagroup.user

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.fragment.app.FragmentActivity
import androidx.biometric.BiometricPrompt
import androidx.biometric.BiometricManager
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.core.net.toUri
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import net.sukavinagroup.user.ui.SukavinaApp

class MainActivity : FragmentActivity() {
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val session: SessionViewModel = viewModel()
            val state = session.state.collectAsStateWithLifecycle().value
            LaunchedEffect(state.token) {
                val preferences = getSharedPreferences("sukavina-permissions", MODE_PRIVATE)
                if (state.token != null && Build.VERSION.SDK_INT >= 33 &&
                    !preferences.getBoolean("notification_permission_requested", false)
                ) {
                    preferences.edit { putBoolean("notification_permission_requested", true) }
                    notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
            }
            SukavinaApp(state = state, session = session)
        }
    }

    fun authenticateBiometric(onSuccess: () -> Unit, onError: (String) -> Unit = {}) {
        val authenticators = BiometricManager.Authenticators.BIOMETRIC_WEAK
        when (BiometricManager.from(this).canAuthenticate(authenticators)) {
            BiometricManager.BIOMETRIC_SUCCESS -> Unit
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> {
                onError("Thiết bị chưa đăng ký vân tay hoặc khuôn mặt. Vui lòng thiết lập sinh trắc học trong Cài đặt rồi thử lại.")
                return
            }
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> {
                onError("Thiết bị này không hỗ trợ xác thực sinh trắc học.")
                return
            }
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> {
                onError("Cảm biến sinh trắc học đang không khả dụng. Vui lòng thử lại sau.")
                return
            }
            else -> {
                onError("Không thể sử dụng sinh trắc học trên thiết bị này.")
                return
            }
        }
        val prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) { onSuccess() }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (errorCode != BiometricPrompt.ERROR_NEGATIVE_BUTTON && errorCode != BiometricPrompt.ERROR_USER_CANCELED) {
                    onError(errString.toString().ifBlank { "Không thể xác thực sinh trắc học." })
                }
            }
        })
        prompt.authenticate(BiometricPrompt.PromptInfo.Builder()
            .setTitle("Xác thực sinh trắc học")
            .setSubtitle("Dùng vân tay hoặc khuôn mặt đã đăng ký trên thiết bị")
            .setAllowedAuthenticators(authenticators)
            .setNegativeButtonText("Hủy")
            .build())
    }

    fun openNotificationSettings() {
        startActivity(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName),
        )
    }

    fun openUrl(url: String) {
        startActivity(Intent(Intent.ACTION_VIEW, url.toUri()))
    }
}
