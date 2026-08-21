package net.sukavinagroup.user

import android.Manifest
import android.app.PendingIntent
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

object NotificationHelper {
    private const val CHANNEL_ID = "sukavina_updates"

    fun createChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL_ID, "Thông báo nội bộ", NotificationManager.IMPORTANCE_DEFAULT,
        ).apply { description = "Bài viết và cập nhật mới từ Sukavina" })
    }

    fun showArticleNotification(context: Context, title: String, count: Int) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.app_icon).setContentTitle("Bài viết nội bộ mới")
            .setContentText(title).setNumber(count).setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT).build()
        NotificationManagerCompat.from(context).notify(1001, notification)
    }

    fun showRequestNotification(context: Context, title: String, count: Int) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.app_icon).setContentTitle("Thông báo đơn từ")
            .setContentText(title).setNumber(count).setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH).build()
        NotificationManagerCompat.from(context).notify(1002, notification)
    }

    fun showAttendanceNotification(context: Context, isCheckIn: Boolean, time: String) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val openApp = PendingIntent.getActivity(
            context,
            1003,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val action = if (isCheckIn) "vào" else "ra"
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.app_icon)
            .setContentTitle("Chấm công $action thành công")
            .setContentText("Giờ $action đã được ghi nhận lúc $time.")
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()
        NotificationManagerCompat.from(context).notify(1003, notification)
    }

    fun showPushNotification(context: Context, title: String, body: String) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val openApp = PendingIntent.getActivity(
            context,
            1004,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.app_icon)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        NotificationManagerCompat.from(context).notify(1004, notification)
    }

    fun clear(context: Context) = NotificationManagerCompat.from(context).cancel(1001)
}
