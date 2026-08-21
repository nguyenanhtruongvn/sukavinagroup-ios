package net.sukavinagroup.user

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import net.sukavinagroup.user.data.ApiClient
import net.sukavinagroup.user.data.ApiException
import net.sukavinagroup.user.data.MessageResponse
import net.sukavinagroup.user.data.PushTokenBody
import java.util.concurrent.TimeUnit

/**
 * Persists the current FCM registration with the API as soon as network access is
 * available. WorkManager retries transient failures even after the app process is
 * killed, so a token refresh cannot silently leave this device without pushes.
 */
object PushTokenSync {
    private const val UNIQUE_WORK_NAME = "sukavina-push-token-sync"

    fun enqueue(context: Context) {
        val request = OneTimeWorkRequestBuilder<PushTokenSyncWorker>()
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            UNIQUE_WORK_NAME,
            ExistingWorkPolicy.REPLACE,
            request,
        )
    }
}

class PushTokenSyncWorker(
    appContext: Context,
    workerParams: WorkerParameters,
) : CoroutineWorker(appContext, workerParams) {
    override suspend fun doWork(): Result {
        val accessToken = SecureSessionStore(applicationContext).getString("token")
            ?: return Result.success()
        val fcmToken = applicationContext.getSharedPreferences(
            SukavinaFirebaseMessagingService.PUSH_PREFERENCES,
            Context.MODE_PRIVATE,
        ).getString(SukavinaFirebaseMessagingService.PUSH_TOKEN_KEY, null)
            ?: return Result.success()

        if (!PushTokenSyncPolicy.isValidToken(fcmToken)) return Result.failure()

        return runCatching {
            ApiClient().post<MessageResponse, PushTokenBody>(
                "auth/push-token",
                PushTokenBody(token = fcmToken),
                accessToken,
            )
        }.fold(
            onSuccess = { Result.success() },
            onFailure = { error ->
                if (PushTokenSyncPolicy.shouldRetry((error as? ApiException)?.statusCode)) {
                    Result.retry()
                } else {
                    Result.failure()
                }
            },
        )
    }
}

internal object PushTokenSyncPolicy {
    fun isValidToken(token: String?): Boolean = token?.length in 1..4096

    /** Retry transport, throttling and server failures; do not loop invalid/expired sessions. */
    fun shouldRetry(statusCode: Int?): Boolean = statusCode == null || statusCode == 408 ||
        statusCode == 429 || statusCode >= 500
}
