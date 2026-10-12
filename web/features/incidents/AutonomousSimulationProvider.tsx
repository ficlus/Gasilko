'use client';
import {createContext,useContext,useEffect,useRef,useState,type ReactNode} from 'react';
import type {Locale} from '../../lib/i18n';
import type {TaskRead} from '../../lib/operational/tasks';
import {agentErrors,type AgentView} from '../../lib/operational/agents';
import {agentText} from '../../lib/operational/agentMessages';
import {useSimulation,SimulationBanner} from './SimulationProvider';
import {useRtsSession} from './rtsSession';
type Request={action:string;summary:string;args:Record<string,unknown>};
type Controller={data:AgentView|null;error:string;busy:boolean;pending:boolean;page:number;
 setPage:(v:number)=>void;scope:(id:string|null)=>void;older:(before:string|null)=>void;refresh:()=>void;
 propose:(action:string,payload:Record<string,unknown>,summary:string)=>void};
const Context=createContext<Controller|null>(null);
export const useAutonomousSimulation=()=>useContext(Context);
export function AutonomousSimulationProvider({account,org,incidentId,read,locale,children}:{account:string;org:string;incidentId:string;read:TaskRead;locale:Locale;children:ReactNode}){
 const sim=useSimulation(),rts=useRtsSession(),t=agentText(locale);
 const [data,setData]=useState<AgentView|null>(null),[error,setError]=useState(''),[page,setPage]=useState(0),[unit,setUnit]=useState<string|null>(null),[before,setBefore]=useState<string|null>(null),[epoch,setEpoch]=useState(0);
 const [proposal,setProposal]=useState<Request|null>(null),[pending,setPending]=useState<Request|null>(null),[busy,setBusy]=useState(false);
 const alive=useRef(true),sending=useRef(false),dialog=useRef<HTMLDialogElement>(null),simRefresh=useRef(sim?.refresh);
 simRefresh.current=sim?.refresh;
 const scenario=sim?.data?.scenario?.id,enabled=!!sim?.data?.enabled,blocked=rts.locked||rts.blocked;
 const key='gasilko.agent.pending.'+account+'.'+org+'.'+incidentId;
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;};},[]);
 useEffect(()=>{try{const raw=sessionStorage.getItem(key);if(raw&&raw.length<16000){const saved=JSON.parse(raw) as Request;
  if(saved.args?.p_organization_id===org&&saved.args?.p_scenario===scenario){setPending(saved);setProposal(saved);}}}catch{}},[key,org,scenario]);
 useEffect(()=>{
  setData(null);if(!scenario||!enabled||blocked)return;
  let cancelled=false,timer:ReturnType<typeof setTimeout>|undefined;let ac:AbortController|undefined;
  async function load(){
   if(cancelled||document.visibilityState!=='visible')return;
   ac?.abort();ac=new AbortController();const current=ac;
   try{
    const value=await read<AgentView>('simulation_agents_read',{p_scenario:scenario,p_organization_id:org,p_unit:unit,p_page:page,p_before:before},current.signal,account);
    if(cancelled||current.signal.aborted)return;
    setData(value);setError('');simRefresh.current?.();
   }catch(e){
    if(cancelled||current.signal.aborted)return;
    const code=e instanceof Error?e.message:'SERVER';setData(null);setError(code);
    if(['NOT_AUTHORIZED','EXPIRED'].includes(code)){setProposal(null);setPending(null);rts.revoke();return;}
   }
   if(!cancelled)timer=setTimeout(()=>void load(),5000);
  }
  function visibility(){clearTimeout(timer);ac?.abort();if(document.visibilityState==='visible')void load();}
  void load();document.addEventListener('visibilitychange',visibility);
  return()=>{cancelled=true;clearTimeout(timer);ac?.abort();document.removeEventListener('visibilitychange',visibility);};
 },[account,org,incidentId,scenario,enabled,blocked,page,unit,before,epoch,read]);
 useEffect(()=>{rts.setAgentEditing(!!proposal||!!pending);return()=>rts.setAgentEditing(false);},[!!proposal,!!pending,rts.setAgentEditing]);
 useEffect(()=>{if(proposal)dialog.current?.showModal();return()=>dialog.current?.close();},[!!proposal]);
 function propose(action:string,payload:Record<string,unknown>,summary:string){
  if(!data?.can_control||!scenario||blocked||busy||pending||rts.externalEditing||rts.copEditing||rts.open)return;
  rts.cancelMode();setError('');setProposal({action,summary,args:{p_scenario:scenario,p_organization_id:org,p_operation:crypto.randomUUID(),p_version:data.clock.version,p_action:action,p_payload:structuredClone(payload)}});
 }
 async function send(request:Request){
  if(sending.current||blocked)return;sending.current=true;setBusy(true);setPending(request);
  try{sessionStorage.setItem(key,JSON.stringify(request));}catch{}
  try{
   await read('simulation_agent_command',request.args,undefined,account);
   try{sessionStorage.removeItem(key);}catch{}
   if(!alive.current)return;setPending(null);setProposal(null);setEpoch(v=>v+1);simRefresh.current?.();
  }catch(e){
   if(!alive.current)return;const code=e instanceof Error?e.message:'SERVER';setError(code);
   if([...agentErrors,'SIMULATION_DISABLED','INVALID_SIMULATION_STATE','INVALID_SIMULATION_UNIT','STALE_VERSION','VALIDATION_FAILED','OPERATION_REUSED','NOT_AUTHORIZED','EXPIRED'].includes(code)){
    setPending(null);setProposal(null);setEpoch(v=>v+1);try{sessionStorage.removeItem(key);}catch{}
   }
   if(['NOT_AUTHORIZED','EXPIRED'].includes(code)){setData(null);rts.revoke();}
  }finally{sending.current=false;if(alive.current)setBusy(false);}
 }
 return <Context.Provider value={{data,error,busy,pending:!!pending,page,setPage,scope:id=>{setUnit(id);setPage(0);},older:setBefore,refresh:()=>setEpoch(v=>v+1),propose}}>
 {children}
 {proposal&&<dialog ref={dialog} className="simulation-dialog" aria-label={t('confirm')} onCancel={e=>{e.preventDefault();if(!pending&&!busy)setProposal(null);}}>
  <SimulationBanner locale={locale}/><h3>{t(proposal.action)}</h3><p className="incident-prose">{proposal.summary}</p><p>{t('notice')}</p>
  {error&&<p role="alert">{t(error)}</p>}{pending&&<p>{t('pending')}</p>}
  <button disabled={busy||blocked} onClick={()=>void send(pending??proposal)}>{t(pending?'retry':'confirm')}</button>
  {!pending&&<button disabled={busy} onClick={()=>setProposal(null)}>{t('cancel')}</button>}
 </dialog>}
 </Context.Provider>;
}
