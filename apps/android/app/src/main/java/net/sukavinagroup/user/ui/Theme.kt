package net.sukavinagroup.user.ui

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

val SukavinaRed = Color(0xFFE92A31)
val SukavinaInk = Color(0xFF111115)
val SukavinaCard = Color(0xFF202027)
val SukavinaMuted = Color(0xFFAAA7AD)
val LocalSukavinaExpressive = staticCompositionLocalOf { false }

private val darkColors = darkColorScheme(
    primary = SukavinaRed, onPrimary = Color.White, background = SukavinaInk,
    onBackground = Color(0xFFF7F2EC), surface = SukavinaCard,
    onSurface = Color(0xFFF7F2EC), secondary = Color(0xFF69C58B),
)

private val lightColors = lightColorScheme(
    primary = Color(0xFFC6252A), onPrimary = Color.White,
    background = Color(0xFFE7E9ED), onBackground = Color(0xFF1F2733),
    surface = Color.White, onSurface = Color(0xFF1F2733),
    surfaceVariant = Color(0xFFE7E9ED), onSurfaceVariant = Color(0xFF5E6672),
    primaryContainer = Color(0xFFFFDAD7), onPrimaryContainer = Color(0xFF410006),
    secondary = Color(0xFF287A4B), outline = Color(0xFF8E949E),
)

@Composable
fun SukavinaTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val useExpressive = remember(context) {
        val activityManager =
            context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA &&
            activityManager?.isLowRamDevice != true
    }
    val colors = if (isSystemInDarkTheme()) darkColors else lightColors

    if (useExpressive) {
        MaterialExpressiveTheme(
            colorScheme = colors,
            motionScheme = MotionScheme.expressive(),
        ) {
            CompositionLocalProvider(LocalSukavinaExpressive provides true, content = content)
        }
    } else {
        MaterialTheme(colorScheme = colors) {
            CompositionLocalProvider(LocalSukavinaExpressive provides false, content = content)
        }
    }
}
