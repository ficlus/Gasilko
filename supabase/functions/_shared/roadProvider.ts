// Shared provider policy; implementations and inspection-plan capacity remain unchanged.
import {GraphHopper,RoutingError,type RoadProvider} from "../plan-routes/provider.ts";
import {OsrmRoutingProvider} from "../plan-routes/osrm.ts";
export async function withRoadProvider<T>(signal:AbortSignal,calculate:(provider:RoadProvider)=>Promise<T>):Promise<T>{
 const base=Deno.env.get("OSRM_BASE_URL"),username=Deno.env.get("OSRM_USERNAME"),password=Deno.env.get("OSRM_PASSWORD"),key=Deno.env.get("GRAPHHOPPER_API_KEY");
 const providerSignal=()=>AbortSignal.any([signal,AbortSignal.timeout(45_000)]);
 if(base&&username&&password){
  try{return await calculate(new OsrmRoutingProvider(base,username,password,providerSignal()));}
  catch(error){
   if(!(error instanceof RoutingError)||error.code!=="ROUTE_PROVIDER"||!key||signal.aborted)throw error;
   return calculate(new GraphHopper(key,providerSignal()));
  }
 }
 if(base||username||password||!key)throw new RoutingError("ROUTE_CONFIGURATION",503);
 return calculate(new GraphHopper(key,providerSignal()));
}
