// Disposable local Auth/REST search and query-plan verification. Never production.
import { execFileSync } from 'node:child_process';
import { randomUUID, randomBytes } from 'node:crypto';
const config=JSON.parse(execFileSync('supabase',['status','-o','json'],{encoding:'utf8',stdio:['ignore','pipe','pipe']}));
if(!['http://127.0.0.1:54321','http://localhost:54321'].includes(config.API_URL))throw Error('Local stack only');
const key=config.PUBLISHABLE_KEY||config.ANON_KEY;
const sql=q=>execFileSync('docker',['exec','-i','supabase_db_gasilko','psql','-U','postgres','-d','postgres','-qAt','-v','ON_ERROR_STOP=1'],{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
let count=0;
function check(ok,label){if(!ok)throw Error(label);console.log(`ok ${++count} - ${label}`)}
async function request(path,body,token){const r=await fetch(config.API_URL+path,{method:'POST',headers:{apikey:key,Authorization:`Bearer ${token||key}`,'Content-Type':'application/json'},body:JSON.stringify(body)});return{ok:r.ok,data:await r.json()};}
try {
 const email=`m25-${randomUUID()}@example.com`,password=randomBytes(24).toString('base64url');
 const signup=await request('/auth/v1/signup',{email,password});const user=signup.data?.id||signup.data?.user?.id;
 if(!signup.ok||!/^[0-9a-f-]{36}$/.test(user))throw Error('Auth fixture failed');
 sql(`update auth.users set email_confirmed_at=now() where id='${user}';`);
 const login=await request('/auth/v1/token?grant_type=password',{email,password});const token=login.data?.access_token;
 if(!login.ok||!token)throw Error('Auth login failed');
 const org=randomUUID(),foreign=randomUUID();
 sql(`insert into public.organizations(id,name,code,type) values('${org}','Search scale','M25-${org.toUpperCase()}','OTHER'),('${foreign}','Foreign search','M25-${foreign.toUpperCase()}','OTHER');
 update public.profiles set account_status='ACTIVE' where id='${user}';
 insert into public.user_organizations(user_id,organization_id,role) values('${user}','${org}','MANAGER');
 insert into public.hydrants(organization_id,hydrant_type_id,address,location_description,status,created_by,updated_by)
 select '${org}','30000000-0000-4000-8000-000000000001','Scale address '||n,case when n=2101 then 'Literal %_ quote " (test)' else null end,
 case when n%2=0 then 'NOT_WORKING' else 'WORKING' end,'${user}','${user}' from generate_series(1,2101)n;
 insert into public.hydrants(organization_id,hydrant_type_id,address,created_by,updated_by) select '${foreign}','30000000-0000-4000-8000-000000000001','Scale address '||n,'${user}','${user}' from generate_series(1,2101)n;
 analyze public.hydrants;`);
 const search=(args={},session=token)=>request('/rest/v1/rpc/search_hydrants',{organization:org,...args},session);
 check(!(await search({},null)).ok,'anonymous RPC search denied');
 let r=await search();check(r.ok&&r.data.length===50,'2101-row organization returns only first 50');
 const first=r.data[0];let ids=new Set();let after;let pages=0;
 do{r=await search({after_id:after??null});check(r.ok&&r.data.length<=50,'REST page bounded');for(const h of r.data){if(ids.has(h.id)||h.organization_id!==org)throw Error('scope or duplicate');ids.add(h.id);}after=r.data.at(-1)?.id;pages++;}while(r.data.length===50);
 check(ids.size===2101&&pages===43,'43 pages return all 2101 own records once');
 r=await search({search_text:'  SCALE ADDRESS 2101  ',status_filter:'WORKING'});check(r.ok&&r.data.length===1,'REST trimmed case-insensitive text AND status');
 r=await search({search_text:'%_ quote " (test)'});check(r.ok&&r.data.length===1,'REST literal special-character substring');
 check(!(await search({organization:foreign,search_text:'%'})).ok,'foreign organization denied');
 check(!(await search({status_filter:'FORGED'})).ok,'invalid status rejected');
 check(!(await search({page_size:100000})).ok,'unbounded page rejected');
 const active=await request('/rest/v1/rpc/set_hydrant_active',{organization:org,hydrant_id:first.id,is_active:false,expected_version:first.version},token);
 check(active.ok,'manager deactivation succeeds');
 r=await search({active_filter:'inactive'});check(r.ok&&r.data.length===1&&r.data[0].id===first.id,'deactivated record enters inactive filter');
 r=await search({active_filter:'active',after_id:null,page_size:100});check(r.ok&&!r.data.some(h=>h.id===first.id),'deactivated record leaves active result');
 sql(`update public.user_organizations set role='FIREFIGHTER' where user_id='${user}' and organization_id='${org}';`);
 r=await search({active_filter:'inactive'});check(r.ok&&r.data.length===0,'manipulated firefighter inactive filter returns nothing');
 for(const state of ['PENDING_APPROVAL','SUSPENDED']){sql(`update public.profiles set account_status='${state}' where id='${user}';`);check(!(await search()).ok,`${state} existing session denied`)}
 sql(`update public.profiles set account_status='ACTIVE' where id='${user}';`);
 const auth=`set role authenticated;set request.jwt.claims='{"sub":"${user}","role":"authenticated"}';`;
 // Exact RPC timing, followed by its representative scoped/order predicate plan.
 const plan=q=>JSON.parse(sql(auth+`explain(analyze,buffers,format json) ${q};`));
 const rpcPlan=plan(`select * from public.search_hydrants('${org}','scale address',null,null,'active',null,50)`);
 const scopePlan=plan(`select h.* from public.hydrants h where organization_id='${org}' and active and strpos(lower(coalesce(address,'')),'scale address')>0 order by id limit 50`);
 console.log('Search RPC EXPLAIN '+JSON.stringify(rpcPlan));
 console.log('Scoped predicate EXPLAIN '+JSON.stringify(scopePlan));
 const sparsePlan=plan(`select * from public.search_hydrants('${org}','Scale address 2101',null,null,'active',null,50)`);
 const missingPlan=plan(`select * from public.search_hydrants('${org}','no matching address',null,null,'active',null,50)`);
 console.log('Sparse search EXPLAIN '+JSON.stringify(sparsePlan));
 console.log('No-match search EXPLAIN '+JSON.stringify(missingPlan));
 check(rpcPlan[0].Plan['Actual Rows']===50,'EXPLAIN actual RPC returns bounded 50');
 console.log(`Hydrant search integration: ${count} assertions passed`);
}catch(e){console.error('Hydrant search integration failed:',e.message);process.exitCode=1;}
