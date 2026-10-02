import {serverClient} from '@/lib/supabase/server';
// Same-origin authenticated bridge: no provider address or privileged key in Web.
export async function POST(request:Request){
 const reply=(body:unknown,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'no-store'}});
 if(request.headers.get('origin')!==new URL(request.url).origin)return reply({error:'FORBIDDEN'},403);
 try{
  if(Number(request.headers.get('content-length')??0)>2048)return reply({error:'VALIDATION'},400);
  const text=await request.text();if(text.length>2048)return reply({error:'VALIDATION'},400);
  const body=JSON.parse(text),c=await serverClient();if(!c)return reply({error:'SERVER'},503);
  const {data:{user},error}=await c.auth.getUser();if(error||!user)return reply({error:'EXPIRED'},401);
  if(!['ROUTE','ROUTE_REMAINING'].includes(body.request?.action))return reply({error:'VALIDATION'},400);
  const r=await c.functions.invoke('plan-routes',{body:{organization:body.organization,request:body.request,web:true}});
  if(r.error){let code='ROUTE_PROVIDER';try{const response=r.error.context;if(response instanceof Response){const data=await response.json();
   if(['ROUTE_LIMIT','ROUTE_UNREACHABLE','ROUTE_CONFIGURATION','ROUTE_PROVIDER','ROUTE_COORDINATES','ROUTE_ASSIGNMENTS','CONFLICT','EXPIRED','FORBIDDEN','VALIDATION'].includes(data.error))code=data.error;}}catch{/* Never return raw provider messages. */}
   return reply({error:code},code==='CONFLICT'?409:code==='FORBIDDEN'?403:code==='EXPIRED'?401:422);}
  return reply({acknowledged:true});
 }catch{return reply({error:'ROUTE_PROVIDER'},502);}
}
