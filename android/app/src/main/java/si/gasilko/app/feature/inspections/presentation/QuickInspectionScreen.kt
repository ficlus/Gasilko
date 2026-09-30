package si.gasilko.app.feature.inspections.presentation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import si.gasilko.app.R
import si.gasilko.app.core.ui.*
import si.gasilko.app.feature.hydrants.domain.RegistryError
import si.gasilko.app.feature.hydrants.presentation.errorLabel
import si.gasilko.app.feature.inspections.domain.*

/** Unconfirmed form state lives in the existing account-scoped registry ViewModel. */
data class InspectionDraft(
    val id: String, val organization: String, val hydrantId: String, val startedAt: Long,
    val result: InspectionResult? = null, val notes: String = "",
    val completion: InspectionCompletion? = null,
    val mode: InspectionMode = InspectionMode.QUICK,
    val step: Int = 0, val answers: Map<GuidedCheck, GuidedAnswer> = emptyMap(),
    val pressure: String = "", val flow: String = "",
    val photos: List<si.gasilko.app.feature.photos.domain.LocalPhotoInput> = emptyList(),
    val planContext: si.gasilko.app.feature.plans.PlanStopContext? = null,
)

fun inspectionResultLabel(result: InspectionResult): Int = when(result) {
    InspectionResult.PASS -> R.string.inspection_pass
    InspectionResult.PASS_WITH_ISSUES -> R.string.inspection_issues
    InspectionResult.FAIL -> R.string.inspection_fail
    InspectionResult.NOT_INSPECTED -> R.string.inspection_not_inspected
}
internal fun inspectionTone(result: InspectionResult)=when(result) {
    InspectionResult.PASS->FieldTone.SUCCESS
    InspectionResult.PASS_WITH_ISSUES->FieldTone.WARNING
    InspectionResult.FAIL->FieldTone.DANGER
    InspectionResult.NOT_INSPECTED->FieldTone.NEUTRAL
}
fun inspectionModeLabel(mode: InspectionMode): Int = when(mode) {
    InspectionMode.QUICK -> R.string.inspection_quick
    InspectionMode.GUIDED -> R.string.inspection_guided
    InspectionMode.CLASSIC -> R.string.inspection_classic
}

@Composable
fun QuickInspectionScreen(draft: InspectionDraft, hydrantLabel: String, busy: Boolean,
    error: RegistryError?, change: (InspectionResult?, String) -> Unit, complete: () -> Unit, cancel: () -> Unit,
    photos: @Composable ()->Unit = {}, identification: @Composable ()->Unit = {}) {
    val editable=!busy && draft.completion==null
    BackHandler { if(!busy)cancel() }
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement=Arrangement.spacedBy(12.dp)) {
            ScreenHeading(stringResource(R.string.inspection_quick),hydrantLabel)
            identification()
            SectionHeading(stringResource(R.string.inspection_choose_result))
            Column(Modifier.selectableGroup(),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                InspectionResult.entries.forEach { result ->
                    InspectionOption(stringResource(inspectionResultLabel(result)),draft.result==result,editable,inspectionTone(result)) {
                        change(result,draft.notes)
                    }
                }
            }
            OutlinedTextField(value=draft.notes,onValueChange={change(draft.result,it)},enabled=editable,
                label={Text(stringResource(R.string.inspection_notes))},minLines=3,modifier=Modifier.fillMaxWidth())
            photos()
            FieldBanner(stringResource(R.string.inspection_complete_notice))
            if(busy) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text(stringResource(R.string.h_saving)) }
            error?.let {
                FieldBanner(stringResource(R.string.inspection_save_failed)+"\n"+stringResource(errorLabel(it)),FieldTone.DANGER)
                if(draft.completion!=null)Text(stringResource(R.string.inspection_retry_notice))
            }
            PrimaryAction(onClick=complete,enabled=!busy && draft.result!=null,modifier=Modifier.fillMaxWidth().heightIn(min=56.dp)) {
                Text(stringResource(if(draft.completion==null)R.string.inspection_complete else R.string.inspection_retry))
            }
            SecondaryAction(onClick=cancel,enabled=!busy,modifier=Modifier.fillMaxWidth().heightIn(min=48.dp)) {
                Text(stringResource(R.string.h_cancel))
            }
        }
    }
}
