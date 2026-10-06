'use client';
import Link from 'next/link';
import {useRouter} from 'next/navigation';
import {useEffect,useRef,useState,type FormEvent} from 'react';
import type {Locale} from '../../lib/i18n';
import {browserClient} from '../../lib/supabase/browser';
import {incidentText} from '../../lib/incidents/messages';
import {incidentPriorities,incidentSeverities,incidentStates,mutationNames,type Candidate,type Core,type Entry,type Incident,type IncidentRow,type InboxItem,type Mutation,type Receipt,type Timeline} from '../../lib/incidents/model';

class IncidentError extends Error {}
async function rpc<T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,expectedAccount?:string):Promise<T> {
 const response=await fetch('/api/incidents',{method:'POST',headers:{'Content-Type':'application/json',...(expectedAccount?{'X-Gasilko-Account':expectedAccount}:{})},body:JSON.stringify({name,args}),signal,cache:'no-store'});
 const result=await response.json();if(!response.ok)throw new IncidentError(result.error??'SERVER');return result.data as T;
}
type RequestState={action:Mutation;args:Record<string,unknown>;storageKey:string};
type Confirmation={action:Mutation;payload:Record<string,unknown>;incident:string;version:string;org:string};
const emptyCore:Core={title:'',summary:'',incident_type_id:'',priority:'NORMAL',severity:'UNKNOWN',latitude:'',longitude:'',address:'',unknown_location_reason:''};
export function IncidentArea({locale,account,destination,initialOrg}:{locale:Locale;account:string;destination?:string;initialOrg?:string}) {
 const t=incidentText(locale),router=useRouter();
 const [entry,setEntry]=useState<Entry|null>(null),[org,setOrg]=useState(initialOrg??''),[rows,setRows]=useState<IncidentRow[]>([]);
 const [detail,setDetail]=useState<Incident|null>(null),[timeline,setTimeline]=useState<Timeline|null>(null),[cursor,setCursor]=useState<string|number>(0);
 const [filter,setFilter]=useState(''),[page,setPage]=useState<{created:string;id:string}|null>(null),[refresh,setRefresh]=useState(0);
 const [loading,setLoading]=useState(true),[error,setError]=useState(''),[notice,setNotice]=useState('');
 const [core,setCore]=useState<Core>(emptyCore),[editing,setEditing]=useState(false),[busy,setBusy]=useState(false);
 const [confirmation,setConfirmation]=useState<Confirmation|null>(null),[reason,setReason]=useState(''),[pending,setPending]=useState<RequestState|null>(null);
 const [sessionValid,setSessionValid]=useState(true);
 const alive=useRef(true),sending=useRef(false),coreLoaded=useRef(false);
 const isNew=destination==='new',isList=!destination;
 const url=(id?:string,acting=org)=>`/${locale}/incidents${id?'/'+id:''}${acting?'?org='+encodeURIComponent(acting):''}`;
 const date=(value:string|null|undefined)=>value?new Date(value).toLocaleString(locale==='de'?'de-DE':'sl-SI'): '—';
 const safeError=(e:unknown)=>{
  const code=e instanceof IncidentError?e.message:'SERVER';
  return code==='STALE_VERSION'?'stale':code==='NOT_AUTHORIZED'?'noAccess':code==='EXPIRED'?'expired':code==='VALIDATION_FAILED'?'invalid':
   code==='OPERATION_REUSED'?'reused':['INVALID_TRANSITION','INVALID_COMMANDER','INVALID_PARTICIPANT','INCIDENT_TERMINAL','INVALID_STATE'].includes(code)?'rejected':'error';
 };
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;};},[]);
 useEffect(()=>{
  const listener=browserClient()?.auth.onAuthStateChange((event,session)=>{
   if(event==='SIGNED_OUT'||(session&&session.user.id!==account)){
    alive.current=false;setSessionValid(false);setDetail(null);setRows([]);setTimeline(null);setEntry(null);setConfirmation(null);
    router.replace(`/${locale}/account`);router.refresh();
   }
  });return()=>listener?.data.subscription.unsubscribe();
 },[account,locale,router]);
 useEffect(()=>{
  const ac=new AbortController();setLoading(true);setError('');
  rpc<Entry>('incident_entry',{},ac.signal).then(value=>{
   setEntry(value);if(!initialOrg)setOrg(value.organizations[0]?.id??'');
   if(!coreLoaded.current)setCore(c=>({...c,incident_type_id:value.types[0]?.id??''}));
  }).catch(e=>{if(!ac.signal.aborted){setEntry(null);setError(safeError(e));}}).finally(()=>{if(!ac.signal.aborted)setLoading(false);});
  return()=>ac.abort();
 },[refresh,initialOrg]);
 useEffect(()=>{
  if(!entry||!org)return;const ac=new AbortController();
  setError('');setLoading(true);setRows([]);setDetail(null);setTimeline(null);
  const args={p_acting_organization_id:org};
  const load=async()=>{
   if(!entry.organizations.some(o=>o.id===org))throw new IncidentError('NOT_AUTHORIZED');
   if(isList)setRows(await rpc<IncidentRow[]>('incident_list',{...args,p_status:filter,p_before_created:page?.created??null,p_before_id:page?.id??null},ac.signal));
   else if(!isNew){
    const value=await rpc<Incident|null>('incident_context',{...args,p_incident_id:destination},ac.signal);
    if(!value)throw new IncidentError('NOT_AUTHORIZED');setDetail(value);
    if(!coreLoaded.current){setCore({title:value.title,summary:value.summary,incident_type_id:value.incident_type_id,severity:value.severity,priority:value.priority,
     latitude:String(value.latitude??''),longitude:String(value.longitude??''),address:value.address??'',unknown_location_reason:value.unknown_location_reason??''});coreLoaded.current=true;}
    setTimeline(await rpc<Timeline>('incident_timeline_page',{...args,p_incident_id:destination,p_after_sequence:cursor,p_limit:30},ac.signal));
   }
  };
  load().catch(e=>{if(!ac.signal.aborted){setError(safeError(e));setDetail(null);setRows([]);}}).finally(()=>{if(!ac.signal.aborted)setLoading(false);});
  return()=>ac.abort();
 },[entry,org,destination,filter,page,cursor,isList,isNew]);

 async function send(request:RequestState) {
  if(sending.current)return;sending.current=true;setBusy(true);setError('');setNotice('');setPending(request);
  try {
   const receipt=await rpc<Receipt>(mutationNames[request.action],request.args,undefined,account);
   try{sessionStorage.removeItem(request.storageKey);}catch{/* Stable in-memory request still covers this session. */}
   if(!alive.current)return;
   setPending(null);setConfirmation(null);setReason('');setNotice('saved');setEditing(false);
   if(request.action==='create')router.push(url(receipt.incident_id,request.args.p_acting_organization_id as string));
   else {setCursor(0);setRefresh(n=>n+1);}
  } catch(e) {
   if(!alive.current)return;setError(safeError(e));
   // A domain rejection is final. A transport/server failure is ambiguous and
   // retains the exact operation/payload for retry, never silently rebased.
   if(e instanceof IncidentError&&e.message!=='SERVER'){
    setPending(null);try{sessionStorage.removeItem(request.storageKey);}catch{/* optional retry key storage */}
    if(e.message==='NOT_AUTHORIZED'||e.message==='EXPIRED'){setDetail(null);setRows([]);setTimeline(null);setConfirmation(null);}
   }
  } finally {sending.current=false;if(alive.current)setBusy(false);}
 }
 async function mutate(action:Mutation,payload:Record<string,unknown>,id:string|null=detail?.id??null,version:string=detail?.version??'0',acting=org) {
  if(!alive.current||sending.current||pending)return;
  sending.current=true;setBusy(true);
  try{
   const base={p_acting_organization_id:acting,p_incident_id:id,p_expected_version:version,p_payload:payload};
   const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(JSON.stringify({action,...base})));
   const hash=Array.from(new Uint8Array(bytes),b=>b.toString(16).padStart(2,'0')).join('');
   const storageKey=`gasilko.incident.operation.${account}.${hash}`;
   let operation:string=crypto.randomUUID();try{operation=sessionStorage.getItem(storageKey)??operation;sessionStorage.setItem(storageKey,operation);}catch{/* Retain operation in memory. */}
   sending.current=false;if(!alive.current)return;
   await send({action,args:{...base,p_operation:operation},storageKey});
  }catch{sending.current=false;setBusy(false);setError('error');}
 }
 function ask(action:Mutation,payload:Record<string,unknown>={},item?:InboxItem) {
  if(busy||pending)return;setReason('');setConfirmation({action,payload,incident:item?.incident_id??detail?.id??'',version:item?.version??detail?.version??'0',org:item?.organization_id??org});
 }
 function submitCore(e:FormEvent) {
  e.preventDefault();const absent=core.latitude.trim()===''&&core.longitude.trim()==='';
  if(!absent&&(core.latitude.trim()===''||core.longitude.trim()===''||!Number.isFinite(Number(core.latitude))||!Number.isFinite(Number(core.longitude)))){setError('invalid');return;}
  void mutate(isNew?'create':'edit',{...core,latitude:absent?null:Number(core.latitude),longitude:absent?null:Number(core.longitude),address:core.address.trim()||null});
 }
 function reload(){setNotice('');setCursor(0);setRefresh(n=>n+1);}
 const coreForm=<form onSubmit={submitCore} className="incident-form"><fieldset disabled={busy||!!pending}>
  <legend>{isNew?t('new'):t('edit')}</legend>
  <label>{t('name')}<input required maxLength={200} value={core.title} onChange={e=>setCore({...core,title:e.target.value})}/></label>
  <label>{t('summary')}<textarea maxLength={10000} value={core.summary} onChange={e=>setCore({...core,summary:e.target.value})}/></label>
  <label>{t('type')}<select required value={core.incident_type_id} onChange={e=>setCore({...core,incident_type_id:e.target.value})}>
   {detail&&!entry?.types.some(x=>x.id===detail.incident_type_id)&&<option value={detail.incident_type_id}>{detail.type.names[locale]??detail.type.code}</option>}
   {entry?.types.map(x=><option key={x.id} value={x.id}>{x.names[locale]??x.code}</option>)}</select></label>
  <div className="web-form-grid">{(['severity','priority'] as const).map(key=><label key={key}>{t(key)}<select value={core[key]} onChange={e=>setCore({...core,[key]:e.target.value})}>
   {(key==='severity'?incidentSeverities:incidentPriorities).map(x=><option key={x} value={x}>{t(x)}</option>)}</select></label>)}</div>
  <div className="web-form-grid">{(['latitude','longitude'] as const).map(key=><label key={key}>{t(key)}<input type="number" step="any" min={key==='latitude'?-90:-180} max={key==='latitude'?90:180} value={core[key]} onChange={e=>setCore({...core,[key]:e.target.value})}/></label>)}</div>
  {core.latitude===''&&core.longitude===''&&<label>{t('unknownLocation')}<input required maxLength={1000} value={core.unknown_location_reason} onChange={e=>setCore({...core,unknown_location_reason:e.target.value})}/></label>}
  <label>{t('address')}<input maxLength={1000} value={core.address} onChange={e=>setCore({...core,address:e.target.value})}/></label>
  <button type="submit">{t('save')}</button></fieldset></form>;
 if(!sessionValid)return <p role="alert">{t('expired')}</p>;
 return <div className="registry incident-area">
  <div className="registry-toolbar"><label>{t('organization')}<select value={org} disabled={busy||!!pending} onChange={e=>router.push(url(destination,e.target.value))}>
   <option value="">{t('select')}</option>{entry?.organizations.map(o=><option value={o.id} key={o.id}>{o.name}</option>)}</select></label>
   <Link href={url()}>{t('list')}</Link>{entry?.organizations.find(o=>o.id===org)?.can_create&&<Link href={url('new')}>{t('new')}</Link>}
   <button disabled={busy||!!pending} onClick={reload}>{t('refresh')}</button></div>
  {error&&<p role="alert">{t(error)}</p>}{notice&&<p role="status">{t(notice)}</p>}{loading&&<p role="status">{t('loading')}</p>}
  {pending&&<section className="admin-notice"><p>{t('pending')}</p><button disabled={busy} onClick={()=>void send(pending)}>{t('retry')}</button></section>}
  {entry?.organizations.length===0&&<p>{t('noOrg')}</p>}
  {isList&&entry&&<>
   {(entry.invitations.length>0||entry.nominations.length>0)&&<section className="admin-card"><h2>{t('inbox')}</h2><p>{t('inboxLimit')}</p>
    {entry.nominations.map(item=><article className="web-row" key={item.id}><strong>{item.reference_number} · {item.title}</strong><p>{t('commander')} · {date(item.expires_at)}</p>
     <button disabled={busy||!!pending} onClick={()=>ask('consent',{consent_id:item.id},item)}>{t('consent')}</button></article>)}
    {entry.invitations.map(item=><article className="web-row" key={item.id}><strong>{item.reference_number} · {item.title}</strong>
     <p>{entry.organizations.find(o=>o.id===item.organization_id)?.name}</p><div className="actions">
      <button disabled={busy||!!pending} onClick={()=>ask('accept',{participant_id:item.id},item)}>{t('accept')}</button>
      <button disabled={busy||!!pending} onClick={()=>ask('decline',{participant_id:item.id},item)}>{t('decline')}</button></div></article>)}</section>}
   <label>{t('status')}<select value={filter} onChange={e=>{setFilter(e.target.value);setPage(null);}}><option value="">{t('all')}</option>{incidentStates.map(x=><option key={x} value={x}>{t(x)}</option>)}</select></label>
   {!loading&&!error&&rows.length===0&&<p>{t('empty')}</p>}
   {rows.map(row=><article className="web-row" key={row.id}><Link href={url(row.id)}><strong>{row.reference_number} · {row.title}</strong></Link>
    <p><span className="admin-badge">{t(row.status)}</span> · {row.type.names[locale]??row.type.code}</p>
    <p>{t('priority')}: {t(row.priority)} · {t('severity')}: {t(row.severity)}</p><p>{row.lead_name} · {date(row.created_at)}</p>{row.address&&<p>{row.address}</p>}</article>)}
   <div className="actions">{page&&<button onClick={()=>setPage(null)}>{t('first')}</button>}{rows.length===25&&<button onClick={()=>{const last=rows[rows.length-1];setPage({created:last.created_at,id:last.id});}}>{t('more')}</button>}</div>
  </>}
  {isNew&&entry?.organizations.find(o=>o.id===org)?.can_create&&<><p>{t('draftIdentity')}</p>{coreForm}</>}
  {isNew&&entry&&!entry.organizations.find(o=>o.id===org)?.can_create&&<p>{t('noAccess')}</p>}
  {detail&&<>
   <header className="admin-card"><p>{detail.reference_number}</p><h2>{detail.title}</h2><span className="admin-badge">{t(detail.status)}</span>
    <p>{t('priority')}: {t(detail.priority)} · {t('severity')}: {t(detail.severity)} · {detail.type.names[locale]??detail.type.code}</p>
    <p>{t('lead')}: {detail.lead_name}</p><p>{t('created')}: {date(detail.created_at)} · {t('started')}: {date(detail.started_at??detail.declared_at)}</p>
    {['CLOSED','CANCELLED'].includes(detail.status)?<p>{t('terminal')}</p>:!Object.values(detail.actions).some(Boolean)&&<p>{t('readOnly')}</p>}
   </header>
   <section className="admin-card"><h2>{t('summary')}</h2><p className="incident-prose">{detail.summary||'—'}</p><h3>{t('location')}</h3><p>{detail.latitude===null?detail.unknown_location_reason:`${detail.latitude}, ${detail.longitude}`}</p><p>{detail.address}</p>
    {detail.actions.edit&&<button disabled={busy||!!pending} onClick={()=>setEditing(!editing)}>{editing?t('dismiss'):t('edit')}</button>}
    {editing&&detail.actions.edit&&coreForm}</section>
   <section className="admin-card"><h2>{t('commander')}</h2><p>{detail.commander?.name??t('noCommander')}</p>
    {detail.commander&&!detail.commander.valid&&!['CLOSED','CANCELLED'].includes(detail.status)&&<p role="alert">{t('invalidCommander')}</p>}
    {detail.nomination&&<p>{t('nomination')}: {detail.nomination.name} · {t(detail.nomination.status)} · {date(detail.nomination.expires_at)}</p>}
    {detail.actions.nominate&&<><p>{t('consentNotice')}</p><CandidatePicker key={`member/${detail.id}/${detail.version}`} locale={locale} org={org} incident={detail.id} kind="MEMBER" disabled={busy||!!pending} onChoose={id=>ask('nominate',{user_id:id})}/></>}
   </section>
   <section className="admin-card"><h2>{t('participants')}</h2>{detail.participants.length<=1&&<p>{t('noParticipant')}</p>}
    {detail.participants.map(p=><article className="web-row" key={p.id}><strong>{p.name}</strong><p>{t(p.status)} · {t(p.agency_role)}</p>{p.end_reason&&<p>{p.end_reason}</p>}
     <div className="actions">{p.can_consent_release&&<button disabled={busy||!!pending} onClick={()=>ask('consent_release',{participant_id:p.id})}>{t('consent_release')}</button>}
     {p.can_release&&<button disabled={busy||!!pending} onClick={()=>ask('release',{participant_id:p.id})}>{t('release')}</button>}</div></article>)}
    {detail.actions.invite&&<CandidatePicker key={`org/${detail.id}/${detail.version}`} locale={locale} org={org} incident={detail.id} kind="ORGANIZATION" disabled={busy||!!pending} onChoose={id=>ask('invite',{organization_id:id})}/>}
   </section>
   <section className="admin-card"><h2>{t('status')}</h2><div className="actions">{(['activate','stabilize','reactivate','close','cancel'] as const).filter(action=>detail.actions[action]).map(action=><button key={action} disabled={busy||!!pending} onClick={()=>ask(action)}>{t(action)}</button>)}</div></section>
   <section className="admin-card"><h2>{t('timeline')}</h2>{timeline?.events.length===0&&<p>{t('noEvents')}</p>}
    <ol>{timeline?.events.map(event=><li key={event.id}><strong>{t(event.event_code)}</strong>{event.subject_name&&<p>{event.subject_name}</p>}<p>{date(event.recorded_at)} · {event.actor_name??'—'} · {event.actor_organization_name}</p>{event.data.reason&&<p>{event.data.reason}</p>}</li>)}</ol>
    <div className="actions">{String(cursor)!=='0'&&<button onClick={()=>setCursor(0)}>{t('older')}</button>}{timeline&&timeline.events.length===30&&<button onClick={()=>setCursor(timeline.events[timeline.events.length-1].sequence)}>{t('later')}</button>}</div>
   </section>
  </>}
  {confirmation&&<ConfirmationDialog title={t(confirmation.action)} text={t('confirmation')} busy={busy||!!pending} onDismiss={()=>setConfirmation(null)}>
   <form onSubmit={e=>{e.preventDefault();void mutate(confirmation.action,{...confirmation.payload,...(reason?{reason}: {})},confirmation.incident,confirmation.version,confirmation.org);}}>
    {['reactivate','close','cancel','decline','consent_release','release'].includes(confirmation.action)&&<label>{t('reason')}<textarea required maxLength={2000} value={reason} onChange={e=>setReason(e.target.value)}/></label>}
    <div className="actions"><button disabled={busy||!!pending} type="submit">{t('confirm')}</button><button disabled={busy||!!pending} type="button" onClick={()=>setConfirmation(null)}>{t('dismiss')}</button></div>
   </form>{error&&<p role="alert">{t(error)}</p>}{error==='stale'&&!pending&&<button onClick={()=>{setConfirmation(null);reload();}}>{t('refresh')}</button>}{pending&&<><p>{t('pending')}</p><button disabled={busy} onClick={()=>void send(pending)}>{t('retry')}</button></>}
  </ConfirmationDialog>}
 </div>;
}

