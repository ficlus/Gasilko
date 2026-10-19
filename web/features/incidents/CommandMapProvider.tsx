'use client';
import {createContext,useContext,useEffect,useMemo,useRef,useState,type ReactNode} from 'react';
import type {TaskRead} from '../../lib/operational/tasks';
import type {Position} from '../../lib/incidents/cop';
import type {NavigationRoute} from '../../lib/operational/navigation';
import {routePath,type CommandMapRow,type MapPage,type RoutePath,type MapRun} from '../../lib/operational/commandMap';
import {mapMetric} from '../../lib/operational/mapDiagnostics';
import {useSimulation} from './SimulationProvider';
import {useIncidentLive} from './IncidentLiveProvider';
import {useRtsSession} from './rtsSession';
type Snapshot={removals:MapPage['removals'];rows:CommandMapRow[];paths:Map<string,RoutePath>;simulation:boolean;automation:boolean|null;limited:boolean;observedAt:string};
type Value={state:'loading'|'complete'|'incomplete'|'error'|'stale'|'revoked';data:Snapshot|null;error:boolean;visible:boolean;setVisible:(v:boolean)=>void;focus:{point:Position;sequence:number}|null;focusPoint:(p:Position)=>void;targets:string[];inspectTargets:(ids:string[])=>void};
const Context=createContext<Value|null>(null);
export const useCommandMap=()=>useContext(Context);
/** One bounded incident collection, driven by F4. No route timers or unit fan-out.
 * Only the visibility boolean is persisted; authorized DTOs stay in scoped memory. */
