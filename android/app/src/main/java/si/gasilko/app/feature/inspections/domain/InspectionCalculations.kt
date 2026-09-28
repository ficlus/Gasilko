package si.gasilko.app.feature.inspections.domain

import java.math.BigDecimal
import java.time.Instant
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit

data class MeasurementValue(val value: Double? = null, val valid: Boolean = true)

/** No grouping, exponent notation or rounding. Comma and point are decimal separators. */
fun parseMeasurement(text: String, maximum: String): MeasurementValue {
    val normalized=text.trim().replace(',','.')
    if(normalized.isEmpty())return MeasurementValue()
    if(!Regex("[0-9]+(\\.[0-9]{1,2})?").matches(normalized))return MeasurementValue(valid=false)
    val value=normalized.toBigDecimalOrNull() ?: return MeasurementValue(valid=false)
    return if(value>=BigDecimal.ZERO && value<=BigDecimal(maximum))MeasurementValue(value.toDouble())
        else MeasurementValue(valid=false)
}

enum class InspectionDueState { NEVER_INSPECTED, CURRENT, DUE_SOON, OVERDUE }
data class InspectionDue(val intervalMonths: Int?, val last: Instant?, val next: Instant?, val state: InspectionDueState?)

/** Calendar months in UTC; completion mode/result do not exclude an event. */
fun inspectionDue(lastCompletedAt: Long?, overrideMonths: Int?, organizationMonths: Int?, now: Instant): InspectionDue {
    val interval=(overrideMonths ?: organizationMonths)?.takeIf { it>0 }
    val last=lastCompletedAt?.let(Instant::ofEpochMilli)
    val next=if(last!=null && interval!=null)last.atZone(ZoneOffset.UTC).plusMonths(interval.toLong()).toInstant() else null
    val state=when {
        last==null -> InspectionDueState.NEVER_INSPECTED
        next==null -> null // Old caches lack organization configuration; never invent an interval.
        now>next -> InspectionDueState.OVERDUE
        next<=now.plus(30,ChronoUnit.DAYS) -> InspectionDueState.DUE_SOON
        else -> InspectionDueState.CURRENT
    }
    return InspectionDue(interval,last,next,state)
}
