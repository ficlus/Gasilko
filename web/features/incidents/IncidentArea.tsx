'use client';
import {SimulationSetup} from './SimulationSetup';
import {SimulationOverview} from './SimulationOverview';
import {SimulationBanner} from './SimulationProvider';
import {simulationErrors,defaultSimulationSetup} from '../../lib/operational/simulation';
import {simulationText} from '../../lib/operational/simulationMessages';
import {IncidentTasks} from './IncidentTasks';
import {taskErrors,taskMutations} from '../../lib/operational/tasks';
import {IncidentLayout,WorkspaceSection} from './workspace';
import {IncidentTimeline} from './IncidentTimeline';
import type {CrewOutcomes} from './TeamCrewTemplate';
import {IncidentResources} from './IncidentResources';
import {resourceErrors,resourceMutations} from '../../lib/operational/model';
import Link from 'next/link';
import {useRouter,useSearchParams} from 'next/navigation';
import {useEffect,useRef,useState,type FormEvent} from 'react';
import type {Locale} from '../../lib/i18n';
import {browserClient} from '../../lib/supabase/browser';
import {incidentText} from '../../lib/incidents/messages';
import {incidentPriorities,incidentSeverities,incidentStates,mutationNames,type Candidate,type CommandRequest,type Core,type Entry,type Incident,type IncidentRow,type InboxItem,type Mutation,type Receipt} from '../../lib/incidents/model';
import {CommandSection,CommandRequests} from './CommandSection';
import {IncidentCop} from './IncidentCop';
import {copErrors,copMutations,type CopFeedback} from '../../lib/incidents/cop';

