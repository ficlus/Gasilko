'use client';
import {createContext,useContext,useEffect,useRef,useState,type ReactNode} from 'react';
import type {Incident,Timeline} from '../../lib/incidents/model';
import type {TaskRead} from '../../lib/operational/tasks';

export type IncidentLiveDomain='INCIDENT'|'COP'|'TASKS'|'RESOURCES'|'NAVIGATION'|'SIMULATION'|'AGENTS'|'TIMELINE';
export type IncidentLiveNotification={id:string;eventCode:string;priority:'INFO'|'WARNING'|'CRITICAL';createdAt:string;entity?:{kind:'MAP_OBJECT'|'TASK'|'INCIDENT_UNIT';id:string};};
type Status='CONNECTING'|'LIVE'|'REFRESHING'|'OFFLINE'|'STALE'|'ACCESS_LOST';
type Live={status:Status;lastSuccess:number|null;notifications:IncidentLiveNotification[];unread:number;lowPriorityToasts:boolean;requestRefresh:()=>void;markSeen:()=>void;dismiss:(id:string)=>void;setLowPriorityToasts:(value:boolean)=>void;};
const Context=createContext<Live|null>(null);
export const useIncidentLive=()=>useContext(Context);
function priority(code:string):IncidentLiveNotification['priority']{
 return /NOT_AUTHORIZED|EXPIRED|CRITICAL/.test(code)?'CRITICAL':/FAILED|FAIL|BLOCKED|UNABLE|REJECTED/.test(code)?'WARNING':'INFO';
}
function entity(event:Timeline['events'][number]):IncidentLiveNotification['entity']|undefined{
 const data=event.data as typeof event.data&{entity_id?:string;task_id?:string;unit_assignment_id?:string};
 if(typeof data.entity_id==='string'&&/^MAP_OBJECT/.test(event.event_code))return {kind:'MAP_OBJECT',id:data.entity_id};
 if(typeof data.task_id==='string')return {kind:'TASK',id:data.task_id};
 if(typeof data.unit_assignment_id==='string')return {kind:'INCIDENT_UNIT',id:data.unit_assignment_id};
 return undefined;
}
/** Authoritative polling coordinator. Socket payloads are intentionally not operational state. */
export function IncidentLiveProvider({account,org,incidentId,read,onInvalidate,onAccessLost,children}:{account:string;org:string;incidentId:string;read:TaskRead;onInvalidate:()=>void;onAccessLost:()=>void;children:ReactNode}){
 const [status,setStatus]=useState<Status>('CONNECTING'),[lastSuccess,setLastSuccess]=useState<number|null>(null),[epoch,setEpoch]=useState(0);
 const [notifications,setNotifications]=useState<IncidentLiveNotification[]>([]),[unread,setUnread]=useState(0),[lowPriorityToasts,setLowPriorityToasts]=useState(true);
 const latest=useRef({onInvalidate,onAccessLost});latest.current={onInvalidate,onAccessLost};
 const revision=useRef<string|null>(null),cursor=useRef<string|null>(null),scope=useRef(''),successful=useRef(false);
 useEffect(()=>{
  const nextScope=account+':'+org+':'+incidentId;
  if(scope.current!==nextScope){scope.current=nextScope;revision.current=null;cursor.current=null;successful.current=false;setNotifications([]);setUnread(0);setLastSuccess(null);}
  let disposed=false,denied=false,inFlight=false,backoff=8000,timer:ReturnType<typeof setTimeout>|undefined,controller:AbortController|null=null;
  const schedule=(ms:number)=>{clearTimeout(timer);if(!disposed&&!denied)timer=setTimeout(()=>void refresh(),ms);};
  async function deriveNotifications(signal:AbortSignal){
   // Start at the initial authorized snapshot, then consume bounded forward pages.
   // The cursor survives reconnection and dismissal; no historical replay or growing ID cache.
   for(let page=0;page<4&&!signal.aborted;page++){
    const timeline=await read<Timeline|null>('incident_timeline_page',{p_acting_organization_id:org,p_incident_id:incidentId,p_after_sequence:cursor.current,p_limit:30},signal,account);
    if(disposed||signal.aborted)return;
    if(!timeline)throw new Error('NOT_AUTHORIZED');
    const events=timeline.events.filter(event=>BigInt(event.sequence)>BigInt(cursor.current??'0'));
    if(!events.length)return;
    const meaningful=events.filter(event=>!/SIMULATION_AGENT_(POSITION|TICK)|POSITION_SAMPLE/.test(event.event_code)).map(event=>({id:event.id||String(event.sequence),eventCode:event.event_code,priority:priority(event.event_code),createdAt:event.recorded_at,entity:entity(event)}));
    cursor.current=String(events[events.length-1].sequence);
    if(meaningful.length){setNotifications(current=>[...meaningful.reverse(),...current].slice(0,50));setUnread(current=>Math.min(99,current+meaningful.length));}
    if(events.length<30||BigInt(cursor.current)>=BigInt(timeline.high_watermark))return;
   }
  }
  async function refresh(){
   clearTimeout(timer);
   if(disposed||denied||inFlight||document.visibilityState!=='visible')return;
   if(!navigator.onLine){setStatus('OFFLINE');return;}
   inFlight=true;controller=new AbortController();const signal=controller.signal;
   const timeout=setTimeout(()=>controller?.abort(),15000);
   setStatus(successful.current?'REFRESHING':'CONNECTING');
   try{
    const snapshot=await read<Incident|null>('incident_context',{p_acting_organization_id:org,p_incident_id:incidentId},signal,account);
    if(disposed||signal.aborted)return;
    if(!snapshot)throw new Error('NOT_AUTHORIZED');
    const next=[snapshot.version,snapshot.revision,snapshot.timeline_sequence].join(':');
    const changed=revision.current!==null&&revision.current!==next;revision.current=next;
    if(cursor.current===null)cursor.current=String(snapshot.timeline_sequence);
    if(changed)latest.current.onInvalidate();
    await deriveNotifications(signal);
    if(disposed||signal.aborted)return;
    successful.current=true;setLastSuccess(Date.now());setStatus('LIVE');backoff=8000;
   }catch(error){
    if(disposed)return;
    const code=error instanceof Error?error.message:'SERVER';
    if(code==='NOT_AUTHORIZED'||code==='EXPIRED'){denied=true;setStatus('ACCESS_LOST');setNotifications([]);setUnread(0);latest.current.onAccessLost();return;}
    setStatus(navigator.onLine?'STALE':'OFFLINE');backoff=Math.min(30000,backoff*2);
   }finally{
    clearTimeout(timeout);inFlight=false;
    if(!disposed&&!denied){if(signal.aborted)setStatus(navigator.onLine?'STALE':'OFFLINE');if(document.visibilityState==='visible'&&navigator.onLine)schedule(backoff);}
   }
  }
  const visible=()=>{if(document.visibilityState==='visible'){backoff=8000;void refresh();}else{clearTimeout(timer);controller?.abort();setStatus('STALE');}};
  const online=()=>{backoff=8000;void refresh();};
  const offline=()=>{clearTimeout(timer);controller?.abort();setStatus('OFFLINE');};
  void refresh();document.addEventListener('visibilitychange',visible);window.addEventListener('online',online);window.addEventListener('offline',offline);
  return()=>{disposed=true;clearTimeout(timer);controller?.abort();document.removeEventListener('visibilitychange',visible);window.removeEventListener('online',online);window.removeEventListener('offline',offline);};
 },[account,org,incidentId,read,epoch]);
 const value:Live={status,lastSuccess,notifications,unread,lowPriorityToasts,requestRefresh:()=>setEpoch(value=>value+1),markSeen:()=>setUnread(0),dismiss:id=>setNotifications(current=>current.filter(note=>note.id!==id)),setLowPriorityToasts};
 return <Context.Provider value={value}>{children}</Context.Provider>;
}
