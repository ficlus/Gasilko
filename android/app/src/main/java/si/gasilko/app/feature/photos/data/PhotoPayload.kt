package si.gasilko.app.feature.photos.data

import kotlinx.serialization.json.*
import si.gasilko.app.feature.photos.domain.*
import java.time.Instant

internal fun Photo.payload() = buildJsonObject {
    put("id",id);put("organization_id",organization);put("hydrant_id",hydrantId);put("inspection_id",inspectionId)
    put("category",category.name);put("storage_path",storagePath);put("mime_type",mimeType);put("byte_size",byteSize)
    put("sha256",sha256);put("captured_at",Instant.ofEpochMilli(capturedAt).toString());put("created_by",createdBy)
    put("created_at",Instant.ofEpochMilli(createdAt).toString());put("active",active)
    put("uploaded_at",uploadedAt?.let { Instant.ofEpochMilli(it).toString() })
}
internal fun decodePhoto(value: JsonElement): Photo {
    val row=if(value is JsonArray)value.single().jsonObject else value.jsonObject
    fun text(key: String)=row[key]?.jsonPrimitive?.contentOrNull
    fun time(key: String)=text(key)?.let { Instant.parse(it).toEpochMilli() }
    return Photo(text("id")!!,text("organization_id")!!,text("hydrant_id")!!,text("inspection_id"),
        PhotoCategory.valueOf(text("category")!!),text("storage_path")!!,text("mime_type")!!,text("byte_size")!!.toLong(),
        text("sha256")!!,time("captured_at")!!,text("created_by")!!,time("created_at")!!,text("active").toBoolean(),time("uploaded_at"))
        .also { it.validate() }
}
