package net.sukavinagroup.user

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/** Receives FCM only while the app is not actively connected through SSE. */
class SukavinaFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        super.onNewToken(token)
        getSharedPreferences(PUSH_PREFERENCES, MODE_PRIVATE)
            .edit()
            .putString(PUSH_TOKEN_KEY, token)
            .apply()
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        val title = message.notification?.title ?: message.data["title"] ?: "Sukavina"
        val body = message.notification?.body ?: message.data["body"] ?: "Bạn có cập nhật mới."
        NotificationHelper.showPushNotification(this, title, body)
    }

    companion object {
        const val PUSH_PREFERENCES = "sukavina-push"
        const val PUSH_TOKEN_KEY = "fcm_token"
    }
}
