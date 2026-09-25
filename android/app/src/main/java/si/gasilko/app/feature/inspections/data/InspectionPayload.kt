package si.gasilko.app.feature.inspections.data

import kotlinx.serialization.json.*
import si.gasilko.app.feature.inspections.domain.*
import java.time.Instant

internal const val CREATE_INSPECTION = "CREATE_INSPECTION"
internal fun InspectionCompletion.payload() = buildJsonObject {
    put("id",id);put("mode",mode.name);put("result",result.name)
    put("started_at",Instant.ofEpochMilli(startedAt).toString())
    put("completed_at",Instant.ofEpochMilli(completedAt).toString())
    put("notes",notes);put("pressure_bar",pressureBar);put("flow_l_min",flowLMin)
}
internal fun JsonObject.inspectionCompletion() = InspectionCompletion(
    InspectionMode.valueOf(getValue("mode").jsonPrimitive.content),
    InspectionResult.valueOf(getValue("result").jsonPrimitive.content),
    Instant.parse(getValue("started_at").jsonPrimitive.content).toEpochMilli(),
    Instant.parse(getValue("completed_at").jsonPrimitive.content).toEpochMilli(),
    this["notes"]?.jsonPrimitive?.contentOrNull, this["pressure_bar"]?.jsonPrimitive?.doubleOrNull,
    this["flow_l_min"]?.jsonPrimitive?.doubleOrNull, getValue("id").jsonPrimitive.content,
)
internal fun decodeInspection(value: JsonElement): Inspection {
    val row=value.jsonObject
    val input=row.inspectionCompletion()
    return Inspection(input.id,row.getValue("hydrant_id").jsonPrimitive.content,
        row.getValue("organization_id").jsonPrimitive.content,row.getValue("inspector_id").jsonPrimitive.content,
        input.mode,input.result,input.startedAt,input.completedAt,input.notes,input.pressureBar,input.flowLMin,
        Instant.parse(row.getValue("created_at").jsonPrimitive.content).toEpochMilli(),
        row.getValue("hydrant_version_before").jsonPrimitive.long,row.getValue("hydrant_version_after").jsonPrimitive.long)
}
