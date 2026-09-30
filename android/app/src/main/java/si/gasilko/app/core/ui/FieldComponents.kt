package si.gasilko.app.core.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp

enum class FieldTone { NEUTRAL, SUCCESS, WARNING, DANGER, INFO }
@Composable fun FieldTone.container(): Color=when(this) {
    FieldTone.NEUTRAL->MaterialTheme.colorScheme.surfaceContainer
    FieldTone.SUCCESS->MaterialTheme.operations.successContainer
    FieldTone.WARNING->MaterialTheme.operations.warningContainer
    FieldTone.DANGER->MaterialTheme.colorScheme.errorContainer
    FieldTone.INFO->MaterialTheme.colorScheme.tertiaryContainer
}
@Composable fun FieldTone.foreground(): Color=when(this) {
    FieldTone.NEUTRAL->MaterialTheme.colorScheme.onSurfaceVariant
    FieldTone.SUCCESS->MaterialTheme.operations.onSuccessContainer
    FieldTone.WARNING->MaterialTheme.operations.onWarningContainer
    FieldTone.DANGER->MaterialTheme.colorScheme.onErrorContainer
    FieldTone.INFO->MaterialTheme.colorScheme.onTertiaryContainer
}

@Composable fun ScreenHeading(title: String,subtitle: String?=null) {
    Row(Modifier.fillMaxWidth().padding(vertical=8.dp),verticalAlignment=Alignment.CenterVertically) {
        Box(Modifier.width(4.dp).height(32.dp).background(MaterialTheme.colorScheme.primary,MaterialTheme.shapes.small))
        Column(Modifier.padding(start=12.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
            Text(title,style=MaterialTheme.typography.headlineSmall,modifier=Modifier.semantics { heading() })
            subtitle?.let { Text(it,style=MaterialTheme.typography.titleMedium,color=MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}
@Composable fun SectionHeading(title: String) {
    Text(title,style=MaterialTheme.typography.titleMedium,color=MaterialTheme.colorScheme.onSurface,
        modifier=Modifier.fillMaxWidth().padding(top=12.dp,bottom=4.dp).semantics { heading() })
}
@Composable fun StatusBadge(label: String,tone: FieldTone=FieldTone.NEUTRAL) {
    // Non-interactive; meaning is always written out, never conveyed by color alone.
    Surface(color=tone.container(),contentColor=tone.foreground(),shape=MaterialTheme.shapes.small) {
        Text(label,style=MaterialTheme.typography.labelMedium,modifier=Modifier.padding(horizontal=10.dp,vertical=6.dp))
    }
}
@Composable fun FieldBanner(text: String,tone: FieldTone=FieldTone.INFO,modifier: Modifier=Modifier) {
    Surface(modifier.fillMaxWidth(),color=tone.container(),contentColor=tone.foreground(),shape=MaterialTheme.shapes.medium) {
        Text(text,style=MaterialTheme.typography.bodyMedium,modifier=Modifier.padding(12.dp))
    }
}
@Composable fun OperationalCard(modifier: Modifier=Modifier,emphasized: Boolean=false,content: @Composable ColumnScope.()->Unit) {
    OutlinedCard(modifier.fillMaxWidth(),colors=CardDefaults.outlinedCardColors(containerColor=MaterialTheme.colorScheme.surface),
        border=BorderStroke(if(emphasized)2.dp else 1.dp,
            if(emphasized)MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant)) {
        Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp),content=content)
    }
}
@Composable fun PrimaryAction(onClick: ()->Unit,modifier: Modifier=Modifier,enabled: Boolean=true,content: @Composable RowScope.()->Unit) {
    Button(onClick=onClick,enabled=enabled,modifier=modifier.heightIn(min=56.dp),shape=MaterialTheme.shapes.medium,
        contentPadding=PaddingValues(horizontal=20.dp,vertical=14.dp),content=content)
}
@Composable fun SecondaryAction(onClick: ()->Unit,modifier: Modifier=Modifier,enabled: Boolean=true,tone: FieldTone=FieldTone.NEUTRAL,content: @Composable RowScope.()->Unit) {
    OutlinedButton(onClick=onClick,enabled=enabled,modifier=modifier.heightIn(min=52.dp),shape=MaterialTheme.shapes.medium,
        colors=ButtonDefaults.outlinedButtonColors(contentColor=tone.foreground()),
        contentPadding=PaddingValues(horizontal=16.dp,vertical=12.dp),content=content)
}
@Composable fun Metric(value: String,label: String,tone: FieldTone,modifier: Modifier=Modifier) {
    Column(modifier,verticalArrangement=Arrangement.spacedBy(4.dp)) {
        Text(value,style=MaterialTheme.typography.headlineSmall,color=tone.foreground())
        Text(label,style=MaterialTheme.typography.labelMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Compact labelled actions for map panels and secondary toolbars. */
@Composable fun CompactAction(onClick: ()->Unit,modifier: Modifier=Modifier,enabled: Boolean=true,content: @Composable RowScope.()->Unit) {
    OutlinedButton(onClick=onClick,enabled=enabled,modifier=modifier.heightIn(min=48.dp),shape=MaterialTheme.shapes.medium,
        contentPadding=PaddingValues(horizontal=12.dp,vertical=8.dp),content=content)
}

/** Icons are decorative: the visible label remains the accessible action name. */
@Composable fun ActionLabel(text: String,icon: Int) {
    Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)) {
        Icon(painterResource(icon),contentDescription=null,modifier=Modifier.size(20.dp))
        Text(text,modifier=Modifier.weight(1f,fill=false))
    }
}

/** Keep toolbars reachable on short screens without consuming the list/grid viewport. */
@Composable fun ScrollableHeader(maxHeight: Dp,content: @Composable ColumnScope.()->Unit) {
    Column(Modifier.fillMaxWidth().heightIn(max=maxHeight).verticalScroll(rememberScrollState()),
        verticalArrangement=Arrangement.spacedBy(8.dp),content=content)
}
