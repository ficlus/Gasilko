import type {Position} from '../incidents/cop';
export type NavigationOrigin={source:'SIMULATED_POSITION'|'ACTUAL_POSITION'|'MANUAL_PLANNING_POINT';coordinate:Position;scenario_id?:string;incident_unit_id?:string;version?:string;observed_at?:string;selected_by?:string};
export type NavigationAssignment={id:string;task_id:string;task_version:string;version:string;status:string;unit_id:string;callsign:string;label_sl:string;label_de:string;target:string|null;can_plan:boolean;can_execute:boolean;ack_ready:boolean;sim_available:boolean;session_id:string|null};
export type NavigationRoute={id:string;session_id:string;revision:number;origin_snapshot:NavigationOrigin;destination_snapshot:{target_type:string;target_entity_id:string|null;geometry:{type:'Point';coordinates:Position};label:string|null};provider:string;profile:string;distance_m:number;duration_s:number;route_geometry:{type:'LineString';coordinates:Position[]};snapped_origin:Position;snapped_destination:Position;calculated_at:string};
export type NavigationSession={id:string;task_assignment_id:string;incident_unit_id:string;status:string;effective_status:string;version:string;route:NavigationRoute;origin_stale:boolean};
export type NavigationView={rows:NavigationAssignment[];more:boolean;session:NavigationSession|null;history:Omit<NavigationRoute,'route_geometry'>[];replacements:{id:string;target:string|null}[];sessions:{id:string;status:string;created_at:string}[];events:{id:string;event_type:string;new_state:string;created_at:string;event_sequence:string}[]};
export const navigationReads=['incident_navigation_read','incident_navigation_route','incident_navigation_command','incident_navigation_calculate'];
export const navigationErrors=['NAV_INVALID_ASSIGNMENT','NAV_INVALID_TARGET','NAV_INVALID_STATE','NAV_POSITION_UNAVAILABLE','NAV_SESSION_EXISTS','NAV_ACTIVE_EXISTS','NAV_ACK_REQUIRED','NAV_LIMIT','NAV_BUSY','ROUTE_LIMIT','ROUTE_UNREACHABLE','ROUTE_CONFIGURATION','ROUTE_PROVIDER','ROUTE_COORDINATES'];
// Access-point separation is disclosed, never mistaken for a moved canonical object.
export function accessDistance(a:Position,b:Position):number{
 const rad=Math.PI/180,dlat=(b[1]-a[1])*rad,dlon=(b[0]-a[0])*rad;
 const h=Math.sin(dlat/2)**2+Math.cos(a[1]*rad)*Math.cos(b[1]*rad)*Math.sin(dlon/2)**2;
 return 6371008.8*2*Math.atan2(Math.sqrt(Math.min(1,h)),Math.sqrt(Math.max(0,1-h)));
}
