package net.sukavinagroup.user.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.graphics.Color

val SukavinaRed = Color(0xFFE92A31)
val SukavinaInk = Color(0xFF111115)
val SukavinaCard = Color(0xFF202027)
val SukavinaMuted = Color(0xFFAAA7AD)

private val darkColors = darkColorScheme(
    primary = SukavinaRed, onPrimary = Color.White, background = SukavinaInk,
    onBackground = Color(0xFFF7F2EC), surface = SukavinaCard,
    onSurface = Color(0xFFF7F2EC), secondary = Color(0xFF69C58B),
)

private val lightColors = lightColorScheme(
    primary = Color(0xFFC6252A), onPrimary = Color.White,
    background = Color(0xFFF6F3EE), onBackground = Color(0xFF211D1C),
    surface = Color.White, onSurface = Color(0xFF211D1C),
    surfaceVariant = Color(0xFFEDE8E3), onSurfaceVariant = Color(0xFF615B58),
    primaryContainer = Color(0xFFFFDAD7), onPrimaryContainer = Color(0xFF410006),
    secondary = Color(0xFF287A4B), outline = Color(0xFF857370),
)

@Composable fun SukavinaTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColors else lightColors, content = content)
}
