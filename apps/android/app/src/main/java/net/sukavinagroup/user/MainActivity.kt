package net.sukavinagroup.user

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.fragment.app.FragmentActivity
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
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
                if (state.token != null && Build.VERSION.SDK_INT >= 33) {
                    notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
            }
            SukavinaApp(state = state, session = session)
        }
    }

    fun authenticateBiometric(onSuccess: () -> Unit) {
        val prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) { onSuccess() }
        })
        prompt.authenticate(BiometricPrompt.PromptInfo.Builder()
            .setTitle("Đăng nhập Sukavina")
            .setSubtitle("Xác nhận bằng vân tay hoặc khuôn mặt")
            .setNegativeButtonText("Hủy")
            .build())
    }
}
