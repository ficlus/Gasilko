import {calculateIncidentRoadRoute} from "../_shared/incidentRoadRoute.ts";
import {RoutingError} from "../plan-routes/provider.ts";
// Dedicated training scheduler only. No browser or user-token entry point.
const headers = {'Content-Type':'application/json','Cache-Control':'no-store'};
const response = (body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers});
async function sameSecret(a:string,b:string){
 const encoder=new TextEncoder();
 const [x,y]=await Promise.all([crypto.subtle.digest('SHA-256',encoder.encode(a)),crypto.subtle.digest('SHA-256',encoder.encode(b))]);
 const aa=new Uint8Array(x),bb=new Uint8Array(y);let difference=0;
 for(let i=0;i<aa.length;i++)difference|=aa[i]^bb[i];
 return difference===0;
}
Deno.serve(async(request:Request)=>{
 if(request.method!=='POST')return response({error:'METHOD'},405);
 const secret=Deno.env.get('SIMULATION_RUNNER_SECRET'),url=Deno.env.get('SUPABASE_URL'),key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
 if(!secret||secret.length<32||!url||!key)return response({error:'CONFIGURATION'},503);
 const bearer=request.headers.get('authorization')??'';
 if(bearer.length>1024||!await sameSecret(bearer,'Bearer '+secret))return response({error:'NOT_AUTHORIZED'},403);
 if(Number(request.headers.get('content-length')??0)>2)return response({error:'INVALID_REQUEST'},400);
 const abort=new AbortController(),timeout=setTimeout(()=>abort.abort(),55000);
 async function rpc(name:string,args:unknown,signal:AbortSignal=abort.signal){
  const result=await fetch(url+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},
   body:JSON.stringify(args),signal});
  if(!result.ok)throw new Error('RUNNER_RPC');
  return await result.json();
 }
 const phases:Record<string,number>={},started=performance.now();
 try{
  const batch=await rpc('simulation_runner_batch',{}) as {scenario:string;tick:string;operation:string}[];
  let completed=0,failed=0;
  for(const row of batch.slice(0,5)){
   const result=await rpc('simulation_runner_tick',{p_scenario:row.scenario,p_tick:row.tick,p_operation:row.operation});
   if(result.error)failed++;else completed++;
  }
  phases.movement_ms=Math.round(performance.now()-started);
  const eventStart=performance.now();
  // Bounded transactional event work; failure must not starve H1 preparation.
  let events:unknown={error:'EVENT_BATCH_UNAVAILABLE'};
  try{events=await rpc('simulation_scenario_event_batch',{},AbortSignal.any([abort.signal,AbortSignal.timeout(3500)]));}catch{/* Retry only on a later runner invocation; no effect replay here. */}
  phases.events_ms=Math.round(performance.now()-eventStart);
  const hazardStart=performance.now();
  let hazards:unknown={error:'HAZARD_BATCH_UNAVAILABLE'};
  try{hazards=await rpc('simulation_hazard_batch',{},AbortSignal.any([abort.signal,AbortSignal.timeout(3500)]));}catch{/* Hazard failure cannot suppress movement/events or H1 planning. */}
  phases.hazards_ms=Math.round(performance.now()-hazardStart);
  const claimStart=performance.now();
  // Movement is processed first on every invocation. One leased route at most;
  // overlapping Cron requests can continue ticking while this request waits for the provider.
  let automation='IDLE';
  const job=await rpc('simulation_automation_claim',{}) as {id?:string;lease?:string;origin?:unknown;destination?:unknown;started?:boolean}|null;
  phases.claim_ms=Math.round(performance.now()-claimStart);
  if(job?.id&&job.lease){
   const providerStart=performance.now();
   let route:unknown=null,error:string|null=null;
   const planningSignal=AbortSignal.any([abort.signal,AbortSignal.timeout(20000)]);
   try{route=await calculateIncidentRoadRoute(job.origin,job.destination,planningSignal);}
   catch(e){error=planningSignal.aborted?'AUTO_TIMEOUT':e instanceof RoutingError?e.code:'ROUTE_PROVIDER';}
   phases.provider_ms=Math.round(performance.now()-providerStart);
   const commitStart=performance.now();
   const result=await rpc('simulation_automation_finish',{p_job:job.id,p_lease:job.lease,p_route:route,p_error:error});
   phases.commit_and_start_ms=Math.round(performance.now()-commitStart);automation=result.state;
  }else if(job?.started)automation='STARTED';
  return response({completed,failed,automation,events,hazards,phases:{...phases,total_ms:Math.round(performance.now()-started)}});
 }catch{return response({error:'RUNNER_UNAVAILABLE'},503);}
 finally{clearTimeout(timeout);}
});
