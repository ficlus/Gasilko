'use client';
import {createContext,useCallback,useContext,useEffect,useRef,useState,type ReactNode} from 'react';
import {browserClient} from '../../lib/supabase/browser';
import type {RealtimeChannel} from '@supabase/supabase-js';
import type {Incident,Timeline} from '../../lib/incidents/model';
import type {TaskRead} from '../../lib/operational/tasks';

export type IncidentLiveDomain='INCIDENT'|'COP'|'TASKS'|'RESOURCES'|'NAVIGATION'|'SIMULATION'|'AGENTS'|'TIMELINE';
export type IncidentLiveNotification={id:string;eventCode:string;priority:'INFO'|'WARNING'|'CRITICAL';createdAt:string;entity?:{kind:'MAP_OBJECT'|'TASK'|'INCIDENT_UNIT';id:string};};
type Status='CONNECTING'|'LIVE'|'REFRESHING'|'OFFLINE'|'STALE'|'ACCESS_LOST'|'POLLING';
type FastRefresh=(signal:AbortSignal)=>Promise<void>;
type Live={bindFastRefresh:(refresh:FastRefresh)=>()=>void;status:Status;lastSuccess:number|null;notifications:IncidentLiveNotification[];unread:number;lowPriorityToasts:boolean;requestRefresh:()=>void;markSeen:()=>void;dismiss:(id:string)=>void;setLowPriorityToasts:(value:boolean)=>void;};
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
 const deniedScope=useRef(false),fast=useRef<FastRefresh|null>(null),[fastEpoch,setFastEpoch]=useState(0);
 const bindFastRefresh=useCallback((callback:FastRefresh)=>{
  fast.current=callback;setFastEpoch(v=>v+1);
  return()=>{if(fast.current===callback){fast.current=null;setFastEpoch(v=>v+1);}};
 },[]);
 // Both lanes belong to F4; one scoped batch, never one poller per unit.
 useEffect(()=>{
  if(!fast.current||status==='ACCESS_LOST')return;
  let disposed=false,inFlight=false,backoff=1000,timer:ReturnType<typeof setTimeout>|undefined;
  let controller:AbortController|null=null;
  const stop=()=>{clearTimeout(timer);controller?.abort();};
  async function tick(){
   clearTimeout(timer);
   if(disposed||deniedScope.current||inFlight||!fast.current||document.visibilityState!=='visible'||!navigator.onLine)return;
   inFlight=true;const ac=new AbortController();controller=ac;
   const timeout=setTimeout(()=>ac.abort(new DOMException('Position refresh timed out','TimeoutError')),5000);
   try{await fast.current(ac.signal);if(!ac.signal.aborted)backoff=1000;}
   catch(error){
    if(disposed)return;
    if(error instanceof Error&&['NOT_AUTHORIZED','EXPIRED','SIMULATION_DISABLED'].includes(error.message)){
     deniedScope.current=true;disposed=true;stop();setStatus('ACCESS_LOST');latest.current.onAccessLost();return;
    }
    backoff=Math.min(15000,backoff*2);
   }finally{
    clearTimeout(timeout);inFlight=false;
    if(!disposed&&!deniedScope.current&&document.visibilityState==='visible'&&navigator.onLine)timer=setTimeout(()=>void tick(),backoff);
   }
  }
  const resume=()=>{stop();if(document.visibilityState==='visible'&&navigator.onLine)void tick();};
  void tick();document.addEventListener('visibilitychange',resume);window.addEventListener('online',resume);window.addEventListener('offline',stop);
  return()=>{disposed=true;stop();document.removeEventListener('visibilitychange',resume);window.removeEventListener('online',resume);window.removeEventListener('offline',stop);};
 },[account,org,incidentId,fastEpoch,status==='ACCESS_LOST']);
 const latest=useRef({onInvalidate,onAccessLost});latest.current={onInvalidate,onAccessLost};
 const revision=useRef<string|null>(null),cursor=useRef<string|null>(null),simCursor=useRef<string|null>(null),scope=useRef(''),successful=useRef(false);
 useEffect(()=>{
  const nextScope=account+':'+org+':'+incidentId;
  if(scope.current!==nextScope){deniedScope.current=false;scope.current=nextScope;revision.current=null;cursor.current=null;simCursor.current=null;successful.current=false;setNotifications([]);setUnread(0);setLastSuccess(null);}
  let disposed=false,denied=false,inFlight=false,backoff=8000,timer:ReturnType<typeof setTimeout>|undefined,controller:AbortController|null=null;
  const client=browserClient();
  let channel:RealtimeChannel|null=null,joined=false,joinGeneration=0,retry=1000,dirty=false;
  let reconnectTimer:ReturnType<typeof setTimeout>|undefined,authTimer:ReturnType<typeof setTimeout>|undefined;
  let hintedRevision=0n,hintedSequence=0n,confirmedRevision=0n,confirmedSequence=0n;
  const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  const decimal=(v:unknown):v is string=>typeof v==='string'&&/^(0|[1-9][0-9]{0,18})$/.test(v)&&BigInt(v)<=9223372036854775807n;
  function closeChannel(){
   joinGeneration++;joined=false;clearTimeout(reconnectTimer);
   const old=channel;channel=null;if(old&&client)void client.removeChannel(old).catch(()=>{});
  }
  function hintRefresh(){
   if(disposed||deniedScope.current||denied)return;
   const queued=dirty;dirty=true;if(!inFlight&&!queued)schedule(750);
  }
  async function connect(){
   closeChannel();const generation=joinGeneration;
   if(!client||disposed||deniedScope.current||denied||document.visibilityState!=='visible'||!navigator.onLine)return;
   try{
    const {data,error}=await client.auth.getSession();
    if(disposed||generation!==joinGeneration)return;
    if(error||!data.session){setStatus('STALE');schedule(0);return;}
    if(data.session.user.id!==account){denyAccess();return;}
    await client.realtime.setAuth(data.session.access_token);
    if(disposed||generation!==joinGeneration)return;
    if(!uuid.test(incidentId)||!uuid.test(org))return;
    channel=client.channel('incident:'+incidentId+':org:'+org,{config:{private:true}});
    channel.on('broadcast',{event:'incident_changed'},({payload})=>{
     if(disposed||generation!==joinGeneration||deniedScope.current)return;
     if(!payload||typeof payload!=='object'||Array.isArray(payload)||Object.keys(payload).sort().join(',')!=='incident_id,revision,timeline_sequence')return;
     if(JSON.stringify(payload).length>512||payload.incident_id!==incidentId||!decimal(payload.revision)||!decimal(payload.timeline_sequence))return;
     const r=BigInt(payload.revision),t=BigInt(payload.timeline_sequence);
     if(r<=confirmedRevision&&t<=confirmedSequence)return;
     if(r<=hintedRevision&&t<=hintedSequence)return;
     hintedRevision=r>hintedRevision?r:hintedRevision;hintedSequence=t>hintedSequence?t:hintedSequence;
     hintRefresh();
    }).subscribe(state=>{
     if(disposed||generation!==joinGeneration||deniedScope.current)return;
     if(state==='SUBSCRIBED'){joined=true;setStatus('REFRESHING');hintRefresh();}
     else if(state==='CHANNEL_ERROR'||state==='TIMED_OUT'||state==='CLOSED'){
      closeChannel();setStatus(navigator.onLine?'STALE':'OFFLINE');hintRefresh();
      if(document.visibilityState==='visible'&&navigator.onLine){
       const wait=Math.min(30000,retry+Math.floor(Math.random()*Math.min(retry,1000)));retry=Math.min(30000,retry*2);
       reconnectTimer=setTimeout(()=>void connect(),wait);
      }
     }
    });
   }catch{if(!disposed&&generation===joinGeneration){setStatus('STALE');hintRefresh();
    reconnectTimer=setTimeout(()=>void connect(),Math.min(30000,retry));retry=Math.min(30000,retry*2);}}
  }
  function denyAccess(){
   deniedScope.current=true;denied=true;closeChannel();clearTimeout(authTimer);
   controller?.abort();setStatus('ACCESS_LOST');setNotifications([]);setUnread(0);latest.current.onAccessLost();
  }
  const auth=client?.auth.onAuthStateChange((event,session)=>{
   if(disposed)return;
   if(event==='SIGNED_OUT'||(session&&session.user.id!==account)){denyAccess();return;}
   if(event==='TOKEN_REFRESHED'||event==='SIGNED_IN'){
    closeChannel();clearTimeout(authTimer);authTimer=setTimeout(()=>{void connect();hintRefresh();},0);
   }
  });
  const schedule=(ms:number)=>{clearTimeout(timer);if(!disposed&&!denied)timer=setTimeout(()=>void refresh(),ms);};
  async function deriveNotifications(signal:AbortSignal){
   // Start at the initial authorized snapshot, then consume bounded forward pages.
   // The cursor survives reconnection and dismissal; no historical replay or growing ID cache.
   for(let page=0;page<4&&!signal.aborted;page++){
    const timeline=await read<Timeline|null>('incident_timeline_page',{p_acting_organization_id:org,p_incident_id:incidentId,p_after_sequence:cursor.current,p_limit:30},signal,account);
    if(disposed||deniedScope.current||signal.aborted)return;
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
   if(disposed||deniedScope.current||denied||inFlight||document.visibilityState!=='visible')return;
   if(!navigator.onLine){setStatus('OFFLINE');return;}
   dirty=false;inFlight=true;controller=new AbortController();const signal=controller.signal;
   const timeout=setTimeout(()=>controller?.abort(),15000);
   setStatus(successful.current?'REFRESHING':'CONNECTING');
   try{
    const snapshot=await read<Pick<Incident,'id'|'version'|'revision'|'timeline_sequence'|'training'>&{scope_fingerprint:string}|null>('incident_sync_head',{p_acting_organization_id:org,p_incident_id:incidentId},signal,account);
    if(disposed||deniedScope.current||signal.aborted)return;
    if(!snapshot)throw new Error('NOT_AUTHORIZED');
    if(!decimal(snapshot.revision)||!decimal(snapshot.timeline_sequence))throw new Error('SCHEMA_MISMATCH');
    if(BigInt(snapshot.revision)<confirmedRevision||BigInt(snapshot.timeline_sequence)<confirmedSequence)throw new Error('STALE');
    confirmedRevision=BigInt(snapshot.revision);confirmedSequence=BigInt(snapshot.timeline_sequence);
    const next=[snapshot.version,snapshot.revision,snapshot.timeline_sequence,snapshot.scope_fingerprint].join(':');
    const changed=revision.current!==null&&revision.current!==next;revision.current=next;
    if(cursor.current===null)cursor.current=String(snapshot.timeline_sequence);
    if(changed)latest.current.onInvalidate();
    setLastSuccess(Date.now()); // Context success must not depend on optional notification feeds.
    await deriveNotifications(signal);
    if(snapshot.training){
     const feed=await read<{cursor:string;events:{id:string;code:string;created_at:string;unit_id:string|null}[]}>('simulation_automation_feed',
      {p_incident:incidentId,p_organization_id:org,p_after:simCursor.current},signal,account);
     if(disposed||deniedScope.current||signal.aborted)return;
     simCursor.current=feed.cursor;
     if(feed.events.length){
      const notes=feed.events.map(event=>({id:event.id,eventCode:event.code,createdAt:event.created_at,priority:priority(event.code),
       entity:event.unit_id?{kind:'INCIDENT_UNIT' as const,id:event.unit_id}:undefined}));
      setNotifications(current=>[...notes.reverse(),...current].slice(0,50));setUnread(current=>Math.min(99,current+notes.length));
     }
    }
    if(disposed||deniedScope.current||signal.aborted)return;
    successful.current=true;
    const caughtUp=confirmedRevision>=hintedRevision&&confirmedSequence>=hintedSequence;
    setStatus(caughtUp?(joined?'LIVE':'POLLING'):'STALE');backoff=8000;
    if(joined&&caughtUp)retry=1000;
   }catch(error){
    if(disposed||deniedScope.current)return;
    const code=error instanceof Error?error.message:'SERVER';
    if(code==='NOT_AUTHORIZED'||code==='EXPIRED'){denyAccess();return;}
    setStatus(navigator.onLine?'STALE':'OFFLINE');backoff=Math.min(30000,backoff*2);
   }finally{
    clearTimeout(timeout);inFlight=false;
    if(!disposed&&!deniedScope.current&&!denied){if(signal.aborted)setStatus(navigator.onLine?'STALE':'OFFLINE');if(document.visibilityState==='visible'&&navigator.onLine)schedule(dirty?1500:backoff);}
   }
  }
  const visible=()=>{if(deniedScope.current)return;if(document.visibilityState==='visible'){backoff=8000;dirty=false;void connect();hintRefresh();}else{clearTimeout(timer);closeChannel();controller?.abort();setStatus('STALE');}};
  const online=()=>{backoff=8000;dirty=false;void connect();hintRefresh();};
  const offline=()=>{if(deniedScope.current)return;clearTimeout(timer);closeChannel();controller?.abort();setStatus('OFFLINE');};
  void connect();void refresh();document.addEventListener('visibilitychange',visible);window.addEventListener('online',online);window.addEventListener('offline',offline);
  return()=>{disposed=true;closeChannel();clearTimeout(authTimer);auth?.data.subscription.unsubscribe();clearTimeout(timer);controller?.abort();document.removeEventListener('visibilitychange',visible);window.removeEventListener('online',online);window.removeEventListener('offline',offline);};
 },[account,org,incidentId,read,epoch,status==='ACCESS_LOST']);
 const value:Live={bindFastRefresh,status,lastSuccess,notifications,unread,lowPriorityToasts,requestRefresh:()=>setEpoch(value=>value+1),markSeen:()=>setUnread(0),dismiss:id=>setNotifications(current=>current.filter(note=>note.id!==id)),setLowPriorityToasts};
 return <Context.Provider value={value}>{children}</Context.Provider>;
}
