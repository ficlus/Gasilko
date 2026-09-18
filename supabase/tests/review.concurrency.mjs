// Disposable local stack only. Independent PostgreSQL connections exercise real locks.
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
const config=JSON.parse(execFileSync('supabase',['status','-o','json'],{encoding:'utf8',stdio:['ignore','pipe','pipe']}));
if (!['http://127.0.0.1:54321','http://localhost:54321'].includes(config.API_URL)) throw Error('Local stack only');
const args=['exec','-i','supabase_db_gasilko','psql','-U','postgres','-d','postgres','-qAt','-v','ON_ERROR_STOP=1'];
const sql=q=>execFileSync('docker',args,{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
const users=Array.from({length:8},()=>randomUUID()), orgs=Array.from({length:6},()=>randomUUID()), requests=Array.from({length:3},()=>randomUUID());
let count=0;
function check(ok,label){if(!ok)throw Error(label);console.log(`ok ${++count} - ${label}`);}
function connection(query){return new Promise(resolve=>{const child=spawn('docker',args,{stdio:['pipe','pipe','pipe']});let output='';child.stdout.on('data',d=>output+=d);child.stderr.resume();child.on('error',()=>resolve({ok:false,output:''}));child.on('close',code=>resolve({ok:code===0,output}));child.stdin.end(query);});}
const as=(user,q)=>`set local role authenticated; set local request.jwt.claims='${JSON.stringify({sub:user,role:'authenticated'})}'; ${q}`;
async function race(a,b,isolation='read committed'){
  const wrap=q=>`begin isolation level ${isolation}; select count(*) from public.countries; select pg_sleep(0.2); ${q}; select pg_sleep(0.2); commit;`;
  return Promise.all([connection(wrap(a)),connection(wrap(b))]);
}
try {
  sql(users.map(id=>`insert into auth.users(id) values('${id}');`).join('\n')+`update public.profiles set account_status='ACTIVE' where id in ('${users[0]}','${users[1]}');`+
    orgs.map((id,n)=>`insert into public.organizations(id,name,code,type,administrative_area_id) values('${id}','Concurrency fixture','M15-C-${id.toUpperCase()}','OTHER','20000000-0000-4000-8000-000000000001');`).join('\n')+
    [0,2,3,4,5].flatMap(n=>[0,1].map(i=>`insert into public.user_organizations(user_id,organization_id,role) values('${users[i]}','${orgs[n]}','ADMIN');`)).join('\n')+
    requests.map((id,n)=>`insert into public.organization_access_requests(id,user_id,organization_id,requested_role) values('${id}','${users[n+2]}','${orgs[0]}','FIREFIGHTER');`).join('\n'));
  let results=await race(as(users[0],`select public.review_organization_access('${requests[0]}','APPROVED')`),as(users[1],`select public.review_organization_access('${requests[0]}','APPROVED')`));
  check(results.every(x=>x.ok)&&results.filter(x=>/^APPROVED$/m.test(x.output)).length===1&&results.filter(x=>/ALREADY_REVIEWED/.test(x.output)).length===1,'two approvals have one winner');
  check(sql(`select count(*) from public.user_organizations where user_id='${users[2]}' and organization_id='${orgs[0]}';`)==='1','concurrent approval creates exactly one membership');
  results=await race(as(users[0],`select public.review_organization_access('${requests[1]}','APPROVED')`),as(users[1],`select public.review_organization_access('${requests[1]}','REJECTED')`));
  check(results.every(x=>x.ok)&&results.filter(x=>/ALREADY_REVIEWED/.test(x.output)).length===1,'approve versus reject has one terminal winner');
  check(sql(`select (r.status='APPROVED')=exists(select 1 from public.user_organizations m where m.user_id=r.user_id and m.organization_id=r.organization_id) from public.organization_access_requests r where id='${requests[1]}';`)==='t','terminal result and membership agree');
  results=await race(`select private.bootstrap_first_admin('${orgs[1]}','${users[5]}','${users[0]}')`,`select private.bootstrap_first_admin('${orgs[1]}','${users[6]}','${users[0]}')`);
  check(results.every(x=>x.ok)&&results.filter(x=>/BOOTSTRAPPED/.test(x.output)).length===1&&results.filter(x=>/ADMIN_EXISTS/.test(x.output)).length===1,'concurrent bootstrap has one winner');
  check(sql(`select count(*) from public.user_organizations where organization_id='${orgs[1]}' and role='ADMIN';`)==='1','bootstrap leaves exactly one first ADMIN');
  for(const [n,verb,isolation] of [[2,'delete','read committed'],[3,'update','read committed'],[4,'update','repeatable read']]) {
    const mutate=(actor,target)=>as(actor,verb==='delete'?`delete from public.user_organizations where organization_id='${orgs[n]}' and user_id='${target}'`:`update public.user_organizations set role='MANAGER' where organization_id='${orgs[n]}' and user_id='${target}'`);
    results=await race(mutate(users[0],users[1]),mutate(users[1],users[0]),isolation);
    check(results.some(x=>x.ok),`${verb} race commits an authorized operation at ${isolation}`);
    check(sql(`select count(*) from public.user_organizations where organization_id='${orgs[n]}' and role='ADMIN';`)==='1',`${verb} race preserves final ADMIN at ${isolation}`);
  }
  check(sql(`select count(*) from public.audit_log where entity_id='${requests[0]}' and action='ACCESS_REQUEST_APPROVED';`)==='1','concurrent review audited once');
  // Same already-issued API session observes the committed activation/membership.
  // Auth token lifecycle itself is covered separately by auth.integration.mjs.
  check(sql(`begin; ${as(users[2],`select public.get_my_account_status(); select count(*) from public.user_organizations where user_id='${users[2]}'`)}; rollback;`).split('\n').join('/')==='ACTIVE/1','approved identity immediately sees ACTIVE and own membership');
  console.log(`Review concurrency: ${count} assertions passed`);
} catch(error) { console.error(error.message);process.exitCode=1; }
// Fixtures stay in this disposable local stack, preserving append-only audit.
// CI stops the stack without backup. Run db reset before another local invocation.
