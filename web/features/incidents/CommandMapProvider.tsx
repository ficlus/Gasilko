'use client';
import {createContext,useContext,useEffect,useRef,useState,type ReactNode} from 'react';
import type {TaskRead} from '../../lib/operational/tasks';
import type {Position} from '../../lib/incidents/cop';
import type {NavigationRoute} from '../../lib/operational/navigation';
import {routePath,type CommandMapRow,type MapPage,type RoutePath,type MapRun} from '../../lib/operational/commandMap';
import {useIncidentLive} from './IncidentLiveProvider';
import {useRtsSession} from './rtsSession';
type Snapshot={rows:CommandMapRow[];paths:Map<string,RoutePath>;simulation:boolean;automation:boolean|null;limited:boolean;observedAt:string};
type Value={data:Snapshot|null;error:boolean;visible:boolean;setVisible:(v:boolean)=>void;focus:{point:Position;sequence:number}|null;focusPoint:(p:Position)=>void;targets:string[];inspectTargets:(ids:string[])=>void};
const Context=createContext<Value|null>(null);
export const useCommandMap=()=>useContext(Context);
/** One bounded incident collection, driven by F4. No route timers or unit fan-out.
 * Only the visibility boolean is persisted; authorized DTOs stay in scoped memory. */
export function CommandMapProvider({account,org,incidentId,refresh,read,children}:{account:string;org:string;incidentId:string;refresh:number;read:TaskRead;children:ReactNode}){
 const live=useIncidentLive(),rts=useRtsSession();
 const [data,setData]=useState<Snapshot|null>(null),[error,setError]=useState(false),[visible,setShown]=useState(true);
 const [targets,inspectTargets]=useState<string[]>([]);
 const [focus,setFocus]=useState<Value['focus']>(null);
 const request=useRef<AbortController|null>(null);
 const cache=useRef(new Map<string,{route:NavigationRoute;path:RoutePath}>());
 const progress=useRef(new Map<string,MapRun>());
 const key='gasilko.map.routes.'+account+'.'+org+'.'+incidentId;
 useEffect(()=>{setData(null);setError(false);cache.current.clear();progress.current.clear();setFocus(null);inspectTargets([]);setShown(true);
  try{setShown(sessionStorage.getItem(key)!=='off');}catch{}
 },[key]);
 useEffect(()=>()=>{request.current?.abort();request.current=null;},[key,rts.blocked,live?.status==='ACCESS_LOST']);
 useEffect(()=>{
  // Coalesce F4 invalidations while a bounded page sequence is in flight.
  // A normal eight-second refresh must not starve a larger route collection.
  if(request.current)return;
  const ac=new AbortController();
  if(rts.blocked||live?.status==='ACCESS_LOST'){setData(null);cache.current.clear();progress.current.clear();return;}
  request.current=ac;
  async function refreshMap(){
   try{
    const rows:CommandMapRow[]=[],paths=new Map<string,RoutePath>(),nextCache=new Map<string,{route:NavigationRoute;path:RoutePath}>(),nextProgress=new Map<string,MapRun>();
    let cursor:string|null=null,more=true,points=0,last:MapPage|null=null,limited=false;
    for(let page=0;page<100&&more;page++){
     const result:MapPage=await read<MapPage>('incident_command_map_read',{p_organization_id:org,p_incident_id:incidentId,p_after:cursor,p_known_routes:[...cache.current.keys()]},ac.signal,account);
     if(ac.signal.aborted)return;last=result;
     for(const item of result.rows){
      if(rows.length>=1000){limited=true;break;}
      let route:NavigationRoute|null=null,run=item.run;
      if(item.route){
       const saved=cache.current.get(item.route.id);
       if(!item.route.route_geometry&&!saved)throw Error('MISSING_GEOMETRY');
       route=item.route.route_geometry?item.route as NavigationRoute:saved!.route;
       const path=saved?.path??routePath(route);
       if(points+path.points.length>250000){limited=true;break;}
       points+=path.points.length;paths.set(route.id,path);nextCache.set(route.id,{route,path});
       if(run?.route_id===route.id){
        const id=run.id+':'+route.id,previous=progress.current.get(id);
        if(previous&&BigInt(previous.version)>=BigInt(run.version))run=previous;
        const reported=Number.isFinite(run.progress_m)?run.progress_m:0;
        const meters=Math.min(path.length,Math.max(previous?.progress_m??0,reported));
        // Keep monotonic confirmed progress per run/immutable route. A newer but
        // inconsistent sample cannot rewind the line or invent a remaining ETA.
        run={...run,progress_m:meters,remaining_s:meters>reported?null:run.remaining_s};
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
    cache.current=nextCache;progress.current=nextProgress;
    setData({rows,paths,simulation:last.simulation,automation:last.automation,limited,observedAt:last.observed_at});setError(false);
   }catch(e){
    if(ac.signal.aborted)return;setData(null);setError(true);
    if(e instanceof Error&&['NOT_AUTHORIZED','EXPIRED','SIMULATION_DISABLED'].includes(e.message)){cache.current.clear();progress.current.clear();inspectTargets([]);if(e.message!=='SIMULATION_DISABLED')rts.revoke();}
   }finally{if(request.current===ac)request.current=null;}
  }
  void refreshMap();
 },[account,org,incidentId,refresh,read,rts.blocked,live?.lastSuccess,live?.status==='ACCESS_LOST']);
 return <Context.Provider value={{data,error,visible,setVisible:v=>{setShown(v);try{sessionStorage.setItem(key,v?'on':'off');}catch{}},
 targets,inspectTargets,focus,focusPoint:point=>setFocus(v=>({point,sequence:(v?.sequence??0)+1}))}}>{children}</Context.Provider>;
}
