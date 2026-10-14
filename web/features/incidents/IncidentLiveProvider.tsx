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
 const revision=useRef<string|null>(null),seen=useRef(new Set<string>()),first=useRef(true),request=useRef<AbortController|null>(null),backoff=useRef(8000),scope=useRef('');
 useEffect(()=>{
  const nextScope=account+':'+org+':'+incidentId;
  if(scope.current!==nextScope){scope.current=nextScope;revision.current=null;seen.current.clear();first.current=true;setNotifications([]);setUnread(0);setLastSuccess(null);setStatus(navigator.onLine?'CONNECTING':'OFFLINE');}
  let disposed=false,timer:ReturnType<typeof setTimeout>|undefined;
  const schedule=(ms:number)=>{clearTimeout(timer);if(!disposed)timer=setTimeout(()=>void refresh(),ms);};
  const eventId=(event:Timeline['events'][number])=>event.id||String(event.sequence);
  async function deriveNotifications(){
   const controller=new AbortController();
   try{
    const timeline=await read<Timeline>('incident_timeline_page',{p_acting_organization_id:org,p_incident_id:incidentId,p_after_sequence:0,p_limit:30},controller.signal,account);
    if(disposed)return;
    const next=timeline.events.filter(event=>!seen.current.has(eventId(event)));
    for(const event of timeline.events)seen.current.add(eventId(event));
    if(first.current){first.current=false;return;}
    const meaningful=next.filter(event=>!/SIMULATION_AGENT_(POSITION|TICK)|POSITION_SAMPLE/.test(event.event_code)).map(event=>({id:eventId(event),eventCode:event.event_code,priority:priority(event.event_code),createdAt:event.recorded_at,entity:entity(event)}));
    if(meaningful.length){setNotifications(current=>[...meaningful,...current].slice(0,50));setUnread(current=>Math.min(99,current+meaningful.length));}
   }catch{/* Notification derivation is best effort; later reads remain authoritative. */}
  }
  async function refresh(){
   if(disposed||document.visibilityState!=='visible')return;
   if(!navigator.onLine){setStatus('OFFLINE');return;}
   request.current?.abort();const controller=new AbortController();request.current=controller;setStatus(lastSuccess===null?'CONNECTING':'REFRESHING');
   try{
    const snapshot=await read<Incident|null>('incident_context',{p_acting_organization_id:org,p_incident_id:incidentId},controller.signal,account);
    if(disposed||controller.signal.aborted)return;
    if(!snapshot)throw new Error('NOT_AUTHORIZED');
    const next=[snapshot.version,snapshot.revision,snapshot.timeline_sequence].join(':');
    const changed=revision.current!==null&&revision.current!==next;revision.current=next;
    setLastSuccess(Date.now());setStatus('LIVE');backoff.current=8000;
    if(changed){latest.current.onInvalidate();void deriveNotifications();}
    else if(first.current)void deriveNotifications();
    schedule(8000);
   }catch(error){
    if(disposed||controller.signal.aborted)return;
    const code=error instanceof Error?error.message:'SERVER';
    if(code==='NOT_AUTHORIZED'||code==='EXPIRED'){setStatus('ACCESS_LOST');latest.current.onAccessLost();return;}
    setStatus(navigator.onLine?'STALE':'OFFLINE');backoff.current=Math.min(30000,Math.max(8000,backoff.current*2));schedule(backoff.current);
   }
  }
  const visible=()=>{if(document.visibilityState==='visible'){backoff.current=8000;void refresh();}};
  const online=()=>{backoff.current=8000;void refresh();};
  const offline=()=>{request.current?.abort();setStatus('OFFLINE');};
  void refresh();document.addEventListener('visibilitychange',visible);window.addEventListener('online',online);window.addEventListener('offline',offline);
  return()=>{disposed=true;clearTimeout(timer);request.current?.abort();document.removeEventListener('visibilitychange',visible);window.removeEventListener('online',online);window.removeEventListener('offline',offline);};
 },[account,org,incidentId,read,epoch]);
 const value:Live={status,lastSuccess,notifications,unread,lowPriorityToasts,requestRefresh:()=>setEpoch(value=>value+1),markSeen:()=>setUnread(0),dismiss:id=>setNotifications(current=>current.filter(note=>note.id!==id)),setLowPriorityToasts};
 return <Context.Provider value={value}>{children}</Context.Provider>;
}
