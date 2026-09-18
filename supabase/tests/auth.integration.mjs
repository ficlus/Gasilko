// Runs only against the disposable CI/local Supabase stack. Never logs credentials.
import { execFileSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
const config = JSON.parse(execFileSync('supabase', ['status', '-o', 'json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
const base = config.API_URL;
if (!['http://127.0.0.1:54321', 'http://localhost:54321'].includes(base)) throw Error('Local Supabase only');
const apiKey = config.PUBLISHABLE_KEY || config.ANON_KEY;
const email = `m13-${randomUUID()}@example.com`;
const password = randomBytes(24).toString('base64url');
let id, organizationId, count = 0;
function check(condition, label) { if (!condition) throw Error(label); count++; console.log(`ok ${count} - ${label}`); }
function sql(query) { return execFileSync('docker', ['exec', '-i', 'supabase_db_gasilko', 'psql', '-U', 'postgres', '-d', 'postgres', '-At', '-v', 'ON_ERROR_STOP=1'], { input: query, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim(); }
async function request(path, body, token, method = 'POST') {
  const response = await fetch(base + path, { method, headers: { apikey: apiKey, Authorization: `Bearer ${token || apiKey}`, 'Content-Type': 'application/json' }, ...(method === 'GET' ? {} : { body: JSON.stringify(body) }) });
  const data = await response.json().catch(() => null);
  return { ok: response.ok, status: response.status, data };
}
try {
  const signup = await request('/auth/v1/signup', { email, password, data: { display_name: 'Integration', preferred_language: 'de', account_status: 'ACTIVE', role: 'ADMIN', organization_id: randomUUID() } });
  check(signup.ok, 'real Auth signup succeeds');
  id = signup.data.id || signup.data.user?.id;
  if (!/^[0-9a-f-]{36}$/.test(id)) throw Error('Invalid fixture identity');
  check(sql(`select count(*) from public.profiles where id='${id}' and account_status='PENDING_APPROVAL' and preferred_language='de';`) === '1', 'real signup provisions one pending profile despite forged ACTIVE');
  check(sql(`select count(*) from public.user_organizations where user_id='${id}';`) === '0', 'real signup cannot create ADMIN or membership');
  const unconfirmed = await request('/auth/v1/token?grant_type=password', { email, password });
  check(!unconfirmed.ok, 'unconfirmed email cannot sign in');
  // Delivery configuration remains a manual acceptance check. Confirm only this fixture.
  sql(`update auth.users set email_confirmed_at=now() where id='${id}';`);
  const login = await request('/auth/v1/token?grant_type=password', { email, password });
  check(login.ok && !!login.data.access_token, 'email/password sign in succeeds after confirmation');
  let session = login.data;
  check((await request('/auth/v1/user', null, session.access_token, 'GET')).ok, 'restored access token validates against Auth');
  organizationId = randomUUID();
  sql(`insert into public.organizations(id,name,code,type,administrative_area_id) values ('${organizationId}','Request integration','M14-INTEGRATION','OTHER','20000000-0000-4000-8000-000000000001');`);
  const discovery=await request('/rest/v1/rpc/discover_organizations',{country:'10000000-0000-4000-8000-000000000001'},session.access_token);
  check(discovery.ok && discovery.data.some(o=>o.id===organizationId), 'pending user discovers selection metadata');
  const attempts=await Promise.all([1,2].map(()=>request('/rest/v1/rpc/request_organization_access',{organization:organizationId,desired_role:'FIREFIGHTER'},session.access_token)));
  check(attempts.filter(r=>r.data?.result==='SUBMITTED').length===1 && attempts.filter(r=>r.data?.result==='DUPLICATE_REQUEST').length===1,'concurrent requests create one pending row');
  check((await request('/rest/v1/rpc/request_organization_access',{organization:organizationId,desired_role:'ADMIN'},session.access_token)).data?.result==='INVALID_ROLE','direct API ADMIN request denied');
  check(!(await request('/rest/v1/organization_access_requests',{user_id:id,organization_id:organizationId,requested_role:'FIREFIGHTER',status:'APPROVED'},session.access_token)).ok,'direct table approval bypass denied');
  check((await request('/rest/v1/rpc/get_my_account_status',{},session.access_token)).data==='PENDING_APPROVAL','request does not activate profile');
  for (const status of ['PENDING_APPROVAL', 'SUSPENDED', 'REJECTED', 'ACTIVE']) {
    sql(`update public.profiles set account_status='${status}' where id='${id}';`);
    const state = await request('/rest/v1/rpc/get_my_account_status', {}, session.access_token);
    check(state.ok && state.data === status, `${status} status is available through caller-only RPC`);
    const organizations = await request('/rest/v1/organizations?select=id', null, session.access_token, 'GET');
    check(organizations.ok && organizations.data.length === 0, `${status} without membership has no protected organization data`);
  }
  const refresh = await request('/auth/v1/token?grant_type=refresh_token', { refresh_token: session.refresh_token });
  check(refresh.ok && !!refresh.data.access_token, 'session refresh succeeds');
  session = refresh.data;
  const logout = await request('/auth/v1/logout?scope=local', {}, session.access_token);
  check(logout.ok, 'session signout succeeds');
  check(!(await request('/auth/v1/token?grant_type=refresh_token', { refresh_token: session.refresh_token })).ok, 'signed-out session cannot refresh');
  check(!(await request('/auth/v1/token?grant_type=password', { email, password: randomBytes(24).toString('hex') })).ok, 'invalid credentials rejected');
  console.log(`Auth integration: ${count} assertions passed`);
} catch {
  // Do not print errors/response objects that might contain session material.
  console.error(`Auth integration failed after ${count} completed assertions`);
  process.exitCode = 1;
} finally {
  if (id && /^[0-9a-f-]{36}$/.test(id)) sql(`begin; delete from public.organization_access_requests where user_id='${id}'; delete from public.organizations where code='M14-INTEGRATION'; delete from public.profiles where id='${id}'; delete from auth.users where id='${id}'; commit;`);
}
