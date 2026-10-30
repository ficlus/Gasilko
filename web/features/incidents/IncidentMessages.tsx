'use client';
import {useEffect,useRef,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import type {TaskRead} from '../../lib/operational/tasks';
import {messageText} from '../../lib/incidents/messageText';
import {useIncidentLive} from './IncidentLiveProvider';
type Kind='INCIDENT'|'ORGANIZATION'|'UNIT';
type Message={id:string;incident_id:string;sender_user_id:string;sender_name:string;audience_kind:Kind;audience_org_id:string|null;audience_unit_assignment_id:string|null;body:string;supersedes_id:string|null;sent_at:string;version:string;can_correct:boolean};
type Target={kind:Kind;id:string;label:string};
type Page={schema_version:number;account:string;organization:string;incident_id:string;revision:string;scope_fingerprint:string;messages:Message[];targets:Target[];has_more:boolean;next_sent_at:string|null;next_id:string|null};
export function IncidentMessages({locale,account,org,incidentId,read,operational}:{locale:Locale;account:string;org:string;incidentId:string;read:TaskRead;operational:boolean}){
 const t=messageText(locale),live=useIncidentLive(),[page,setPage]=useState<Page|null>(null),[error,setError]=useState(false),[denied,setDenied]=useState(false);
 const [body,setBody]=useState(''),[selected,setSelected]=useState(''),[confirmed,setConfirmed]=useState(false),[parent,setParent]=useState<Message|null>(null);
 const [rejected,setRejected]=useState(false);
 const [busy,setBusy]=useState(false),[sent,setSent]=useState(false),[epoch,setEpoch]=useState(0),[history,setHistory]=useState<Message[]|null>(null);
 const [frozen,setFrozen]=useState<Record<string,unknown>|null>(null);
 const generation=useRef(0),frozenRef=useRef<Record<string,unknown>|null>(null);
 const scope=useRef<string|null>(null),alive=useRef(false),sending=useRef<AbortController|null>(null);
 const target=page?.targets.find(x=>x.kind+':'+x.id===selected);
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;generation.current++;sending.current?.abort();};},[account,org,incidentId]);
 useEffect(()=>{
  if(!operational){setPage(null);return;}
  const stamp=++generation.current;const ac=new AbortController();setError(false);
  read<Page>('incident_message_page',{p_acting_organization_id:org,p_incident_id:incidentId,p_scope_fingerprint:scope.current},ac.signal,account).then(value=>{
   if(ac.signal.aborted||stamp!==generation.current)return;
   if(value.account!==account||value.organization!==org||value.incident_id!==incidentId||value.schema_version!==1)throw new Error('SCHEMA_MISMATCH');
   scope.current=value.scope_fingerprint;setPage(current=>
    current&&current.revision===value.revision&&current.scope_fingerprint===value.scope_fingerprint&&current.messages.length>value.messages.length
     ? {...value,messages:current.messages.map(m=>value.messages.find(fresh=>fresh.id===m.id)??m),
        has_more:current.has_more,next_sent_at:current.next_sent_at,next_id:current.next_id}
     :value);setDenied(false);
  }).catch(err=>{
   if(ac.signal.aborted||stamp!==generation.current)return;setError(true);
   if(err instanceof Error&&['NOT_AUTHORIZED','EXPIRED','SCOPE_CHANGED'].includes(err.message)){setPage(null);setHistory(null);scope.current=null;setDenied(true);}
  });
  return()=>ac.abort();
 },[account,org,incidentId,read,operational,live?.lastSuccess,epoch]);
 function failure(err:unknown){
  setError(true);
  if(err instanceof Error&&['NOT_AUTHORIZED','EXPIRED','SCOPE_CHANGED'].includes(err.message)){
   setPage(null);setHistory(null);scope.current=null;setDenied(true);
  }
 }
 async function send(){
  if(busy||sending.current||!operational)return;
  let args=frozenRef.current??frozen;
  if(!args){
   if(!target||!confirmed||!body.trim()||Array.from(body).length>4000)return;
   args={p_operation:crypto.randomUUID(),p_acting_organization_id:org,p_incident_id:incidentId,p_expected_version:0,
    p_payload:{id:crypto.randomUUID(),body,audience_kind:target.kind,
     ...(target.kind==='ORGANIZATION'?{audience_org_id:target.id}:{}),
     ...(target.kind==='UNIT'?{audience_unit_assignment_id:target.id}:{}),
     ...(parent?{supersedes_id:parent.id,parent_version:parent.version}:{})}};
   frozenRef.current=args;setFrozen(args);
  }
  setBusy(true);setError(false);setSent(false);setRejected(false);const ac=new AbortController();sending.current=ac;
  try{
   const result=await read<{operation_id:string;incident_id:string;message_id:string}>('incident_message_send',args,ac.signal,account);
   if(!alive.current||ac.signal.aborted)return;
   const payload=args.p_payload as {id:string};
   if(result.operation_id!==args.p_operation||result.incident_id!==incidentId||result.message_id!==payload.id)throw new Error('SERVER');
   frozenRef.current=null;setFrozen(null);setBody('');setParent(null);setConfirmed(false);setSent(true);setEpoch(x=>x+1);live?.requestRefresh();
  }catch(err){if(alive.current&&!ac.signal.aborted){failure(err);setRejected(err instanceof Error&&['VALIDATION_FAILED','STALE_VERSION','INCIDENT_TERMINAL','OPERATION_REUSED'].includes(err.message));}}
  finally{if(sending.current===ac)sending.current=null;if(alive.current)setBusy(false);}
 }
 async function older(){
  if(!page?.has_more||busy)return;const stamp=generation.current;setBusy(true);
  try{
   const next=await read<Page>('incident_message_page',{p_acting_organization_id:org,p_incident_id:incidentId,
    p_before_sent_at:page.next_sent_at,p_before_id:page.next_id,p_scope_fingerprint:page.scope_fingerprint,
    p_expected_revision:page.revision},undefined,account);
   if(!alive.current||stamp!==generation.current)return;
   if(next.account!==account||next.organization!==org||next.incident_id!==incidentId||next.scope_fingerprint!==page.scope_fingerprint||next.revision!==page.revision)throw new Error('SCOPE_CHANGED');
   const rows=[...page.messages,...next.messages].filter((m,i,a)=>a.findIndex(x=>x.id===m.id)===i).slice(0,100);
   setPage({...next,messages:rows,has_more:rows.length<100&&next.has_more});
  }catch(err){if(alive.current&&stamp===generation.current){failure(err);setEpoch(x=>x+1);}}
  finally{if(alive.current)setBusy(false);}
 }
 async function showHistory(id:string){
  const stamp=generation.current;
  try{const value=await read<{messages:Message[]}>('incident_message_history',{p_acting_organization_id:org,p_incident_id:incidentId,p_message_id:id},undefined,account);
   if(alive.current&&stamp===generation.current)setHistory(value.messages);
  }catch(err){if(alive.current&&stamp===generation.current){setHistory(null);failure(err);}}
 }
 function correct(m:Message){
  const option=page?.targets.find(x=>x.kind===m.audience_kind&&(x.kind==='INCIDENT'||x.id===(x.kind==='UNIT'?m.audience_unit_assignment_id:m.audience_org_id)));
  if(!option||frozen)return;setParent(m);setBody(m.body);setSelected(option.kind+':'+option.id);setConfirmed(false);setSent(false);
 }
 if(!operational)return <section className="admin-card"><h2>{t('title')}</h2><p>{t('disabled')}</p></section>;
 if(denied||(body&&selected&&!target))return <section className="admin-card"><h2>{t('title')}</h2><p role="alert">{t('denied')}</p></section>;
 return <section className="admin-card" aria-label={t('title')}>
  <h2>{t('title')}</h2><p role="note">{t('warning')}</p>
  {!operational&&<p>{t('disabled')}</p>}
  {error&&<p role="alert">{t(denied?'denied':'error')}</p>}
  <p role="status">{busy?t('pending'):sent?t('sent'):frozen?t('pending'):t('draft')}</p>
  {frozen&&<p>{t('frozen')}</p>}
  {frozen&&rejected&&<button type="button" disabled={busy} onClick={()=>{frozenRef.current=null;setFrozen(null);setRejected(false);setConfirmed(false);}}>{t('newDraft')}</button>}
  <label>{t('scope')}<select value={selected} disabled={!!frozen||busy||!!parent} onChange={ev=>{setSelected(ev.target.value);setConfirmed(false);}}>
   <option value="">—</option>{page?.targets.map(x=><option key={x.kind+':'+x.id} value={x.kind+':'+x.id}>{t(x.kind)} · {x.label}</option>)}
  </select></label>
  <label>{t('body')}<textarea value={body} disabled={!!frozen||busy||!operational} onChange={ev=>setBody(Array.from(ev.target.value).slice(0,4000).join(''))}/></label>
  <p>{t('remaining')}: {4000-Array.from(body).length}</p>
  {target&&<p>{t(target.kind)} · {target.label}</p>}
  <label><input type="checkbox" checked={confirmed} disabled={!!frozen||busy} onChange={ev=>setConfirmed(ev.target.checked)}/>{t('confirm')}</label>
  <button type="button" disabled={busy||!operational||denied||(!frozen&&(!confirmed||!target||!body.trim()))} onClick={()=>void send()}>{t(frozen?'retry':'send')}</button>
  <ol>{page?.messages.map(m=><li key={m.id}><p>{m.sender_name} · {m.sent_at} · {t(m.audience_kind)}</p>
   <p style={{whiteSpace:'pre-wrap',overflowWrap:'anywhere'}}>{m.body}</p>{m.supersedes_id&&<strong>{t('corrected')}</strong>}
   <button type="button" onClick={()=>void showHistory(m.id)}>{t('history')}</button>
   {m.can_correct&&m.sender_user_id===account&&<button type="button" disabled={!!frozen||busy} onClick={()=>correct(m)}>{t('correct')}</button>}
  </li>)}</ol>
  {page&&!page.messages.length&&<p>{t('empty')}</p>}
  {page?.has_more&&<button type="button" disabled={busy} onClick={()=>void older()}>{t('older')}</button>}
  {history&&<section aria-label={t('history')}><h3>{t('history')}</h3>{history.map(m=><article key={m.id}><p>{m.sent_at}</p><p style={{whiteSpace:'pre-wrap'}}>{m.body}</p>
   {m.supersedes_id&&<button type="button" onClick={()=>void showHistory(m.supersedes_id!)}>{t('older')}</button>}</article>)}<button type="button" onClick={()=>setHistory(null)}>{t('close')}</button></section>}
 </section>;
}
