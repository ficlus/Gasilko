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
import si.gasilko.app.core.ui.*
import si.gasilko.app.feature.hydrants.domain.RegistryError
import si.gasilko.app.feature.hydrants.presentation.errorLabel
import si.gasilko.app.feature.inspections.domain.InspectionResult

@Composable
fun ClassicInspectionScreen(draft: InspectionDraft, hydrantLabel: String, busy: Boolean, error: RegistryError?,
    answer: (GuidedCheck,GuidedAnswer)->Unit, change: (InspectionResult?,String)->Unit,
    complete: (String)->Unit, cancel: ()->Unit, measurements: (String,String)->Unit,
    photos: @Composable ()->Unit = {}) {
    val editable=!busy && draft.completion==null
    val resources=LocalContext.current.resources
    val answered=GuidedCheck.entries.all { it in draft.answers } && draft.result!=null
    BackHandler { if(!busy)cancel() }
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement=Arrangement.spacedBy(12.dp)) {
            ScreenHeading(stringResource(R.string.inspection_classic),hydrantLabel)
            GuidedCheck.entries.forEach { check ->
                OperationalCard { InspectionCheckOptions(check,draft.answers[check],editable) { answer(check,it) } }
            }
            InspectionMeasurementInputs(draft,editable,measurements)
            photos()
            SectionHeading(stringResource(R.string.inspection_choose_result))
            Text(stringResource(R.string.guided_result_notice))
            Column(Modifier.selectableGroup(),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                InspectionResult.entries.forEach { result ->
                    InspectionOption(stringResource(inspectionResultLabel(result)),draft.result==result,editable,inspectionTone(result)) {
                        change(result,draft.notes)
                    }
                }
            }
            OutlinedTextField(draft.notes,{change(draft.result,it)},enabled=editable,
                label={Text(stringResource(R.string.inspection_notes))},minLines=3,modifier=Modifier.fillMaxWidth())
            FieldBanner(stringResource(R.string.inspection_complete_notice))
            if(busy) { LinearProgressIndicator(Modifier.fillMaxWidth());Text(stringResource(R.string.h_saving)) }
            error?.let {
                FieldBanner(stringResource(R.string.inspection_save_failed)+"\n"+stringResource(errorLabel(it)),FieldTone.DANGER)
                if(draft.completion!=null)Text(stringResource(R.string.inspection_retry_notice))
            }
            if(!answered)FieldBanner(stringResource(R.string.inspection_checks_required),FieldTone.WARNING)
            PrimaryAction(onClick={complete(draft.completion?.notes ?: InspectionNotesFormatter.format(resources,draft.answers,draft.notes))},
                enabled=!busy && answered && draft.measurementsValid(),modifier=Modifier.fillMaxWidth().heightIn(min=56.dp)) {
                Text(stringResource(if(draft.completion==null)R.string.inspection_complete else R.string.inspection_retry))
            }
            SecondaryAction(onClick=cancel,enabled=!busy,modifier=Modifier.fillMaxWidth().heightIn(min=48.dp)) {
                Text(stringResource(R.string.h_cancel))
            }
        }
    }
}
