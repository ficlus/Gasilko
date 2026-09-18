import test from 'node:test';
import assert from 'node:assert/strict';
import { canReview, reviewRequest } from '../lib/access/review.ts';
function client(status='ACTIVE', role='ADMIN', identity='caller') {
  const query={select(){return this},eq(){return this},then(resolve){resolve({data:[{user_id:identity,role}]})}};
  return {auth:{getUser:async()=>({data:{user:{id:'caller'}}})},rpc:async()=>({data:status}),from:()=>query};
}
for(const role of ['ADMIN','MANAGER'])test(role+' may enter reviewer route',async()=>assert.equal(await canReview(client('ACTIVE',role)),true));
test('FIREFIGHTER reviewer route denied',async()=>assert.equal(await canReview(client('ACTIVE','FIREFIGHTER')),false));
for(const status of ['PENDING_APPROVAL','SUSPENDED','REJECTED','UNKNOWN'])test(status+' reviewer route denied',async()=>assert.equal(await canReview(client(status)),false));
test('other user role cannot grant reviewer route',async()=>assert.equal(await canReview(client('ACTIVE','ADMIN','other')),false));
test('unverified identity cannot enter review',async()=>assert.equal(await canReview({auth:{getUser:async()=>({data:{user:null}})}}),false));
test('network failure locks reviewer route',async()=>assert.equal(await canReview({auth:{getUser:async()=>{throw Error()}}}),false));
test('review sends only request id and decision',async()=>{let args;assert.equal(await reviewRequest({rpc:async(...a)=>{args=a;return{data:'APPROVED'}}},'request','APPROVED'),'APPROVED');assert.deepEqual(args,['review_organization_access',{request_id:'request',decision:'APPROVED'}]);});
for(const result of ['APPROVED','REJECTED','ALREADY_REVIEWED','NOT_AUTHORIZED','INELIGIBLE','UNAVAILABLE','ALREADY_MEMBER'])test('review preserves '+result,async()=>assert.equal(await reviewRequest({rpc:async()=>({data:result})},'id','REJECTED'),result));
test('invalid decision is never sent',async()=>assert.equal(await reviewRequest({rpc:()=>{throw Error()}},'id','ADMIN'),'NOT_AUTHORIZED'));
test('server failure never reports successful approval',async()=>assert.equal(await reviewRequest({rpc:async()=>({error:{message:'private detail'}})},'id','APPROVED'),'ERROR'));
test('network failure never reports successful approval',async()=>assert.equal(await reviewRequest({rpc:async()=>{throw Error()}},'id','APPROVED'),'ERROR'));
