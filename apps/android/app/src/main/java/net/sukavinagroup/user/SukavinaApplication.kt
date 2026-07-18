package net.sukavinagroup.user

import android.app.Application

class SukavinaApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        NotificationHelper.createChannel(this)
    }
}
