export const agentErrors=['AUTO_TASK_ENDED','AUTO_SCENARIO_PAUSED','AUTO_MANUAL','AUTO_TIMEOUT','AUTO_RETRY_LIMIT','AUTO_INTERNAL','SIM_LIMIT','SIM_RATE_LIMIT','SIM_RUN_EXISTS','SIM_ROUTE_REQUIRED','SIM_ACCESS_GAP','SIM_STOP_BEFORE_EDIT','SIM_RUNNER_ERROR'];
export const agentProfiles=['NORMAL','SLOW_RESPONSE','NO_RESPONSE','BREAKDOWN','COMMUNICATION_LOSS','ROUTE_BLOCKED'] as const;
export const agentEvents=['SIM_BREAKDOWN','SIM_ROAD_BLOCKED','SIM_SIGNAL_LOSS','SIM_NO_RESPONSE','SIM_HOLD','SIM_RESUME'] as const;
export type AgentRun={id:string;incident_unit_id:string;task_assignment_id:string;navigation_session_id:string|null;route_id:string|null;
 status:string;behavior:string;profile:string;version:string;callsign:string;operational_status:string;navigation_status:string|null;target:string;
 progress_m:number;length_m:number;speed_mps:number;baseline_mps:number;acknowledged:boolean;started:boolean;failure:string|null;last_sim:number;
 configuration:Record<string,number>};
export type AgentAssignment={id:string;unit_id:string;callsign:string;behavior:string;label_sl:string;label_de:string;status:string;target:string;
 position_version:string;session_id:string|null;route_id:string|null;distance_m:number|null;duration_s:number|null;snapped_origin:[number,number]|null;access_gap:number|null;origin_current:boolean|null};
export type AgentView={automation:{enabled:boolean;profile:string;more:boolean;jobs:AutomationJob[]};can_control:boolean;clock:{seconds:number;scale:number;tick:string;version:string;last_tick_at:string|null;last_runner_at:string|null;last_error:string|null;behind:boolean};
 runs:AgentRun[];assignments:AgentAssignment[];more:boolean;signals:Record<string,string>;counts:{total:number;active:number;moving:number;waiting:number;blocked:number};
 events:{sequence:string;run_id:string|null;event_type:string;actor_origin:string;actor_user_id:string|null;sim_seconds:number;created_at:string;payload:Record<string,unknown>}[];
 injections:{id:string;run_id:string;event_type:string;trigger_type:string;trigger_value:number;duration:number;fired_at:number|null}[]};
export const terminalAgent=(r:AgentRun)=>['SIM_COMPLETED','SIM_CANCELLED','SIM_UNABLE'].includes(r.status);

export type AutomationJob={id:string;version:string;unit_id:string;callsign:string;task_id:string;assignment_id:string;behavior:string;profile:string;
 state:string;attempts:number;next_attempt_at:string;updated_at:string;error:string|null;detail:{distance_m?:number;snapped_origin?:[number,number]};
 session_id:string|null;run_id:string|null;run_state:string|null;navigation_state:string|null;route_id:string|null;
 distance_m:number|null;duration_s:number|null;remaining_s:number|null;position_version:string|null;label_sl:string;label_de:string;target:string|null};
