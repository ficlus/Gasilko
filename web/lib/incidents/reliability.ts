/** D2 is read-only provenance, never a command result or field readiness claim. */
export type ReliabilitySample={source:string;completeness:'AVAILABLE'|'NOT_COLLECTED';count:number|null;cap:number;capped:boolean;last_at?:string|null;};
export type ReliabilitySummary={
 schema_version:1;account:string;acting_organization_id:string;incident_id:string;authority:'CURRENT_INCIDENT_CONTROLLER';
 as_of_server:string;window:'1h'|'24h'|'7d';mode:'REAL'|'TRAINING';version:string;revision:string;timeline_sequence:string;scope_fingerprint:string;
 own_receipts:ReliabilitySample;task_history:ReliabilitySample&{blocked_events:number|null;unable_events:number|null};
 task_transport:ReliabilitySample&{event_cap:number;sampled_events:number;transport_only:true;states:Record<'PENDING'|'LEASED'|'ACCEPTED'|'FAILED'|'SUPPRESSED',number>|null};
 not_collected:string[];
};
const decimal=(v:unknown)=>typeof v==='string'&&/^(0|[1-9][0-9]{0,18})$/.test(v)&&BigInt(v)<=9223372036854775807n;
const count=(v:unknown,cap:number)=>typeof v==='number'&&Number.isSafeInteger(v)&&v>=0&&v<=cap;
const timestamp=(v:unknown)=>typeof v==='string'&&/(?:Z|[+-]00:00)$/.test(v)&&Number.isFinite(Date.parse(v));
export function reliabilitySummary(value:unknown,account:string,org:string,incident:string,window:string):ReliabilitySummary {
 if(!value||typeof value!=='object')throw new Error('SCHEMA_UNAVAILABLE');
 const v=value as ReliabilitySummary;
 if(v.schema_version!==1||v.account!==account||v.acting_organization_id!==org||v.incident_id!==incident||
  v.authority!=='CURRENT_INCIDENT_CONTROLLER'||v.window!==window||!['REAL','TRAINING'].includes(v.mode)||
  !timestamp(v.as_of_server)||![v.version,v.revision,v.timeline_sequence].every(decimal)||
  typeof v.scope_fingerprint!=='string'||!/^[0-9a-f]{32}$/.test(v.scope_fingerprint))throw new Error('SCHEMA_UNAVAILABLE');
 for(const [sample,source,cap] of [[v.own_receipts,'CANONICAL_OWN_RECEIPTS',1000],
  [v.task_history,'CANONICAL_TASK_TIMELINE',1000],[v.task_transport,'M10_TASK_TRANSPORT',2000]] as const) {
  if(!sample||sample.source!==source||sample.cap!==cap||typeof sample.capped!=='boolean'||
   !['AVAILABLE','NOT_COLLECTED'].includes(sample.completeness)||
   (sample.completeness==='NOT_COLLECTED'?sample.count!==null:!count(sample.count,cap)||sample.count===0)||
   (sample.last_at!=null&&!timestamp(sample.last_at)))throw new Error('SCHEMA_UNAVAILABLE');
 }
 const history=v.task_history,transport=v.task_transport;
 if(history.count===null?(history.blocked_events!==null||history.unable_events!==null):
  (!count(history.blocked_events,history.count)||!count(history.unable_events,history.count)))throw new Error('SCHEMA_UNAVAILABLE');
 if(transport.transport_only!==true||transport.event_cap!==200||!count(transport.sampled_events,200))throw new Error('SCHEMA_UNAVAILABLE');
 const states=transport.states;
 if(transport.count===null) {
  if(states!==null)throw new Error('SCHEMA_UNAVAILABLE');
 } else if(!states||!(['PENDING','LEASED','ACCEPTED','FAILED','SUPPRESSED'] as const).every(k=>count(states[k],transport.count!))||
  Object.values(states).reduce((a,b)=>a+b,0)!==transport.count)throw new Error('SCHEMA_UNAVAILABLE');
 if(!Array.isArray(v.not_collected)||v.not_collected.length>12||v.not_collected.some(k=>typeof k!=='string'||k.length>50))throw new Error('SCHEMA_UNAVAILABLE');
 return v;
}
