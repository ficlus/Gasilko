package si.gasilko.app.feature.inspections.presentation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import si.gasilko.app.R
import si.gasilko.app.feature.hydrants.domain.RegistryError
import si.gasilko.app.feature.hydrants.presentation.errorLabel
import si.gasilko.app.feature.inspections.domain.*

/** Unconfirmed form state lives in the existing account-scoped registry ViewModel. */
data class QuickInspectionDraft(
    val id: String, val organization: String, val hydrantId: String, val startedAt: Long,
    val result: InspectionResult? = null, val notes: String = "",
    val completion: InspectionCompletion? = null,
)

fun inspectionResultLabel(result: InspectionResult): Int = when(result) {
    InspectionResult.PASS -> R.string.inspection_pass
    InspectionResult.PASS_WITH_ISSUES -> R.string.inspection_issues
    InspectionResult.FAIL -> R.string.inspection_fail
    InspectionResult.NOT_INSPECTED -> R.string.inspection_not_inspected
}
fun inspectionModeLabel(mode: InspectionMode): Int = when(mode) {
    InspectionMode.QUICK -> R.string.inspection_quick
    InspectionMode.GUIDED -> R.string.inspection_guided
    InspectionMode.CLASSIC -> R.string.inspection_classic
}

@Composable
fun QuickInspectionScreen(draft: QuickInspectionDraft, hydrantLabel: String, busy: Boolean,
    error: RegistryError?, change: (InspectionResult?, String) -> Unit, complete: () -> Unit, cancel: () -> Unit) {
    val editable=!busy && draft.completion==null
    BackHandler { if(!busy)cancel() }
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement=Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.inspection_quick),style=MaterialTheme.typography.headlineMedium)
            Text(hydrantLabel,style=MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.inspection_choose_result))
            Column(Modifier.selectableGroup(),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                InspectionResult.entries.forEach { result ->
                    Surface(shape=MaterialTheme.shapes.medium,
                        color=if(draft.result==result)MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceVariant) {
                        Row(Modifier.fillMaxWidth().heightIn(min=64.dp)
                            .selectable(selected=draft.result==result,enabled=editable,role=Role.RadioButton,
                                onClick={change(result,draft.notes)}).padding(12.dp),verticalAlignment=Alignment.CenterVertically) {
                            RadioButton(selected=draft.result==result,onClick=null,enabled=editable)
                            Spacer(Modifier.width(12.dp))
                            Text(stringResource(inspectionResultLabel(result)),style=MaterialTheme.typography.titleMedium)
                        }
                    }
                }
            }
            OutlinedTextField(value=draft.notes,onValueChange={change(draft.result,it)},enabled=editable,
                label={Text(stringResource(R.string.inspection_notes))},minLines=3,modifier=Modifier.fillMaxWidth())
            Text(stringResource(R.string.inspection_complete_notice))
            if(busy) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text(stringResource(R.string.h_saving)) }
            error?.let {
                Text(stringResource(R.string.inspection_save_failed),color=MaterialTheme.colorScheme.error)
                Text(stringResource(errorLabel(it)),color=MaterialTheme.colorScheme.error)
                if(draft.completion!=null)Text(stringResource(R.string.inspection_retry_notice))
            }
            Button(onClick=complete,enabled=!busy && draft.result!=null,modifier=Modifier.fillMaxWidth().heightIn(min=56.dp)) {
                Text(stringResource(if(draft.completion==null)R.string.inspection_complete else R.string.inspection_retry))
            }
            OutlinedButton(onClick=cancel,enabled=!busy,modifier=Modifier.fillMaxWidth().heightIn(min=48.dp)) {
                Text(stringResource(R.string.h_cancel))
            }
        }
    }
}
