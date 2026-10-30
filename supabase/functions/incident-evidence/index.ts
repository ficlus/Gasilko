// No SDK/dependency or new secret: same authenticated REST/Storage boundary as incident-navigation.
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const safe=new Set(['NOT_AUTHORIZED','ATTACHMENT_LIMIT','OPERATION_REUSED','VALIDATION_FAILED','ATTACHMENT_NOT_READY','ATTACHMENT_REJECTED','ATTACHMENT_NOT_UPLOADED','ATTACHMENT_MALFORMED','ATTACHMENT_TOO_LARGE','ATTACHMENT_TYPE_UNSUPPORTED','STORAGE_TEMPORARILY_UNAVAILABLE']);
class Failure extends Error {constructor(public code:string,public status=422){super(code);}}
const headers={'Cache-Control':'private, no-store, max-age=0','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'};
const reply=(error:string,status:number)=>new Response(JSON.stringify({error}),{status,headers:{...headers,'Content-Type':'application/json'}});
async function bounded(response:Request|Response,limit:number):Promise<Uint8Array>{
 const size=Number(response.headers.get('content-length'));
 if(size>limit){await response.body?.cancel();throw new Failure('ATTACHMENT_TOO_LARGE');}
 const reader=response.body?.getReader();if(!reader)throw new Failure('ATTACHMENT_MALFORMED');
 // Fixed cap avoids unbounded chunk accumulation. Only one object per invocation.
 const out=new Uint8Array(limit);let length=0;
 try{while(true){const {value,done}=await reader.read();if(done)break;
  if(length+value.length>limit)throw new Failure('ATTACHMENT_TOO_LARGE');out.set(value,length);length+=value.length;
 }}finally{await reader.cancel();}
 return out.subarray(0,length);
}
const ascii=(b:Uint8Array,start:number,end:number)=>new TextDecoder('latin1').decode(b.subarray(start,end));
function content(b:Uint8Array,mime:string):boolean{
 if(!b.length)return false;
 if(mime==='image/jpeg'){
  if(b.length<12||b[0]!==255||b[1]!==216||b[b.length-2]!==255||b[b.length-1]!==217)return false;
  let p=2,frame=false;
  while(p+3<b.length){
   if(b[p++]!==255)return false;while(b[p]===255)p++;const marker=b[p++];
   if(marker===218)return frame&&p+2<b.length; // Entropy stream: signature/structure, not a full decoder.
   if(marker===217)return false;
   const n=(b[p]<<8)|b[p+1];if(n<2||p+n>b.length)return false;
   if([192,193,194].includes(marker)){
    if(n<8)return false;const height=(b[p+3]<<8)|b[p+4],width=(b[p+5]<<8)|b[p+6];
    if(!height||!width||height*width>100_000_000)return false;frame=true;
   }p+=n;
  }return false;
 }
 if(mime==='image/webp'){
  if(b.length<20||ascii(b,0,4)!=='RIFF'||ascii(b,8,12)!=='WEBP')return false;
  const view=new DataView(b.buffer,b.byteOffset,b.byteLength);if(view.getUint32(4,true)+8!==b.length)return false;
  let p=12,image=false;
  while(p+8<=b.length){const tag=ascii(b,p,p+4),n=view.getUint32(p+4,true);
   if(!n||p+8+n>b.length)return false;
   if(tag==='VP8 '){if(n<10||b[p+11]!==157||b[p+12]!==1||b[p+13]!==42)return false;image=true;}
   if(tag==='VP8L'){if(n<5||b[p+8]!==47)return false;image=true;}
   if(tag==='ANIM'||tag==='ANMF')return false;
   p+=8+n+(n%2);
  }return image&&p===b.length;
 }
 if(mime==='application/pdf'){
  const head=ascii(b,0,8),tail=ascii(b,Math.max(0,b.length-2048),b.length);
  const match=/startxref\s+(\d+)\s+%%EOF\s*$/.exec(tail);
  return /^%PDF-[12]\.\d/.test(head)&&!!match&&Number(match[1])<b.length;
 }return false;
}
Deno.serve(async req=>{
 try{
  if(req.method!=='POST')return reply('VALIDATION_FAILED',405);
  const authorization=req.headers.get('authorization');
  if(!authorization?.startsWith('Bearer '))return reply('EXPIRED',401);
  const raw=await bounded(req,4096);let input:any;
  try{input=JSON.parse(new TextDecoder().decode(raw));}catch{throw new Failure('VALIDATION_FAILED');}
  if(!['verify','download'].includes(input.action)||!uuid.test(input.organization??'')||!uuid.test(input.incident??'')
   ||!uuid.test(input.attachment??'')||(input.action==='verify'&&!uuid.test(input.operation??'')))throw new Failure('VALIDATION_FAILED');
  const url=Deno.env.get('SUPABASE_URL'),anon=Deno.env.get('SUPABASE_ANON_KEY'),service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if(!url||!anon||!service)throw new Failure('STORAGE_TEMPORARILY_UNAVAILABLE',503);
  const signal=AbortSignal.timeout(90_000);
  const auth=await fetch(url+'/auth/v1/user',{headers:{Authorization:authorization,apikey:anon},signal});
  if(!auth.ok){await auth.body?.cancel();return reply(auth.status<500?'EXPIRED':'STORAGE_TEMPORARILY_UNAVAILABLE',auth.status<500?401:503);}
  const user=await auth.json();if(!uuid.test(user.id??''))return reply('EXPIRED',401);
  async function rpc(name:string,args:unknown,trusted=false){
   const r=await fetch(url+'/rest/v1/rpc/'+name,{method:'POST',signal,headers:{Authorization:trusted?'Bearer '+service:authorization!,apikey:trusted?service!:anon!,'Content-Type':'application/json'},body:JSON.stringify(args)});
   if(!r.ok){let x:any={};try{x=await r.json();}catch{}
    const code=x.code==='42501'?'NOT_AUTHORIZED':safe.has(x.message)?x.message:'STORAGE_TEMPORARILY_UNAVAILABLE';
    throw new Failure(code,code==='NOT_AUTHORIZED'?403:code==='ATTACHMENT_LIMIT'?429:r.status>=500?503:422);
   }return r.json();
  }
  const args={p_acting_organization_id:input.organization,p_incident_id:input.incident,p_attachment_id:input.attachment,p_upload:input.action==='verify'};
  const item=await rpc('incident_attachment_access',args);
  const extension=item.mime==='image/jpeg'?'jpg':item.mime==='image/webp'?'webp':item.mime==='application/pdf'?'pdf':null;
  // Derive again; never proxy any caller-provided URL or metadata path.
  const path=input.incident+'/'+input.attachment+'/original.'+extension;
  if(!extension||item.bucket!=='incident-evidence'||item.path!==path||item.id!==input.attachment||item.incident_id!==input.incident)throw new Failure('VALIDATION_FAILED');
  if(input.action==='verify'&&item.status==='READY')return new Response(JSON.stringify({data:item}),{headers:{...headers,'Content-Type':'application/json'}});
  if(input.action==='verify'&&item.status==='REJECTED')throw new Failure('ATTACHMENT_REJECTED');
  if(input.action==='verify'&&item.object_exists===false)throw new Failure('ATTACHMENT_NOT_UPLOADED',409);
  const stored=await fetch(url+'/storage/v1/object/authenticated/incident-evidence/'+path,{signal,headers:{Authorization:'Bearer '+service,apikey:service,'Cache-Control':'no-cache'}});
  if(!stored.ok){await stored.body?.cancel();throw new Failure(stored.status===404?'ATTACHMENT_NOT_UPLOADED':'STORAGE_TEMPORARILY_UNAVAILABLE',stored.status===404?409:503);}
  let bytes:Uint8Array|undefined,hash:string|undefined,error:string|null=null;
  try{
   bytes=await bounded(stored,item.mime==='application/pdf'?20971520:10485760);
   if(bytes.length!==Number(item.size)||!content(bytes,item.mime))throw new Failure('ATTACHMENT_MALFORMED');
   hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes.slice().buffer as ArrayBuffer))).map(x=>x.toString(16).padStart(2,'0')).join('');
   if(input.action==='verify'&&hash!==item.declared_sha256)throw new Failure('ATTACHMENT_MALFORMED');
  }catch(e){if(!(e instanceof Failure))throw e;error=e.code;}
  if(input.action==='verify'){
   const result=await rpc('incident_attachment_commit',{p_actor:user.id,p_org:input.organization,p_incident:input.incident,
    p_attachment:input.attachment,p_operation:input.operation,p_mime:item.mime,p_size:bytes?.length??0,p_sha256:hash??null,p_error:error},true);
   return new Response(JSON.stringify({data:result}),{headers:{...headers,'Content-Type':'application/json'}});
  }
  if(error||!bytes||hash!==item.sha256)throw new Failure('ATTACHMENT_MALFORMED');
  // A second live check after byte retrieval prevents late fetch from bypassing known narrowing.
  const current=await rpc('incident_attachment_access',args);
  if(current.sha256!==hash||current.status!=='READY')throw new Failure('ATTACHMENT_NOT_READY');
  return new Response(bytes as BodyInit,{headers:{...headers,'Content-Type':item.mime,
   'Content-Length':String(bytes.length),'Content-Disposition':'attachment; filename="evidence-'+input.attachment+'.'+extension+'"',
   'Content-Security-Policy':"sandbox; default-src 'none'"}});
 }catch(error){return error instanceof Failure?reply(error.code,error.status):reply('STORAGE_TEMPORARILY_UNAVAILABLE',503);}
});
