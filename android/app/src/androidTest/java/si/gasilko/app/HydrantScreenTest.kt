package si.gasilko.app

import android.content.res.Configuration
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.hydrants.presentation.*
import java.util.Locale

class HydrantScreenTest {
    @get:Rule val compose=createComposeRule()
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    @After fun close(){scope.cancel()}
    private class Fake(val role:RegistryRole):HydrantRepository {
        var row=Hydrant("h","a","A-H-000001","t",HydrantStatus.UNKNOWN,address="Station",version=2)
        var writes=0;var conflict=false
        override suspend fun organizations()=listOf(RegistryOrganization("a","Station A",role))
        override suspend fun types(organization:String)=listOf(HydrantType("t",null,"CUSTOM","Custom type",true))
        override suspend fun list(organization:String,includeInactive:Boolean,after:String?)=if(row.active || includeInactive)listOf(row)else emptyList()
        override suspend fun get(organization:String,id:String)=row
        override suspend fun create(organization:String,id:String,fields:HydrantFields):Hydrant{writes++;row=row.copy(id=id,address=fields.address);return row}
        override suspend fun update(organization:String,id:String,fields:HydrantFields,version:Long):Hydrant{writes++;row=row.copy(notes=fields.notes,version=version+1);return row}
        override suspend fun changeStatus(organization:String,id:String,status:HydrantStatus,version:Long):Hydrant{writes++;if(conflict){row=row.copy(version=3);throw RegistryFailure(RegistryError.CONFLICT)};row=row.copy(status=status,version=version+1);return row}
        override suspend fun setActive(organization:String,id:String,active:Boolean,version:Long):Hydrant{writes++;row=row.copy(active=active,version=version+1);return row}
    }
    private fun show(f:Fake):HydrantViewModel {val m=HydrantViewModel(f,scope);compose.setContent{MaterialTheme{HydrantScreen(m)}};compose.waitForIdle();return m}
    @Test fun firefighterCanReadButHasNoMasterActions(){val m=show(Fake(RegistryRole.FIREFIGHTER));compose.onNodeWithText("Station A",substring=true).assertExists();compose.onNodeWithTag("hydrant-h").performClick();compose.onNodeWithTag("edit").assertDoesNotExist();compose.onNodeWithTag("set-active").assertDoesNotExist();compose.runOnIdle{assertEquals("h",m.state.value.selected?.id)}}
    @Test fun managerDeactivationRequiresDialog(){val f=Fake(RegistryRole.MANAGER);show(f);compose.onNodeWithTag("hydrant-h").performClick();compose.onNodeWithTag("set-active").performScrollTo().performClick();compose.runOnIdle{assertEquals(0,f.writes)};compose.onNodeWithTag("confirm-deactivate").performClick();compose.waitForIdle();compose.runOnIdle{assertFalse(f.row.active);assertEquals(1,f.writes)}}
    @Test fun createUsesDynamicTypeAndShowsAssignedCode(){val f=Fake(RegistryRole.FIREFIGHTER);val m=show(f);compose.onNodeWithTag("add").performClick();compose.onNodeWithTag("type").performClick();compose.onNodeWithTag("type-t").performClick();compose.onNodeWithTag("address").performScrollTo().performTextInput("New address");compose.onNodeWithTag("save").performScrollTo().performClick();compose.waitForIdle();compose.onNodeWithText("A-H-000001").assertExists();compose.runOnIdle{assertNull(m.state.value.form);assertEquals(1,f.writes)}}
    @Test fun statusConflictShowsLatestWithoutRetry(){val f=Fake(RegistryRole.FIREFIGHTER).apply{conflict=true};val m=show(f);compose.onNodeWithTag("hydrant-h").performClick();compose.onNodeWithTag("status").performScrollTo().performClick();compose.onNodeWithTag("status-WORKING").performClick();compose.onNodeWithTag("save-status").performScrollTo().performClick();compose.waitForIdle();compose.onNodeWithTag("conflict").assertExists();compose.runOnIdle{assertEquals(3L,m.state.value.selected?.version);assertEquals(1,f.writes)}}
    @Test fun slovenianAndGermanRegistryResourcesExist(){val context=InstrumentationRegistry.getInstrumentation().targetContext
        for(language in listOf("sl","de")){val config=Configuration(context.resources.configuration).apply{setLocale(Locale.forLanguageTag(language))};val resources=context.createConfigurationContext(config).resources
            R.string::class.java.fields.filter{it.name.startsWith("h_")}.forEach{assertTrue(resources.getString(it.getInt(null)).isNotBlank())}
            assertEquals(if(language=="sl")"Deluje" else "Funktionsfähig",resources.getString(R.string.h_working))
        }
    }
}
