@file:Suppress("DEPRECATION")

package net.sukavinagroup.user

import android.content.Context
import androidx.core.content.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/** One-release bridge from the deprecated AndroidX encrypted preferences store. */
object LegacySecureSessionMigration {
    private const val LEGACY_PREFERENCES = "sukavina-secure-session"
    private const val MIGRATION_COMPLETE = "secure_session_migrated_v2"
    private val secretKeys = setOf(
        "token",
        "refresh_token",
        "widget_token",
        "biometric_refresh_token",
    )

    fun migrate(context: Context, metadata: android.content.SharedPreferences, secure: SecureSessionStore) {
        if (metadata.getBoolean(MIGRATION_COMPLETE, false)) return

        runCatching {
            val legacy = EncryptedSharedPreferences.create(
                context,
                LEGACY_PREFERENCES,
                MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )

            secretKeys.forEach { key ->
                legacy.getString(key, null)?.takeIf(String::isNotBlank)?.let {
                    check(secure.putString(key, it)) { "Could not migrate secure session value" }
                }
            }
            metadata.edit {
                legacy.getString("last_login", null)?.let { putString("last_login", it) }
                putBoolean("biometric_enabled", legacy.getBoolean("biometric_enabled", false))
                legacy.getStringSet("known_articles", null)?.let { putStringSet("known_articles", it) }
                legacy.getStringSet("hidden_notification_articles", null)?.let {
                    putStringSet("hidden_notification_articles", it)
                }
                legacy.all.forEach { (key, value) ->
                    if (key.startsWith("known_attendance_record_ids_") && value is Set<*>) {
                        putStringSet(key, value.filterIsInstance<String>().toSet())
                    }
                }
                putBoolean(MIGRATION_COMPLETE, true)
            }
            context.deleteSharedPreferences(LEGACY_PREFERENCES)
        }.onFailure {
            // Keep the legacy file and retry on the next launch; never discard a session on migration failure.
        }
    }
}
