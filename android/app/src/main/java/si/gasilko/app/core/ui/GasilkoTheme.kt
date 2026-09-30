package si.gasilko.app.core.ui

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Fixed light palette: device wallpaper and system dark mode must not change field semantics.
private val FieldColors=lightColorScheme(
    primary=Color(0xFFB32624),onPrimary=Color.White,
    primaryContainer=Color(0xFFFFDAD5),onPrimaryContainer=Color(0xFF690F0D),
    secondary=Color(0xFF414951),onSecondary=Color.White,
    secondaryContainer=Color(0xFFE2E6EA),onSecondaryContainer=Color(0xFF242B31),
    tertiary=Color(0xFF195D91),onTertiary=Color.White,
    tertiaryContainer=Color(0xFFDCEEFF),onTertiaryContainer=Color(0xFF123D60),
    error=Color(0xFFAD201D),onError=Color.White,
    errorContainer=Color(0xFFFFDAD6),onErrorContainer=Color(0xFF680B09),
    background=Color(0xFFF5F6F7),onBackground=Color(0xFF20262C),
    surface=Color.White,onSurface=Color(0xFF20262C),
    surfaceVariant=Color(0xFFE9ECEF),onSurfaceVariant=Color(0xFF4A535D),
    surfaceContainerLowest=Color.White,surfaceContainerLow=Color(0xFFF8F9FA),
    surfaceContainer=Color(0xFFF0F2F4),surfaceContainerHigh=Color(0xFFE9ECEF),surfaceContainerHighest=Color(0xFFE1E5E9),
    surfaceBright=Color.White,surfaceDim=Color(0xFFDADFE4),
    outline=Color(0xFF737D87),outlineVariant=Color(0xFFC6CDD4),
    inverseSurface=Color(0xFF293138),inverseOnSurface=Color(0xFFF3F5F6),inversePrimary=Color(0xFFFFB4A9),
)
@Immutable data class OperationalColors(
    val success: Color=Color(0xFF1B6539),val successContainer: Color=Color(0xFFE0F1E5),
    val onSuccessContainer: Color=Color(0xFF164D2C),
    val warning: Color=Color(0xFF795500),val warningContainer: Color=Color(0xFFFFEDBD),
    val onWarningContainer: Color=Color(0xFF5A4000),
)
private val LocalOperationalColors=staticCompositionLocalOf { OperationalColors() }
val MaterialTheme.operations: OperationalColors @Composable get()=LocalOperationalColors.current

private fun fieldType(size: Int,line: Int,weight: FontWeight=FontWeight.Normal)=TextStyle(
    fontFamily=FontFamily.SansSerif,fontSize=size.sp,lineHeight=line.sp,fontWeight=weight)
private val FieldTypography=Typography(
    headlineLarge=fieldType(30,38,FontWeight.Bold),headlineMedium=fieldType(26,34,FontWeight.Bold),
    headlineSmall=fieldType(23,30,FontWeight.Bold),titleLarge=fieldType(21,28,FontWeight.SemiBold),
    titleMedium=fieldType(17,24,FontWeight.SemiBold),titleSmall=fieldType(15,22,FontWeight.SemiBold),
    bodyLarge=fieldType(16,24),bodyMedium=fieldType(15,22),bodySmall=fieldType(13,20),
    labelLarge=fieldType(15,20,FontWeight.SemiBold),labelMedium=fieldType(13,18,FontWeight.SemiBold),
    labelSmall=fieldType(12,16,FontWeight.SemiBold),
)
@Composable fun GasilkoTheme(content: @Composable ()->Unit) {
    CompositionLocalProvider(LocalOperationalColors provides OperationalColors()) {
        MaterialTheme(colorScheme=FieldColors,typography=FieldTypography,
            shapes=Shapes(extraSmall=RoundedCornerShape(4.dp),small=RoundedCornerShape(8.dp),
                medium=RoundedCornerShape(12.dp),large=RoundedCornerShape(16.dp),extraLarge=RoundedCornerShape(20.dp)),content=content)
    }
}
