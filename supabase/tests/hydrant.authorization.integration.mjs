// Real Auth + PostgREST boundary. Only disposable localhost Supabase is allowed.
import { execFileSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
const config = JSON.parse(execFileSync('supabase', ['status','-o','json'], {encoding:'utf8',stdio:['ignore','pipe','pipe']}));
const base = config.API_URL;
if (!['http://127.0.0.1:54321','http://localhost:54321'].includes(base)) throw Error('Local stack only');
const key = config.PUBLISHABLE_KEY || config.ANON_KEY;
const sql = q => execFileSync('docker',['exec','-i','supabase_db_gasilko','psql','-U','postgres','-d','postgres','-qAt','-v','ON_ERROR_STOP=1'],{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
let count=0;
function check(ok,label){if(!ok)throw Error(label);console.log(`ok ${++count} - ${label}`);}
async function request(path,body,token,method='POST',extraHeaders={}){
  const response=await fetch(base+path,{method,headers:{apikey:key,Authorization:`Bearer ${token||key}`,'Content-Type':'application/json',...extraHeaders},...(method==='GET'?{}:{body:JSON.stringify(body)})});
  return {ok:response.ok,status:response.status,data:await response.json().catch(()=>null)};
}
const one = response => Array.isArray(response.data) ? response.data[0] : response.data;
async function loginFixture(){
  const email=`m22-${randomUUID()}@example.com`,password=randomBytes(24).toString('base64url');
  const signup=await request('/auth/v1/signup',{email,password});
  const id=signup.data?.id || signup.data?.user?.id;
  if(!signup.ok || !/^[0-9a-f-]{36}$/.test(id))throw Error('Auth fixture failed');
  sql(`update auth.users set email_confirmed_at=now() where id='${id}';`);
  const login=await request('/auth/v1/token?grant_type=password',{email,password});
  if(!login.ok || !login.data?.access_token)throw Error('Auth login failed');
  return {id,token:login.data.access_token};
}
try{
  const ff=await loginFixture(),manager=await loginFixture(),org=randomUUID(),foreign=randomUUID(),hydrant=randomUUID();
  sql(`insert into public.organizations(id,name,code,type) values('${org}','Hydrant API','M22-API-${org.toUpperCase()}','OTHER'),('${foreign}','Foreign API','M22-API-${foreign.toUpperCase()}','OTHER');
    update public.profiles set account_status='ACTIVE' where id in ('${ff.id}','${manager.id}');
    insert into public.user_organizations(user_id,organization_id,role) values('${ff.id}','${org}','FIREFIGHTER'),('${manager.id}','${org}','MANAGER');`);
  const rpc=(name,body,token=ff.token)=>request(`/rest/v1/rpc/${name}`,body,token);
  const fields={address:'API fixture'},create={organization:org,hydrant_type:'30000000-0000-4000-8000-000000000001',fields,hydrant_id:hydrant};
  check(!(await request('/rest/v1/hydrants?select=id',null,null,'GET')).ok,'anonymous REST read denied');
  const created=await rpc('create_hydrant',create);
  let row=one(created);
  check(created.ok && row?.id===hydrant && /-H-000001$/.test(row.code),'real firefighter creates centrally coded hydrant');
  check(row.created_by===ff.id && row.updated_by===ff.id && row.version===2,'API actor and version are server established');
  check(!(await rpc('create_hydrant',create)).ok,'duplicate UUID cannot overwrite');
  const own=await request(`/rest/v1/hydrants?select=id&organization_id=eq.${org}`,null,ff.token,'GET');
  check(own.ok && own.data.length===1,'member reads own hydrant through REST');
  check(!(await rpc('create_hydrant',{...create,organization:foreign,hydrant_id:randomUUID()})).ok,'foreign organization creation denied');
  check(!(await rpc('create_hydrant',{...create,hydrant_id:randomUUID(),fields:{...fields,updated_by:manager.id}})).ok,'forged actor patch rejected by API');
  check(!(await rpc('create_hydrant',{...create,hydrant_id:randomUUID(),actor:manager.id})).ok,'extra actor argument cannot resolve privileged RPC');
  check(!(await request('/rest/v1/hydrants',{id:hydrant,organization_id:foreign},ff.token,'POST',{Prefer:'resolution=merge-duplicates'})).ok,'malicious REST upsert denied');
  check(!(await request(`/rest/v1/hydrants?id=eq.${hydrant}`,{status:'WORKING',address:'Bypass'},ff.token,'PATCH')).ok,'crafted REST status and master edit denied');
  check(!(await request(`/rest/v1/hydrants?id=eq.${hydrant}`,{},ff.token,'DELETE')).ok,'REST physical delete denied');
  const changed=await rpc('change_hydrant_status',{organization:org,hydrant_id:hydrant,new_status:'WORKING',expected_version:row.version});
  row=one(changed);
  check(changed.ok && row.status==='WORKING' && row.version===3 && row.updated_by===ff.id,'status RPC changes only authorized data');
  const stale=await rpc('change_hydrant_status',{organization:org,hydrant_id:hydrant,new_status:'UNKNOWN',expected_version:2});
  check(!stale.ok && stale.data?.code==='P0001' && stale.data?.message==='HYDRANT_VERSION_CONFLICT','API reports deterministic version conflict');
  check(!(await rpc('update_hydrant',{organization:org,hydrant_id:hydrant,changes:{notes:'Bypass'},expected_version:row.version})).ok,'firefighter master RPC denied');
  const edited=await rpc('update_hydrant',{organization:org,hydrant_id:hydrant,changes:{notes:'Manager edit'},expected_version:row.version},manager.token);
  row=one(edited);
  check(edited.ok && row.version===4 && row.updated_by===manager.id,'manager master RPC attributes actual caller');
  const deactivated=await rpc('set_hydrant_active',{organization:org,hydrant_id:hydrant,is_active:false,expected_version:row.version},manager.token);
  row=one(deactivated);
  check(deactivated.ok && row.active===false && row.version===5,'manager deactivation succeeds');
  check((await request(`/rest/v1/hydrants?id=eq.${hydrant}&select=id`,null,ff.token,'GET')).data?.length===0,'firefighter cannot read inactive row');
  check((await request(`/rest/v1/hydrants?id=eq.${hydrant}&select=id`,null,manager.token,'GET')).data?.length===1,'manager can read inactive row');
  check(!(await rpc('change_hydrant_status',{organization:org,hydrant_id:hydrant,new_status:'UNKNOWN',expected_version:5})).ok,'firefighter cannot update hidden inactive row');
  const reactivated=await rpc('set_hydrant_active',{organization:org,hydrant_id:hydrant,is_active:true,expected_version:row.version},manager.token);
  row=one(reactivated);
  check(reactivated.ok && row.active===true,'manager reactivation succeeds');
  check(!(await rpc('create_hydrant_type',{organization:org,type_code:'API_TYPE',type_name:'API type'},manager.token)).ok,'manager type administration denied');
  sql(`update public.user_organizations set role='ADMIN' where user_id='${manager.id}' and organization_id='${org}';`);
  const type=await rpc('create_hydrant_type',{organization:org,type_code:'API_TYPE',type_name:'API type'},manager.token);
  check(type.ok && one(type).organization_id===org,'existing session observes ADMIN type authority');
  check(!(await rpc('update_hydrant_type',{organization:org,type_id:'30000000-0000-4000-8000-000000000001',changes:{name:'No'}},manager.token)).ok,'global type mutation denied through API');
  for(const state of ['PENDING_APPROVAL','SUSPENDED','REJECTED']){
    sql(`update public.profiles set account_status='${state}' where id='${ff.id}';`);
    check((await request('/rest/v1/hydrants?select=id',null,ff.token,'GET')).data?.length===0,`${state} token has no protected reads`);
    check(!(await rpc('change_hydrant_status',{organization:org,hydrant_id:hydrant,new_status:'UNKNOWN',expected_version:row.version})).ok,`${state} token has no mutation authority`);
  }
  check(sql(`select count(*) from public.audit_log where entity_id='${hydrant}' and action='HYDRANT_CREATED' and user_id='${ff.id}' and organization_id='${org}';`)==='1','real API create audited once with correct actor and scope');
  check(!(await rpc('assign_hydrant_code',{organization:org,hydrant,actor:ff.id})).ok,'private allocator is not exposed through REST');
  console.log(`Hydrant Auth integration: ${count} assertions passed`);
}catch{
  // Never print session material or raw provider responses.
  console.error(`Hydrant Auth integration failed after ${count} assertions`);process.exitCode=1;
}
// Keep fixtures in the disposable stack: code reservations and audit are permanent.
