package net.sukavinagroup.user.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources
import java.io.IOException
import java.util.concurrent.TimeUnit

class ApiClient {
    companion object { const val BASE_URL = "https://sukavinagroup.net/api/" }

    val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS).build()

    suspend inline fun <reified T> get(path: String, token: String? = null): T =
        execute(Request.Builder().url(BASE_URL + path).apply {
            header("Accept", "application/json")
            token?.let { header("Authorization", "Bearer $it") }
        }.build())

    suspend inline fun <reified T, reified B> post(path: String, body: B, token: String? = null): T {
        val payload = json.encodeToString(body).toRequestBody("application/json".toMediaType())
        return execute(Request.Builder().url(BASE_URL + path).post(payload).apply {
            header("Accept", "application/json")
            token?.let { header("Authorization", "Bearer $it") }
        }.build())
    }

    suspend inline fun <reified T, reified B> patch(path: String, body: B? = null, token: String): T {
        val payload = body?.let { json.encodeToString(it).toRequestBody("application/json".toMediaType()) }
            ?: ByteArray(0).toRequestBody("application/json".toMediaType())
        return execute(Request.Builder().url(BASE_URL + path).patch(payload)
            .header("Authorization", "Bearer $token").header("Accept", "application/json").build())
    }

    suspend inline fun <reified T> delete(path: String, token: String): T =
        execute(Request.Builder().url(BASE_URL + path).delete()
            .header("Authorization", "Bearer $token").header("Accept", "application/json").build())

    suspend inline fun <reified T> delete(path: String, body: DeleteAccountBody, token: String): T {
        val payload = json.encodeToString(body).toRequestBody("application/json".toMediaType())
        return execute(Request.Builder().url(BASE_URL + path).delete(payload)
            .header("Authorization", "Bearer $token").header("Accept", "application/json").build())
    }

    suspend inline fun <reified T> execute(request: Request): T = withContext(Dispatchers.IO) {
        try {
            http.newCall(request).execute().use { response ->
                val text = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    val message = runCatching { json.decodeFromString<ApiError>(text).message }.getOrNull()
                    throw ApiException(message ?: "Yêu cầu không thành công (${response.code})", response.code)
                }
                json.decodeFromString<T>(text)
            }
        } catch (error: ApiException) {
            throw error
        } catch (_: IOException) {
            throw ApiException("Không thể kết nối đến máy chủ. Hãy kiểm tra Wi-Fi hoặc dữ liệu di động rồi thử lại.")
        }
    }

    fun events(listener: EventSourceListener): EventSource {
        val request = Request.Builder().url(BASE_URL + "public/news/events")
            .header("Accept", "text/event-stream").build()
        return EventSources.createFactory(http).newEventSource(request, listener)
    }
}

class ApiException(message: String, val statusCode: Int? = null) : Exception(message)
