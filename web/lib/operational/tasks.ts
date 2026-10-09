import type {Locale} from '../i18n';
import {taskText} from './taskMessages';
import type {OperationalTarget} from './target';
import type {Geometry} from '../incidents/cop';
export const nativeBehaviors=['NONE','MOVE_TO','HOLD_POSITION','WITHDRAW_TO','REQUEST_STATUS'] as const;
export const recipientTypes=['INCIDENT_UNIT','INCIDENT_CREW_MEMBER'] as const;
export const targetTypes=['NONE','HYDRANT','INCIDENT_MAP_OBJECT','INCIDENT_SECTOR','COORDINATE'] as const;
export const parameterTypes=['TEXT','INTEGER','DECIMAL','BOOLEAN','CHOICE'] as const;
export type TaskTarget=OperationalTarget|{kind:'NONE'};
export type Parameter={code:string;label_sl:string;label_de:string;type:typeof parameterTypes[number];required:boolean;sort_order:number;min?:number;max?:number;max_length?:number;options?:{code:string;label_sl:string;label_de:string}[]};
export type ActionConfiguration={id?:string;version_number?:string;native_behavior:typeof nativeBehaviors[number];label_sl:string;label_de:string;description_sl:string;description_de:string;default_priority:string;requires_acknowledgement:boolean;active_for_new_commands:boolean;recipient_types:string[];target_types:string[];parameter_definitions:Parameter[]};
export type ActionDefinition={id:string;owner_organization_id:string|null;code:string;active:boolean;version:string;configuration:ActionConfiguration};
export type Recipient={id:string;type:typeof recipientTypes[number];name:string;organization_id:string;organization_name:string;sector_id:string|null};
export type Task={id:string;incident_id:string;configuration:ActionConfiguration;version:string;priority:string;title:string|null;notes:string|null;status:string;outcome:string|null;issued_at:string;issuer_name:string;organization_name:string;target_type:TaskTarget['kind'];target_entity_id:string|null;target_label_snapshot:string|null;target_geometry_snapshot:Geometry|null;parameters:Record<string,unknown>};
export type TaskAssignment={id:string;recipient_type:string;recipient_name:string;status:string;version:string;blocked_reason:string|null;unable_reason:string|null;can_execute:boolean;can_cancel:boolean;acknowledged_at:string|null;started_at:string|null;blocked_at:string|null;completed_at:string|null;unable_at:string|null;cancelled_at:string|null};
export type TaskDetail=Task&{assignments:TaskAssignment[];can_cancel:boolean};
export type TaskPage<T>={rows:T[];more:boolean};
export type TaskRead=<T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,account?:string)=>Promise<T>;
export const taskMutations=['issue_task','transition_task_assignment','cancel_task'] as const;
export const taskErrors=['INVALID_ACTION_DEFINITION','INVALID_ACTION_PARAMETERS','INVALID_TASK_TARGET','TASK_POINT_REQUIRED','INVALID_TASK_RECIPIENT','INVALID_TASK_TRANSITION','TASK_NOT_FOUND','TASK_LIMIT_REACHED','UNRESOLVED_TASKS'] as const;
export const taskReads=['operational_action_catalog','incident_task_recipients','incident_tasks_page','incident_task_detail'];
export const actionCatalogReads=['operational_action_catalog'];
export const actionCatalogWrites=['operational_action_save'];
export const actionLabel=(configuration:ActionConfiguration,locale:string)=>locale==='de'?configuration.label_de:configuration.label_sl;
export const parameterLabel=(p:{label_sl:string;label_de:string},locale:string)=>locale==='de'?p.label_de:p.label_sl;
export function blankConfiguration():ActionConfiguration{return {native_behavior:'NONE',label_sl:'',label_de:'',description_sl:'',description_de:'',default_priority:'NORMAL',requires_acknowledgement:true,active_for_new_commands:true,recipient_types:['INCIDENT_UNIT','INCIDENT_CREW_MEMBER'],target_types:['NONE'],parameter_definitions:[]};}

const safeTaskErrors=new Set<string>([...taskErrors,'NOT_AUTHORIZED','EXPIRED','SERVER','STALE_VERSION','OPERATION_REUSED','VALIDATION_FAILED','INCIDENT_TERMINAL','INVALID_GEOMETRY','UNSUPPORTED_GEOMETRY','GEOMETRY_TOO_LARGE']);
/** Transport/JSON failures remain ambiguous; only explicit domain rejections end a retry. */
export function taskErrorCode(error:unknown):string{
 return error instanceof Error&&safeTaskErrors.has(error.message)?error.message:'SERVER';
}

export function parameterValueLabel(p:Parameter,value:unknown,locale:Locale):string{
 if(value===undefined||value===null)return '—';
 if(p.type==='CHOICE'){const option=p.options?.find(o=>o.code===value);return option?parameterLabel(option,locale):String(value);}
 if(p.type==='BOOLEAN')return taskText(locale)(value?'yes':'no');
 return String(value);
}
