import type {Position} from '../incidents/cop';
export const simulationTemplates=['STRUCTURE_FIRE','WILDFIRE','TRAFFIC_ACCIDENT','SANDBOX'] as const;
export type SimulationTemplate=typeof simulationTemplates[number];
export type PositionOrigin='ACTUAL_GPS'|'SIMULATED';
export type TrainingLabel={id:string;title:string;status:string;version:string};
export type Scenario=TrainingLabel&{incident_id:string;organization_id:string;template:SimulationTemplate;seed:number;center_longitude:number;center_latitude:number;radius_m:number;event_sequence:string;created_by:string;updated_at:string};
export type SimulationPosition={scenario_id:string;incident_id:string;incident_unit_id:string;source:'SIMULATED';ordinal:number;initial_longitude:number;initial_latitude:number;longitude:number;latitude:number;heading_degrees:number;speed_mps:number;observed_at:string;version:string;callsign:string;name:string;organization_id:string;organization_name:string;sector_id:string|null;deployment_status:string;can_command:boolean};
export type SimulationEvent={id:string;sequence:string;event_type:string;incident_unit_id:string|null;payload:Record<string,unknown>;actor_user_id:string;created_at:string;operation_id:string};
export type SimulationView={enabled:boolean;scenario:Scenario|null;positions:SimulationPosition[];candidates:{id:string;name:string}[];events:SimulationEvent[];can_control:boolean;can_provision?:boolean;next_ordinal?:number;capacity_remaining?:number};
export type SimulationAction='PROVISION'|'ATTACH'|'SET_POSITION'|'RESET_POSITION'|'REMOVE'|'START'|'PAUSE'|'RESUME'|'RESET'|'FINISH';
export const simulationReads=['simulation_environment','simulation_labels','simulation_read','simulation_overview'];
export const simulationErrors=['SIMULATION_DISABLED','INVALID_SIMULATION_STATE','INVALID_SIMULATION_UNIT','INVALID_SIMULATION_POSITION','SIMULATION_LIMIT','SIMULATION_RESOURCE_DISABLED'];
export type SimulationSetup={id:string;template:SimulationTemplate;seed:number;radius_m:number};
export const defaultSimulationSetup=():SimulationSetup=>({id:crypto.randomUUID(),template:'STRUCTURE_FIRE',seed:1,radius_m:500});
/** Same bounded spherical placement as the SQL fixture generator. Never a road/GPS model. */
export function simulationInitialPosition(seed:number,template:SimulationTemplate,center:Position,radius:number,index:number):Position{
 const salt={STRUCTURE_FIRE:11,WILDFIRE:23,TRAFFIC_ACCIDENT:37,SANDBOX:53}[template];
 const x=((seed+index*104729+salt)*48271)%2147483647,y=((x+1)*48271)%2147483647;
 const bearing=2*Math.PI*x/2147483647,distance=radius*Math.sqrt(y/2147483647)/6371008.8;
 const lat=center[1]*Math.PI/180,lon=center[0]*Math.PI/180;
 const nextLat=Math.asin(Math.max(-1,Math.min(1,Math.sin(lat)*Math.cos(distance)+Math.cos(lat)*Math.sin(distance)*Math.cos(bearing))));
 const nextLon=(lon+Math.atan2(Math.sin(bearing)*Math.sin(distance)*Math.cos(lat),Math.cos(distance)-Math.sin(lat)*Math.sin(nextLat)))*180/Math.PI;
 return [nextLon-360*Math.floor((nextLon+180)/360),nextLat*180/Math.PI];
}
