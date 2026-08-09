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


@Composable fun MainScreen(state: SessionUiState, session: SessionViewModel) {
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
            val selectedArticle = article
            when {
                attendanceOpen -> AttendanceScreen(session) { attendanceOpen = false }
                selectedArticle != null -> ArticleDetail(selectedArticle) { article = null }
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