function ConfirmationDialog({title,text,busy,onDismiss,children}:{title:string;text:string;busy:boolean;onDismiss:()=>void;children:React.ReactNode}) {
 const ref=useRef<HTMLDialogElement>(null);
 useEffect(()=>{const dialog=ref.current;dialog?.showModal();return()=>dialog?.close();},[]);
 return <dialog ref={ref} aria-labelledby="incident-confirm-title" onCancel={e=>{e.preventDefault();if(!busy)onDismiss();}}><h2 id="incident-confirm-title">{title}</h2><p>{text}</p>{children}</dialog>;
}
function CandidatePicker({locale,org,incident,kind,disabled,onChoose}:{locale:Locale;org:string;incident:string;kind:'MEMBER'|'ORGANIZATION';disabled:boolean;onChoose:(id:string)=>void}) {
 const t=incidentText(locale);const [query,setQuery]=useState(''),[rows,setRows]=useState<Candidate[]>([]),[selected,setSelected]=useState(''),[error,setError]=useState(false),[loading,setLoading]=useState(false);
 const controller=useRef<AbortController|null>(null);
 useEffect(()=>()=>controller.current?.abort(),[]);
 async function search(e:FormEvent){e.preventDefault();controller.current?.abort();const ac=new AbortController();controller.current=ac;setLoading(true);setError(false);setRows([]);setSelected('');
  try{const value=await rpc<Candidate[]>('incident_candidates',{p_incident_id:incident,p_acting_organization_id:org,p_kind:kind,p_query:query},ac.signal);if(!ac.signal.aborted)setRows(value);}
  catch{if(!ac.signal.aborted)setError(true);}finally{if(!ac.signal.aborted)setLoading(false);}}
 return <div><form onSubmit={search}><label>{kind==='MEMBER'?t('nominate'):t('invite')}<input maxLength={100} value={query} onChange={e=>setQuery(e.target.value)} placeholder={t('search')}/></label><button disabled={disabled||loading}>{t('find')}</button></form>
  {error&&<p role="alert">{t('unavailable')}</p>}{loading&&<p role="status">{t('loading')}</p>}
  {!loading&&rows.length===0&&<p>{t('noCandidates')}</p>}{rows.length>0&&<><label>{t('select')}<select value={selected} onChange={e=>setSelected(e.target.value)}><option value="">{t('select')}</option>{rows.map(r=><option key={r.id} value={r.id}>{r.name}</option>)}</select></label>
   <button disabled={disabled||!selected} onClick={()=>onChoose(selected)}>{kind==='MEMBER'?t('nominate'):t('invite')}</button></>}
 </div>;
}
