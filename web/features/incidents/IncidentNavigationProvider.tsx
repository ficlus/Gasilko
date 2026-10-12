'use client';
import {createContext,useContext,useEffect,useRef,useState,type ReactNode} from 'react';
import type {Locale} from '../../lib/i18n';
import type {Position} from '../../lib/incidents/cop';
import type {TaskRead} from '../../lib/operational/tasks';
import {navigationErrors,type NavigationAssignment,type NavigationView,type NavigationRoute} from '../../lib/operational/navigation';
import {navigationText} from '../../lib/operational/navigationMessages';
import {typingTarget} from '../../lib/operational/rts';
import {useRtsSession} from './rtsSession';
import {useSimulation} from './SimulationProvider';
type Request={name:string;args:Record<string,unknown>;assignment:string;label:string};
type ContextValue={data:NavigationView|null;route:NavigationRoute|null;assignment:string|null;busy:boolean;pending:boolean;error:string;page:number;
 picking:boolean;candidate:Position|null;fit:number;history:boolean;select:(id:string|null)=>void;scopeUnit:(id:string|null)=>void;refresh:()=>void;
 pick:()=>void;point:(p:Position)=>void;cancelPick:()=>void;prepare:(source:'SIMULATED_POSITION'|'MANUAL_PLANNING_POINT')=>void;
 command:(action:string,replacement?:string)=>void;show:()=>void;older:()=>void;viewRoute:(id:string)=>void;current:()=>void;pageTo:(n:number)=>void;session:(id:string)=>void};
