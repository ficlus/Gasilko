import {NextResponse} from 'next/server';
import {serverClient} from '../../../../lib/supabase/server';
import {loadAccount} from '../../../../lib/auth/load';
import {publicConfig} from '../../../../lib/supabase/config';
export const dynamic='force-dynamic';
export const maxDuration=120;
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const headers={'Cache-Control':'private, no-store, max-age=0','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'};
const safe=new Set(['NOT_AUTHORIZED','ATTACHMENT_LIMIT','EXPIRED','OPERATION_REUSED','ATTACHMENT_NOT_READY','ATTACHMENT_REJECTED','ATTACHMENT_NOT_UPLOADED','ATTACHMENT_MALFORMED','ATTACHMENT_TOO_LARGE','ATTACHMENT_TYPE_UNSUPPORTED','STORAGE_TEMPORARILY_UNAVAILABLE']);
export async function POST(request:Request){
 if(request.headers.get('origin')!==new URL(request.url).origin)return NextResponse.json({error:'NOT_AUTHORIZED'},{status:403,headers});
 const client=await serverClient(),config=publicConfig();
 if(!client||!config||(await loadAccount(client)).state!=='ACTIVE')return NextResponse.json({error:'EXPIRED'},{status:401,headers});
 const {data:{user}}=await client.auth.getUser();
 if(!user||request.headers.get('X-Gasilko-Account')!==user.id)return NextResponse.json({error:'EXPIRED'},{status:401,headers});
 try{
  if(Number(request.headers.get('content-length'))>4096)throw new Error('VALIDATION_FAILED');
  const reader=request.body?.getReader();if(!reader)throw new Error('VALIDATION_FAILED');
  let size=0,text='';const decoder=new TextDecoder();
  try{while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>4096)throw new Error('VALIDATION_FAILED');text+=decoder.decode(value,{stream:true});}text+=decoder.decode();}finally{await reader.cancel();}
  const input=JSON.parse(text);
  if(!['verify','download'].includes(input.action)||!uuid.test(input.organization??'')||!uuid.test(input.incident??'')||!uuid.test(input.attachment??'')
   ||(input.action==='verify'&&!uuid.test(input.operation??'')))throw new Error('VALIDATION_FAILED');
  const {data:{session}}=await client.auth.getSession();
  if(!session||session.user.id!==user.id)return NextResponse.json({error:'EXPIRED'},{status:401,headers});
  const result=await fetch(config.url+'/functions/v1/incident-evidence',{method:'POST',cache:'no-store',
   signal:AbortSignal.any([request.signal,AbortSignal.timeout(105000)]),
   headers:{Authorization:'Bearer '+session.access_token,apikey:config.key,'Content-Type':'application/json'},body:JSON.stringify(input)});
  if(!result.ok){
   let code='STORAGE_TEMPORARILY_UNAVAILABLE';try{const body=await result.json();if(safe.has(body.error))code=body.error;}catch{}
   return NextResponse.json({error:code},{status:result.status,headers});
  }
  const outgoing=new Headers(headers);
  for(const name of ['Content-Type','Content-Length','Content-Disposition','Content-Security-Policy']){const value=result.headers.get(name);if(value)outgoing.set(name,value);}
  // Server-to-server stream, no arbitrary URL, no service-role key in Next/browser.
  return new Response(result.body,{headers:outgoing});
 }catch{return NextResponse.json({error:'STORAGE_TEMPORARILY_UNAVAILABLE'},{status:503,headers});}
}
