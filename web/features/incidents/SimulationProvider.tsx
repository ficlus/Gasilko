'use client';
import {createContext,useCallback,useContext,useEffect,useRef,useState,type ReactNode} from 'react';
import {workflowText} from '../../lib/operational/workflowMessages';
import {mapMetric} from '../../lib/operational/mapDiagnostics';
import type {Locale} from '../../lib/i18n';
import type {Position} from '../../lib/incidents/cop';
import type {TaskRead} from '../../lib/operational/tasks';
import {simulationErrors,type SimulationAction,type SimulationView,type SimulationSample} from '../../lib/operational/simulation';
import {simulationText} from '../../lib/operational/simulationMessages';
import {typingTarget} from '../../lib/operational/rts';
import {useIncidentLive} from './IncidentLiveProvider';
import {useRtsSession} from './rtsSession';

type Request={action:SimulationAction;args:{p_operation:string;p_acting_organization_id:string;p_incident_id:string;p_expected_version:string;p_action:SimulationAction;p_payload:Record<string,unknown>};summary:string};
type Move={unitId:string;positionVersion:string;longitude:string;latitude:string;heading:string;speed:string};
type Controller={unitsVisible:boolean;setUnitsVisible:(v:boolean)=>void;sample:SimulationSample|null;sampleStale:boolean;setMapActive:(active:boolean)=>void;data:SimulationView|null;error:string;busy:boolean;pending:boolean;proposal:Request|null;move:Move|null;before:string|null;
 refresh:()=>void;older:(sequence:string|null)=>void;propose:(action:SimulationAction,payload:Record<string,unknown>,summary:string)=>void;
 startMove:(move:Move)=>void;cancelMove:()=>void;pickPosition:(position:Position)=>void};
