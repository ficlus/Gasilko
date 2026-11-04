// Authenticated POST only. No new dependency, secret or verify_jwt exception.
import {constructDeviceChallengeV1,verifyClaimedDeviceProofV1} from "../_shared/deviceProofLifecycle.ts";
import {encodeDeviceProofTranscriptV1} from "../_shared/deviceProofV1.ts";
import {encodeLocationSample,verifyLocationSample,requireSampleIdentity,sha256,unhex} from "../_shared/vehicleLocationSample.ts";
const uuid=/^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const safe=new Set(["CAPABILITY_DISABLED","POLICY_UNAPPROVED","RETENTION_NOT_READY","DEVICE_PROOF_REQUIRED","DEVICE_APPROVAL_REQUIRED","NOT_AUTHORIZED","SCOPE_CHANGED",
 "CHALLENGE_EXPIRED","CLAIM_EXPIRED","CREDENTIAL_REVOKED","SESSION_EXPIRED","SESSION_CONFLICT","OPERATION_REUSED","INVALID_LOCATION","RATE_LIMITED","RESOURCE_LIMIT_REACHED","VALIDATION_FAILED","CREDENTIAL_GENERATION_CHANGED","STALE_VERSION","CHALLENGE_CONSUMED","CHALLENGE_CLAIMED"]);
