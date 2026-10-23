import type {Feature} from 'geojson';
import type {Position} from '../incidents/cop';
export type HazardEffect={type:'WIND'|'SPREAD'|'BOOST'|'IGNITE'|'ENABLE'|'REVEAL'|'STOP';value:unknown};
export type HazardModel={id:string;type:'STRUCTURE_FIRE'|'WILDFIRE';title:string;enabled:boolean;visibility:'START'|'HIDDEN';center:Position;radius_m:number;cell_m:25|50;wind_direction:number;wind_speed:number;fuel:number;moisture:number;spread:number;decline_seconds:number;
 origins:{id:string;position:Position;intensity:number;initial:boolean}[];blocked:Position[];
 zones:{id:string;kind:'HEAT_ZONE'|'SMOKE_ZONE'|'COLLAPSE_RISK'|'HAZARDOUS_MATERIAL'|'ACCESS_HAZARD';position:Position;radius_m:number}[];
 effects:{event_id:string;effect:HazardEffect}[]};
export type HazardPlan={schema_version:1;models:HazardModel[]};
export const emptyHazardPlan=():HazardPlan=>({schema_version:1,models:[]});
export type HazardRow={id:string;version:string;title:string;type:HazardModel['type'];step:number;features:Feature[];lag_steps:number;last_scan_at:string|null;error:string|null;enabled:boolean;wind_direction:number;wind_speed:number;burning:number;configuration?:HazardModel;revealed?:boolean;processing_ms?:number;pending_effects?:number};
export type HazardSnapshot={initialization_state?:string|null;can_control:boolean;status:string;seconds:number;models:HazardRow[]};
export const hazardRpcs=['simulation_hazards_read','simulation_hazard_command'] as const;
export function newHazard(center:Position,title:string):HazardModel{
 return {id:crypto.randomUUID(),type:'STRUCTURE_FIRE',title,enabled:true,visibility:'START',center,radius_m:100,cell_m:25,wind_direction:90,wind_speed:2,fuel:0.7,moisture:0.3,spread:1,decline_seconds:900,
 origins:[{id:crypto.randomUUID(),position:center,intensity:0.2,initial:true}],blocked:[],zones:[],effects:[]};
}
export function effectDefault(type:HazardEffect['type'],model:HazardModel):HazardEffect{
 return {type,value:type==='WIND'?{direction:model.wind_direction,speed:model.wind_speed}:type==='IGNITE'?model.origins[0]?.id??'':type==='ENABLE'?true:type==='SPREAD'?1:type==='BOOST'?0.2:null};
}
