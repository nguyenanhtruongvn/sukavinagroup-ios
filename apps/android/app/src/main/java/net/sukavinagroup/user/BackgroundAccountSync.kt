package net.sukavinagroup.user

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import net.sukavinagroup.user.data.ApiClient
import net.sukavinagroup.user.data.ApiException
import net.sukavinagroup.user.data.Dashboard
import net.sukavinagroup.user.data.LoginResponse
import net.sukavinagroup.user.data.RefreshSessionBody
import java.util.concurrent.TimeUnit

/**
 * Keeps the signed-in account useful while the UI is closed: refreshes the
 * session, updates the attendance widget, and lets the separate FCM worker
 * retry token registration. Work is network-only and deliberately runs at a
 * modest cadence so it respects Android battery limits.
 */
object BackgroundAccountSync {
    private const val PERIODIC_WORK = "sukavina-background-account-sync"
    private const val IMMEDIATE_WORK = "sukavina-background-account-sync-now"

    private val networkConstraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    fun schedule(context: Context) {
        val request = PeriodicWorkRequestBuilder<BackgroundAccountSyncWorker>(6, TimeUnit.HOURS, 1, TimeUnit.HOURS)
            .setConstraints(networkConstraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
            PERIODIC_WORK,
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )
    }

    fun enqueueImmediate(context: Context) {
        val request = OneTimeWorkRequestBuilder<BackgroundAccountSyncWorker>()
            .setConstraints(networkConstraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            IMMEDIATE_WORK,
            ExistingWorkPolicy.KEEP,
            request,
        )
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context.applicationContext).apply {
            cancelUniqueWork(PERIODIC_WORK)
            cancelUniqueWork(IMMEDIATE_WORK)
        }
    }
}

class BackgroundAccountSyncWorker(
    appContext: Context,
    workerParams: WorkerParameters,
) : CoroutineWorker(appContext, workerParams) {
    override suspend fun doWork(): Result {
        val secureStore = SecureSessionStore(applicationContext)
        val refreshToken = secureStore.getString("refresh_token") ?: return Result.success()
        val api = ApiClient()

        return runCatching {
            val session = api.post<LoginResponse, RefreshSessionBody>(
                "auth/refresh",
                RefreshSessionBody(refreshToken),
            )
            secureStore.putString("token", session.accessToken)
            if (session.refreshToken.isNotBlank()) secureStore.putString("refresh_token", session.refreshToken)
            if (session.widgetToken.isNotBlank()) secureStore.putString("widget_token", session.widgetToken)
            val dashboard = api.get<Dashboard>("me/dashboard", session.accessToken)
            AttendanceWidgetStore.update(applicationContext, dashboard)
            PushTokenSync.enqueue(applicationContext)
        }.fold(
            onSuccess = { Result.success() },
            onFailure = { error ->
                when ((error as? ApiException)?.statusCode) {
                    401, 403 -> Result.success()
                    else -> Result.retry()
                }
            },
        )
    }
}
