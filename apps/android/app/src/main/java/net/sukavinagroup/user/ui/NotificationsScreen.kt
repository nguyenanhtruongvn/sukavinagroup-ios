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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
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
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatWriter
import com.google.zxing.common.BitMatrix


@Composable fun NewsScreen(items: List<ContentItem>, open: (ContentItem) -> Unit) {
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
fun SwipeDeleteItem(
    onDelete: () -> Unit,
    content: @Composable () -> Unit,
) {
    val haptics = LocalHapticFeedback.current
    val dismissState = rememberSwipeToDismissBoxState(
        positionalThreshold = { distance -> distance * .5f },
    )
    LaunchedEffect(dismissState.currentValue) {
        if (dismissState.currentValue == SwipeToDismissBoxValue.EndToStart) {
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            onDelete()
        }
    }
    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        enableDismissFromEndToStart = true,
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.error),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Icon(
                    Icons.Default.Delete,
                    contentDescription = "Xóa",
                    tint = MaterialTheme.colorScheme.onError,
                    modifier = Modifier.padding(horizontal = 24.dp),
                )
            }
        },
        content = {
            Box(
                modifier = Modifier
                .fillMaxWidth()
                    .clip(appShape(22.dp, AppShapeRole.EXTRA_LARGE)),
            ) { content() }
        },
    )
}

@Composable fun NotificationsScreen(state: SessionUiState, session: SessionViewModel, openArticle: (ContentItem) -> Unit) {
    var selected by remember { mutableStateOf<EmployeeRequest?>(null) }
    var reviewing by remember { mutableStateOf<EmployeeRequest?>(null) }
    var confirmClear by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    val refreshScope = rememberCoroutineScope()
    val requests = (state.requests + state.approvals).associateBy { it.id }
    val visibleArticles = state.dashboard?.contentItems.orEmpty().filterNot { it.id in state.hiddenArticleIds }
    val unread = state.unreadCount + state.requestNotifications.count { !it.read }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(20.dp, 20.dp, 20.dp, 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) { PortalPageTitle("Thông báo"); Text(if (unread > 0) "$unread thông báo chưa đọc" else "Bạn đã đọc tất cả", color = SukavinaMuted) }
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
                val tone = kind?.color ?: when { item.type.contains("rejected") -> SukavinaRed; item.type.contains("cancelled") -> Color(0xFF8E8E93); item.type == "request_pending" -> Color(0xFFFF9500); else -> Color(0xFF34C759) }
                SwipeDeleteItem(onDelete = { session.deleteNotification(item.id) }) {
                    Surface(
                        onClick = { session.openNotification(item.id); if (request != null) { if (item.type == "request_pending" && request.status == "pending" && state.approvals.any { it.id == request.id }) reviewing = request else selected = request } },
                        shape = appShape(20.dp, AppShapeRole.EXTRA_LARGE),
                        color = if (item.read) Color(0xFFF2F2F7) else MaterialTheme.colorScheme.surface,
                        tonalElevation = 0.dp,
                        border = androidx.compose.foundation.BorderStroke(if (item.read) 1.dp else 1.dp, if (item.read) Color.Transparent else tone.copy(alpha = .36f)),
                        shadowElevation = if (item.read) 0.dp else 4.dp,
                        ) {
                        Row(Modifier.fillMaxWidth().background(Brush.linearGradient(listOf(if (item.read) Color.Transparent else tone.copy(alpha = .12f), Color.Transparent))).padding(15.dp), verticalAlignment = Alignment.Top) {
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
                        color = if (isUnread) MaterialTheme.colorScheme.surface else Color(0xFFF2F2F7),
                        tonalElevation = 0.dp,
                        border = androidx.compose.foundation.BorderStroke(if (isUnread) 1.dp else 1.dp, if (isUnread) SukavinaRed.copy(alpha = .36f) else Color.Transparent),
                        shadowElevation = if (isUnread) 4.dp else 0.dp,
                    ) { Row(Modifier.fillMaxWidth().background(Brush.linearGradient(listOf(if (isUnread) SukavinaRed.copy(alpha = .12f) else Color.Transparent, Color.Transparent))).padding(15.dp), verticalAlignment = Alignment.Top) { Surface(Modifier.size(44.dp), appShape(14.dp), color = SukavinaRed.copy(alpha = .16f)) { Icon(Icons.Default.Campaign, null, tint = SukavinaRed, modifier = Modifier.padding(11.dp)) }; Column(Modifier.padding(start = 12.dp).weight(1f)) { Text(item.title, fontWeight = FontWeight.Bold); Text(item.body.plainText(), color = SukavinaMuted, maxLines = 2, overflow = TextOverflow.Ellipsis) }; if (isUnread) Surface(shape = CircleShape, color = SukavinaRed.copy(alpha = .18f)) { Text("Mới", color = SukavinaRed, fontSize = 10.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp)) } } }
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

@Composable fun NewsCard(item: ContentItem, onClick: () -> Unit) = Card(onClick = onClick, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
    Column(Modifier.padding(18.dp)) {
        Text(item.createdAt.toDateLabel(), color = SukavinaRed, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        Text(item.title, fontSize = 18.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(vertical = 7.dp))
        Text(item.body.plainText(), color = SukavinaMuted, maxLines = 3, overflow = TextOverflow.Ellipsis)
    }
}

@Composable fun ArticleDetail(item: ContentItem, back: () -> Unit) {
    Scaffold(topBar = { TopAppBar(title = { Text("Bài viết") }, navigationIcon = { IconButton(onClick = back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Quay lại") } }) }) { padding ->
        LazyColumn(Modifier.padding(padding), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            item { Text(item.createdAt.toDateLabel(), color = SukavinaRed, fontWeight = FontWeight.Bold); Text(item.title, fontSize = 29.sp, lineHeight = 35.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(top = 7.dp)) }
            item {
                AndroidView(factory = { context -> TextView(context).apply { setTextColor(android.graphics.Color.rgb(241,238,234)); textSize = 17f; setLineSpacing(8f, 1f); setPadding(0,8,0,30) } },
                    update = { it.text = Html.fromHtml(item.body.take(750_000), Html.FROM_HTML_MODE_LEGACY) }, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}
