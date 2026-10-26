'use client';
import {createContext,useContext,useEffect,useState,type ReactNode} from 'react';
import type {Locale} from '../../lib/i18n';
import type {TemplateRead} from '../../lib/operational/templates';
import type {OperationalRead,WaterResource} from '../../lib/operational/operations';
import {operationText} from '../../lib/operational/operationMessages';
import {templateText} from '../../lib/operational/templateMessages';
import {useSimulation} from './SimulationProvider';
import {useIncidentLive} from './IncidentLiveProvider';
import {useRtsSession} from './rtsSession';
import {useTemplateMutation} from './useTemplateMutation';
import {TemplateConfirmation} from './TemplateLibrary';
import {useSimulationHazards} from './SimulationHazards';
import {WorkspaceSlot,useWorkspace} from './workspace';
type Scope={account:string;org:string;incidentId:string;refresh:number;read:TemplateRead};
type Value={allowed:boolean;mutation:ReturnType<typeof useTemplateMutation>;data:OperationalRead|null;error:boolean;scope:Scope;reload:()=>void;before:string|null;older:(id:string|null)=>void};
const Context=createContext<Value|null>(null);
export const useOperationalEffects=()=>useContext(Context);
export function OperationalEffectsProvider({children,...scope}:Scope&{children:ReactNode}){
 const sim=useSimulation(),live=useIncidentLive(),rts=useRtsSession();
 const [value,setValue]=useState<OperationalRead|null>(null),[error,setError]=useState(false),[epoch,setEpoch]=useState(0),[before,older]=useState<string|null>(null);
 const [loaded,setLoaded]=useState('');
 const {account,org,incidentId,read,refresh}=scope,key=account+':'+org+':'+incidentId;
 const hazards=useSimulationHazards();
 const mutation=useTemplateMutation(account,org,'operations:'+incidentId,read,()=>{setEpoch(n=>n+1);hazards?.reload();});
 const allowed=!!sim?.data?.scenario&&!rts.blocked&&live?.status!=='ACCESS_LOST';
 useEffect(()=>{
  const ac=new AbortController();
  if(!allowed){setValue(null);return()=>ac.abort();}
  void read<OperationalRead>('simulation_operations_read',{p_organization_id:org,p_incident_id:incidentId,p_before:before},ac.signal,account)
   .then(v=>{if(!ac.signal.aborted){setValue(v);setLoaded(key);setError(false);}})
   .catch(()=>{if(!ac.signal.aborted){setValue(null);setError(true);}});
  return()=>ac.abort();
 },[key,read,refresh,epoch,before,allowed,live?.lastSuccess,sim?.data?.scenario?.version]);
 return <Context.Provider value={{allowed,mutation,data:allowed&&loaded===key?value:null,error,scope,reload:()=>setEpoch(n=>n+1),before,older}}>{children}</Context.Provider>;
}
export function OperationalEffectsPanel({locale}:{locale:Locale}){
 const ctx=useOperationalEffects(),workspace=useWorkspace(),t=operationText(locale);
 if(!ctx?.allowed)return null;
 const feedback=<OperationFeedback locale={locale}/>;
 if(!ctx.data)return <>{feedback}{ctx.error&&<p role="alert">{t('stale')} <button onClick={ctx.reload}>{t('refresh')}</button></p>}</>;
 const data=ctx.data,selected=workspace?.selected?.kind==='INCIDENT_UNIT'?data.resources.find(r=>r.unit_id===workspace.selected?.id):null;
 return <>
 {feedback}
 <details className="admin-card"><summary>{t('title')}</summary><p>{t('disclaimer')}</p><p>{t('resetHelp')}</p><p role="status">{t(data.status)}</p><p>{t('observed')}: {new Date(data.observed_at).toLocaleString(locale)}</p><button onClick={ctx.reload}>{t('refresh')}</button>
 {!data.resources.length&&<p>{t('empty')}</p>}
 {data.resources.map(r=><details key={r.id}><summary>{r.name} · {r.remaining_l.toLocaleString(locale)} / {r.capacity_l.toLocaleString(locale)} L</summary><ResourceOperations key={ctx.scope.account+ctx.scope.org+r.id} locale={locale} resource={r}/></details>)}
 <details><summary>{t('history')}</summary>{data.history.map(h=><article className="web-row" key={h.id}><strong>{t(h.kind)}</strong><span>{h.sim_second} s</span>
 {typeof h.data.delivered_l==='number'&&<span>{h.data.delivered_l.toLocaleString(locale)} L</span>}
 {typeof h.data.liters==='number'&&<span>{h.data.liters.toLocaleString(locale)} L</span>}
 {typeof h.data.reason==='string'&&<p>{h.kind==='REFILLED'?h.data.reason:t(h.data.reason)}</p>}
 </article>)}
 <button disabled={!ctx.before} onClick={()=>ctx.older(null)}>{t('latest')}</button><button disabled={data.history.length<50} onClick={()=>ctx.older(data.history.at(-1)?.id??null)}>{t('older')}</button></details>
 </details>
 {selected&&<WorkspaceSlot name="selectedPane"><section className="admin-card"><h3>{t('title')} · {selected.name}</h3><ResourceSummary locale={locale} resource={selected}/></section></WorkspaceSlot>}
 </>;
}
function OperationFeedback({locale}:{locale:Locale}){
 const ctx=useOperationalEffects()!,mutation=ctx.mutation,t=operationText(locale),tt=templateText(locale),rts=useRtsSession();
 return <>{mutation.error&&<p role="alert">{mutation.error.startsWith('OP_')?t(mutation.error):tt(mutation.error)}</p>}
 {mutation.pending&&<section className="admin-card" role="status"><p>{t(mutation.state==='CONFIRMED'?'confirmedCleanup':'pending')}</p>
 <p>{t(String(mutation.pending.args.p_action))} · <code>{String(mutation.pending.args.p_operation)}</code></p>
 <button type="button" disabled={mutation.busy||!mutation.ready||rts.locked} onClick={mutation.retry}>{t('retry')}</button></section>}</>;
}
function ResourceSummary({locale,resource:r}:{locale:Locale;resource:WaterResource}){
 const ctx=useOperationalEffects()!,data=ctx.data!,t=operationText(locale),connection=data.connections.find(c=>c.consumer_id===r.id);
 const executions=data.executions.filter(e=>e.resource_id===r.id),supply=connection?data.resources.find(v=>v.id===connection.source_id):r;
 return <><p>{t('remaining')}: {r.remaining_l.toLocaleString(locale)} / {r.capacity_l.toLocaleString(locale)} L</p>
 {r.remaining_l===0&&!connection&&<p role="status">{t('WATER_DEPLETED')}</p>}
 <p>{t('supply')}: {connection?data.resources.find(v=>v.id===connection.source_id)?.name:t('tank')} {connection?' · '+connection.flow_lpm+' L/min':''}</p>
 {connection&&<p>{t('remaining')}: {supply?.remaining_l.toLocaleString(locale)??'—'} L</p>}
 {connection&&!connection.available&&<p role="status">{t('SUPPLY_UNAVAILABLE')} · {t('reconnect')}</p>}
 {connection&&supply?.remaining_l===0&&<p role="status">{t('WATER_DEPLETED')}</p>}
 {executions.map(e=><section key={e.id}><strong>{t(e.state==='PENDING'?'ARMED':e.state)}</strong>{e.reason&&<p>{t(e.reason)}</p>}<p>{t('delivered')}: {e.delivered_l.toLocaleString(locale)} L · {e.flow_lpm} L/min</p><p>{t('progress')}: {e.active_seconds} / {e.duration_seconds} s</p>
 {data.status==='RUNNING'&&['ACTIVE','PENDING'].includes(e.state)&&data.seconds-e.last_step*5>10&&<p>{t('stale')}</p>}</section>)}</>;
}
function ResourceOperations({locale,resource:r}:{locale:Locale;resource:WaterResource}){
 const ctx=useOperationalEffects()!,data=ctx.data!,hazards=useSimulationHazards(),t=operationText(locale),rts=useRtsSession();
 const [model,setModel]=useState(''),[assignment,setAssignment]=useState(''),[source,setSource]=useState(''),[flow,setFlow]=useState(200),[duration,setDuration]=useState(300),[liters,setLiters]=useState(0),[reason,setReason]=useState(''),[lon,setLon]=useState(''),[lat,setLat]=useState('');
 const [confirmation,setConfirmation]=useState<{action:string;version:string;payload:Record<string,unknown>}|null>(null);
 const mutation=ctx.mutation;
 useEffect(()=>{if(mutation.state==='CONFIRMED')setConfirmation(null);},[mutation.state]);
 const busy=mutation.busy||!!mutation.pending||!mutation.ready||!data.can_control||rts.locked;
 const task=data.assignments.find(a=>a.id===assignment&&a.resource_id===r.id);
 const connection=data.connections.find(c=>c.consumer_id===r.id);
 const active=data.executions.find(e=>e.resource_id===r.id&&['PENDING','ACTIVE','BLOCKED'].includes(e.state));
 const target=task?.target??[Number(lon),Number(lat)];
 const validTarget=!!task||lon.trim()!==''&&lat.trim()!==''&&Number.isFinite(Number(lon))&&Number.isFinite(Number(lat))&&Math.abs(Number(lon))<=180&&Math.abs(Number(lat))<=90;
 const ask=(action:string,payload:Record<string,unknown>,version=r.version)=>setConfirmation({action,version,payload});
 return <><ResourceSummary locale={locale} resource={r}/>
 {data.can_control&&<fieldset disabled={busy}><p>{t('bindingHelp')}</p>
 {active?<><button type="button" onClick={()=>ask('STOP_ACTIVITY',{execution_id:active.id},active.version)}>{t('STOP_ACTIVITY')}</button>{active.state==='BLOCKED'&&<button type="button" onClick={()=>ask('RESUME_ACTIVITY',{execution_id:active.id},active.version)}>{t('RESUME_ACTIVITY')}</button>}</>:<>
 <label>{t('assignment')}<select value={assignment} onChange={e=>setAssignment(e.target.value)}><option value="">{t('instructor')}</option>{data.assignments.filter(a=>a.resource_id===r.id).map(a=><option key={a.id} value={a.id}>{a.title??a.id}</option>)}</select></label>
 {assignment&&!task&&<p role="alert">{t('OP_TASK_UNAVAILABLE')}</p>}
 <label>{t('model')}<select value={model} onChange={e=>{setModel(e.target.value);const row=hazards?.data?.models.find(m=>m.id===e.target.value);const point=row?.features.find(f=>f.geometry.type==='Point');if(point?.geometry.type==='Point'){setLon(String(point.geometry.coordinates[0]));setLat(String(point.geometry.coordinates[1]));}}}><option value="">—</option>{hazards?.data?.models.filter(m=>m.enabled&&m.revealed!==false).map(m=><option key={m.id} value={m.id}>{m.title}</option>)}</select></label>
 {!task&&<div className="web-form-grid"><label>{t('longitude')}<input type="number" step="any" value={lon} onChange={e=>setLon(e.target.value)}/></label><label>{t('latitude')}<input type="number" step="any" value={lat} onChange={e=>setLat(e.target.value)}/></label>
 <label>{t('flow_lpm')}<input type="number" min={0.012} step="0.001" max={r.pump_lpm} value={flow} onChange={e=>setFlow(Number(e.target.value))}/></label><label>{t('duration_seconds')}<input type="number" min={5} max={3600} step={5} value={duration} onChange={e=>setDuration(Number(e.target.value))}/></label></div>}
 <button type="button" disabled={!model||!validTarget||!r.available||r.pump_lpm<=0||!!assignment&&!task} onClick={()=>ask('APPLY_WATER',{resource_id:r.id,model_id:model,target,assignment_id:task?.id??null,flow_lpm:task?.flow_lpm??flow,duration_seconds:task?.duration_seconds??duration})}>{t('APPLY_WATER')}</button>
 </>}
 <details><summary>{t('supply')}</summary>
 {connection?<button type="button" onClick={()=>ask('DISCONNECT_SUPPLY',{resource_id:r.id})}>{t('DISCONNECT_SUPPLY')}</button>:<>
 <label>{t('supply')}<select value={source} onChange={e=>setSource(e.target.value)}><option value="">—</option>{data.resources.filter(v=>v.id!==r.id&&v.capacity_l>0&&v.pump_lpm>0&&v.available).map(v=><option key={v.id} value={v.id}>{v.name} · {v.remaining_l} L</option>)}</select></label>
 <label>{t('flow_lpm')}<input type="number" min={0.012} step="0.001" max={5000} value={flow} onChange={e=>setFlow(Number(e.target.value))}/></label>
 <button type="button" disabled={!source||!!active&&active.state!=='BLOCKED'} onClick={()=>ask('CONNECT_SUPPLY',{resource_id:r.id,source_id:source,source_version:data.resources.find(v=>v.id===source)?.version,flow_lpm:flow})}>{t('CONNECT_SUPPLY')}</button></>}
 <label>{t('liters')}<input type="number" min={0} max={r.capacity_l-r.remaining_l} step="0.001" value={liters} onChange={e=>setLiters(Number(e.target.value))}/></label><label>{t('reason')}<input maxLength={500} value={reason} onChange={e=>setReason(e.target.value)}/></label>
 <button type="button" disabled={!reason.trim()||liters<=0||liters>r.capacity_l-r.remaining_l} onClick={()=>ask('REFILL',{resource_id:r.id,liters,reason})}>{t('REFILL')}</button>
 </details></fieldset>}
 {confirmation&&!mutation.pending&&<TemplateConfirmation locale={locale} busy={busy} onCancel={()=>setConfirmation(null)} onConfirm={()=>{if(busy)return;mutation.mutate('simulation_operational_command',{p_incident_id:ctx.scope.incidentId,p_action:confirmation.action,p_expected_version:confirmation.version,p_payload:confirmation.payload});}}>
 <h3>{t(confirmation.action)} · {r.name}</h3><p>{t('disclaimer')}</p>
 {Object.entries(confirmation.payload).filter(([k])=>['flow_lpm','duration_seconds','liters','reason'].includes(k)).map(([k,v])=><p key={k}>{t(k)}: {String(v)}</p>)}
 <OperationFeedback locale={locale}/>
 </TemplateConfirmation>}
 </>;
}
