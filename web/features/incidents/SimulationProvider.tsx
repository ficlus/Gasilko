'use client';
import {createContext,useContext,useEffect,useRef,useState,type ReactNode} from 'react';
import type {Locale} from '../../lib/i18n';
import type {Position} from '../../lib/incidents/cop';
import type {TaskRead} from '../../lib/operational/tasks';
import {simulationErrors,type SimulationAction,type SimulationView} from '../../lib/operational/simulation';
import {simulationText} from '../../lib/operational/simulationMessages';
import {typingTarget} from '../../lib/operational/rts';
import {useRtsSession} from './rtsSession';

type Request={action:SimulationAction;args:{p_operation:string;p_acting_organization_id:string;p_incident_id:string;p_expected_version:string;p_action:SimulationAction;p_payload:Record<string,unknown>};summary:string};
type Move={unitId:string;positionVersion:string;longitude:string;latitude:string;heading:string;speed:string};
type Controller={data:SimulationView|null;error:string;busy:boolean;pending:boolean;proposal:Request|null;move:Move|null;before:string|null;
 refresh:()=>void;older:(sequence:string|null)=>void;propose:(action:SimulationAction,payload:Record<string,unknown>,summary:string)=>void;
 startMove:(move:Move)=>void;cancelMove:()=>void;pickPosition:(position:Position)=>void};