class IncidentError extends Error {}
async function rpc<T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,expectedAccount?:string):Promise<T> {
 const response=await fetch('/api/incidents',{method:'POST',headers:{'Content-Type':'application/json',...(expectedAccount?{'X-Gasilko-Account':expectedAccount}:{})},body:JSON.stringify({name,args}),signal,cache:'no-store'});
 const result=await response.json();if(!response.ok)throw new IncidentError(result.error??'SERVER');return result.data as T;
}
type RequestState={action:Mutation;args:Record<string,unknown>;storageKey:string};
type Confirmation={training?:boolean;action:Mutation;payload:Record<string,unknown>;incident:string;version:string;org:string;description?:string};
const emptyCore:Core={title:'',summary:'',incident_type_id:'',priority:'NORMAL',severity:'UNKNOWN',latitude:'',longitude:'',address:'',unknown_location_reason:''};
export function IncidentArea({locale,account,destination,initialOrg}:{locale:Locale;account:string;destination?:string;initialOrg?:string}) {
 const baseText=incidentText(locale),simText=simulationText(locale),t=(key:string)=>key==='create_simulation'?simText('new'):(simulationErrors as readonly string[]).includes(key)?simText(key):baseText(key),router=useRouter();
 const requestedTraining=useSearchParams().get('training')==='1';
 const [simulationEnvironment,setSimulationEnvironment]=useState<{enabled:boolean;can_create:boolean}|null>(null),[training,setTraining]=useState(false),[simulationSetup,setSimulationSetup]=useState(defaultSimulationSetup);
 const [entry,setEntry]=useState<Entry|null>(null),[org,setOrg]=useState(initialOrg??''),[rows,setRows]=useState<IncidentRow[]>([]);
 const [detail,setDetail]=useState<Incident|null>(null);
 const [filter,setFilter]=useState(''),[page,setPage]=useState<{created:string;id:string}|null>(null),[refresh,setRefresh]=useState(0);
 const [loading,setLoading]=useState(true),[error,setError]=useState(''),[notice,setNotice]=useState('');
 const [core,setCore]=useState<Core>(emptyCore),[editing,setEditing]=useState(false),[busy,setBusy]=useState(false);
 const [confirmation,setConfirmation]=useState<Confirmation|null>(null),[reason,setReason]=useState(''),[pending,setPending]=useState<RequestState|null>(null);
 const [sessionValid,setSessionValid]=useState(true);
 const [commandInbox,setCommandInbox]=useState<CommandRequest[]>([]);
 const [copFeedback,setCopFeedback]=useState<CopFeedback>({sequence:0,kind:'saved'});
 const [crewOutcomes,setCrewOutcomes]=useState<CrewOutcomes>({});
 const [taskFeedback,setTaskFeedback]=useState<CopFeedback>({sequence:0,kind:'saved'});
 const [resourceFeedback,setResourceFeedback]=useState<CopFeedback>({sequence:0,kind:'saved'});
 const alive=useRef(true),sending=useRef(false),coreLoaded=useRef(false);
 const isNew=destination==='new',isList=!destination;
 const url=(id?:string,acting=org)=>`/${locale}/incidents${id?'/'+id:''}${acting?'?org='+encodeURIComponent(acting):''}`;
 const date=(value:string|null|undefined)=>value?new Date(value).toLocaleString(locale==='de'?'de-DE':'sl-SI'): '—';
 const safeError=(e:unknown)=>{
  const code=e instanceof IncidentError?e.message:'SERVER';
  if(([...simulationErrors,...copErrors,...resourceErrors,...taskErrors] as readonly string[]).includes(code))return code;
  if(['INVALID_COMMAND_HIERARCHY','INVALID_COMMAND_ROLE','INVALID_COMMAND_CANDIDATE','TRANSFER_NOT_CURRENT','TRANSFER_EXPIRED','TRANSFER_ALREADY_PENDING','LEAD_TRANSFER_REQUIRES_CONSENT','COMMANDER_STILL_VALID','PARTICIPANT_HAS_ACTIVE_COMMAND'].includes(code))return code;
  return code==='STALE_VERSION'?'stale':code==='NOT_AUTHORIZED'?'noAccess':code==='EXPIRED'?'expired':code==='VALIDATION_FAILED'?'invalid':
   code==='OPERATION_REUSED'?'reused':['INVALID_TRANSITION','INVALID_COMMANDER','INVALID_PARTICIPANT','INCIDENT_TERMINAL','INVALID_STATE'].includes(code)?'rejected':'error';
 };
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;};},[]);
 useEffect(()=>{
  const listener=browserClient()?.auth.onAuthStateChange((event,session)=>{
   if(event==='SIGNED_OUT'||(session&&session.user.id!==account)){
    alive.current=false;setSessionValid(false);setDetail(null);setRows([]);setEntry(null);setCommandInbox([]);setConfirmation(null);
    router.replace(`/${locale}/account`);router.refresh();
   }
  });return()=>listener?.data.subscription.unsubscribe();
 },[account,locale,router]);
 useEffect(()=>{
  const ac=new AbortController();setLoading(true);setError('');
  rpc<Entry>('incident_entry',{},ac.signal,account).then(value=>{
   if(ac.signal.aborted)return;setEntry(value);if(!initialOrg)setOrg(value.organizations[0]?.id??'');
   if(!coreLoaded.current)setCore(c=>({...c,incident_type_id:value.types[0]?.id??''}));
  }).catch(e=>{if(!ac.signal.aborted){setEntry(null);setDetail(null);setError(safeError(e));}}).finally(()=>{if(!ac.signal.aborted)setLoading(false);});
  return()=>ac.abort();
 },[refresh,initialOrg,account]);
 useEffect(()=>{
  const ac=new AbortController();setCommandInbox([]);
  if(isList)rpc<CommandRequest[]>('incident_command_inbox',{},ac.signal,account)
   .then(value=>{if(!ac.signal.aborted)setCommandInbox(value);}).catch(e=>{if(!ac.signal.aborted)setError(safeError(e));});
  return()=>ac.abort();
 },[refresh,isList,account]);
 useEffect(()=>{
  setSimulationEnvironment(null);setTraining(false);const ac=new AbortController();
  if(org)void rpc<{enabled:boolean;can_create:boolean}>('simulation_environment',{p_acting_organization_id:org},ac.signal,account)
   .then(value=>{if(!ac.signal.aborted){setSimulationEnvironment(value);setTraining(value.can_create&&requestedTraining);}}).catch(()=>{if(!ac.signal.aborted)setSimulationEnvironment(null);});
  return()=>ac.abort();
 },[org,account,requestedTraining]);
 useEffect(()=>{setDetail(null);setConfirmation(null);setTaskFeedback({sequence:0,kind:'saved'});coreLoaded.current=false;},[org]);
 useEffect(()=>{
  if(!entry||!org)return;const ac=new AbortController();
  setError('');setLoading(true);setRows([]);
  const args={p_acting_organization_id:org};
  const load=async()=>{
   if(!entry.organizations.some(o=>o.id===org))throw new IncidentError('NOT_AUTHORIZED');
   if(isList)setRows(await rpc<IncidentRow[]>('incident_list',{...args,p_status:filter,p_before_created:page?.created??null,p_before_id:page?.id??null},ac.signal));
   else if(!isNew){
    const value=await rpc<Incident|null>('incident_context',{...args,p_incident_id:destination},ac.signal,account);
    if(ac.signal.aborted)return;if(!value)throw new IncidentError('NOT_AUTHORIZED');setDetail(value);
    if(!coreLoaded.current){setCore({title:value.title,summary:value.summary,incident_type_id:value.incident_type_id,severity:value.severity,priority:value.priority,
     latitude:String(value.latitude??''),longitude:String(value.longitude??''),address:value.address??'',unknown_location_reason:value.unknown_location_reason??''});coreLoaded.current=true;}
   }
  };
  load().catch(e=>{if(!ac.signal.aborted){setError(safeError(e));setDetail(null);setRows([]);}}).finally(()=>{if(!ac.signal.aborted)setLoading(false);});
  return()=>ac.abort();
 },[entry,org,destination,filter,page,isList,isNew]);

 async function send(request:RequestState) {
  if(sending.current)return;sending.current=true;setBusy(true);setError('');setNotice('');setPending(request);
  if(request.action==='add_crew_member'){const payload=request.args.p_payload as {user_id:string;unit_assignment_id:string};setCrewOutcomes(v=>({...v,[payload.unit_assignment_id+':'+payload.user_id]:{state:'pending'}}));}
  try {
   const receipt=await rpc<Receipt>(mutationNames[request.action],request.args,undefined,account);
   try{sessionStorage.removeItem(request.storageKey);}catch{/* Stable in-memory request still covers this session. */}
   if(!alive.current)return;
   setPending(null);setConfirmation(null);setReason('');setNotice('saved');setEditing(false);
   if((taskMutations as readonly string[]).includes(request.action))setTaskFeedback(v=>({sequence:v.sequence+1,kind:'saved'}));
   if(copMutations.includes(request.action))setCopFeedback(v=>({sequence:v.sequence+1,kind:'saved'}));
   if((resourceMutations as readonly string[]).includes(request.action))setResourceFeedback(v=>({sequence:v.sequence+1,kind:'saved'}));
   if(request.action==='add_crew_member'){const payload=request.args.p_payload as {user_id:string;unit_assignment_id:string};const person=payload.unit_assignment_id+':'+payload.user_id;setCrewOutcomes(v=>({...v,[person]:{state:'saved'}}));}
   if(request.action==='create'||request.action==='create_simulation')router.push(url(receipt.incident_id,request.args.p_acting_organization_id as string));
   else {setRefresh(n=>n+1);}
  } catch(e) {
   if(!alive.current)return;setError(safeError(e));
   if(request.action==='add_crew_member'){const payload=request.args.p_payload as {user_id:string;unit_assignment_id:string};const person=payload.unit_assignment_id+':'+payload.user_id;setCrewOutcomes(v=>({...v,[person]:{state:e instanceof IncidentError&&e.message!=='SERVER'?'failed':'pending',error:safeError(e)}}));}
   if((taskMutations as readonly string[]).includes(request.action)&&e instanceof IncidentError&&['STALE_VERSION','INVALID_ACTION_DEFINITION'].includes(e.message))setTaskFeedback(v=>({sequence:v.sequence+1,kind:'stale'}));
   if(copMutations.includes(request.action)&&e instanceof IncidentError&&e.message==='STALE_VERSION')setCopFeedback(v=>({sequence:v.sequence+1,kind:'stale'}));
   if((resourceMutations as readonly string[]).includes(request.action)&&e instanceof IncidentError&&e.message==='STALE_VERSION')setResourceFeedback(v=>({sequence:v.sequence+1,kind:'stale'}));
   if(e instanceof IncidentError&&['NOT_AUTHORIZED','EXPIRED'].includes(e.message)){setTaskFeedback(v=>({sequence:v.sequence+1,kind:'blocked'}));setCopFeedback(v=>({sequence:v.sequence+1,kind:'blocked'}));setResourceFeedback(v=>({sequence:v.sequence+1,kind:'blocked'}));}
   // A domain rejection is final. A transport/server failure is ambiguous and
   // retains the exact operation/payload for retry, never silently rebased.
   if(e instanceof IncidentError&&e.message!=='SERVER'){
    setPending(null);try{sessionStorage.removeItem(request.storageKey);}catch{/* optional retry key storage */}
    if(e.message==='NOT_AUTHORIZED'||e.message==='EXPIRED'){setDetail(null);setRows([]);setCommandInbox([]);setConfirmation(null);}
   }
  } finally {sending.current=false;if(alive.current)setBusy(false);}
 }
 async function mutate(action:Mutation,payload:Record<string,unknown>,id:string|null=detail?.id??null,version:string=detail?.version??'0',acting=org) {
  if(!alive.current||loading||sending.current||pending)return;
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
 function ask(action:Mutation,payload:Record<string,unknown>={},item?:InboxItem,description?:string) {
  if(loading||busy||pending)return;setReason('');setConfirmation({training:!!(item?.training??detail?.training),action,payload,incident:item?.incident_id??detail?.id??'',version:item?.version??detail?.version??'0',org:item?.organization_id??org,description});
 }
 function submitCore(e:FormEvent) {
  e.preventDefault();const absent=core.latitude.trim()===''&&core.longitude.trim()==='';
  if(!absent&&(core.latitude.trim()===''||core.longitude.trim()===''||!Number.isFinite(Number(core.latitude))||!Number.isFinite(Number(core.longitude)))){setError('invalid');return;}
  const payload={...core,latitude:absent?null:Number(core.latitude),longitude:absent?null:Number(core.longitude),address:core.address.trim()||null};
  if(isNew&&training){
   if(!simulationEnvironment?.can_create||absent){setError('invalid');return;}
   void mutate('create_simulation',{core:payload,scenario:{...simulationSetup,longitude:Number(core.longitude),latitude:Number(core.latitude)}});
  }else void mutate(isNew?'create':'edit',payload);
 }
 function reload(){setNotice('');setRefresh(n=>n+1);}
 const coreForm=<form onSubmit={submitCore} className="incident-form"><fieldset disabled={loading||busy||!!pending}>
  <legend>{isNew?t('new'):t('edit')}</legend>
  {isNew&&simulationEnvironment?.can_create&&<label><input type="checkbox" checked={training} onChange={e=>setTraining(e.target.checked)}/>{simText('enable')}</label>}
  {isNew&&training&&<SimulationSetup locale={locale} value={simulationSetup} onChange={setSimulationSetup} core={core} onCore={setCore}/>}

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
  <div className="registry-toolbar"><label>{t('organization')}<select value={org} disabled={loading||busy||!!pending} onChange={e=>router.push(url(destination,e.target.value))}>
   <option value="">{t('select')}</option>{entry?.organizations.map(o=><option value={o.id} key={o.id}>{o.name}</option>)}</select></label>
   <Link href={url()}>{t('list')}</Link>{simulationEnvironment?.can_create&&<Link href={url('new')+'&training=1'}>{simText('new')}</Link>}{entry?.organizations.find(o=>o.id===org)?.can_create&&<Link href={url('new')}>{t('new')}</Link>}
   <button disabled={loading||busy||!!pending} onClick={reload}>{t('refresh')}</button></div>
  {error&&<p role="alert">{t(error)}</p>}{notice&&<p role="status">{t(notice)}</p>}{loading&&<p role="status">{t('loading')}</p>}
  {pending&&<section className="admin-notice"><p>{t('pending')}</p><button disabled={busy} onClick={()=>void send(pending)}>{t('retry')}</button></section>}
  {entry?.organizations.length===0&&<p>{t('noOrg')}</p>}
  {isList&&entry&&<>
   {simulationEnvironment?.enabled&&org&&<SimulationOverview key={account+org} locale={locale} account={account} org={org} read={rpc}/>}
   {commandInbox.length>0&&<section className="admin-card"><h2>{t('commandInbox')}</h2><p>{t('commandInboxLimit')}</p><CommandRequests locale={locale} items={commandInbox} disabled={loading||busy||!!pending} onAction={ask}/></section>}
   {(entry.invitations.length>0||entry.nominations.length>0)&&<section className="admin-card"><h2>{t('inbox')}</h2><p>{t('inboxLimit')}</p>
    {entry.nominations.map(item=><article className="web-row" key={item.id}>{item.training&&<SimulationBanner locale={locale}/>}<strong>{item.reference_number} · {item.title}</strong><p>{t('commander')} · {date(item.expires_at)}</p>
     <button disabled={loading||busy||!!pending} onClick={()=>ask('consent',{consent_id:item.id},item)}>{t('consent')}</button></article>)}
    {entry.invitations.map(item=><article className="web-row" key={item.id}><strong>{item.reference_number} · {item.title}</strong>
     <p>{entry.organizations.find(o=>o.id===item.organization_id)?.name}</p><div className="actions">
      <button disabled={loading||busy||!!pending} onClick={()=>ask('accept',{participant_id:item.id},item)}>{t('accept')}</button>
      <button disabled={loading||busy||!!pending} onClick={()=>ask('decline',{participant_id:item.id},item)}>{t('decline')}</button></div></article>)}</section>}
   <label>{t('status')}<select value={filter} onChange={e=>{setFilter(e.target.value);setPage(null);}}><option value="">{t('all')}</option>{incidentStates.map(x=><option key={x} value={x}>{t(x)}</option>)}</select></label>
   {!loading&&!error&&rows.length===0&&<p>{t('empty')}</p>}
   {rows.map(row=><article className="web-row" key={row.id}>{row.training&&<SimulationBanner locale={locale}/>}<Link href={url(row.id)}><strong>{row.reference_number} · {row.title}</strong></Link>
    <p><span className="admin-badge">{t(row.status)}</span> · {row.type.names[locale]??row.type.code}</p>
    <p>{t('priority')}: {t(row.priority)} · {t('severity')}: {t(row.severity)}</p><p>{row.lead_name} · {date(row.created_at)}</p>{row.address&&<p>{row.address}</p>}</article>)}
   <div className="actions">{page&&<button onClick={()=>setPage(null)}>{t('first')}</button>}{rows.length===25&&<button onClick={()=>{const last=rows[rows.length-1];setPage({created:last.created_at,id:last.id});}}>{t('more')}</button>}</div>
  </>}
  {isNew&&entry?.organizations.find(o=>o.id===org)?.can_create&&<><p>{t('draftIdentity')}</p>{coreForm}</>}
  {isNew&&entry&&!entry.organizations.find(o=>o.id===org)?.can_create&&<p>{t('noAccess')}</p>}
  {detail&&<IncidentLayout key={`${account}/${org}/${detail.id}`} locale={locale} simulation={{account,org,incidentId:detail.id,refresh,read:rpc,onInventoryChanged:()=>setRefresh(v=>v+1)}} operational={['ACTIVE','STABILIZED'].includes(detail.status)} locked={loading||busy||!!pending||!!confirmation} onAccessLost={()=>{setDetail(null);setError('noAccess');}}
   header={<header className="admin-card workspace-header">{detail.training&&<SimulationBanner locale={locale}/>}<p>{detail.reference_number}</p><h2>{detail.title}</h2><span className="admin-badge">{t(detail.status)}</span>
    <p>{t('priority')}: {t(detail.priority)} · {t('severity')}: {t(detail.severity)} · {detail.type.names[locale]??detail.type.code}</p>
    <p>{t('lead')}: {detail.lead_name}</p><p>{t('commander')}: {detail.commander?.name??t('noCommander')}</p>
    {detail.commander&&!detail.commander.valid&&['ACTIVE','STABILIZED'].includes(detail.status)&&<p role="alert">{t('invalidCommander')}</p>}
    {['CLOSED','CANCELLED'].includes(detail.status)?<p>{t('terminal')}</p>:!Object.values(detail.actions).some(Boolean)&&<p>{t('readOnly')}</p>}
   </header>}
   operations={<>
    <WorkspaceSection title={t('commandTree')}>   {detail.status!=='DRAFT'&&<CommandSection key={`${account}/${org}/${detail.id}/${detail.version}`} locale={locale} account={account} org={org} incident={detail} disabled={loading||busy||!!pending} read={rpc} onAction={ask}/>}
   <section className="admin-card"><h2>{t('commander')}</h2><p>{detail.commander?.name??t('noCommander')}</p>
    {detail.commander&&!detail.commander.valid&&!['CLOSED','CANCELLED'].includes(detail.status)&&<p role="alert">{t('invalidCommander')}</p>}
    {detail.nomination&&<p>{t('nomination')}: {detail.nomination.name} · {t(detail.nomination.status)} · {date(detail.nomination.expires_at)}</p>}
    {detail.actions.nominate&&<><p>{t('consentNotice')}</p><CandidatePicker key={`member/${detail.id}/${detail.version}`} locale={locale} org={org} incident={detail.id} kind="MEMBER" disabled={loading||busy||!!pending} onChoose={id=>ask('nominate',{user_id:id})}/></>}
   </section>
</WorkspaceSection>
    <WorkspaceSection title={t('participants')}>   <section className="admin-card"><h2>{t('participants')}</h2>{detail.participants.length<=1&&<p>{t('noParticipant')}</p>}
    {detail.participants.map(p=><article className="web-row" key={p.id}><strong>{p.name}</strong><p>{t(p.status)} · {t(p.agency_role)}</p>{p.end_reason&&<p>{p.end_reason}</p>}
     <div className="actions">{p.can_consent_release&&<button disabled={loading||busy||!!pending} onClick={()=>ask('consent_release',{participant_id:p.id})}>{t('consent_release')}</button>}
     {p.can_release&&<button disabled={loading||busy||!!pending} onClick={()=>ask('release',{participant_id:p.id})}>{t('release')}</button>}</div></article>)}
    {detail.actions.invite&&<CandidatePicker key={`org/${detail.id}/${detail.version}`} locale={locale} org={org} incident={detail.id} kind="ORGANIZATION" disabled={loading||busy||!!pending} onChoose={id=>ask('invite',{organization_id:id})}/>}
   </section>
</WorkspaceSection>
    <WorkspaceSection title={t('summary')}>   <section className="admin-card"><h2>{t('summary')}</h2><p>{t('created')}: {date(detail.created_at)} · {t('started')}: {date(detail.started_at??detail.declared_at)}</p><p className="incident-prose">{detail.summary||'—'}</p><h3>{t('location')}</h3><p>{detail.latitude===null?detail.unknown_location_reason:`${detail.latitude}, ${detail.longitude}`}</p><p>{detail.address}</p>
    {detail.actions.edit&&<button disabled={loading||busy||!!pending} onClick={()=>setEditing(!editing)}>{editing?t('dismiss'):t('edit')}</button>}
    {editing&&detail.actions.edit&&coreForm}</section>
</WorkspaceSection>
    <WorkspaceSection title={t('status')}>   <section className="admin-card"><h2>{t('status')}</h2><div className="actions">{(['activate','stabilize','reactivate','close','cancel'] as const).filter(action=>detail.actions[action]).map(action=><button key={action} disabled={loading||busy||!!pending} onClick={()=>ask(action)}>{t(action)}</button>)}</div></section>
</WorkspaceSection>
   </>}
   secondary={<IncidentTimeline locale={locale} account={account} org={org} incident={detail.id} revision={refresh} read={rpc}/>}>
   <IncidentCop key={`${account}/${org}/${detail.id}`} locale={locale} account={account} org={org} incidentId={detail.id} refresh={refresh} feedback={copFeedback} disabled={loading||busy||!!pending} read={rpc} onAction={ask}/>
   <IncidentTasks key={`${account}/${org}/${detail.id}`} locale={locale} account={account} org={org} incidentId={detail.id} version={detail.version} incidentReference={detail.reference_number} organizationName={entry?.organizations.find(o=>o.id===org)?.name??org} operational={['ACTIVE','STABILIZED'].includes(detail.status)} refresh={refresh} feedback={taskFeedback} disabled={loading||busy||!!pending} read={rpc} onAction={ask}/>
   <IncidentResources crewOutcomes={crewOutcomes} key={`${account}/${org}/${detail.id}`} locale={locale} account={account} org={org} incidentId={detail.id} refresh={refresh} feedback={resourceFeedback} disabled={loading||busy||!!pending} read={rpc} onAction={ask}/>
  </IncidentLayout>}
  {confirmation&&<ConfirmationDialog title={t(confirmation.action)} text={t('confirmation')} busy={busy||!!pending} onDismiss={()=>setConfirmation(null)}>
   {confirmation.training&&<SimulationBanner locale={locale}/>}
   {confirmation.description&&<p className="incident-prose">{confirmation.description}</p>}
   {confirmation.action==='recover_command'&&<p role="alert">{t('recoveryWarning')}</p>}
   <form onSubmit={e=>{e.preventDefault();void mutate(confirmation.action,{...confirmation.payload,...(reason?{reason}: {})},confirmation.incident,confirmation.version,confirmation.org);}}>
    {['reactivate','close','cancel','decline','consent_release','release','transfer_command','recover_command','end_role','decline_command','cancel_command'].includes(confirmation.action)&&<label>{t('reason')}<textarea required maxLength={2000} value={reason} onChange={e=>setReason(e.target.value)}/></label>}
    {['transfer_command','recover_command','accept_command','consent_lead'].includes(confirmation.action)&&<label><input type="checkbox" required/>{t('commandSafetyConfirm')}</label>}
    <div className="actions"><button disabled={loading||busy||!!pending} type="submit">{t('confirm')}</button><button disabled={loading||busy||!!pending} type="button" onClick={()=>setConfirmation(null)}>{t('dismiss')}</button></div>
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