const Context=createContext<ContextValue|null>(null);
export const useIncidentNavigation=()=>useContext(Context);
export function IncidentNavigationProvider({account,org,incidentId,refresh:externalRefresh,locale,read,children}:{account:string;org:string;incidentId:string;refresh:number;locale:Locale;read:TaskRead;children:ReactNode}){
 const rts=useRtsSession(),sim=useSimulation(),t=navigationText(locale);
 const [assignment,setAssignment]=useState<string|null>(null),[unit,setUnit]=useState<string|null>(null),[sessionId,setSessionId]=useState<string|null>(null);
 const [data,setData]=useState<NavigationView|null>(null),[historic,setHistoric]=useState<NavigationRoute|null>(null),[page,setPage]=useState(0),[before,setBefore]=useState<number|null>(null),[epoch,setEpoch]=useState(0),[fit,setFit]=useState(0);
 const [picking,setPicking]=useState(false),[candidate,setCandidate]=useState<Position|null>(null),[error,setError]=useState('');
 const [proposal,setProposal]=useState<Request|null>(null),[pending,setPending]=useState<Request|null>(null),[busy,setBusy]=useState(false);
 const alive=useRef(true),sending=useRef(false),dialog=useRef<HTMLDialogElement>(null),routeRequest=useRef(0);
 const key='gasilko.navigation.pending.'+account+'.'+org+'.'+incidentId;
 const blocked=rts.locked||rts.blocked;
 function failure(e:unknown){
  const code=e instanceof Error?e.message:'SERVER';setError([...navigationErrors,'NOT_AUTHORIZED','EXPIRED','STALE_VERSION','OPERATION_REUSED','VALIDATION_FAILED','SIMULATION_DISABLED'].includes(code)?code:'SERVER');
  if(['NOT_AUTHORIZED','EXPIRED'].includes(code)){setData(null);setHistoric(null);setPicking(false);setCandidate(null);setProposal(null);setPending(null);rts.revoke();}
 }
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;routeRequest.current++;};},[]);
 useEffect(()=>{try{
  const raw=sessionStorage.getItem(key);if(raw&&raw.length<16000){const p=JSON.parse(raw) as Request;
   if(['incident_navigation_calculate','incident_navigation_command'].includes(p.name)&&p.assignment&&
    (p.args.p_incident_id===incidentId||(p.args.request as {incident_id?:string})?.incident_id===incidentId)){
    setPending(p);setProposal(p);setAssignment(p.assignment);
   }}
 }catch{}},[key,incidentId]);
 useEffect(()=>{
  const ac=new AbortController();setData(null);setHistoric(null);routeRequest.current++;
  if(blocked)return()=>ac.abort();
  void read<NavigationView>('incident_navigation_read',{p_organization_id:org,p_incident_id:incidentId,p_assignment_id:assignment,p_unit_id:unit,p_session_id:sessionId,p_page:page,p_before_revision:before},ac.signal,account)
   .then(v=>{if(!ac.signal.aborted)setData(v);}).catch(e=>{if(!ac.signal.aborted)failure(e);});
  return()=>ac.abort();
 },[account,org,incidentId,assignment,unit,sessionId,page,before,epoch,externalRefresh,read,blocked,sim?.data?.scenario?.version]);
 useEffect(()=>{rts.setNavigationEditing(picking||!!proposal||!!pending);return()=>rts.setNavigationEditing(false);},[picking,!!proposal,!!pending,rts.setNavigationEditing]);
 useEffect(()=>{if(blocked){setPicking(false);setCandidate(null);setHistoric(null);setData(null);}},[blocked]);
 useEffect(()=>{if(proposal)dialog.current?.showModal();return()=>dialog.current?.close();},[!!proposal]);
 function select(id:string|null){if(pending||busy||proposal)return;setAssignment(id);setPage(0);setSessionId(null);setHistoric(null);setBefore(null);setError('');setPicking(false);setCandidate(null);}
 function review(request:Request){if(blocked||busy||pending||rts.copEditing||sim?.move||sim?.proposal||rts.open||rts.agentEditing)return;setError('');setPicking(false);rts.cancelMode();setProposal(request);}
 const row=data?.rows.find(a=>a.id===assignment);
 function prepare(source:'SIMULATED_POSITION'|'MANUAL_PLANNING_POINT'){
  if(!row?.can_plan||(source==='MANUAL_PLANNING_POINT'&&!candidate))return;
  const current=data?.session,open=current&&['PLANNED','ACTIVE','PAUSED'].includes(current.status);
  review({name:'incident_navigation_calculate',assignment:row.id,label:t(open?'recalculate':'prepare'),args:{organization:org,request:{
   operation_id:crypto.randomUUID(),incident_id:incidentId,assignment_id:row.id,assignment_version:row.version,task_version:row.task_version,
   session_id:open?current.id:crypto.randomUUID(),version:open?current.version:'0',
   origin:source==='SIMULATED_POSITION'?{source}:{source,coordinate:candidate}
  }}});
 }
 function command(action:string,replacement?:string){
  if(!data?.session||!row)return;
  review({name:'incident_navigation_command',assignment:row.id,label:t(action),args:{p_organization_id:org,p_incident_id:incidentId,p_operation:crypto.randomUUID(),p_session_id:data.session.id,p_expected_version:data.session.version,p_action:action,p_replacement_id:replacement||null}});
 }
 async function send(request:Request){
  if(sending.current||blocked)return;sending.current=true;setBusy(true);setError('');setPending(request);
  try{sessionStorage.setItem(key,JSON.stringify(request));}catch{}
  try{
   await read(request.name,request.args,undefined,account);
   try{sessionStorage.removeItem(key);}catch{}
   if(!alive.current)return;setProposal(null);setPending(null);setCandidate(null);setHistoric(null);setSessionId(null);setBefore(null);setEpoch(v=>v+1);
  }catch(e){
   if(!alive.current)return;failure(e);
   const code=e instanceof Error?e.message:'SERVER';
   // Provider/transport/lease errors retain the exact durable operation. Explicit rejection requires new review.
   if([...navigationErrors.filter(c=>!['ROUTE_PROVIDER','ROUTE_CONFIGURATION','NAV_BUSY','NAV_LIMIT'].includes(c)),
    'NOT_AUTHORIZED','EXPIRED','STALE_VERSION','OPERATION_REUSED','VALIDATION_FAILED','SIMULATION_DISABLED'].includes(code)){
    setPending(null);setProposal(null);try{sessionStorage.removeItem(key);}catch{}setEpoch(v=>v+1);
   }
  }finally{sending.current=false;if(alive.current)setBusy(false);}
 }
 const value:ContextValue={data,route:historic??data?.session?.route??null,assignment,busy,pending:!!pending,error,page,picking,candidate,fit,history:!!historic,
 select,scopeUnit:id=>{if(pending||busy||proposal)return;setUnit(id);select(null);setPage(0);},
 refresh:()=>{setError('');setEpoch(v=>v+1);},pick:()=>{
  if(!row?.can_plan||blocked||pending||proposal||rts.externalEditing||rts.copEditing||rts.open||rts.mode!=='NORMAL')return;
  setCandidate(null);setPicking(true);rts.cancelMode();
 },point:p=>{if(picking&&!blocked)setCandidate(p);},cancelPick:()=>{setPicking(false);setCandidate(null);},prepare,command,
 show:()=>setFit(v=>v+1),older:()=>{const last=data?.history.at(-1);if(last)setBefore(last.revision);},
 viewRoute:id=>{
  const request=++routeRequest.current;void read<NavigationRoute>('incident_navigation_route',{p_organization_id:org,p_incident_id:incidentId,p_route_id:id},undefined,account)
   .then(r=>{if(alive.current&&request===routeRequest.current){setHistoric(r);setFit(v=>v+1);}}).catch(e=>{if(alive.current&&request===routeRequest.current)failure(e);});
 },current:()=>{routeRequest.current++;setHistoric(null);setBefore(null);},pageTo:setPage,session:id=>{setSessionId(id);setBefore(null);}};
 return <Context.Provider value={value}><div onKeyDownCapture={e=>{
  if(e.key==='Escape'&&picking&&!typingTarget(e.target)&&!e.nativeEvent.isComposing){e.preventDefault();e.stopPropagation();setPicking(false);setCandidate(null);}
 }}>{children}
 {proposal&&<dialog ref={dialog} className="simulation-dialog" onCancel={e=>{e.preventDefault();if(!pending&&!busy)setProposal(null);}}>
  <h3>{proposal.label}</h3><p>{row?.callsign} → {row?.target}</p><p>{t('planningNotice')}</p>
  <p>{t((proposal.args.request as {origin?:{source:string}})?.origin?.source??'title')}</p>
  {candidate&&<p>{candidate.join(', ')}</p>}{error&&<p role="alert">{t(error)}</p>}
  {pending&&<p>{t('pending')}</p>}
  <button disabled={busy||blocked} onClick={()=>void send(pending??proposal)}>{t(pending?'retry':'confirm')}</button>
  {!pending&&<button disabled={busy} onClick={()=>setProposal(null)}>{t('cancel')}</button>}
 </dialog>}
 </div></Context.Provider>;
}
