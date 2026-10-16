'use client';
import {createContext,useContext,useEffect,useState,type ReactNode} from 'react';
import {geometryPositions,type Geometry} from '../../lib/incidents/cop';
import type {Locale} from '../../lib/i18n';
import type {TemplateRead} from '../../lib/operational/templates';
import {eventTime,type EventHistory,type ScenarioEvent,type ScenarioEvents as Snapshot} from '../../lib/operational/scenarioEvents';
import {scenarioEventText} from '../../lib/operational/scenarioEventMessages';
import {templateText} from '../../lib/operational/templateMessages';
import {useIncidentLive} from './IncidentLiveProvider';
import {useTemplateMutation} from './useTemplateMutation';
import {TemplateConfirmation} from './TemplateLibrary';
import {useWorkspace} from './workspace';
type Scope={account:string;org:string;incidentId:string;refresh:number;read:TemplateRead;onInventoryChanged:()=>void};
type Value={data:Snapshot|null;error:boolean;selected:string;select:(id:string)=>void;focus:{id:string;nonce:number};focusEvent:(id:string)=>void;reload:()=>void;scope:Scope};
const Context=createContext<Value|null>(null);
export const useScenarioEvents=()=>useContext(Context);
/** Only revealed DTOs live here. Instructor definitions are fetched in the gated panel. */
export function ScenarioEventsProvider({children,...scope}:Scope&{children:ReactNode}){
 const live=useIncidentLive(),[data,setData]=useState<Snapshot|null>(null),[error,setError]=useState(false),[epoch,setEpoch]=useState(0);
 const [selected,select]=useState(''),[focus,setFocus]=useState({id:'',nonce:0});
 const {account,org,incidentId,read,refresh}=scope;
 useEffect(()=>{
  const ac=new AbortController();
  read<Snapshot|null>('simulation_scenario_events',{p_organization_id:org,p_incident_id:incidentId},ac.signal,account)
   .then(v=>{if(!ac.signal.aborted){setData(v);setError(false);}})
   .catch(()=>{if(!ac.signal.aborted){setData(null);select('');setError(true);}});
  return()=>ac.abort();
 },[account,org,incidentId,read,refresh,epoch,live?.lastSuccess]);
 const reload=()=>{setEpoch(n=>n+1);live?.requestRefresh();scope.onInventoryChanged();};
 return <Context.Provider value={{data,error,selected,select,focus,focusEvent:id=>setFocus(v=>({id,nonce:v.nonce+1})),reload,scope}}>{children}</Context.Provider>;
}
export function ScenarioEventsPanel({locale}:{locale:Locale}){
 const ctx=useScenarioEvents(),workspace=useWorkspace(),t=scenarioEventText(locale);
 const [instructor,setInstructor]=useState(false);
 if(ctx?.error)return <p role="alert">{t('error')} <button type="button" onClick={ctx.reload}>{t('refresh')}</button></p>;
 if(!ctx?.data)return null;
 const data=ctx.data;
 function inspect(id:string){ctx!.select(id);workspace?.showDetails();}
 return <section className="admin-card scenario-events">
  <h3>{t('reports')}</h3><p>{t('simulated')}</p>
  {data.worker_stale&&<p role="status" className="admin-notice">{t('worker')}</p>}
  {!data.events.length&&<p>{t('empty')}</p>}
  <ul className="template-items">{data.events.map(e=><li key={e.id}><button type="button" onClick={()=>inspect(e.id)}>{e.title} · {t(e.type)} · {eventTime(e.simulation_seconds??0)}</button></li>)}</ul>
  <button type="button" onClick={ctx.reload}>{t('refresh')}</button>
  {data.can_control&&<details open={instructor} onToggle={e=>setInstructor(e.currentTarget.open)}><summary>{t('instructor')}</summary>
   {instructor&&<InstructorEvents key={ctx.scope.account+':'+ctx.scope.org+':'+ctx.scope.incidentId} locale={locale}/>}
  </details>}
  {!workspace&&<ScenarioEventDetails locale={locale}/>}
 </section>;
}
export function ScenarioEventDetails({locale}:{locale:Locale}){
 const ctx=useScenarioEvents(),t=scenarioEventText(locale);
 if(!ctx?.data||!ctx.selected)return null;
 const e=ctx.data.events.find(e=>e.id===ctx.selected),annotation=ctx.data.annotations.find(a=>a.id===(e?.result.annotation_id??ctx.selected.replace(/^annotation:/,'')));
 if(!e&&!annotation)return null;
 return <section className="admin-card scenario-event-details">
  <p className="admin-badge">{t('simulated')}</p><h3>{e?.title??annotation?.title}</h3><p>{t(e?.type??annotation!.type)}</p>
  <p className="incident-prose">{e?.description??annotation?.description}</p>
  <p>{t('time')}: {eventTime(e?.simulation_seconds??0)} · {e?.executed_at?new Date(e.executed_at).toLocaleString(locale):annotation?.revealed_at?new Date(annotation.revealed_at).toLocaleString(locale):''}</p>
  {(e?.type==='ACCESS_RESTRICTION'||annotation?.type==='ACCESS_RESTRICTION')&&<p>{t('advisory')}</p>}
  {annotation&&<><p>{annotation.title} · {t('version')} {annotation.version}</p><button type="button" onClick={()=>ctx.focusEvent(annotation.id)}>{t('focus')}</button></>}
  <button type="button" onClick={()=>ctx.select('')}>{t('close')}</button>
 </section>;
}
function InstructorEvents({locale}:{locale:Locale}){
 const ctx=useScenarioEvents()!,{scope}=ctx,live=useIncidentLive(),t=scenarioEventText(locale),tt=templateText(locale);
 const [data,setData]=useState<Snapshot|null>(null),[error,setError]=useState(false),[epoch,setEpoch]=useState(0);
 const [confirmation,setConfirmation]=useState<{event:ScenarioEvent;action:'TRIGGER'|'RETRY'|'CANCEL'}|null>(null);
 const [history,setHistory]=useState<EventHistory[]>([]),[after,setAfter]=useState('0'),[showHistory,setShowHistory]=useState(false);
 const mutation=useTemplateMutation(scope.account,scope.org,'scenario-events:'+scope.incidentId,scope.read,()=>{setConfirmation(null);setEpoch(n=>n+1);ctx.reload();});
 useEffect(()=>{
  const ac=new AbortController();
  scope.read<Snapshot>('simulation_scenario_events',{p_organization_id:scope.org,p_incident_id:scope.incidentId,p_instructor:true},ac.signal,scope.account)
   .then(v=>{if(!ac.signal.aborted){setData(v);setError(false);}})
   .catch(()=>{if(!ac.signal.aborted){setData(null);setHistory([]);setConfirmation(null);setError(true);}});
  return()=>ac.abort();
 },[scope.account,scope.org,scope.incidentId,scope.read,scope.refresh,epoch,live?.lastSuccess]);
 useEffect(()=>{
  if(!showHistory||!data)return;
  const ac=new AbortController();setHistory([]);
  scope.read<EventHistory[]>('simulation_scenario_event_history',{p_organization_id:scope.org,p_incident_id:scope.incidentId,p_after:after},ac.signal,scope.account)
   .then(v=>{if(!ac.signal.aborted)setHistory(v);}).catch(()=>{if(!ac.signal.aborted){setData(null);setHistory([]);setError(true);}});
  return()=>ac.abort();
 },[showHistory,after,epoch,scope.account,scope.org,scope.incidentId,scope.read,data?.can_control,live?.lastSuccess]);
 if(error||!data)return <p role="alert">{t(error?'error':'loading')}</p>;
 const disabled=mutation.busy||!!mutation.pending;
 return <div>
  <p>{t('controls')}</p><p>{t(data.status)} · {t('time')}: {eventTime(data.seconds)}</p>
  {data.worker_stale&&<p role="alert">{t('worker')}</p>}
  {data.status==='RUNNING'&&data.events.some(e=>e.state==='PLANNED')&&(!data.last_event_scan_at||Date.now()-Date.parse(data.last_event_scan_at)>30000)&&<p role="alert">{t('workerEvents')}</p>}
  {mutation.error&&<p role="alert">{tt(mutation.error)}</p>}
  {mutation.pending&&<p>{t('pending')} <button disabled={mutation.busy} onClick={mutation.retry}>{t('retry')}</button></p>}
  {!data.events.length&&<p>{t('noPlan')}</p>}
  <ol className="template-items">{data.events.map(e=><li key={e.id}><details><summary>{e.title} · {t(e.state)} · {e.definition?.trigger.mode==='SIMULATION_TIME'?eventTime(e.definition.trigger.offset_seconds??0):t(e.definition?.trigger.mode??'')}</summary>
   <p>{t(e.type)}</p><p className="incident-prose">{e.description}</p>
   {e.blocked_reason&&<p role="status">{t(e.blocked_reason)}</p>}
   {e.definition?.trigger.event_id&&<p>{t('prior')}: {data.events.find(v=>v.id===e.definition?.trigger.event_id)?.title}</p>}
   {e.definition?.effect&&<><p>{t('target')}: {data.events.find(v=>v.id===e.definition?.effect?.target_event_id)?.title??'—'} · {t('expectedVersion')}: {e.definition.effect.expected_version??'—'}</p>{e.definition.effect.geometry&&<GeometryValues locale={locale} geometry={e.definition.effect.geometry}/>}</>}
   <p>{t('attempts')}: {e.attempts}/3 · {t('version')}: {e.version}</p>
   <Outcome locale={locale} result={e.result}/>
   <div className="actions">
    {e.state==='PLANNED'&&e.definition?.trigger.mode==='MANUAL'&&<button disabled={disabled||data.status!=='RUNNING'||!!e.blocked_reason} onClick={()=>setConfirmation({event:e,action:'TRIGGER'})}>{t('TRIGGER')}</button>}
    {['BLOCKED','RETRYABLE_FAILURE'].includes(e.state)&&<button disabled={disabled||data.status!=='RUNNING'||e.attempts>=3||!!e.blocked_reason} onClick={()=>setConfirmation({event:e,action:'RETRY'})}>{t('RETRY')}</button>}
    {!['EXECUTED','CANCELLED'].includes(e.state)&&<button disabled={disabled||!['RUNNING','PAUSED'].includes(data.status)} onClick={()=>setConfirmation({event:e,action:'CANCEL'})}>{t('CANCEL')}</button>}
   </div>
  </details></li>)}</ol>
  <details open={showHistory} onToggle={e=>setShowHistory(e.currentTarget.open)}><summary>{t('history')}</summary>
   {history.map(h=><article key={h.id}><strong>{data.events.find(e=>e.id===h.event_id)?.title} · {t(h.state)}</strong><p>{t(h.origin)} · {h.actor??'—'} · {eventTime(h.seconds)} · {new Date(h.recorded_at).toLocaleString(locale)}</p><Outcome locale={locale} result={h.result}/></article>)}
   <div className="actions">{after!=='0'&&<button onClick={()=>setAfter('0')}>{t('first')}</button>}{history.length===25&&<button onClick={()=>setAfter(history[history.length-1].id)}>{t('more')}</button>}</div>
  </details>
  {confirmation&&<TemplateConfirmation locale={locale} busy={disabled} onCancel={()=>setConfirmation(null)} onConfirm={()=>mutation.mutate('simulation_scenario_event_command',{p_incident_id:scope.incidentId,p_event_id:confirmation.event.id,p_expected_version:confirmation.event.version,p_action:confirmation.action})}>
   <h3>{t(confirmation.action)} · {confirmation.event.title}</h3><p>{t('confirm')}</p><p>{confirmation.event.description}</p>
   {mutation.error&&<p role="alert">{tt(mutation.error)}</p>}{mutation.pending&&<button type="button" disabled={mutation.busy} onClick={mutation.retry}>{t('retry')}</button>}
  </TemplateConfirmation>}
 </div>;
}
function Outcome({locale,result}:{locale:Locale;result:ScenarioEvent['result']}){
 const t=scenarioEventText(locale);
 return <div><strong>{t('outcome')}</strong>{result.error?<p role="alert">{t(result.error)}</p>:<><p>{result.title} {result.description}</p>{result.annotation_version&&<p>{t('version')}: {result.annotation_version}</p>}{result.geometry&&<GeometryValues locale={locale} geometry={result.geometry}/>} {result.cancelled&&<p>{t('CANCELLED')}</p>}</>}</div>;
}

function GeometryValues({locale,geometry}:{locale:Locale;geometry:Geometry}){
 const t=scenarioEventText(locale);
 return <details><summary>{t('geometry')}</summary><ol>{geometryPositions(geometry).map((p,i)=><li key={i}>{p[1].toFixed(6)}, {p[0].toFixed(6)}</li>)}</ol></details>;
}
