import type {Geometry} from '../incidents/cop';
export const scenarioEventTypes=['INCIDENT_REPORT','HAZARD_REVEAL','HAZARD_UPDATE','ACCESS_RESTRICTION','RESOURCE_REQUEST','COMMUNICATION_EVENT','PHASE_CHANGE'] as const;
export type ScenarioEventType=typeof scenarioEventTypes[number];
export type EventDefinition={
 id:string;type:ScenarioEventType;title:string;description:string;visibility:'COMMANDER';
 trigger:{mode:'SIMULATION_TIME'|'MANUAL'|'AFTER_EVENT';offset_seconds:number|null;event_id:string|null};
 effect:{geometry:Geometry|null;source_object_id:string|null;target_event_id:string|null;expected_version:number|null}|null;
};
export type EventPlan={schema_version:1;events:EventDefinition[]};
export const emptyEventPlan=():EventPlan=>({schema_version:1,events:[]});
export const geographicEvent=(type:ScenarioEventType)=>['HAZARD_REVEAL','HAZARD_UPDATE','ACCESS_RESTRICTION'].includes(type);
export function newEvent(title:string):EventDefinition{return {id:crypto.randomUUID(),type:'INCIDENT_REPORT',title,description:'',visibility:'COMMANDER',trigger:{mode:'SIMULATION_TIME',offset_seconds:0,event_id:null},effect:null};}
export type ScenarioEvent={
 id:string;type:ScenarioEventType;title:string;description:string;state:'PLANNED'|'BLOCKED'|'RETRYABLE_FAILURE'|'EXECUTED'|'CANCELLED';
 version:string;attempts:number;result:{error?:string;annotation_id?:string;annotation_version?:string;geometry?:Geometry;title?:string;description?:string;kind?:string;type?:string;cancelled?:boolean};
 executed_at:string|null;simulation_seconds:number|null;definition?:EventDefinition;ordinal?:number;blocked_reason?:string|null;
};
export type EventAnnotation={id:string;title:string;description:string;type:ScenarioEventType;version:string;geometry:Geometry;revealed_at:string};
export type ScenarioEvents={can_control:boolean;status:string;seconds:number;last_runner_at:string|null;last_event_scan_at:string|null;worker_stale:boolean;events:ScenarioEvent[];annotations:EventAnnotation[]};
export type EventHistory={id:string;event_id:string;version:string;operation_id:string;actor:string|null;origin:string;state:string;seconds:number;result:ScenarioEvent['result'];recorded_at:string};
export const scenarioEventRpcs=['simulation_scenario_events','simulation_scenario_event_command','simulation_scenario_event_history'] as const;
export const eventTime=(seconds:number)=>Math.floor(seconds/60).toString().padStart(2,'0')+':'+(seconds%60).toString().padStart(2,'0');
