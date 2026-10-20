'use client';
import {createContext,useContext,useEffect,useMemo,useState,type ReactNode} from 'react';
import type {Locale} from '../../lib/i18n';
import type {TemplateRead} from '../../lib/operational/templates';
import {effectDefault,type HazardSnapshot,type HazardEffect,type HazardRow} from '../../lib/operational/hazards';
import {hazardText} from '../../lib/operational/hazardMessages';
import {templateText} from '../../lib/operational/templateMessages';
import {useIncidentLive} from './IncidentLiveProvider';
import {useRtsSession} from './rtsSession';
import {useTemplateMutation} from './useTemplateMutation';
import {TemplateConfirmation} from './TemplateLibrary';
import {HazardEffectFields} from './HazardPlanEditor';
type Scope={account:string;org:string;incidentId:string;refresh:number;read:TemplateRead};
type Value={data:HazardSnapshot|null;error:boolean;selected:string;select:(id:string)=>void;instructor:boolean;setInstructor:(v:boolean)=>void;layers:{fire:boolean;smoke:boolean;hazards:boolean};setLayer:(k:'fire'|'smoke'|'hazards',v:boolean)=>void;reload:()=>void;scope:Scope};
const Context=createContext<Value|null>(null);
export const useSimulationHazards=()=>useContext(Context);
export function SimulationHazardsProvider({children,...scope}:Scope&{children:ReactNode}){
 const live=useIncidentLive(),rts=useRtsSession();
 const [data,setData]=useState<HazardSnapshot|null>(null),[error,setError]=useState(false),[epoch,setEpoch]=useState(0),[instructor,setInstructor]=useState(false);
 const [selected,select]=useState(''),[layers,setLayers]=useState({fire:true,smoke:true,hazards:true});
 const {account,org,incidentId,read,refresh}=scope;
 const requestKey=account+':'+org+':'+incidentId+':'+instructor;
 const [loadedKey,setLoadedKey]=useState('');
 useEffect(()=>{
  const ac=new AbortController();
  if(rts.blocked||live?.status==='ACCESS_LOST'){select('');setInstructor(false);return()=>ac.abort();}
  read<HazardSnapshot|null>('simulation_hazards_read',{p_organization_id:org,p_incident_id:incidentId,p_instructor:instructor},ac.signal,account)
   .then(v=>{if(!ac.signal.aborted){setData(v);setLoadedKey(requestKey);setError(false);if(!v?.can_control)setInstructor(false);}})
   .catch(e=>{if(!ac.signal.aborted){setData(null);select('');setError(true);if(e instanceof Error&&['NOT_AUTHORIZED','EXPIRED'].includes(e.message))setInstructor(false);}});
  return()=>ac.abort();
 },[account,org,incidentId,read,refresh,epoch,instructor,live?.lastSuccess,rts.blocked,live?.status==='ACCESS_LOST']);
 const value=useMemo<Value>(()=>({data:loadedKey===requestKey&&!rts.blocked&&live?.status!=='ACCESS_LOST'?data:null,error,selected,select,instructor,setInstructor,layers,setLayer:(k,v)=>setLayers(old=>({...old,[k]:v})),reload:()=>setEpoch(n=>n+1),scope}),[data,error,selected,instructor,layers,scope,loadedKey,requestKey,rts.blocked,live?.status]);
 return <Context.Provider value={value}>{children}</Context.Provider>;
}
export function SimulationHazardsPanel({locale}:{locale:Locale}){
 const ctx=useSimulationHazards(),t=hazardText(locale);
 if(!ctx)return null;
 if(ctx.error)return <p role="alert">{t('error')} <button type="button" onClick={ctx.reload}>{t('refresh')}</button></p>;
 if(!ctx.data)return null;
 const data=ctx.data,row=data.models.find(v=>v.id===ctx.selected);
 return <details className="admin-card simulation-hazards"><summary>{t('title')}</summary>
  <p>{t('disclaimer')}</p><p>{t(data.status)} · {t('seconds')}: {data.seconds}</p>
  <div className="actions">{(['fire','smoke','hazards'] as const).map(k=><label key={k}><input type="checkbox" checked={ctx.layers[k]} onChange={e=>ctx.setLayer(k,e.target.checked)}/>{t(k)}</label>)}</div>
  {data.can_control&&<label><input type="checkbox" checked={ctx.instructor} onChange={e=>{ctx.select('');ctx.setInstructor(e.target.checked);}}/>{t('instructor')}</label>}
  {!data.models.length&&<p>{t('empty')}</p>}
  <div className="template-items">{data.models.map(m=><button type="button" key={m.id} aria-pressed={row?.id===m.id} onClick={()=>ctx.select(m.id)}>{m.title} · {t(m.type)} · {t('burning')}: {m.burning}</button>)}</div>
  {row&&<section aria-label={t('selected')}><h4>{row.title}</h4>
   <dl className="command-route-facts"><dt>{t('step')}</dt><dd>{row.step}</dd><dt>{t('intensity')}</dt><dd>{Math.max(0,...row.features.filter(f=>f.properties?.kind==='FIRE').map(f=>Number(f.properties?.intensity))).toFixed(2)}</dd><dt>{t('elapsed')}</dt><dd>{row.step*5}</dd><dt>{t('lag')}</dt><dd>{row.lag_steps}</dd><dt>{t('freshness')}</dt><dd>{row.last_scan_at?new Date(row.last_scan_at).toLocaleString(locale):'—'}</dd>
    <dt>{t('enabled')}</dt><dd>{row.enabled?'✓':'—'}</dd><dt>{t('wind_direction')}</dt><dd>{row.wind_direction}°</dd><dt>{t('wind_speed')}</dt><dd>{row.wind_speed} m/s</dd>
    {ctx.instructor&&<><dt>{t('geometrySize')}</dt><dd>{row.features.reduce((n,f)=>n+(f.geometry.type==='Polygon'?f.geometry.coordinates.reduce((sum,ring)=>sum+ring.length,0):1),0)}</dd><dt>{t('pending')}</dt><dd>{row.pending_effects}</dd><dt>{t('processing')}</dt><dd>{row.processing_ms??'—'}</dd><dt>{t('visibility')}</dt><dd>{t(row.revealed?'revealed':'hidden')}</dd></>}
   </dl>
   <p>{t('phase')}: {[...new Set(row.features.filter(f=>f.properties?.kind==='FIRE').map(f=>String(f.properties?.phase)))].map(t).join(', ')||t('EXTINGUISHED')}</p>
   <ul>{row.features.filter(f=>f.properties?.phase==='INSTRUCTOR').map(f=><li key={f.id}>{t(String(f.properties?.kind))}</li>)}</ul>
   {row.step>=5760&&<p role="status">{t('budget')}</p>}{row.error&&<p role="alert">{t(row.error)}</p>}
   {ctx.instructor&&data.can_control&&row.configuration&&<HazardControls key={ctx.scope.account+':'+ctx.scope.org+':'+ctx.scope.incidentId+':'+row.id} locale={locale} row={row}/>}
  </section>}
  <p>{t('simSmoke')}</p><button type="button" onClick={ctx.reload}>{t('refresh')}</button>
 </details>;
}
function HazardControls({locale,row}:{locale:Locale;row:HazardRow}){
 const ctx=useSimulationHazards()!,t=hazardText(locale),tt=templateText(locale),{scope}=ctx;
 const [effect,setEffect]=useState<HazardEffect>(()=>effectDefault('IGNITE',row.configuration!)),[confirm,setConfirm]=useState<{version:string;effect:unknown}|null>(null);
 const mutation=useTemplateMutation(scope.account,scope.org,'hazard:'+scope.incidentId+':'+row.id,scope.read,()=>{setConfirm(null);ctx.reload();});
 const disabled=mutation.busy||!!mutation.pending||!['RUNNING','PAUSED'].includes(ctx.data?.status??'');
 return <div><p>{t('queueHelp')}</p>
  <HazardEffectFields locale={locale} model={row.configuration!} value={effect} onChange={setEffect} disabled={disabled}/>
  <button type="button" disabled={disabled} onClick={()=>setConfirm({version:row.version,effect:structuredClone(effect)})}>{t('apply')}</button>
  {row.error==='HAZARD_PROCESSING_FAILED'&&<button type="button" disabled={disabled} onClick={()=>setConfirm({version:row.version,effect:{type:'RETRY',value:null}})}>{t('RETRY')}</button>}
  {mutation.error&&<p role="alert">{tt(mutation.error)}</p>}
  {mutation.pending&&<button type="button" disabled={mutation.busy} onClick={mutation.retry}>{t('retry')}</button>}
  {confirm&&<TemplateConfirmation locale={locale} busy={mutation.busy||!!mutation.pending} onCancel={()=>setConfirm(null)}
   onConfirm={()=>mutation.mutate('simulation_hazard_command',{p_incident_id:scope.incidentId,p_model:row.id,p_expected_version:confirm.version,p_effect:confirm.effect})}>
   <h3>{row.title} · {t((confirm.effect as {type:string}).type)}</h3><p>{t('queueHelp')}</p>
   {mutation.error&&<p role="alert">{tt(mutation.error)}</p>}
   {mutation.pending&&<button type="button" disabled={mutation.busy} onClick={mutation.retry}>{t('retry')}</button>}
  </TemplateConfirmation>}
 </div>;
}
