import {calculateIncidentRoadRoute} from "../_shared/incidentRoadRoute.ts";
import {RoutingError,type Point} from "../plan-routes/provider.ts";
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const point=(p:unknown):p is Point=>Array.isArray(p)&&p.length===2&&p.every(v=>typeof v==="number"&&Number.isFinite(v))&&Math.abs(p[0])<=180&&Math.abs(p[1])<=90;
const safe=new Set(["NOT_AUTHORIZED","EXPIRED","STALE_VERSION","OPERATION_REUSED","VALIDATION_FAILED","NAV_INVALID_ASSIGNMENT","NAV_INVALID_TARGET","NAV_INVALID_STATE","NAV_POSITION_UNAVAILABLE","NAV_SESSION_EXISTS","NAV_LIMIT","NAV_BUSY","SIMULATION_DISABLED","ROUTE_LIMIT","ROUTE_UNREACHABLE","ROUTE_CONFIGURATION","ROUTE_PROVIDER","ROUTE_COORDINATES"]);
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"Content-Type":"application/json","Cache-Control":"no-store"}});
async function bodyText(req:Request){
 const reader=req.body?.getReader();if(!reader)throw new RoutingError("VALIDATION_FAILED",400);
 const decoder=new TextDecoder();let text="",size=0;
 while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>8192){await reader.cancel();throw new RoutingError("VALIDATION_FAILED",400);}text+=decoder.decode(value,{stream:true});}
 return text+decoder.decode();
}
Deno.serve(async req=>{
 try{
  if(req.method!=="POST")return reply({error:"METHOD_NOT_ALLOWED"},405);
  const authorization=req.headers.get("authorization");if(!authorization?.startsWith("Bearer "))throw new RoutingError("EXPIRED",401);
  let body:any;try{body=JSON.parse(await bodyText(req));}catch(error){if(error instanceof RoutingError)throw error;throw new RoutingError("VALIDATION_FAILED",400);}
  const request=body?.request;
  if(!uuid.test(body?.organization??"")||!request||["operation_id","incident_id","assignment_id","session_id"].some(k=>!uuid.test(request[k]??"")))
   throw new RoutingError("VALIDATION_FAILED",400);
  const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!anon||!service)throw new RoutingError("ROUTE_CONFIGURATION",503);
  const signal=AbortSignal.timeout(100_000);
  const auth=await fetch(url+"/auth/v1/user",{headers:{Authorization:authorization,apikey:anon},signal});
  if(!auth.ok){await auth.body?.cancel();throw new RoutingError(auth.status===401||auth.status===403?"EXPIRED":"ROUTE_PROVIDER",auth.status===401||auth.status===403?401:503);}
  const user=await auth.json();if(!uuid.test(user.id??""))throw new RoutingError("EXPIRED",401);
  async function rpc(name:string,args:unknown,trusted=false):Promise<any>{
   const res=await fetch(url+"/rest/v1/rpc/"+name,{method:"POST",signal,headers:{Authorization:trusted?"Bearer "+service:authorization!,apikey:trusted?service!:anon!,"Content-Type":"application/json"},body:JSON.stringify(args)});
   if(!res.ok){let e:any={};try{e=await res.json();}catch{}const code=e.code==="42501"?"NOT_AUTHORIZED":safe.has(e.message)?e.message:/^22|^23/.test(e.code??"")?"VALIDATION_FAILED":"ROUTE_PROVIDER";throw new RoutingError(code,code==="NOT_AUTHORIZED"?403:code==="STALE_VERSION"?409:422);}
   const text=await res.text();return text?JSON.parse(text):null;
  }
  const prepared=await rpc("incident_navigation_prepare",{p_organization_id:body.organization,p_request:request});
  if(prepared.acknowledged)return reply({acknowledged:true,result:prepared.result});
  await rpc("incident_navigation_lease",{p_actor:user.id,p_operation:request.operation_id},true);
  const input=prepared.input,origin=input?.origin?.coordinate,destination=input?.destination?.geometry?.coordinates;
  if(!point(origin)||!point(destination))throw new RoutingError("ROUTE_COORDINATES");
  const route=await calculateIncidentRoadRoute(origin,destination,signal);
  const result=await rpc("incident_navigation_commit",{p_actor:user.id,p_organization_id:body.organization,p_request:request,p_input:input,p_route:route},true);
  // Geometry is read afterward through the current caller's scoped projection.
  return reply({acknowledged:true,result});
 }catch(error){return error instanceof RoutingError?reply({error:safe.has(error.code)?error.code:"ROUTE_PROVIDER"},error.status):reply({error:"ROUTE_PROVIDER"},502);}
});