const Context=createContext<Controller|null>(null);
export const useSimulation=()=>useContext(Context);
export function SimulationBanner({locale}:{locale:Locale}){return <p className="simulation-banner" role="note"><strong>SIM · {simulationText(locale)('banner')}</strong></p>;}
export function SimulationProvider({account,org,incidentId,refresh:externalRefresh,locale,read,onInventoryChanged,children}:{account:string;org:string;incidentId:string;refresh:number;locale:Locale;read:TaskRead;onInventoryChanged:()=>void;children:ReactNode}){
 const rts=useRtsSession(),t=simulationText(locale);
 const [data,setData]=useState<SimulationView|null>(null),[error,setError]=useState(''),[epoch,setEpoch]=useState(0),[before,setBefore]=useState<string|null>(null);
 const [proposal,setProposal]=useState<Request|null>(null),[pending,setPending]=useState<Request|null>(null),[busy,setBusy]=useState(false),[rejected,setRejected]=useState(false),[move,setMove]=useState<Move|null>(null);
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
  void read<SimulationView>('simulation_read',{p_incident_id:incidentId,p_acting_organization_id:org,p_before_sequence:before},ac.signal,account)
   .then(value=>{if(!ac.signal.aborted){setData(value);if(!value.enabled||!value.can_control)setMove(null);}})
   .catch(e=>{if(ac.signal.aborted)return;setData(null);setMove(null);const code=e instanceof Error?e.message:'SERVER';setError(t(code)==code?'SERVER':code);
    if(['NOT_AUTHORIZED','EXPIRED'].includes(code)){setProposal(null);setPending(null);rts.revoke();}})
  return()=>ac.abort();
 },[account,org,incidentId,externalRefresh,epoch,before,read]);
 useEffect(()=>{rts.setExternalEditing(!!move||!!proposal||!!pending);return()=>rts.setExternalEditing(false);},[!!move,!!proposal,!!pending,rts.setExternalEditing]);
 useEffect(()=>{if(proposal){dialog.current?.showModal();}return()=>dialog.current?.close();},[!!proposal]);
 useEffect(()=>{if(rts.locked)setMove(null);},[rts.locked]);
 function propose(action:SimulationAction,payload:Record<string,unknown>,summary:string){
  if(!data?.scenario||!data.can_control||!data.enabled||pending||busy||rts.locked)return;
  rts.cancelMode();setMove(null);setError('');setRejected(false);
  setProposal({action,summary,args:{p_operation:crypto.randomUUID(),p_acting_organization_id:org,p_incident_id:incidentId,p_expected_version:data.scenario.version,p_action:action,p_payload:structuredClone(payload)}});
 }
 async function send(request:Request){
  if(sending.current||!alive.current)return;sending.current=true;setBusy(true);setError('');setPending(request);
  try{sessionStorage.setItem(key,JSON.stringify(request));}catch{/* Keep exact in-memory operation/payload. */}
  try{
   await read('simulation_command',request.args,undefined,account);
   try{sessionStorage.removeItem(key);}catch{}
   if(!alive.current)return;setPending(null);setProposal(null);setEpoch(v=>v+1);setBefore(null);setError('saved');
   if(request.action==='PROVISION')onInventoryChanged();
  }catch(e){
   if(!alive.current)return;const code=e instanceof Error?e.message:'SERVER';
   const definitive=[...simulationErrors,'NOT_AUTHORIZED','EXPIRED','STALE_VERSION','VALIDATION_FAILED','OPERATION_REUSED','INVALID_UNIT','UNIT_ALREADY_DEPLOYED','INCIDENT_TERMINAL'].includes(code);
   setError(t(code)===code?(definitive?'INVALID_SIMULATION_UNIT':'SERVER'):code);
   if(definitive){setPending(null);setRejected(true);try{sessionStorage.removeItem(key);}catch{}setEpoch(v=>v+1);}
   if(['NOT_AUTHORIZED','EXPIRED'].includes(code)){setData(null);setMove(null);rts.revoke();}
  }finally{sending.current=false;if(alive.current)setBusy(false);}
 }
 const controller:Controller={data,error,busy,pending:!!pending,proposal,move,before,refresh:()=>{setError('');setEpoch(v=>v+1);},older:setBefore,propose,
  startMove:value=>{if(!data?.can_control||!data.enabled||pending||proposal||rts.locked||rts.copEditing||rts.mode!=='NORMAL'){setError('modeBusy');return;}rts.cancelMode();setMove(value);},
  cancelMove:()=>setMove(null),pickPosition:p=>{if(!move||rts.locked)return;propose('SET_POSITION',{unit_id:move.unitId,position_version:move.positionVersion,longitude:p[0],latitude:p[1],heading_degrees:Number(move.heading),speed_mps:Number(move.speed)},t('SET_POSITION')+'\n'+p.join(', '));}};
 return <Context.Provider value={controller}><div className="simulation-scope" onKeyDownCapture={e=>{
  if(e.key==='Escape'&&move&&!typingTarget(e.target)&&!e.nativeEvent.isComposing){e.preventDefault();e.stopPropagation();setMove(null);}
 }}>
  {data?.scenario&&<SimulationBanner locale={locale}/>}
  {children}
  {proposal&&<dialog ref={dialog} className="simulation-dialog" aria-label={t('confirm')} onCancel={e=>{e.preventDefault();if(!busy&&!pending){setProposal(null);setRejected(false);}}}>
   <SimulationBanner locale={locale}/><h3>{t(proposal.action)}</h3><p className="incident-prose">{proposal.summary}</p>
   <p>{t('ack')}</p>{['RESET','RESET_POSITION','FINISH'].includes(proposal.action)&&<p>{t('resetWarning')}</p>}
   {error&&<p role="alert">{t(error)}</p>}
   {rejected?<><p>{t('STALE_VERSION')}</p><button disabled={busy||!data?.can_control||!data.scenario} onClick={()=>{
    if(!data?.scenario)return;const payload={...proposal.args.p_payload};
    if(typeof payload.unit_id==='string'){const position=data.positions.find(p=>p.incident_unit_id===payload.unit_id);if(!position){setError('INVALID_SIMULATION_UNIT');return;}payload.position_version=position.version;}
    propose(proposal.action,payload,proposal.summary);
   }}>{t('review')}</button><button onClick={()=>{setProposal(null);setRejected(false);}}>{t('cancel')}</button></>:pending?<><p>{t('pending')}</p><button disabled={busy} onClick={()=>void send(pending)}>{t('retry')}</button></>:
    <div className="actions"><button disabled={busy} onClick={()=>void send(proposal)}>{t('confirm')}</button><button disabled={busy} onClick={()=>setProposal(null)}>{t('cancel')}</button></div>}
  </dialog>}
 </div></Context.Provider>;
}
