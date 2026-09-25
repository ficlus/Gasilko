package si.gasilko.app.feature.inspections.presentation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import si.gasilko.app.R
import si.gasilko.app.feature.hydrants.domain.RegistryError
import si.gasilko.app.feature.hydrants.presentation.errorLabel
import si.gasilko.app.feature.inspections.domain.InspectionResult

@Composable
fun ClassicInspectionScreen(draft: InspectionDraft, hydrantLabel: String, busy: Boolean, error: RegistryError?,
    answer: (GuidedCheck,GuidedAnswer)->Unit, change: (InspectionResult?,String)->Unit,
    complete: (String)->Unit, cancel: ()->Unit) {
    val editable=!busy && draft.completion==null
    val resources=LocalContext.current.resources
    val answered=GuidedCheck.entries.all { it in draft.answers } && draft.result!=null
    BackHandler { if(!busy)cancel() }
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement=Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.inspection_classic),style=MaterialTheme.typography.headlineMedium)
            Text(hydrantLabel,style=MaterialTheme.typography.titleMedium)
            GuidedCheck.entries.forEach { check ->
                InspectionCheckOptions(check,draft.answers[check],editable) { answer(check,it) }
                HorizontalDivider()
            }
            Text(stringResource(R.string.inspection_choose_result),style=MaterialTheme.typography.titleLarge)
            Text(stringResource(R.string.guided_result_notice))
            Column(Modifier.selectableGroup(),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                InspectionResult.entries.forEach { result ->
                    InspectionOption(stringResource(inspectionResultLabel(result)),draft.result==result,editable) {
                        change(result,draft.notes)
                    }
                }
            }
            OutlinedTextField(draft.notes,{change(draft.result,it)},enabled=editable,
                label={Text(stringResource(R.string.inspection_notes))},minLines=3,modifier=Modifier.fillMaxWidth())
            Text(stringResource(R.string.inspection_complete_notice))
            if(busy) { LinearProgressIndicator(Modifier.fillMaxWidth());Text(stringResource(R.string.h_saving)) }
            error?.let {
                Text(stringResource(R.string.inspection_save_failed),color=MaterialTheme.colorScheme.error)
                Text(stringResource(errorLabel(it)),color=MaterialTheme.colorScheme.error)
                if(draft.completion!=null)Text(stringResource(R.string.inspection_retry_notice))
            }
            if(!answered)Text(stringResource(R.string.inspection_checks_required))
            Button(onClick={complete(draft.completion?.notes ?: InspectionNotesFormatter.format(resources,draft.answers,draft.notes))},
                enabled=!busy && answered,modifier=Modifier.fillMaxWidth().heightIn(min=56.dp)) {
                Text(stringResource(if(draft.completion==null)R.string.inspection_complete else R.string.inspection_retry))
            }
            OutlinedButton(onClick=cancel,enabled=!busy,modifier=Modifier.fillMaxWidth().heightIn(min=48.dp)) {
                Text(stringResource(R.string.h_cancel))
            }
        }
    }
}
