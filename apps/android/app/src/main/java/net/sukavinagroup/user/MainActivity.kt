package net.sukavinagroup.user

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import net.sukavinagroup.user.ui.SukavinaApp

class MainActivity : ComponentActivity() {
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
}
