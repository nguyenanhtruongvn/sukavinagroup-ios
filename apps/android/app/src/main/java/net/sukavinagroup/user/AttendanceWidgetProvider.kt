package net.sukavinagroup.user

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.widget.RemoteViews
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import net.sukavinagroup.user.data.ApiClient
import net.sukavinagroup.user.data.Dashboard
import net.sukavinagroup.user.data.WidgetTokenBody
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.TemporalAdjusters

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
                val widgetToken = preferences.getString("widget_token", null) ?: return@runCatching
                val dashboard = ApiClient().post<Dashboard, WidgetTokenBody>(
                    "public/widget/attendance",
                    WidgetTokenBody(widgetToken),
                )
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
                bindWeek(views)
                manager.updateAppWidget(id, views)
            }
        }

        private fun bindWeek(views: RemoteViews) {
            val dayViews = intArrayOf(
                R.id.widget_day_1,
                R.id.widget_day_2,
                R.id.widget_day_3,
                R.id.widget_day_4,
                R.id.widget_day_5,
                R.id.widget_day_6,
                R.id.widget_day_7,
            )
            val zone = ZoneId.of("Asia/Ho_Chi_Minh")
            val today = LocalDate.now(zone)
            val monday = today.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
            dayViews.forEachIndexed { index, viewId ->
                val date = monday.plusDays(index.toLong())
                val isToday = date == today
                views.setTextViewText(viewId, date.dayOfMonth.toString())
                views.setInt(
                    viewId,
                    "setBackgroundResource",
                    if (isToday) R.drawable.attendance_widget_today else 0,
                )
                views.setTextColor(viewId, if (isToday) Color.rgb(211, 18, 52) else Color.WHITE)
            }
        }
    }
}

object AttendanceWidgetStore {
    private const val PREFERENCES = "sukavina-attendance-widget"

    data class State(
        val checkIn: String = "--:--",
        val checkOut: String = "--:--",
    )

    fun update(context: Context, dashboard: Dashboard) {
        val ordered = dashboard.attendanceRecords.sortedBy { it.punchedAt }
        val checkIn = ordered.firstOrNull()?.punchedAt.toTime()
        val checkOut = ordered.takeIf { it.size > 1 }?.lastOrNull()?.punchedAt.toTime()
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .putString("check_in", checkIn)
            .putString("check_out", checkOut)
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
