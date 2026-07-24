package net.sukavinagroup.user

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import net.sukavinagroup.user.data.ApiClient
import net.sukavinagroup.user.data.Dashboard
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

class AttendanceWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        render(context, manager, ids)
        val pendingResult = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            runCatching {
                val preferences = EncryptedSharedPreferences.create(
                    context,
                    "sukavina-secure-session",
                    MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
                )
                val token = preferences.getString("token", null) ?: return@runCatching
                val dashboard = ApiClient().get<Dashboard>("me/dashboard", token)
                AttendanceWidgetStore.update(context, dashboard)
            }
            renderAll(context)
            pendingResult.finish()
        }
    }

    companion object {
        fun renderAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, AttendanceWidgetProvider::class.java))
            render(context, manager, ids)
        }

        private fun render(context: Context, manager: AppWidgetManager, ids: IntArray) {
            if (ids.isEmpty()) return
            val state = AttendanceWidgetStore.load(context)
            val openApp = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            ids.forEach { id ->
                val views = RemoteViews(context.packageName, R.layout.attendance_widget)
                views.setOnClickPendingIntent(R.id.widget_root, openApp)
                views.setTextViewText(R.id.widget_check_in, state.checkIn)
                views.setTextViewText(R.id.widget_check_out, state.checkOut)
                views.setTextViewText(R.id.widget_status, state.status)
                views.setTextViewText(R.id.widget_updated, state.updated)
                manager.updateAppWidget(id, views)
            }
        }
    }
}

object AttendanceWidgetStore {
    private const val PREFERENCES = "sukavina-attendance-widget"

    data class State(
        val checkIn: String = "--:--",
        val checkOut: String = "--:--",
        val status: String = "Chưa chấm công",
        val updated: String = "Mở Sukavina để cập nhật",
    )

    fun update(context: Context, dashboard: Dashboard) {
        val ordered = dashboard.attendanceRecords.sortedBy { it.punchedAt }
        val checkIn = ordered.firstOrNull()?.punchedAt.toTime()
        val checkOut = ordered.takeIf { it.size > 1 }?.lastOrNull()?.punchedAt.toTime()
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .putString("check_in", checkIn)
            .putString("check_out", checkOut)
            .putString("status", dashboard.attendanceStatus.ifBlank { "Chưa chấm công" })
            .putString("updated", "Cập nhật ${OffsetDateTime.now().format(DateTimeFormatter.ofPattern("HH:mm"))}")
            .apply()
        AttendanceWidgetProvider.renderAll(context)
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().clear().apply()
        AttendanceWidgetProvider.renderAll(context)
    }

    fun load(context: Context): State {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        return State(
            checkIn = preferences.getString("check_in", null) ?: "--:--",
            checkOut = preferences.getString("check_out", null) ?: "--:--",
            status = preferences.getString("status", null) ?: "Chưa chấm công",
            updated = preferences.getString("updated", null) ?: "Mở Sukavina để cập nhật",
        )
    }

    private fun String?.toTime(): String {
        if (this.isNullOrBlank()) return "--:--"
        return runCatching {
            OffsetDateTime.parse(this)
                .atZoneSameInstant(ZoneId.systemDefault())
                .format(DateTimeFormatter.ofPattern("HH:mm"))
        }.getOrDefault("--:--")
    }
}