class Failure extends Error {constructor(readonly code:string,readonly retryable=false){super(code);}}
const headers={"Cache-Control":"private, no-store, max-age=0","Content-Type":"application/json","X-Content-Type-Options":"nosniff","Referrer-Policy":"no-referrer"};
const result=(data:unknown)=>new Response(JSON.stringify({ok:true,schemaVersion:1,result:data,serverTime:new Date().toISOString()}),{headers});
const failure=(code:string,retryable=false)=>new Response(JSON.stringify({ok:false,schemaVersion:1,code,retryable}),{status:code==="NOT_AUTHORIZED"?403:retryable?503:422,headers});
function object(value:unknown,keys:readonly string[]):Record<string,any>{
 if(!value||typeof value!=="object"||Array.isArray(value)||Object.keys(value).length!==keys.length||keys.some(k=>!Object.hasOwn(value,k)))throw new Failure("INVALID_INPUT");
 return value as Record<string,any>;
}
// Recursive JSON parser rejects duplicate decoded keys before JSON.parse can
// discard them. Arrays/depth>8 and unbounded request bodies are not accepted.
function strictJson(text:string):unknown {
 let i=0;const ws=()=>{while(/\s/.test(text[i]??"")&&i<text.length)i++;};
 function string(){const start=i++;while(i<text.length){const c=text[i++];if(c==="\\"){i++;continue;}if(c==='"')return JSON.parse(text.slice(start,i));}throw new Failure("INVALID_INPUT");}
 function value(depth:number):any{ws();if(depth>8)throw new Failure("INVALID_INPUT");
  if(text[i]==="{"){i++;const out=Object.create(null),seen=new Set<string>();ws();if(text[i]==="}"){i++;return out;}
   while(i<text.length){ws();if(text[i]!=='"')throw new Failure("INVALID_INPUT");const k=string();if(seen.has(k))throw new Failure("INVALID_INPUT");seen.add(k);
    ws();if(text[i++]!==":")throw new Failure("INVALID_INPUT");out[k]=value(depth+1);ws();const c=text[i++];if(c==="}")return out;if(c!==",")throw new Failure("INVALID_INPUT");}
  }else if(text[i]==='"')return string();
  else {const start=i;while(i<text.length&&!/[\s,}]/.test(text[i]))i++;const token=text.slice(start,i);
   if(!/^(true|false|null|1)$/.test(token))throw new Failure("INVALID_INPUT");return JSON.parse(token);}
  throw new Failure("INVALID_INPUT");
 }
 const out=value(0);ws();if(i!==text.length)throw new Failure("INVALID_INPUT");return out;
}
async function body(req:Request){
 const reader=req.body?.getReader();if(!reader)throw new Failure("INVALID_INPUT");
 const bytes=new Uint8Array(16384);let size=0;
 try{for(;;){const r=await reader.read();if(r.done)break;if(size+r.value.length>bytes.length)throw new Failure("INVALID_INPUT");bytes.set(r.value,size);size+=r.value.length;}}
 finally{await reader.cancel();}
 try{return strictJson(new TextDecoder("utf-8",{fatal:true}).decode(bytes.subarray(0,size)));}catch{throw new Failure("INVALID_INPUT");}
}
function ids(value:Record<string,unknown>,keys:string[]){
 if(keys.some(k=>typeof value[k]!=="string"||!uuid.test(value[k] as string)))throw new Failure("INVALID_INPUT");
}
function raw64(value:unknown){if(typeof value!=="string"||!/^[0-9a-f]{128}$/.test(value))throw new Failure("INVALID_ENCODING");return unhex(value,64);}
Deno.serve(async req=>{
 if(req.method!=="POST")return new Response(null,{status:405,headers:{...headers,Allow:"POST"}});
 try{
  const authorization=req.headers.get("authorization");if(!authorization?.startsWith("Bearer "))throw new Failure("NOT_AUTHORIZED");
  const expectedAccount=req.headers.get("X-Gasilko-Account");
  if(!expectedAccount||!uuid.test(expectedAccount))throw new Failure("NOT_AUTHORIZED");
  const input=object(await body(req),["action","organization","incident","operation","args"]);
  if(typeof input.action!=="string"||!uuid.test(input.organization)||!uuid.test(input.incident)||!uuid.test(input.operation))throw new Failure("INVALID_INPUT");
  const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!anon||!service)throw new Failure("BACKEND_UNAVAILABLE",true);
  const epoch=Deno.env.get("VEHICLE_LOCATION_RELEASE_EPOCH");
  const signal=AbortSignal.timeout(12000);
  // Actual live Auth user; never actor/role/policy fields from caller JSON.
  const auth=await fetch(url+"/auth/v1/user",{headers:{Authorization:authorization,apikey:anon},signal});
  if(!auth.ok){await auth.body?.cancel();throw new Failure(auth.status>=500?"BACKEND_UNAVAILABLE":"NOT_AUTHORIZED",auth.status>=500);}
  const user=await auth.json();if(typeof user.id!=="string"||!uuid.test(user.id)||user.id!==expectedAccount)throw new Failure("NOT_AUTHORIZED");
  async function rpc(name:string,args:Record<string,unknown>):Promise<any>{
   const r=await fetch(url+"/rest/v1/rpc/"+name,{method:"POST",signal,headers:{Authorization:"Bearer "+service,apikey:service!,
    "Content-Type":"application/json"},body:JSON.stringify({p_actor:user.id,p_epoch:epoch&&uuid.test(epoch)?epoch:null,p_org:input.organization,p_incident:input.incident,...args})});
   if(!r.ok){let e:any={};try{e=await r.json();}catch{}
    throw new Failure(e.code==="42501"?"NOT_AUTHORIZED":e.message==="VALIDATION_FAILED"?"INVALID_INPUT":/^22|^23/.test(e.code??"")?"INVALID_INPUT":safe.has(e.message)?e.message:"BACKEND_UNAVAILABLE",
     !safe.has(e.message)&&e.code!=="42501"&&!/^22|^23/.test(e.code??""));}
   if(r.status===204)return null;
   const text=await r.text();return text?JSON.parse(text):null;
  }
  const command=(action:string,args:unknown)=>rpc("vehicle_location_control",{p_action:action,p_operation:input.operation,p_payload:args});
  if(!["stop","revoke"].includes(input.action) && (!epoch||!uuid.test(epoch)))throw new Failure("CAPABILITY_DISABLED");
  if(!["stop","revoke"].includes(input.action))await rpc("vehicle_location_budget",{});
  let data:any;
  switch(input.action){
   case "context":object(input.args,[]);data=await rpc("vehicle_location_context",{});break;
   case "positions":object(input.args,[]);data=await rpc("vehicle_location_positions",{});break;
   case "register":{
    const x=object(input.args,["credential","deployment","vehicle","spki"]);
    if(![x.credential,x.deployment,x.vehicle].every(v=>typeof v==="string"&&uuid.test(v)))throw new Failure("INVALID_INPUT");
    await rpc("vehicle_location_context",{});
    if(typeof x.spki!=="string")throw new Failure("INVALID_ENCODING");
    const spki=unhex(x.spki,91);
    if(!x.spki.startsWith("3059301306072a8648ce3d020106082a8648ce3d03010703420004"))throw new Failure("INVALID_ENCODING");
    try{await crypto.subtle.importKey("spki",spki.buffer as ArrayBuffer,{name:"ECDSA",namedCurve:"P-256"},false,["verify"]);}
    catch{throw new Failure("PROOF_INVALID");}
    data=await command("REGISTER",{...x,keyHash:await sha256(spki)});break;
   }
   case "issue":{
    const x=object(input.args,["credential","confirmOperation"]);
    if(!uuid.test(x.credential)||!uuid.test(x.confirmOperation))throw new Failure("INVALID_INPUT");
    const context=await command("ISSUE_CONTEXT",x);
    if(context.issued){data=context.issued;break;}
    const prepared=await constructDeviceChallengeV1(context);
    data=await command("ISSUE",{...x,document:prepared.challenge,transcriptHash:prepared.transcriptSha256});break;
   }
   case "confirm":{
    const x=object(input.args,["challenge","signature"]);if(!uuid.test(x.challenge))throw new Failure("INVALID_INPUT");
    const signature=raw64(x.signature),signatureHash=await sha256(signature);
    const snapshot=await command("CLAIM",{challenge:x.challenge,signatureHash});
    if(snapshot.confirmed){data=snapshot.confirmed;break;}
    const c=snapshot.challenge;
    const verified=await verifyClaimedDeviceProofV1(snapshot,{protocolVersion:1,credentialId:c.credentialId,challengeId:c.challengeId,
     issueOperationId:c.issueOperationId,confirmOperationId:input.operation,signatureEncoding:"P1363_RAW64",
     signatureRaw:signature,transcript:encodeDeviceProofTranscriptV1(c)});
    // No caller-supplied verification flag or DB snapshot crosses this boundary.
    data=await command("FINALIZE",{challenge:x.challenge,claim:verified.claimId,
     transcriptHash:verified.evidence.transcriptSha256,signatureHash:verified.evidence.signatureSha256});break;
   }
   case "consent":object(input.args,["binding","policy","noticeHash","accepted"]);ids(input.args,["binding","policy"]);if(typeof input.args.noticeHash!=="string"||!/^[0-9a-f]{64}$/.test(input.args.noticeHash))throw new Failure("INVALID_INPUT");if(input.args.accepted!==true)throw new Failure("POLICY_UNAPPROVED");data=await command("CONSENT",input.args);break;
   case "start":{
    object(input.args,["binding","consent"]);ids(input.args,["binding","consent"]);
    const nonce=crypto.getRandomValues(new Uint8Array(32));
    const sessionContext=btoa(String.fromCharCode(...nonce)).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
    data=await command("START",{...input.args,sessionContext});break;
   }
   case "renew":object(input.args,["session"]);ids(input.args,["session"]);data=await command("RENEW",input.args);break;
   case "stop":object(input.args,["session","reason"]);ids(input.args,["session"]);if(!["USER_STOP","LEFT_VEHICLE","LOGOUT","PERMISSION_REVOKED","ERROR"].includes(input.args.reason))throw new Failure("INVALID_INPUT");data=await command("STOP",input.args);break;
   case "revoke":object(input.args,["credential","reason"]);ids(input.args,["credential"]);if(input.args.reason!=="OWNER_REQUEST")throw new Failure("INVALID_INPUT");data=await command("REVOKE",input.args);break;
   case "sample":{
    const x=object(input.args,["sample","signature"]),bytes=encodeLocationSample(x.sample),hash=await sha256(bytes),signature=raw64(x.signature);
    await requireSampleIdentity(x.sample);
    if(x.sample.sampleId!==input.operation)throw new Failure("INVALID_INPUT");
    const snapshot=await rpc("vehicle_location_sample",{p_sample:x.sample,p_hash:hash,p_commit:false});
    if(snapshot.ack){data=snapshot.ack;break;}
    await verifyLocationSample(x.sample,unhex(snapshot.spki,91),signature);
    data=(await rpc("vehicle_location_sample",{p_sample:x.sample,p_hash:hash,p_commit:true})).ack;break;
   }
   default:throw new Failure("INVALID_INPUT");
  }
  return result(data);
 }catch(e){
  if(e instanceof Failure)return failure(e.code,e.retryable);
  if(e instanceof Error&&["INVALID_INPUT","INVALID_LOCATION"].includes(e.message))return failure(e.message);
  // Never serialize errors/stack/request: signatures/coordinates/JWT stay private.
  const cryptoError=e instanceof Error&&["INVALID_ENCODING","INVALID_PUBLIC_KEY","INVALID_SIGNATURE","CREDENTIAL_MISMATCH","SCOPE_MISMATCH","TRANSCRIPT_MISMATCH","EXPIRED"].includes(e.message);
  return failure(cryptoError?"PROOF_INVALID":"OUTCOME_UNKNOWN",!cryptoError);
 }
});
