package si.gasilko.app.core.access
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
class AccessRepositoryTest {
 private class Fake:AccessGateway {
  var result="SUBMITTED";var calls=0;var fail=false;var parent:String?=null
  override suspend fun countries()=listOf(Choice("SI","Slovenia"))
  override suspend fun areas(country:String,parent:String?,after:String?):List<Choice>{this.parent=parent;return listOf(Choice("child","Child"))}
  override suspend fun organizations(country:String,area:String?,after:String?)=listOf(Organization("org","Organization","CODE"))
  override suspend fun history(last:AccessRequest?):List<AccessRequest>{if(fail)throw IllegalStateException();return listOf(AccessRequest("request","Organization","MANAGER","PENDING","2026-01-01"))}
  override suspend fun submit(organization:String,role:String):String{calls++;return result}
 }
 @Test fun loadsOwnHistory()=runTest{val r=AccessRepository(Fake());r.load();assertEquals("PENDING",r.state.value.history.single().status)}
 @Test fun failedReloadClearsPreviousAccountHistory()=runTest{val g=Fake();val r=AccessRepository(g);r.load();g.fail=true;r.load();assertTrue(r.state.value.history.isEmpty());assertEquals("ERROR",r.state.value.result)}
 @Test fun arbitraryDepthIsPassedThrough()=runTest{val g=Fake();val r=AccessRepository(g);r.browse("AT",(1..7).map{Choice("area-"+it,"Area")});assertEquals("area-7",g.parent)}
 @Test fun adminNeverSent()=runTest{val g=Fake();val r=AccessRepository(g);r.submit("org","ADMIN");assertEquals(0,g.calls);assertEquals("INVALID_ROLE",r.state.value.result)}
 @Test fun submittedRemainsPending()=runTest{val r=AccessRepository(Fake());r.submit("org","MANAGER");assertEquals("SUBMITTED",r.state.value.result);assertEquals("PENDING",r.state.value.history.single().status)}
 @Test fun duplicateIsSafeResult()=runTest{val g=Fake();g.result="DUPLICATE_REQUEST";val r=AccessRepository(g);r.submit("org","FIREFIGHTER");assertEquals(g.result,r.state.value.result)}
 @Test fun existingMemberIsSafeResult()=runTest{val g=Fake();g.result="ALREADY_MEMBER";val r=AccessRepository(g);r.submit("org","FIREFIGHTER");assertEquals(g.result,r.state.value.result)}
 @Test fun failureAllowsRetry()=runTest{val g=Fake();g.fail=true;val r=AccessRepository(g);r.load();assertFalse(r.state.value.busy);assertEquals("ERROR",r.state.value.result);g.fail=false;r.load();assertNull(r.state.value.result)}
}
