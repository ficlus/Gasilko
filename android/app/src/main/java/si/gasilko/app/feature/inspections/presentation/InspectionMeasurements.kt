package si.gasilko.app.feature.inspections.presentation

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import si.gasilko.app.R
import si.gasilko.app.feature.inspections.domain.parseMeasurement
import java.text.NumberFormat

fun InspectionDraft.measurementsValid() = parseMeasurement(pressure,"999.99").valid && parseMeasurement(flow,"999999.99").valid

@Composable
fun InspectionMeasurementInputs(draft: InspectionDraft, enabled: Boolean, change: (String,String)->Unit) {
    Text(stringResource(R.string.inspection_measurements),style=MaterialTheme.typography.titleLarge)
    val pressure=parseMeasurement(draft.pressure,"999.99")
    val flow=parseMeasurement(draft.flow,"999999.99")
    OutlinedTextField(draft.pressure,{change(it,draft.flow)},enabled=enabled,singleLine=true,
        isError=!pressure.valid,label={Text(stringResource(R.string.inspection_pressure))},
        keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Decimal),modifier=Modifier.fillMaxWidth())
    if(!pressure.valid)Text(stringResource(R.string.inspection_pressure_invalid),color=MaterialTheme.colorScheme.error)
    OutlinedTextField(draft.flow,{change(draft.pressure,it)},enabled=enabled,singleLine=true,
        isError=!flow.valid,label={Text(stringResource(R.string.inspection_flow))},
        keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Decimal),modifier=Modifier.fillMaxWidth())
    if(!flow.valid)Text(stringResource(R.string.inspection_flow_invalid),color=MaterialTheme.colorScheme.error)
}

@Composable
fun InspectionMeasurementValues(pressure: Double?, flow: Double?) {
    val format=NumberFormat.getNumberInstance().apply { maximumFractionDigits=2 }
    pressure?.let { Text(stringResource(R.string.inspection_pressure_value,format.format(it))) }
    flow?.let { Text(stringResource(R.string.inspection_flow_value,format.format(it))) }
}
