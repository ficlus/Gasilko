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
 const abort=new AbortController(),timeout=setTimeout(()=>abort.abort(),25000);
 async function rpc(name:string,args:unknown){
  const result=await fetch(url+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},
   body:JSON.stringify(args),signal:abort.signal});
  if(!result.ok)throw new Error('RUNNER_RPC');
  return await result.json();
 }
 try{
  const batch=await rpc('simulation_runner_batch',{}) as {scenario:string;tick:string;operation:string}[];
  let completed=0,failed=0;
  for(const row of batch.slice(0,5)){
   const result=await rpc('simulation_runner_tick',{p_scenario:row.scenario,p_tick:row.tick,p_operation:row.operation});
   if(result.error)failed++;else completed++;
  }
  return response({completed,failed});
 }catch{return response({error:'RUNNER_UNAVAILABLE'},503);}
 finally{clearTimeout(timeout);}
});
