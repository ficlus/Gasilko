import {browserClient} from '../supabase/browser';
import {dictionary,type Locale} from '../i18n';
import type {Row} from '../hydrants/admin';
import type {RoadGeometry} from '../mapGeometry';

export const planStates=['DRAFT','PLANNED','ACTIVE','COMPLETED','CANCELLED'] as const;
export type PlanState=typeof planStates[number];
export type Team={id:string;organization_id:string;name:string;active:boolean;organization_name:string;writable:boolean;member_count:number;plan_count:number};
export type TeamDetail={team:Team;revision:string;writable:boolean;member_count:number;members:{user_id:string;display_name:string;active:boolean}[];more:boolean;plans:{id:string;name:string;status:PlanState;updated_at:string}[]};
export type Plan={id:string;organization_id:string;organization_name:string;name:string;status:PlanState;version:number;writable:boolean;
 selection_mode:string;selection_snapshot:unknown;start_latitude:number|null;start_longitude:number|null;return_to_start:boolean;
 created_at:string;updated_at:string;started_at:string|null;completed_at:string|null;latest_activity:string|null;
 total:number;completed:number;skipped:number;unassigned:number;team_count:number;stale_routes:number;route_summary:Pick<Route,'team_id'|'provider'|'valid'|'calculated_at'>[]};
export type Item={id:string;hydrant_id:string;team_id:string|null;route_order:number|null;execution_version:number;inspection_id:string|null;
 completed_at:string|null;skipped_at:string|null;skip_reason:string|null;inspection_result:string|null;hydrant:Row;
 inspection:{id:string;mode:string;result:string;completed_at:string;notes:string|null;pressure_bar:number|null;flow_l_min:number|null}|null};
export type Route={team_id:string;provider:string;valid:boolean;calculated_at:string;distance_m:number;duration_s:number;geometry:RoadGeometry};
export type PlanDetail={plan:Plan;writable:boolean;limited:boolean;teams:(Pick<Team,'id'|'name'|'active'> & {total:number;completed:number;skipped:number;latest_activity:string|null})[];items:Item[];routes:Route[];
 history:{id:string;item_id:string;from_team_id:string;to_team_id:string;reason:string;actor:string|null;created_at:string}[];history_more:boolean;
 audit:{action:string;created_at:string;actor:string|null}[]};
export type Page<T>={rows:T[];more:boolean};
export class PlanningError extends Error{}
export async function planningRpc<T>(name:string,args:Record<string,unknown>):Promise<T>{
 const c=browserClient();if(!c)throw new PlanningError('SERVER');
 const {data,error,status}=await c.rpc(name,args);
 if(error){const m=error.message??'';throw new PlanningError(status===401?'EXPIRED':error.code==='42501'?'FORBIDDEN':
 /CONFLICT|ITEM_CHANGED/.test(m)?'CONFLICT':m==='ROUTE_ASSIGNMENTS_REQUIRED'?'ROUTE_ASSIGNMENTS':
 m==='TEAM_MEMBER_REQUIRED'?'TEAM_MEMBER_REQUIRED':/^22|^23/.test(error.code??'')?'VALIDATION':'SERVER');}
 return data as T;
}
export async function routePlan(organization:string,request:Record<string,unknown>){
 const response=await fetch('/api/plan-routes',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({organization,request})});
 const result=await response.json();if(!response.ok)throw new PlanningError(result.error??'SERVER');return result;
}
export function planningError(locale:Locale,error:unknown){
 const t=dictionary(locale),code=error instanceof PlanningError?error.message:'SERVER';
 return ({CONFLICT:t.pConflict,EXPIRED:t.hExpired,FORBIDDEN:t.hForbidden,VALIDATION:t.pValidation,TEAM_MEMBER_REQUIRED:t.pMemberRequired,
 ROUTE_LIMIT:t.pRouteLimit,ROUTE_UNREACHABLE:t.pRouteUnreachable,ROUTE_CONFIGURATION:t.pRouteConfiguration,ROUTE_PROVIDER:t.pRouteProvider,
 ROUTE_COORDINATES:t.pRouteCoordinates,ROUTE_ASSIGNMENTS:t.pRouteAssignments} as Record<string,string>)[code]??t.hServer;
}
export function stateLabel(t:ReturnType<typeof dictionary>,s:string){return ({DRAFT:t.pDraft,PLANNED:t.pPlanned,ACTIVE:t.pActive,COMPLETED:t.pCompleted,CANCELLED:t.pCancelled} as Record<string,string>)[s]??t.hMissing;}
export function providerLabel(t:ReturnType<typeof dictionary>,s:string){return s==='OSRM'?t.pOsrm:s==='GraphHopper'?t.pGraphHopper:t.hMissing;}
