import type {Geometry,Position,MapKind} from '../incidents/cop';
export const templateCategories=['STRUCTURE_FIRE','WILDFIRE','TRAFFIC_ACCIDENT','SANDBOX'] as const;
export const templateProfiles=['NORMAL','SLOW_RESPONSE','NO_RESPONSE','BREAKDOWN','COMMUNICATION_LOSS','ROUTE_BLOCKED'] as const;
export type Definition={
 schema_version:1;
 metadata:{title:string;description:string;category:typeof templateCategories[number];difficulty:'BEGINNER'|'INTERMEDIATE'|'ADVANCED';objectives:string[];duration_minutes:number;initial_situation:string};
 world:{center:Position|null;incident_location:Position|null;radius_m:number};
 initial_objects:{id:string;kind:MapKind;label:string;description:string;geometry:Geometry|null}[];
 virtual_units:{id:string;kind:'OTHER';position:Position|null;heading:number}[];
 briefings:{commander:string;instructor:string};
 simulation_defaults:{clock_scale:1|5|10;automatic_execution:false;response_profile:typeof templateProfiles[number]};
};
export type Template={id:string;revision:string;builtin:boolean;archived:boolean;version_id:string;version:number;state:'DRAFT'|'PUBLISHED';definition:Definition};
export type TemplateRow=Omit<Template,'definition'>&{title:string;description:string;category:string};
export type Initialization={state:'WAITING_COMMAND'|'READY';scenario_version:string;incident_version:string;objects:number;units:number;clock_scale:number|null;response_profile:string|null;can_initialize:boolean};
export type TemplateRead=<T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,account?:string)=>Promise<T>;
export const templateRpcs=['simulation_template_list','simulation_template_read','simulation_template_command','simulation_template_initialization','simulation_template_initialize'] as const;
export function blankDefinition(title:string):Definition{
 return {schema_version:1,metadata:{title,description:'',category:'SANDBOX',difficulty:'BEGINNER',objectives:[],duration_minutes:30,initial_situation:''},
 world:{center:null,incident_location:null,radius_m:1000},initial_objects:[],virtual_units:[],briefings:{commander:'',instructor:''},
 simulation_defaults:{clock_scale:1,automatic_execution:false,response_profile:'NORMAL'}};
}
/** Suggested placements only, never GPS. Geodesic destination avoids latitude-dependent offsets. */
export function offsetPosition(center:Position,meters:number,bearing:number):Position{
 const r=Math.PI/180,lat=center[1]*r,lon=center[0]*r,a=meters/6371008.8,b=bearing*r;
 const y=Math.asin(Math.sin(lat)*Math.cos(a)+Math.cos(lat)*Math.sin(a)*Math.cos(b));
 const x=lon+Math.atan2(Math.sin(b)*Math.sin(a)*Math.cos(lat),Math.cos(a)-Math.sin(lat)*Math.sin(y));
 return [((x/r+540)%360)-180,y/r];
}
export function placeUnset(d:Definition,center:Position):Definition{
 return {...d,world:{...d.world,center,incident_location:d.world.incident_location??center},
 initial_objects:d.initial_objects.map((o,i)=>({...o,geometry:o.geometry??(o.kind==='PERIMETER'?null:{type:'Point',coordinates:offsetPosition(center,Math.min(100,d.world.radius_m/3),i*80)})})),
 virtual_units:d.virtual_units.map((u,i)=>({...u,position:u.position??offsetPosition(center,Math.min(150,d.world.radius_m/2),200+i*8)}))};
}
export function placementMissing(d:Definition){
 return !d.world.center||!d.world.incident_location||d.initial_objects.some(o=>!o.geometry)||d.virtual_units.some(u=>!u.position);
}
