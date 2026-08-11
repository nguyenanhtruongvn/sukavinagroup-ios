package net.sukavinagroup.user

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.widget.RemoteViews
import androidx.core.content.edit
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
import java.util.Locale

class AttendanceWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        render(context, manager, ids)
        val pendingResult = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            runCatching {
                val metadata = context.getSharedPreferences("sukavina-session-metadata", Context.MODE_PRIVATE)
                val secureStore = SecureSessionStore(context)
                LegacySecureSessionMigration.migrate(context, metadata, secureStore)
                val widgetToken = secureStore.getString("widget_token") ?: return@runCatching
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

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        render(context, manager, intArrayOf(appWidgetId))
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
                val options = manager.getAppWidgetOptions(id)
                // Launchers do not report resized widget bounds consistently: some keep
                // MIN_HEIGHT at the provider minimum and only update MAX_HEIGHT.
                val currentHeight = maxOf(
                    options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT),
                    options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT),
                )
                val isLarge = currentHeight >= 250
                val views = RemoteViews(
                    context.packageName,
                    if (isLarge) R.layout.attendance_widget_large else R.layout.attendance_widget,
                )
                views.setOnClickPendingIntent(R.id.widget_root, openApp)
                views.setTextViewText(R.id.widget_check_in, state.checkIn)
                views.setTextViewText(R.id.widget_check_out, state.checkOut)
                if (isLarge) bindMonth(views) else bindWeek(views)
                manager.updateAppWidget(id, views)
            }
        }

        private fun bindMonth(views: RemoteViews) {
            val zone = ZoneId.of("Asia/Ho_Chi_Minh")
            val today = LocalDate.now(zone)
            val firstDay = today.withDayOfMonth(1)
            val gridStart = firstDay.minusDays((firstDay.dayOfWeek.value - 1).toLong())
            val text = StringBuilder()
            val ranges = mutableListOf<Triple<IntRange, Boolean, Boolean>>()
            repeat(42) { index ->
                val date = gridStart.plusDays(index.toLong())
                val start = text.length
                text.append(String.format(Locale.US, "%2d", date.dayOfMonth))
                ranges += Triple(start until text.length, date.month == today.month, date == today)
                if (index % 7 == 6) {
                    if (index != 41) text.append('\n')
                } else {
                    text.append("  ")
                }
            }
            val calendarText = SpannableString(text.toString())
            ranges.forEach { (range, isInMonth, isToday) ->
                if (!isInMonth) {
                    calendarText.setSpan(
                        ForegroundColorSpan(Color.rgb(150, 160, 166)),
                        range.first,
                        range.last + 1,
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                    )
                }
                if (isToday) {
                    calendarText.setSpan(
                        BackgroundColorSpan(Color.rgb(233, 32, 45)),
                        range.first,
                        range.last + 1,
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                    )
                    calendarText.setSpan(
                        ForegroundColorSpan(Color.WHITE),
                        range.first,
                        range.last + 1,
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                    )
                    calendarText.setSpan(
                        StyleSpan(Typeface.BOLD),
                        range.first,
                        range.last + 1,
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                    )
                }
            }
            views.setTextViewText(
                R.id.widget_month_title,
                today.format(DateTimeFormatter.ofPattern("'Tháng' M • yyyy", Locale.forLanguageTag("vi-VN"))),
            )
            views.setTextViewText(R.id.widget_month_grid, calendarText)
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
                views.setTextColor(viewId, if (isToday) Color.WHITE else Color.rgb(35, 45, 54))
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
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit {
            putString("check_in", checkIn)
            putString("check_out", checkOut)
        }
        AttendanceWidgetProvider.renderAll(context)
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit { clear() }
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
