'use client';
import {useEffect,useRef,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import type {TaskRead} from '../../lib/operational/tasks';
import {reliabilitySummary,type ReliabilitySummary,type ReliabilitySample} from '../../lib/incidents/reliability';
import {reliabilityText} from '../../lib/incidents/reliabilityText';
import {useIncidentLive} from './IncidentLiveProvider';

type Phase='IDLE'|'LOADING'|'AVAILABLE'|'EMPTY'|'STALE'|'OFFLINE'|'BUSY'|'SCHEMA_UNAVAILABLE'|'DENIED'|'ERROR';
const stages=['CODE_MERGED','SQL_APPLIED','EDGE_DEPLOYED','STORAGE_CONFIGURED','REALTIME_CONFIGURED','WEB_DEPLOYED',
 'ANDROID_INSTALLED','HUMAN_VERIFIED','OPERATIONAL_RELEASED'] as const;
/** Existing authenticated read lane, manually opened; no timer, telemetry, mutation or new transport. */
export function IncidentReliability({locale,account,org,incidentId,controller,refresh,read}:{
 locale:Locale;account:string;org:string;incidentId:string;controller:boolean;refresh:number;read:TaskRead;
}) {
 const t=reliabilityText(locale),live=useIncidentLive();
 const [open,setOpen]=useState(false),[window,setWindow]=useState<'1h'|'24h'|'7d'>('24h'),[request,setRequest]=useState(0);
 const [state,setState]=useState<{scope:string;phase:Phase;sample:ReliabilitySummary|null}>({scope:'',phase:'IDLE',sample:null});
 const generation=useRef(0),scope=account+'/'+org+'/'+incidentId,activeScope=useRef(scope);activeScope.current=scope;
 const denied=!controller||live?.status==='ACCESS_LOST';
 const headScope=live?.authorizationFingerprint;
 const networkUnavailable=live?.status==='OFFLINE';
 useEffect(()=>{
  const current=++generation.current,ac=new AbortController();
  setState({scope,phase:denied?'DENIED':open?'LOADING':'IDLE',sample:null});
  if(!open||denied)return()=>{ac.abort();};
  if(!navigator.onLine||networkUnavailable){setState({scope,phase:'OFFLINE',sample:null});return()=>ac.abort();}
  void read<unknown>('incident_field_reliability_summary',{p_acting_organization_id:org,p_incident_id:incidentId,p_window:window},ac.signal,account)
   .then(value=>{
    if(ac.signal.aborted||generation.current!==current||activeScope.current!==scope)return;
    const sample=reliabilitySummary(value,account,org,incidentId,window);
    if(headScope&&sample.scope_fingerprint!==headScope)throw new Error('STALE');
    setState({scope,phase:[sample.own_receipts,sample.task_history,sample.task_transport].every(s=>s.count===null)?'EMPTY':'AVAILABLE',sample});
   }).catch(error=>{
    if(ac.signal.aborted||generation.current!==current||activeScope.current!==scope)return;
    const code=error instanceof Error?error.message:'SERVER';
    const phase:Phase=!navigator.onLine?'OFFLINE':['NOT_AUTHORIZED','EXPIRED'].includes(code)?'DENIED':
     ['SCHEMA_UNAVAILABLE','SCHEMA_MISMATCH'].includes(code)?'SCHEMA_UNAVAILABLE':code==='BUSY'?'BUSY':code==='STALE'?'STALE':'ERROR';
    setState({scope,phase,sample:null});
   });
  return()=>ac.abort();
 },[account,org,incidentId,scope,controller,denied,headScope,networkUnavailable,open,window,request,refresh,read]);
 const sample=!denied&&!networkUnavailable&&state.scope===scope&&state.sample&&state.sample.window===window&&(!headScope||state.sample.scope_fingerprint===headScope)?state.sample:null;
 const phase:Phase=denied?'DENIED':networkUnavailable?'OFFLINE':state.scope!==scope?'IDLE':
  sample&&live&& !['LIVE','POLLING'].includes(live.status)?'STALE':state.phase;
 const date=(value:string|number)=>new Intl.DateTimeFormat(locale==='de'?'de-DE':'sl-SI',
  {dateStyle:'medium',timeStyle:'medium',timeZone:'UTC'}).format(new Date(value));
 const numeric=(value:number|null)=>value===null?t('NOT_COLLECTED'):String(value);
 function metric(label:Parameters<typeof t>[0],value:ReliabilitySample) {
  return <article className="admin-card"><h3>{t(label)}</h3><p>{numeric(value.count)}</p>
   <p>{t('source')}: {t(value.source==='CANONICAL_OWN_RECEIPTS'?'receiptSource':value.source==='CANONICAL_TASK_TIMELINE'?'taskSource':'transportSource')} · {t('cap')}: {value.cap}</p>
   {value.capped&&<p role="status">{t('capped')}</p>}{value.last_at&&<p>{date(value.last_at)} UTC</p>}</article>;
 }
 return <details className="workspace-section" onToggle={event=>setOpen(event.currentTarget.open)}>
  <summary>{t('title')}</summary>
  <p>{t('localNote')}</p>
  <p>{t('context')}: {incidentId} / {org}</p>
  <div className="actions"><label>{t('window')}<select value={window} onChange={event=>setWindow(event.target.value as typeof window)}>
   {(['1h','24h','7d'] as const).map(value=><option key={value} value={value}>{t(value)}</option>)}</select></label>
   <button type="button" disabled={denied||phase==='LOADING'} onClick={()=>setRequest(v=>v+1)}>{t('refresh')}</button></div>
  {denied&&<p>{t('DENIED')}</p>}
  <p role={['DENIED','ERROR','BUSY','SCHEMA_UNAVAILABLE'].includes(phase)?'alert':'status'} aria-live="polite">{t(phase)}</p>
  {sample&&<>
   <p><strong>{t('serverOnly')} · {t(sample.mode)}</strong></p>
   <p>{t('sample')}: {date(sample.as_of_server)} UTC · {t('window')}: {t(sample.window)}</p>
   {live?.lastSuccess!=null&&<p>{t('head')}: {date(live.lastSuccess)} UTC</p>}
   {metric('receipt',sample.own_receipts)}{metric('activity',sample.task_history)}
   <section className="admin-card"><h3>{t('review')}</h3><p>{t('historyNote')}</p>
    <p>{t('blocked')}: {numeric(sample.task_history.blocked_events)} · {t('unable')}: {numeric(sample.task_history.unable_events)}</p>
    <a href="#sim-command">{t('commands')}</a>
   </section>
   <section className="admin-card"><h3>{t('transport')}</h3><p>{t('transportNote')}</p>
    {sample.task_transport.states?<dl>{(['PENDING','LEASED','ACCEPTED','FAILED','SUPPRESSED'] as const).map(key=>
     <div key={key}><dt>{t(key)}</dt><dd>{sample.task_transport.states![key]}</dd></div>)}</dl>:<p>{t('NOT_COLLECTED')}</p>}
    <p>{t('cap')}: {sample.task_transport.cap}</p>{sample.task_transport.capped&&<p role="status">{t('capped')}</p>}
   </section>
  </>}
  <p>{t('missing')}</p>
  <details><summary>{t('readiness')}</summary><p>{t('readinessNote')}</p>
   <ul>{stages.map(stage=><li key={stage}>{t(stage)}: {t('unrecorded')}</li>)}</ul>
  </details>
 </details>;
}
