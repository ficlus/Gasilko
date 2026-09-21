package si.gasilko.app.feature.hydrants

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import si.gasilko.app.feature.hydrants.data.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.hydrants.presentation.statusLabel
import si.gasilko.app.R
import java.io.IOException

class HydrantContractTest {
    private fun invalid(form: HydrantForm,error: RegistryError){try{form.fields();fail("Expected validation")}catch(e: RegistryFailure){assertEquals(error,e.reason)}}
    @Test fun addressAndDescriptionLocations(){assertEquals("Street",HydrantForm("x","t",address=" Street ").fields().address);assertEquals("Station",HydrantForm("x","t",description="Station").fields().description)}
    @Test fun coordinateBoundariesAndDecimalComma(){assertEquals(-90.0,HydrantForm("x","t",latitude="-90",longitude="180").fields().latitude!!,0.0);assertEquals(46.5,HydrantForm("x","t",latitude="46,5",longitude="14,2").fields().latitude!!,0.0)}
    @Test fun coordinatePairRequiredEvenWithAddress(){invalid(HydrantForm("x","t",latitude="45",address="Street"),RegistryError.COORDINATES);invalid(HydrantForm("x","t",longitude="14",address="Street"),RegistryError.COORDINATES)}
    @Test fun boundsAndNonFiniteRejected(){for(lat in listOf("-90.1","90.1","NaN","Infinity","abc"))invalid(HydrantForm("x","t",latitude=lat,longitude="14"),RegistryError.COORDINATES);invalid(HydrantForm("x","t",latitude="45",longitude="180.1"),RegistryError.COORDINATES)}
    @Test fun whitespaceNotLocation(){invalid(HydrantForm("x","t",address=" \n",description="\t"),RegistryError.LOCATION)}
    @Test fun typeRequired(){invalid(HydrantForm("x",address="Street"),RegistryError.TYPE)}
    @Test fun intervalValidation(){for(v in listOf("0","-1","1.5","999999999999"))invalid(HydrantForm("x","t",address="Street",interval=v),RegistryError.INTERVAL);assertNull(HydrantForm("x","t",address="Street").fields().interval)}
    @Test fun payloadCannotForgeMetadataOrEditStatus(){val f=HydrantForm("x","t",address="Street").fields();assertEquals(setOf("hydrant_type_id","latitude","longitude","address","location_description","notes","inspection_interval_months"),f.payload(false).keys);assertEquals("UNKNOWN",f.payload(true)["status"]!!.jsonPrimitive.content)}
    @Test fun stableErrorMapping(){assertEquals(RegistryError.CONFLICT,registryError("P0001","HYDRANT_VERSION_CONFLICT"));assertEquals(RegistryError.SERVER,registryError("P0001","unrelated"));assertEquals(RegistryError.FORBIDDEN,registryError("42501",null));assertEquals(RegistryError.EXPIRED,registryError(null,null,401));assertEquals(RegistryError.VALIDATION,registryError("23514",null));assertEquals(RegistryError.SERVER,registryError("XX000","sensitive details"))}
    @Test fun everyStatusHasPresentationLabel(){assertEquals(listOf(R.string.h_working,R.string.h_not_working,R.string.h_needs_inspection,R.string.h_unknown),HydrantStatus.entries.map(::statusLabel))}
    private val record=Json.parseToJsonElement("""{"id":"h","organization_id":"a","code":"A-H-000001","hydrant_type_id":"t","status":"UNKNOWN","active":true,"version":2,"created_by":"me","address":"Street"}""")
    private inner class Wire:RegistryTransport {
        var name="";var args=buildJsonObject{};var prior:JsonElement?=null;var fail=false;var rpcCalls=0;var filters:Map<String,String?> = emptyMap()
        override fun actor()="me"
        override suspend fun rows(table:String,filters:Map<String,String?>,after:String?):JsonArray {this.filters=filters;if(fail)throw IOException();return JsonArray(listOfNotNull(prior))}
        override suspend fun rpc(name:String,arguments:JsonObject):JsonElement {this.name=name;args=arguments;rpcCalls++;return record}
    }
    @Test fun statusUsesDedicatedRpcAndVersion()=runTest{val w=Wire();OnlineHydrantRepository(w).changeStatus("a","h",HydrantStatus.WORKING,7);assertEquals("change_hydrant_status",w.name);assertEquals(7,w.args["expected_version"]!!.jsonPrimitive.int);assertEquals(setOf("organization","hydrant_id","expected_version","new_status"),w.args.keys)}
    @Test fun masterAndActiveUseNarrowRpcs()=runTest{val w=Wire();val r=OnlineHydrantRepository(w);r.update("a","h",HydrantForm("h","t",address="Street").fields(),8);assertEquals("update_hydrant",w.name);assertFalse(w.args["changes"]!!.jsonObject.containsKey("status"));r.setActive("a","h",false,9);assertEquals("set_hydrant_active",w.name);assertEquals(9,w.args["expected_version"]!!.jsonPrimitive.int)}
    @Test fun createPassesStableUuidAndNoActor()=runTest{val w=Wire();OnlineHydrantRepository(w).create("a","h",HydrantForm("h","t",address="Street").fields());assertEquals("h",w.args["hydrant_id"]!!.jsonPrimitive.content);assertEquals(setOf("organization","hydrant_id","hydrant_type","fields"),w.args.keys)}
    @Test fun uncertainCreateReconcilesOwnUuidWithoutDuplicateRpc()=runTest{val w=Wire().apply{prior=record};val h=OnlineHydrantRepository(w).create("a","h",HydrantForm("h","t",address="Street").fields());assertEquals("A-H-000001",h.code);assertEquals(0,w.rpcCalls);assertEquals(mapOf("organization_id" to "a","id" to "h"),w.filters)}
    @Test fun collidingOtherActorNeverAcknowledged()=runTest{val w=Wire().apply{prior=JsonObject(record.jsonObject+mapOf("created_by" to JsonPrimitive("other")))};try{OnlineHydrantRepository(w).create("a","h",HydrantForm("h","t",address="Street").fields());fail()}catch(e:RegistryFailure){assertEquals(RegistryError.FORBIDDEN,e.reason)};assertEquals(0,w.rpcCalls)}
    @Test fun networkMappedWithoutLeakingException()=runTest{val w=Wire().apply{fail=true};try{OnlineHydrantRepository(w).list("a",false);fail()}catch(e:RegistryFailure){assertEquals(RegistryError.NETWORK,e.reason);assertNull(e.message)}}
    @Test fun missingDetailMapsUnavailable()=runTest{try{OnlineHydrantRepository(Wire()).get("a","missing");fail()}catch(e:RegistryFailure){assertEquals(RegistryError.UNAVAILABLE,e.reason)}}
    @Test fun scalarAndArrayRpcResponsesDecode(){assertEquals(decodeHydrant(record),decodeHydrant(JsonArray(listOf(record))))}
    @Test fun membershipsAndOrganizationsPageWithoutMixingRosters()=runTest {
        val calls=mutableListOf<Triple<String,Map<String,String?>,String?>>()
        val wire=object: RegistryTransport {
            override fun actor()="me"
            override suspend fun rpc(name:String,arguments:JsonObject)=JsonNull
            override suspend fun rows(table:String,filters:Map<String,String?>,after:String?):JsonArray {
                calls.add(Triple(table,filters,after))
                return JsonArray((if(after==null)0..99 else 100..100).map { n -> val id=n.toString().padStart(3,'0')
                    if(table=="user_organizations")buildJsonObject{put("organization_id",id);put("role","FIREFIGHTER")}
                    else buildJsonObject{put("id",id);put("name",id);put("active",true)}
                })
            }
        }
        assertEquals(101,OnlineHydrantRepository(wire).organizations().size)
        assertEquals(listOf(null,"099"),calls.filter{it.first=="user_organizations"}.map{it.third})
        assertTrue(calls.filter{it.first=="user_organizations"}.all{it.second==mapOf("user_id" to "me")})
    }
}
