import {withRoadProvider} from "./roadProvider.ts";
import {RoutingError,type Point} from "../plan-routes/provider.ts";
const point=(p:unknown):p is Point=>Array.isArray(p)&&p.length===2&&p.every(v=>typeof v==="number"&&Number.isFinite(v))&&Math.abs(p[0])<=180&&Math.abs(p[1])<=90;

/** Shared road calculation only. Caller must authorize the human request or leased SIM job. */
export async function calculateIncidentRoadRoute(origin:unknown,destination:unknown,signal:AbortSignal){
 if(!point(origin)||!point(destination))throw new RoutingError("ROUTE_COORDINATES");
 return await withRoadProvider(signal,async provider=>{
  const path=await provider.route([origin,destination],true);
  if(!Number.isFinite(path.distance)||path.distance<0||!Number.isFinite(path.seconds)||path.seconds<0||
   path.coordinates.length<2||!path.coordinates.every(point)||path.snapped.length!==2||!path.snapped.every(point))
   throw new RoutingError("ROUTE_PROVIDER",502);
  if(path.coordinates.length>50000)throw new RoutingError("ROUTE_LIMIT");
  const result={provider:provider.name,profile:"car",distance_m:path.distance,duration_s:path.seconds,
   geometry:{type:"LineString",coordinates:path.coordinates},steps:path.legs??null,snapped_origin:path.snapped[0],snapped_destination:path.snapped[1]};
  if(new TextEncoder().encode(JSON.stringify(result)).length>3_000_000)throw new RoutingError("ROUTE_LIMIT");
  return result;
 });
}