export function CommandMapProvider({account,org,incidentId,refresh,read,children}:{account:string;org:string;incidentId:string;refresh:number;read:TaskRead;children:ReactNode}){
 const live=useIncidentLive(),rts=useRtsSession(),sim=useSimulation();
 const [data,setData]=useState<Snapshot|null>(null),[error,setError]=useState(false),[visible,setShown]=useState(true);
 const [state,setState]=useState<Value['state']>('loading');
 const retry=useRef<(()=>void)|null>(null);
 const [targets,inspectTargets]=useState<string[]>([]);
 const [focus,setFocus]=useState<Value['focus']>(null);
 const request=useRef<AbortController|null>(null);
 const cache=useRef(new Map<string,{route:NavigationRoute;path:RoutePath}>());
 const progress=useRef(new Map<string,MapRun>());
 const key='gasilko.map.routes.'+account+'.'+org+'.'+incidentId;
 useEffect(()=>{setData(null);setState('loading');setError(false);cache.current.clear();progress.current.clear();setFocus(null);inspectTargets([]);setShown(true);
  try{setShown(sessionStorage.getItem(key)!=='off');}catch{}
 },[key]);
 useEffect(()=>{
  let disposed=false,dirty=false,revoked=false;
  if(rts.blocked||live?.status==='ACCESS_LOST'){setData(null);setState('revoked');cache.current.clear();progress.current.clear();return;}
  async function refreshMap(){
   if(disposed||revoked)return;dirty=true;
   if(request.current)return;
   if(document.visibilityState!=='visible'||!navigator.onLine){setState('stale');return;}
   dirty=false;const ac=new AbortController();request.current=ac;
   const timeout=setTimeout(()=>ac.abort(),60000),started=performance.now();

   try{
    const rows:CommandMapRow[]=[],paths=new Map<string,RoutePath>(),nextCache=new Map<string,{route:NavigationRoute;path:RoutePath}>(),nextProgress=new Map<string,MapRun>();
    let cursor:string|null=null,more=true,points=0,last:MapPage|null=null,limited=false,revision:string|null=null;
    for(let page=0;page<100&&more;page++){
     const result:MapPage=await read<MapPage>('incident_command_map_read',{p_organization_id:org,p_incident_id:incidentId,p_after:cursor,p_known_routes:[...cache.current.keys()]},ac.signal,account);
     if(ac.signal.aborted)return;
     if(!result.revision||revision!==null&&revision!==result.revision)throw Error('STALE_VERSION');
     revision=result.revision;last=result;
     for(const item of result.rows){
      if(rows.length>=1000){limited=true;break;}
      let route:NavigationRoute|null=null,run=item.run;
      if(item.route){
       const saved=cache.current.get(item.route.id);
       if(saved&&(saved.route.session_id!==item.session_id||saved.route.revision!==item.route.revision))throw Error('INVALID_GEOMETRY_IDENTITY');
       if(!item.route.route_geometry&&!saved)throw Error('MISSING_GEOMETRY');
       route=item.route.route_geometry?item.route as NavigationRoute:saved!.route;
       const path=saved?.path??routePath(route);
       if(points+path.points.length>250000){limited=true;break;}
       points+=path.points.length;paths.set(route.id,path);nextCache.set(route.id,{route,path});
       if(run?.route_id===route.id){
        const id=run.id+':'+route.id,previous=progress.current.get(id);
        if(previous&&BigInt(previous.version)>=BigInt(run.version))run=previous;
        const reported=run.confirmed!==false&&Number.isFinite(run.progress_m)?run.progress_m:previous?.progress_m??0;
        const meters=Math.min(path.length,Math.max(previous?.progress_m??0,reported));
        // Keep monotonic confirmed progress per run/immutable route. A newer but
        // inconsistent sample cannot rewind the line or invent a remaining ETA.
        run={...run,progress_m:meters,remaining_s:run.confirmed===false||meters>reported?null:run.remaining_s};
        nextProgress.set(id,run);
       }
      }
      rows.push({...item,route,run});
     }
     if(limited)break;
     more=result.more;if(more&&(!result.cursor||result.cursor===cursor))throw Error('INVALID_CURSOR');cursor=result.cursor;
     if(page===99&&more)limited=true;
    }
    if(ac.signal.aborted||!last)return;
    if(limited){setState('incomplete');setError(false);return;}
    const check=await read<MapPage>('incident_command_map_read',{p_organization_id:org,p_incident_id:incidentId,p_after:cursor,p_known_routes:[...nextCache.keys()]},ac.signal,account);
    if(ac.signal.aborted)return;if(check.revision!==revision)throw Error('STALE_VERSION');
    const removals=last.removals.filter(r=>cache.current.has(r.route_id)&&!nextCache.has(r.route_id));
    cache.current=nextCache;progress.current=nextProgress;setState('complete');
    mapMetric('collection',performance.now()-started,rows.length);

    setData({removals,rows,paths,simulation:last.simulation,automation:last.automation,limited,observedAt:last.observed_at});setError(false);
   }catch(e){
    if(disposed||ac.signal.aborted)return;setState('error');setError(true);
    if(e instanceof Error&&['NOT_AUTHORIZED','EXPIRED','SIMULATION_DISABLED'].includes(e.message)){revoked=true;setData(null);setState('revoked');cache.current.clear();progress.current.clear();inspectTargets([]);if(e.message!=='SIMULATION_DISABLED')rts.revoke();}
    }finally{
    clearTimeout(timeout);if(request.current===ac)request.current=null;
    if(!disposed&&ac.signal.aborted)setState('stale');
    if(!disposed&&!revoked&&dirty)void refreshMap();
   }
  }

  retry.current=()=>void refreshMap();void refreshMap();
  const resume=()=>{if(document.visibilityState==='visible'&&navigator.onLine)void refreshMap();else request.current?.abort();};
  document.addEventListener('visibilitychange',resume);window.addEventListener('offline',resume);window.addEventListener('online',resume);
  return()=>{disposed=true;retry.current=null;request.current?.abort();request.current=null;document.removeEventListener('visibilitychange',resume);window.removeEventListener('offline',resume);window.removeEventListener('online',resume);};
 },[account,org,incidentId,read,rts.blocked,live?.status==='ACCESS_LOST']);
 const runMembership=sim?.sample?.runs.map(r=>r.id+':'+r.route_id+':'+r.status).join('|');
 useEffect(()=>{retry.current?.();},[refresh,live?.lastSuccess,runMembership]);
 // Progress updates never change collection membership. Keep confirmed values on signal loss.
 const displayed=useMemo(()=>{
  if(!data||!sim?.sample||sim.sample.scenario_id!==sim.data?.scenario?.id)return data;
  const byAssignment=new Map(sim.sample.runs.map(run=>[run.assignment_id,run]));
  let changed=false;
  const rows=data.rows.map(row=>{
   const next=byAssignment.get(row.id),old=row.run;
   if(!next||!old||next.id!==old.id||next.unit_id!==row.unit_id||next.route_id!==row.route?.id||BigInt(next.version)<=BigInt(old.version))return row;
   const previous=progress.current.get(next.id+':'+next.route_id)??old;
   const meters=next.confirmed===false?previous.progress_m:Math.min(data.paths.get(next.route_id!)?.length??next.length_m,Math.max(previous.progress_m,next.progress_m));
   const run={...next,progress_m:meters,remaining_s:next.confirmed===false||meters>next.progress_m?null:next.remaining_s};
   progress.current.set(next.id+':'+next.route_id,run);
   changed=true;return {...row,run};
  });
  return changed?{...data,rows}:data;
 },[data,sim?.sample?.runs,sim?.sample?.scenario_id,sim?.data?.scenario?.id]);
 return <Context.Provider value={{data:displayed,state,error,visible,setVisible:v=>{setShown(v);try{sessionStorage.setItem(key,v?'on':'off');}catch{}},
 targets,inspectTargets,focus,focusPoint:point=>setFocus(v=>({point,sequence:(v?.sequence??0)+1}))}}>{children}</Context.Provider>;
}
