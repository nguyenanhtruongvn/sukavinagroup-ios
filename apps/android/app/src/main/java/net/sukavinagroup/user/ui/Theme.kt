package net.sukavinagroup.user.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val SukavinaRed = Color(0xFFE92A31)
val SukavinaInk = Color(0xFF111115)
val SukavinaCard = Color(0xFF202027)
val SukavinaMuted = Color(0xFFAAA7AD)

private val colors = darkColorScheme(
    primary = SukavinaRed, onPrimary = Color.White, background = SukavinaInk,
    onBackground = Color(0xFFF7F2EC), surface = SukavinaCard,
    onSurface = Color(0xFFF7F2EC), secondary = Color(0xFF69C58B),
)

@Composable fun SukavinaTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = colors, content = content)
}
