package si.gasilko.app.feature.inspections.presentation

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import si.gasilko.app.R
import si.gasilko.app.feature.inspections.domain.*
import java.text.DateFormat
import java.util.Date

@Composable
fun InspectionDueDetails(due: InspectionDue) {
    val format=DateFormat.getDateTimeInstance(DateFormat.SHORT,DateFormat.SHORT)
    Text(stringResource(R.string.inspection_due_title),style=MaterialTheme.typography.titleMedium)
    Text(stringResource(R.string.inspection_due_local))
    Text(stringResource(R.string.inspection_last,due.last?.let { format.format(Date.from(it)) }
        ?: stringResource(R.string.inspection_never)))
    Text(due.intervalMonths?.let { stringResource(R.string.inspection_effective_interval,it) }
        ?: stringResource(R.string.inspection_interval_unknown))
    due.next?.let { Text(stringResource(R.string.inspection_next,format.format(Date.from(it)))) }
    due.state?.let { state -> Text(stringResource(when(state) {
        InspectionDueState.NEVER_INSPECTED -> R.string.inspection_never
        InspectionDueState.CURRENT -> R.string.inspection_current
        InspectionDueState.DUE_SOON -> R.string.inspection_due_soon
        InspectionDueState.OVERDUE -> R.string.inspection_overdue
    })) }
}
