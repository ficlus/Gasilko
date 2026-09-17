import test from 'node:test';
import assert from 'node:assert/strict';
import { loadAccount, signOutSession } from '../lib/auth/load.ts';
import { accountState, canEnterAdmin, errorKey } from '../lib/auth/state.ts';
function fake({ user = { id: 'caller' }, status = 'ACTIVE', roles = [], authError = null, profileError = null, memberError = null, signoutError = null } = {}) {
  let queries = 0; let signedOut = false;
  const chain = { select() { return this; }, eq() { return this; }, then(resolve) { queries++; resolve({ data: roles, error: memberError }); } };
  return { auth: { getUser: async () => ({ data: { user: signedOut ? null : user }, error: authError }), signOut: async ({scope}) => { assert.equal(scope,'local'); if (!signoutError) signedOut=true; return {error:signoutError}; } }, rpc: async name => { assert.equal(name,'get_my_account_status'); return {data:status,error:profileError}; }, from: name => { assert.equal(name,'user_organizations'); return chain; }, queries:()=>queries };
}
test('unauthenticated protected route cannot authorize', async()=>assert.deepEqual(await loadAccount(fake({user:null})),{state:'UNAUTHENTICATED',admin:false}));
for(const status of ['PENDING_APPROVAL','SUSPENDED','REJECTED']) test(status+' blocks admin even with forged ADMIN membership', async()=>{ const c=fake({status,roles:[{user_id:'caller',organization_id:'org',role:'ADMIN'}]}); assert.deepEqual(await loadAccount(c),{state:status,admin:false}); assert.equal(c.queries(),0); });
for(const role of ['FIREFIGHTER','MANAGER']) test(role+' is not an admin', async()=>assert.equal((await loadAccount(fake({roles:[{user_id:'caller',organization_id:'org',role}]}))).admin,false));
test('ACTIVE without membership is not admin',async()=>assert.deepEqual(await loadAccount(fake()),{state:'ACTIVE',admin:false}));
test('own ADMIN membership permits shell',async()=>assert.equal((await loadAccount(fake({roles:[{user_id:'caller',organization_id:'org',role:'ADMIN'}]}))).admin,true));
test('another users ADMIN membership grants nothing',()=>assert.equal(canEnterAdmin('ACTIVE',[{user_id:'other',organization_id:'org',role:'ADMIN'}],'caller'),false));
test('unknown/missing profile status fails closed',async()=>{assert.equal(accountState('OWNER'),'ERROR');assert.equal((await loadAccount(fake({status:null}))).state,'ERROR');});
test('profile errors fail closed',async()=>assert.deepEqual(await loadAccount(fake({profileError:{}})),{state:'ERROR',admin:false}));
test('membership errors fail closed',async()=>assert.equal((await loadAccount(fake({memberError:{}}))).admin,false));
test('expired or revoked auth is unauthenticated',async()=>assert.equal((await loadAccount(fake({authError:{status:401}}))).state,'UNAUTHENTICATED'));
test('network failure locks rather than trusting cookie',async()=>assert.deepEqual(await loadAccount({auth:{getUser:async()=>{throw Error('network');}}}),{state:'ERROR',admin:false}));
test('successful signout removes next-request authorization',async()=>{const c=fake();assert.equal(await signOutSession(c),true);assert.equal((await loadAccount(c)).state,'UNAUTHENTICATED');});
test('signout errors do not claim success',async()=>assert.equal(await signOutSession(fake({signoutError:{}})),false));
test('missing configuration fails closed',async()=>assert.equal((await loadAccount(null)).state,'ERROR'));
test('provider errors become bounded localized keys',()=>{assert.equal(errorKey({code:'invalid_credentials'}),'invalidCredentials');assert.equal(errorKey({code:'weak_password'}),'weakPassword');assert.equal(errorKey({code:'email_exists'}),'signupNotice');assert.equal(errorKey({code:'sensitive server detail'}),'authError');});
