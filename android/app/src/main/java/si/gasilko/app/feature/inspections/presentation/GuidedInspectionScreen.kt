package si.gasilko.app.feature.inspections.presentation

import android.content.res.Resources
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import si.gasilko.app.R
import si.gasilko.app.feature.hydrants.domain.RegistryError
import si.gasilko.app.feature.hydrants.presentation.errorLabel
import si.gasilko.app.feature.inspections.domain.InspectionResult

enum class GuidedCheck(val label: Int, val question: Int) {
    ACCESSIBILITY(R.string.guided_accessibility,R.string.guided_accessibility_question),
    VISIBLE_DAMAGE(R.string.guided_damage,R.string.guided_damage_question),
    IDENTIFICATION(R.string.guided_identification,R.string.guided_identification_question),
    OPERATION(R.string.guided_operation,R.string.guided_operation_question),
}
enum class GuidedAnswer(val label: Int) {
    YES(R.string.guided_yes), NO(R.string.guided_no), NOT_CHECKED(R.string.guided_not_checked),
}

/** Fixed order and a single formatter for the MVP notes bridge. Enum keys remain
 * the answer state; the rendered summary is frozen with the event on confirmation. */
object GuidedNotesFormatter {
    fun format(resources: Resources, answers: Map<GuidedCheck, GuidedAnswer>, notes: String): String {
        val summary=GuidedCheck.entries.joinToString("\n") { check ->
            "${resources.getString(check.label)}: ${resources.getString(answers.getValue(check).label)}"
        }
        return summary + if(notes.isBlank()) "" else "\n\n$notes"
    }
}

@Composable
private fun GuidedOption(label: String, selected: Boolean, enabled: Boolean, choose: () -> Unit) {
    Surface(shape=MaterialTheme.shapes.medium,
        color=if(selected)MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceVariant) {
        Row(Modifier.fillMaxWidth().heightIn(min=64.dp).selectable(selected=selected,enabled=enabled,
            role=Role.RadioButton,onClick=choose).padding(12.dp),verticalAlignment=Alignment.CenterVertically) {
            RadioButton(selected=selected,onClick=null,enabled=enabled)
            Spacer(Modifier.width(12.dp))
            Text(label,style=MaterialTheme.typography.titleMedium)
        }
    }
}

@Composable
fun GuidedInspectionScreen(draft: InspectionDraft, hydrantLabel: String, busy: Boolean, error: RegistryError?,
    answer: (GuidedCheck,GuidedAnswer)->Unit, change: (InspectionResult?,String)->Unit,
    move: (Boolean)->Unit, complete: (String)->Unit, cancel: ()->Unit) {
    val editable=!busy && draft.completion==null
    val resources=LocalContext.current.resources
    val review=draft.step==5
    BackHandler { if(!busy) { if(draft.step==0 || draft.completion!=null)cancel() else move(false) } }
    Scaffold { padding ->
        key(draft.id,draft.step) {
            Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement=Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.inspection_guided),style=MaterialTheme.typography.headlineMedium)
                Text(hydrantLabel,style=MaterialTheme.typography.titleMedium)
                Text(if(review)stringResource(R.string.guided_review) else stringResource(R.string.guided_progress,draft.step+1,5))
                if(draft.step<4) {
                    val check=GuidedCheck.entries[draft.step]
                    Text(stringResource(check.question),style=MaterialTheme.typography.titleLarge)
                    val choices=if(check==GuidedCheck.VISIBLE_DAMAGE)listOf(GuidedAnswer.NO,GuidedAnswer.YES,GuidedAnswer.NOT_CHECKED)
                        else GuidedAnswer.entries.toList()
                    Column(Modifier.selectableGroup(),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                        choices.forEach { value -> GuidedOption(stringResource(value.label),draft.answers[check]==value,editable) { answer(check,value) } }
                    }
                } else if(!review) {
                    Text(stringResource(R.string.inspection_choose_result),style=MaterialTheme.typography.titleLarge)
                    Text(stringResource(R.string.guided_result_notice))
                    Column(Modifier.selectableGroup(),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                        InspectionResult.entries.forEach { value -> GuidedOption(stringResource(inspectionResultLabel(value)),draft.result==value,editable) { change(value,draft.notes) } }
                    }
                } else {
                    GuidedCheck.entries.forEach { check ->
                        Text(stringResource(check.label),style=MaterialTheme.typography.titleMedium)
                        draft.answers[check]?.let { Text(stringResource(it.label)) }
                    }
                    draft.result?.let {
                        Text(stringResource(R.string.inspection_choose_result),style=MaterialTheme.typography.titleMedium)
                        Text(stringResource(inspectionResultLabel(it)))
                    }
                }
                if(draft.step>=4)OutlinedTextField(draft.notes,{change(draft.result,it)},enabled=editable,
                    label={Text(stringResource(R.string.inspection_notes))},minLines=3,modifier=Modifier.fillMaxWidth())
                if(busy) { LinearProgressIndicator(Modifier.fillMaxWidth());Text(stringResource(R.string.h_saving)) }
                error?.let {
                    Text(stringResource(R.string.inspection_save_failed),color=MaterialTheme.colorScheme.error)
                    Text(stringResource(errorLabel(it)),color=MaterialTheme.colorScheme.error)
                    if(draft.completion!=null)Text(stringResource(R.string.inspection_retry_notice))
                }
                if(review) {
                    Text(stringResource(R.string.inspection_complete_notice))
                    Button(onClick={complete(draft.completion?.notes ?: GuidedNotesFormatter.format(resources,draft.answers,draft.notes))},
                        enabled=!busy && draft.result!=null && GuidedCheck.entries.all { it in draft.answers },
                        modifier=Modifier.fillMaxWidth().heightIn(min=56.dp)) {
                        Text(stringResource(if(draft.completion==null)R.string.inspection_complete else R.string.inspection_retry))
                    }
                } else {
                    val answered=if(draft.step<4)GuidedCheck.entries[draft.step] in draft.answers else draft.result!=null
                    Button(onClick={move(true)},enabled=editable && answered,modifier=Modifier.fillMaxWidth().heightIn(min=56.dp)) {
                        Text(stringResource(if(draft.step==4)R.string.guided_review else R.string.guided_next))
                    }
                }
                if(draft.step>0)OutlinedButton(onClick={move(false)},enabled=editable,modifier=Modifier.fillMaxWidth().heightIn(min=48.dp)) {
                    Text(stringResource(R.string.h_back))
                }
                TextButton(onClick=cancel,enabled=!busy,modifier=Modifier.fillMaxWidth().heightIn(min=48.dp)) { Text(stringResource(R.string.h_cancel)) }
            }
        }
    }
}
