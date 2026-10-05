import {serverClient} from '@/lib/supabase/server';
export async function POST(request:Request){
 const reply=(body:unknown,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'no-store'}});
 if(request.headers.get('origin')!==new URL(request.url).origin)return reply({error:'FORBIDDEN'},403);
 try{
  const raw=await request.text();if(raw.length>1024)return reply({error:'VALIDATION'},400);
  const body=JSON.parse(raw),client=await serverClient();if(!client)return reply({error:'SERVER'},503);
  const {data:{user},error}=await client.auth.getUser();if(error||!user)return reply({error:'EXPIRED'},401);
  const r=await client.functions.invoke('organization-invite',{body:{invitation:body.invitation,locale:body.locale}});
  if(r.error){let code='INVITE_DELIVERY';try{const response=r.error.context;if(response instanceof Response){const data=await response.json();if(['EXPIRED','FORBIDDEN','INVITE_CONFIGURATION'].includes(data.error))code=data.error;}}catch{/* No raw Auth response. */}
   return reply({error:code},code==='FORBIDDEN'?403:code==='EXPIRED'?401:502);}
  return reply({acknowledged:true});
 }catch{return reply({error:'INVITE_DELIVERY'},502);}
}
