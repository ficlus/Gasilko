import type {Geometry,Position} from '../incidents/cop';
import {accessDistance,type NavigationRoute} from './navigation';
export type MapRun={id:string;route_id:string|null;version:string;status:string;progress_m:number;length_m:number;remaining_s:number|null;sample:string};
export type CommandMapRow={id:string;task_id:string;unit_id:string;callsign:string;status:string;version:string;title:string|null;priority:string;label_sl:string;label_de:string;native_behavior:string;target:string|null;target_type:string;target_entity_id:string|null;target_geometry:Geometry|null;
 session_id:string|null;navigation_state:string|null;route:NavigationRoute|null;run:MapRun|null;automation:{id:string;state:string;error:string|null}|null};
export type MapPage={rows:(Omit<CommandMapRow,'route'>&{route:(Omit<NavigationRoute,'route_geometry'>&{route_geometry?:NavigationRoute['route_geometry']})|null})[];cursor:string|null;more:boolean;simulation:boolean;automation:boolean|null;observed_at:string};
export type RoutePath={points:Position[];cumulative:Float64Array;length:number};
/** Same sphere/ordered arc length as SIM agent_path. No nearest-segment search:
 * loops, crossings and reversed paths remain ordered by authoritative progress. */
export function routePath(route:NavigationRoute):RoutePath{
 const points=route.route_geometry.coordinates,cumulative=new Float64Array(points.length);
 if(points.length<2||points.length>50000||points.some(p=>p.length!==2||!Number.isFinite(p[0])||!Number.isFinite(p[1])||Math.abs(p[0])>180||Math.abs(p[1])>90))throw Error('INVALID_GEOMETRY');
 for(let i=1;i<points.length;i++)cumulative[i]=cumulative[i-1]+accessDistance(points[i-1],points[i]);
 return {points,cumulative,length:cumulative.at(-1)??0};
}
function interpolate(a:Position,b:Position,f:number,d:number):Position{
 const rad=Math.PI/180,arc=d/6371008.8;
 if(arc<1e-9||Math.abs(Math.sin(arc))<1e-9)return b;
 const aa=Math.sin((1-f)*arc)/Math.sin(arc),bb=Math.sin(f*arc)/Math.sin(arc);
 const x=aa*Math.cos(a[1]*rad)*Math.cos(a[0]*rad)+bb*Math.cos(b[1]*rad)*Math.cos(b[0]*rad);
 const y=aa*Math.cos(a[1]*rad)*Math.sin(a[0]*rad)+bb*Math.cos(b[1]*rad)*Math.sin(b[0]*rad);
 const z=aa*Math.sin(a[1]*rad)+bb*Math.sin(b[1]*rad);
 return [Math.atan2(y,x)/rad,Math.atan2(z,Math.hypot(x,y))/rad];
}
export function remainingPath(path:RoutePath,progress:number):Position[]{
 const {points,cumulative,length}=path,p=Math.max(0,Math.min(length,Number.isFinite(progress)?progress:0));
 if(p<=0)return points;
 if(p>=length)return []; // Arrived: destination stays visible; no fictitious residual line.
 let lo=1,hi=points.length-1;
 while(lo<hi){const mid=(lo+hi)>>>1;if(cumulative[mid]<p)lo=mid+1;else hi=mid;}
 while(lo<points.length-1&&cumulative[lo]-cumulative[lo-1]<1e-6)lo++;
 const d=cumulative[lo]-cumulative[lo-1],f=d<1e-6?1:Math.max(0,Math.min(1,(p-cumulative[lo-1])/d));
 return [interpolate(points[lo-1],points[lo],f,d),...points.slice(lo)];
}