const Context=createContext<Controller|null>(null);
export const useSimulation=()=>useContext(Context);
export function SimulationBanner({locale}:{locale:Locale}){return <p className="simulation-banner" role="note"><strong>SIM · {simulationText(locale)('banner')}</strong></p>;}
export function SimulationProvider({account,org,incidentId,refresh:externalRefresh,locale,read,onInventoryChanged,children}:{account:string;org:string;incidentId:string;refresh:number;locale:Locale;read:TaskRead;onInventoryChanged:()=>void;children:ReactNode}){
 const live=useIncidentLive(),rts=useRtsSession(),t=simulationText(locale);
 const [data,setData]=useState<SimulationView|null>(null),[error,setError]=useState(''),[epoch,setEpoch]=useState(0),[before,setBefore]=useState<string|null>(null);
 const [proposal,setProposal]=useState<Request|null>(null),[pending,setPending]=useState<Request|null>(null),[busy,setBusy]=useState(false),[rejected,setRejected]=useState(false),[move,setMove]=useState<Move|null>(null);
 const [sample,setSample]=useState<SimulationSample|null>(null),[sampleStale,setSampleStale]=useState(false),[mapActive,setMapActive]=useState(false);
 const [unitsVisible,setUnitsVisible]=useState(true);
 const latestData=useRef(data);latestData.current=data;
 const lastSample=useRef<SimulationSample|null>(null);
 const fastRead=useCallback(async(signal:AbortSignal)=>{
  try{
   const started=performance.now();
   const value=await read<SimulationSample>('simulation_map_sample',{p_incident_id:incidentId,p_acting_organization_id:org},signal,account);
   if(signal.aborted||value.scenario_id!==latestData.current?.scenario?.id)return;
   const previous=lastSample.current;
   if(previous&&Date.parse(value.observed_at)<Date.parse(previous.observed_at))return;
   mapMetric('position_fetch',performance.now()-started,value.positions.length);
   for(const p of value.positions)mapMetric('position_age',Date.now()-Date.parse(p.observed_at));
   if(previous?.scenario_id===value.scenario_id){
    const positionKey=(rows:SimulationSample['positions'])=>rows.map(p=>[p.incident_unit_id,p.version,p.can_command,p.deployment_status,p.callsign,p.sector_id,p.organization_name].join(':')).join('|');
    const runKey=(rows:SimulationSample['runs'])=>rows.map(r=>r.id+':'+r.version+':'+r.position_version+':'+r.confirmed).join('|');
    if(positionKey(previous.positions)===positionKey(value.positions))value.positions=previous.positions;
    if(runKey(previous.runs)===runKey(value.runs))value.runs=previous.runs;
   }
   lastSample.current=value;setSample(value);setSampleStale(false);
  }catch(e){if(!signal.aborted||signal.reason instanceof DOMException&&signal.reason.name==='TimeoutError')setSampleStale(true);throw e;}
 },[account,org,incidentId,read]);
 useEffect(()=>{
  if(!mapActive||!data?.enabled||!data.scenario||data.scenario.status==='FINISHED'||rts.blocked)return;
  return live?.bindFastRefresh(fastRead);
 },[mapActive,data?.enabled,data?.scenario?.id,data?.scenario?.status,rts.blocked,live?.bindFastRefresh,fastRead]);
 useEffect(()=>{if(rts.blocked||live?.status==='ACCESS_LOST'){setSample(null);lastSample.current=null;setData(null);}},[rts.blocked,live?.status]);
 const alive=useRef(true),sending=useRef(false),dialog=useRef<HTMLDialogElement>(null);
 const key='gasilko.simulation.pending.'+account+'.'+org+'.'+incidentId;
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;};},[]);
 useEffect(()=>{
  try{const text=sessionStorage.getItem(key);if(text&&text.length<40000){const saved=JSON.parse(text) as Request;
   if(saved.args?.p_incident_id===incidentId&&saved.args.p_acting_organization_id===org&&['PROVISION','ATTACH','SET_POSITION','RESET_POSITION','REMOVE','START','PAUSE','RESUME','RESET','FINISH'].includes(saved.action)){setPending(saved);setProposal(saved);}
  }}catch{/* Optional browser storage; the in-memory request still supports exact retry. */}
 },[key,incidentId,org]);
 useEffect(()=>{
  const ac=new AbortController();
  if(rts.blocked||live?.status==='ACCESS_LOST')return()=>ac.abort();
  void read<SimulationView>('simulation_read',{p_incident_id:incidentId,p_acting_organization_id:org,p_before_sequence:before},ac.signal,account)
   .then(value=>{if(!ac.signal.aborted){setData(value);if(!value.enabled||!value.can_control)setMove(null);}})
   .catch(e=>{if(ac.signal.aborted)return;setMove(null);const code=e instanceof Error?e.message:'SERVER';setError(t(code)==code?'SERVER':code);
    if(['NOT_AUTHORIZED','EXPIRED'].includes(code)){setData(null);setSample(null);lastSample.current=null;setProposal(null);setPending(null);rts.revoke();}})
  return()=>ac.abort();
 },[account,org,incidentId,externalRefresh,epoch,before,read,live?.lastSuccess,rts.blocked,live?.status==='ACCESS_LOST']);
 useEffect(()=>{rts.setExternalEditing(!!move||!!proposal||!!pending);return()=>rts.setExternalEditing(false);},[!!move,!!proposal,!!pending,rts.setExternalEditing]);
 useEffect(()=>{if(proposal){dialog.current?.showModal();}return()=>dialog.current?.close();},[!!proposal]);
 useEffect(()=>{if(rts.locked)setMove(null);},[rts.locked]);
 function propose(action:SimulationAction,payload:Record<string,unknown>,summary:string){
  if(!data?.scenario||data.scenario.status==='FINISHED'||!data.can_control||!data.enabled||pending||busy||rts.locked||rts.navigationEditing||rts.agentEditing)return;
  rts.cancelMode();setMove(null);setError('');setRejected(false);
  setProposal({action,summary,args:{p_operation:crypto.randomUUID(),p_acting_organization_id:org,p_incident_id:incidentId,p_expected_version:data.scenario.version,p_action:action,p_payload:structuredClone(payload)}});
 }
 async function send(request:Request){
  const wasPending=!!pending;
  if(sending.current||!alive.current)return;sending.current=true;setBusy(true);setError('');setPending(request);
  try{const raw=JSON.stringify(request);sessionStorage.setItem(key,raw);if(sessionStorage.getItem(key)!==raw)throw new Error();}catch{sending.current=false;setBusy(false);setError('storage');return;}
  try{
   await read('simulation_command',request.args,undefined,account);
   try{sessionStorage.removeItem(key);}catch{}
   if(!alive.current)return;setPending(null);setProposal(null);setEpoch(v=>v+1);setBefore(null);setError('saved');
   onInventoryChanged();
  }catch(e){
   if(!alive.current)return;const code=e instanceof Error?e.message:'SERVER';
   const definitive=!wasPending&&(e as {outcome?:string}).outcome==='REJECTED';
   setError(t(code)===code?(definitive?'INVALID_SIMULATION_UNIT':'SERVER'):code);
   if(definitive){setPending(null);setRejected(true);try{sessionStorage.removeItem(key);}catch{}setEpoch(v=>v+1);}
   if(['NOT_AUTHORIZED','EXPIRED'].includes(code)){setData(null);setMove(null);rts.revoke();}
  }finally{sending.current=false;if(alive.current)setBusy(false);}
 }
 async function reconcile(){
  if(!pending||sending.current)return;sending.current=true;setBusy(true);
  try{
   const value=await read<{state:string}>('simulation_operation_resolve',{p_organization_id:org,p_name:'simulation_command',p_args:pending.args},undefined,account);
   if(!alive.current)return;
   if(value.state==='CONFIRMED'){try{sessionStorage.removeItem(key);}catch{}setPending(null);setProposal(null);setEpoch(v=>v+1);setBefore(null);setError('saved');onInventoryChanged();}
   else setError('pending');
  }catch{if(alive.current)setError('SERVER');}finally{sending.current=false;if(alive.current)setBusy(false);}
 }
 const currentSample=sample&&data?.scenario&&sample.scenario_id===data.scenario.id&&BigInt(sample.scenario_version)>=BigInt(data.scenario.version)?sample:null;
 const controller:Controller={unitsVisible,setUnitsVisible,sample:currentSample,sampleStale,setMapActive,data,error,busy,pending:!!pending,proposal,move,before,refresh:()=>{setError('');setEpoch(v=>v+1);},older:setBefore,propose,
  startMove:value=>{if(!data?.can_control||data.scenario?.status==='FINISHED'||!data.enabled||pending||proposal||rts.locked||rts.externalEditing||rts.copEditing||rts.mode!=='NORMAL'){setError('modeBusy');return;}rts.cancelMode();setMove(value);},
  cancelMove:()=>setMove(null),pickPosition:p=>{if(!move||rts.locked)return;propose('SET_POSITION',{unit_id:move.unitId,position_version:move.positionVersion,longitude:p[0],latitude:p[1],heading_degrees:Number(move.heading),speed_mps:Number(move.speed)},t('SET_POSITION')+'\n'+p.join(', '));}};
 return <Context.Provider value={controller}><div className="simulation-scope" onKeyDownCapture={e=>{
  if(e.key==='Escape'&&move&&!typingTarget(e.target)&&!e.nativeEvent.isComposing){e.preventDefault();e.stopPropagation();setMove(null);}
 }}>
  {data?.scenario&&<SimulationBanner locale={locale}/>}
  {children}
  {pending&&!proposal&&<section className="admin-notice"><p>{workflowText(locale)('OUTCOME_UNKNOWN')}</p><button onClick={()=>setProposal(pending)}>{t('retry')}</button></section>}
  {proposal&&<dialog ref={dialog} className="simulation-dialog" aria-label={t('confirm')} onCancel={e=>{e.preventDefault();if(!busy){setProposal(null);setRejected(false);}}}>
   <SimulationBanner locale={locale}/><h3>{t(proposal.action)}</h3><p className="incident-prose">{proposal.summary}</p>
   {proposal.action==='FINISH'&&<><p>{workflowText(locale)('finishWarning')}</p><p>{data?.scenario?.title} · {data?.positions.length} {t('positions')}</p></>}
   <p>{t('ack')}</p>{['RESET','RESET_POSITION','FINISH'].includes(proposal.action)&&<p>{t('resetWarning')}</p>}
   {error&&<p role="alert">{t(error)===error?workflowText(locale)(error):t(error)}</p>}
   {rejected?<><p>{t('STALE_VERSION')}</p><button disabled={busy||!data?.can_control||!data.scenario} onClick={()=>{
    if(!data?.scenario)return;const payload={...proposal.args.p_payload};
    if(typeof payload.unit_id==='string'){const position=data.positions.find(p=>p.incident_unit_id===payload.unit_id);if(!position){setError('INVALID_SIMULATION_UNIT');return;}payload.position_version=position.version;}
    propose(proposal.action,payload,proposal.summary);
   }}>{t('review')}</button><button onClick={()=>{setProposal(null);setRejected(false);}}>{t('cancel')}</button></>:pending?<><p>{t('pending')}</p><button disabled={busy} onClick={()=>void send(pending)}>{t('retry')}</button><button disabled={busy} onClick={()=>void reconcile()}>{workflowText(locale)('reconcile')}</button><button disabled={busy} onClick={()=>setProposal(null)}>{t('cancel')}</button></>:
    <div className="actions"><button disabled={busy} onClick={()=>void send(proposal)}>{t('confirm')}</button><button disabled={busy} onClick={()=>setProposal(null)}>{t('cancel')}</button></div>}
  </dialog>}
 </div></Context.Provider>;
}
