package si.gasilko.app.core.database

import androidx.room.*
import si.gasilko.app.feature.photos.domain.Photo

@Entity(tableName="photos",primaryKeys=["account","id"],
    indices=[Index(value=["account","organization","hydrantId","inspectionId"])])
data class PhotoEntity(val account: String, @Embedded val value: Photo, val localPath: String? = null,
    val syncIssue: String? = null)

@Dao
interface PhotoDao {
    @Insert suspend fun insert(photo: PhotoEntity)
    @Query("SELECT * FROM photos WHERE account=:account AND organization=:organization AND hydrantId=:hydrant AND (:inspection IS NULL OR inspectionId=:inspection) ORDER BY capturedAt DESC,id DESC")
    suspend fun list(account: String, organization: String, hydrant: String, inspection: String?): List<PhotoEntity>
    @Query("SELECT * FROM photos WHERE account=:account AND id=:id")
    suspend fun identity(account: String, id: String): PhotoEntity?
    @Query("UPDATE photos SET createdAt=:createdAt, uploadedAt=:uploadedAt, active=:active WHERE account=:account AND organization=:organization AND id=:id AND syncIssue IS NULL")
    suspend fun acknowledge(account: String, organization: String, id: String, createdAt: Long, uploadedAt: Long, active: Boolean): Int
    @Query("UPDATE photos SET syncIssue=:issue WHERE account=:account AND organization=:organization AND id=:id AND syncIssue IS NULL")
    suspend fun issue(account: String, organization: String, id: String, issue: String)
    @Query("SELECT EXISTS(SELECT 1 FROM photos WHERE account=:account AND organization=:organization AND syncIssue IS NOT NULL)")
    suspend fun hasIssues(account: String, organization: String): Boolean
    @Query("UPDATE pending_hydrant_changes SET state='ATTENTION' WHERE account=:account AND organization=:organization AND operationId=:id AND operation='UPLOAD_PHOTO' AND state='PENDING'")
    suspend fun block(account: String, organization: String, id: String)
}
