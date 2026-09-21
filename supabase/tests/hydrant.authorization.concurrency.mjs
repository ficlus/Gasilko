// Separate connections exercise mutation/version locks and live revocation.
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
const config=JSON.parse(execFileSync('supabase',['status','-o','json'],{encoding:'utf8',stdio:['ignore','pipe','pipe']}));
if(!['http://127.0.0.1:54321','http://localhost:54321'].includes(config.API_URL))throw Error('Local stack only');
const args=['exec','-i','supabase_db_gasilko','psql','-U','postgres','-d','postgres','-qAt','-v','ON_ERROR_STOP=1'];
const sql=q=>execFileSync('docker',args,{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
let count=0;
function check(ok,label){if(!ok)throw Error(label);console.log(`ok ${++count} - ${label}`);}
function start(query,waitForMarker=false){
  let readyResolve,readyReject;
  const ready=new Promise((resolve,reject)=>{readyResolve=resolve;readyReject=reject;});
  if(!waitForMarker)readyResolve();
  const done=new Promise(resolve=>{
    const child=spawn('docker',args,{stdio:['pipe','pipe','pipe']});let output='',error='';
    child.stdout.on('data',d=>{output+=d;if(output.includes('LOCK_HELD'))readyResolve();});
    child.stderr.on('data',d=>error+=d);
    child.on('error',()=>{if(waitForMarker)readyReject(Error('Connection failed'));resolve({ok:false,output,error});});
    child.on('close',code=>{if(waitForMarker&&!output.includes('LOCK_HELD'))readyReject(Error('Lock setup failed'));resolve({ok:code===0,output,error});});
    child.stdin.end(query);
  });
  return {ready,done};
}
const org=randomUUID(),ff=randomUUID(),manager=randomUUID(),admin=randomUUID(),type=randomUUID();
const hydrants=Array.from({length:6},()=>randomUUID());
const as=(actor,q)=>`set local role authenticated; set local request.jwt.claims='${JSON.stringify({sub:actor,role:'authenticated'})}'; ${q}`;
const tx=(q,isolation='read committed')=>`begin isolation level ${isolation}; select count(*) from public.countries; select pg_sleep(0.2); ${q}; select pg_sleep(0.2); commit;`;
const create=n=>`select public.create_hydrant('${org}','30000000-0000-4000-8000-000000000001','{"address":"Concurrent"}','${hydrants[n]}')`;
const version=()=>sql(`select version from public.hydrants where id='${hydrants[0]}'`);
const auditCount=()=>sql(`select count(*) from public.audit_log where entity_id='${hydrants[0]}'`);
const update=(note,v)=>`select public.update_hydrant('${org}','${hydrants[0]}','{"notes":"${note}"}',${v})`;
async function queuedAfter(lockQuery,mutation,isolation='read committed'){
  const holder=start(`begin; ${lockQuery}; select 'LOCK_HELD'; select pg_sleep(1); commit;`,true);
  await holder.ready;
  const result=await start(tx(mutation,isolation)).done;
  const held=await holder.done;
  if(!held.ok)throw Error('Lock holder failed');
  return result;
}
try{
  sql(`insert into auth.users(id) values('${ff}'),('${manager}'),('${admin}');
    update public.profiles set account_status='ACTIVE' where id in ('${ff}','${manager}','${admin}');
    insert into public.organizations(id,name,code,type) values('${org}','Concurrency','M22-C-${org.toUpperCase()}','OTHER');
    insert into public.user_organizations(user_id,organization_id,role) values('${ff}','${org}','FIREFIGHTER'),('${manager}','${org}','MANAGER'),('${admin}','${org}','ADMIN');
    insert into public.hydrant_types(id,organization_id,code,name) values('${type}','${org}','LOCAL','Local');`);
  let results=await Promise.all([start(tx(as(ff,create(0)))).done,start(tx(as(ff,create(0)))).done]);
  check(results.filter(r=>r.ok).length===1 && results.some(r=>/duplicate key|Previously assigned hydrant UUID cannot be recreated/.test(r.error)),'same UUID concurrent create has one safe winner');
  check(sql(`select count(*) from public.hydrants where id='${hydrants[0]}'`)==='1' && auditCount()==='1','duplicate create leaves one hydrant and one audit');
  check(sql(`select last_value from private.hydrant_code_counters where organization_id='${org}'`)==='1','duplicate create does not consume another committed code');
  results=await Promise.all([start(tx(as(ff,create(1)))).done,start(tx(as(manager,create(2)))).done]);
  check(results.every(r=>r.ok),'different UUID online creates both commit');
  check(sql(`select count(distinct code) from public.hydrants where organization_id='${org}'`)==='3','online creates receive unique codes');
  let v=version();
  results=await Promise.all([start(tx(as(manager,update('A',v)))).done,start(tx(as(admin,update('B',v)))).done]);
  check(results.filter(r=>r.ok).length===1 && results.some(r=>/HYDRANT_VERSION_CONFLICT/.test(r.error)),'same-version master edits have one winner and one conflict');
  check(version()===String(Number(v)+1) && auditCount()==='2','concurrent master edit increments and audits once');
  v=version();
  results=await Promise.all([start(tx(as(ff,`select public.change_hydrant_status('${org}','${hydrants[0]}','WORKING',${v})`))).done,start(tx(as(manager,update('C',v)))).done]);
  check(results.filter(r=>r.ok).length===1 && results.some(r=>/HYDRANT_VERSION_CONFLICT/.test(r.error)),'status versus master uses same expected-version gate');
  check(version()===String(Number(v)+1) && auditCount()==='3','status/master race audits one committed mutation');
  for(const isolation of ['read committed','repeatable read']){
    sql(`update public.user_organizations set role='MANAGER' where user_id='${manager}' and organization_id='${org}';`);
    const before=auditCount();v=version();
    const result=await queuedAfter(`update public.user_organizations set role='FIREFIGHTER' where user_id='${manager}' and organization_id='${org}'`,as(manager,update('Revoked',v)),isolation);
    check(!result.ok && /NOT_AUTHORIZED|could not serialize access/.test(result.error),`queued writer cannot retain demoted authority at ${isolation}`);
    check(version()===v && auditCount()===before,`demotion denial changes neither data nor audit at ${isolation}`);
  }
  sql(`update public.user_organizations set role='MANAGER' where user_id='${manager}' and organization_id='${org}';`);
  v=version();let before=auditCount();
  let result=await queuedAfter(`update public.profiles set account_status='SUSPENDED' where id='${manager}'`,as(manager,update('Suspended',v)));
  check(!result.ok && /NOT_AUTHORIZED/.test(result.error),'queued mutation rechecks suspended profile after lock wait');
  check(version()===v && auditCount()===before,'suspension denial preserves data and audit');
  sql(`update public.profiles set account_status='ACTIVE' where id='${manager}';`);
  result=await queuedAfter(as(manager,`select public.set_hydrant_active('${org}','${hydrants[0]}',false,${v})`),as(ff,`select public.change_hydrant_status('${org}','${hydrants[0]}','UNKNOWN',${v})`));
  check(!result.ok && /NOT_AUTHORIZED/.test(result.error),'queued firefighter cannot mutate newly deactivated hydrant');
  check(version()===String(Number(v)+1) && auditCount()===String(Number(before)+1),'only deactivation commits and audits');
  result=await queuedAfter(as(admin,`select public.update_hydrant_type('${org}','${type}','{"active":false}')`),as(ff,`select public.create_hydrant('${org}','${type}','{"address":"Inactive race"}','${hydrants[3]}')`));
  check(!result.ok && /Inactive hydrant type/.test(result.error),'type deactivation wins before queued new reference');
  check(sql(`select count(*) from public.hydrants where id='${hydrants[3]}'`)==='0' && sql(`select count(*) from public.audit_log where entity_id='${hydrants[3]}'`)==='0','rejected type reference leaves no hydrant or audit');
  before=sql(`select last_value from private.hydrant_code_counters where organization_id='${org}'`);
  result=await start(`begin; ${as(ff,create(4))}; rollback;`).done;
  check(result.ok && sql(`select count(*) from public.hydrants where id='${hydrants[4]}'`)==='0' && sql(`select count(*) from public.audit_log where entity_id='${hydrants[4]}'`)==='0','rollback removes API create and audit atomically');
  check(sql(`select last_value from private.hydrant_code_counters where organization_id='${org}'`)===before,'rollback also restores counter');
  console.log(`Hydrant authorization concurrency: ${count} assertions passed`);
}catch(error){console.error(error.message);process.exitCode=1;}
// Fixtures are removed by the next local reset, never by deleting audit history.
