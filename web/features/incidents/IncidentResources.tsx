'use client';
import {useEffect,useRef,useState,type FormEvent} from 'react';
import {incidentText} from '../../lib/incidents/messages';
import type {Locale} from '../../lib/i18n';
import {operationalText} from '../../lib/operational/messages';
import type {Resources,ResourceCandidate,Unit,Allocation} from '../../lib/operational/model';
import type {Mutation,InboxItem} from '../../lib/incidents/model';
import type {CopFeedback} from '../../lib/incidents/cop';
import type {CommandAction} from './CommandSection';
import {useWorkspace,WorkspaceSlot,WorkspaceSection} from './workspace';

type Read=<T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,account?:string)=>Promise<T>;
type Props={locale:Locale;account:string;org:string;incidentId:string;refresh:number;feedback:CopFeedback;disabled:boolean;read:Read;onAction:CommandAction};
export function IncidentResources({locale,account,org,incidentId,refresh,feedback,disabled,read,onAction}:Props){
 const workspace=useWorkspace();
 const t=operationalText(locale);
 const [view,setView]=useState<Resources|null>(null),[error,setError]=useState(''),[page,setPage]=useState(0),[reload,setReload]=useState(0);
 const [owner,setOwner]=useState(''),[mode,setMode]=useState<'UNIT'|'RESOURCE'>('UNIT'),[candidate,setCandidate]=useState<ResourceCandidate|null>(null);
 const [sector,setSector]=useState(''),[unit,setUnit]=useState(''),[quantity,setQuantity]=useState('1'),[newId,setNewId]=useState(''),[manual,setManual]=useState(false);
 const [stale,setStale]=useState(false),[blocked,setBlocked]=useState(false);
 const acRef=useRef<AbortController|null>(null);
 const scope={p_incident_id:incidentId,p_acting_organization_id:org};
 const blockedRef=useRef(false);
 function fail(e:unknown){const code=e instanceof Error?e.message:'SERVER';setError(code);
  if(['NOT_AUTHORIZED','EXPIRED'].includes(code)){blockedRef.current=true;setBlocked(true);setView(null);setCandidate(null);acRef.current?.abort();}}
 useEffect(()=>{if(feedback.kind==='blocked'){blockedRef.current=true;setBlocked(true);setView(null);setCandidate(null);acRef.current?.abort();}
  if(feedback.kind==='stale'){setStale(true);setReload(v=>v+1);}
  if(feedback.kind==='saved'){setCandidate(null);setNewId('');setManual(false);}
 },[feedback]);
 useEffect(()=>{if(blockedRef.current)return;const ac=new AbortController();acRef.current=ac;setError('');
  void read<Resources>('incident_resources',{p_incident_id:incidentId,p_acting_organization_id:org,p_history_page:page},ac.signal,account)
   .then(r=>{if(!ac.signal.aborted&&!blockedRef.current){setView(r);setOwner(v=>r.organizations.some(o=>o.id===v)?v:r.organizations[0]?.id??'');}})
   .catch(e=>{if(!ac.signal.aborted){setView(null);fail(e);}});
  return()=>ac.abort();
 },[account,org,incidentId,refresh,page,reload,read]);
 const locked=disabled||stale||blocked||!view;
 function ask(action:Mutation,payload:Record<string,unknown>,description:string){
  if(!view||locked)return;
  const context:InboxItem={id:incidentId,incident_id:incidentId,organization_id:org,version:view.version,title:'',reference_number:''};
  onAction(action,payload,context,description);
 }
 function propose(){
  if(!candidate||!owner)return;const id=newId||crypto.randomUUID();setNewId(id);
  if(mode==='UNIT'){if(!manual)return;ask('deploy_unit',{id,unit_id:candidate.id,sector_id:sector||null},[t('manualOnScene'),candidate.callsign,candidate.name,view?.organizations.find(o=>o.id===owner)?.name,view?.sectors.find(s=>s.id===sector)?.name].filter(Boolean).join(' · '));}
  else ask('allocate_resource',{id,resource_id:candidate.id,quantity,unit_assignment_id:unit||null},[candidate.name,quantity,t(candidate.unit_of_measure_code??''),view?.units.find(u=>u.id===unit)?.callsign??t('none')].join(' · '));
 }
 if(blocked)return <section className="admin-card"><p role="alert">{t(error||'NOT_AUTHORIZED')}</p></section>;
 return <WorkspaceSlot name="operational"><WorkspaceSection title={t('resourcesTitle')} open><section className="admin-card"><h2>{t('resourcesTitle')}</h2><p>{t('bounded')}</p>
  {error&&<p role="alert">{t(error)}</p>}{!view&&<p role="status">{t('loading')}</p>}
  {stale&&<aside role="alert"><p>{t('stale')}</p><button disabled={disabled||!view} onClick={()=>{setStale(false);setCandidate(null);setNewId('');}}>{t('reedit')}</button></aside>}
  {view&&<>
   <p>{t('version')}: {view.version}</p><button disabled={disabled} onClick={()=>setReload(v=>v+1)}>{t('refresh')}</button>
   <h3>{t('UNIT')}</h3>{!view.units.length&&<p>{t('empty')}</p>}
   {workspace&&view.units.map(u=><button className="web-row" key={u.id} onClick={()=>workspace.select({kind:'INCIDENT_UNIT',id:u.id})}>
    <strong>{u.callsign} · {u.name}</strong><span>{t(u.status)} · {u.sector_name??t('none')}</span>
    <small>{t('crew')}: {u.crew.length} · {t('UNIT_LEADER')}: {u.leader?.name??t('none')}</small></button>)}
   {view.units.filter(u=>!workspace||(workspace.selected?.kind==='INCIDENT_UNIT'&&workspace.selected.id===u.id)).map(u=><WorkspaceSlot name="selectedPane" key={u.id}><div><p>{incidentText(locale)('workspaceNoPosition')}</p><UnitCard key={u.id+':'+u.version} unit={u} view={view} locale={locale} locked={locked} account={account} scope={scope} read={read} ask={ask} onError={fail}/></div></WorkspaceSlot>)}
   <h3>{t('RESOURCE')}</h3>{!view.allocations.length&&<p>{t('empty')}</p>}
   {workspace&&view.allocations.map(a=><button className="web-row" key={a.id} onClick={()=>workspace.select({kind:'ALLOCATION',id:a.id})}>
    <strong>{a.name}</strong><span>{a.quantity} {t(a.unit_of_measure_code)} · {t(a.status)}</span><small>{a.unit_name??a.organization_name}</small></button>)}
   {view.allocations.filter(a=>!workspace||(workspace.selected?.kind==='ALLOCATION'&&workspace.selected.id===a.id)).map(a=><WorkspaceSlot name="selectedPane" key={a.id}><AllocationCard key={a.id} allocation={a} locale={locale} locked={locked} ask={ask}/></WorkspaceSlot>)}
   <div className="actions"><button disabled={!page||disabled} onClick={()=>setPage(v=>v-1)}>{t('previous')}</button><span>{t('history')} · {page+1}</span><button disabled={!view.history_more||disabled} onClick={()=>setPage(v=>v+1)}>{t('next')}</button></div>
   {!!view.organizations.length&&<fieldset disabled={locked}><legend>{t('deploy_unit')} / {t('allocate_resource')}</legend>
    <label>{t('organization')}<select value={owner} onChange={e=>{setOwner(e.target.value);setCandidate(null);setNewId('');setUnit('');}}>{view.organizations.map(o=><option key={o.id} value={o.id}>{o.name}</option>)}</select></label>
    <label>{t('select')}<select value={mode} onChange={e=>{setMode(e.target.value as 'UNIT'|'RESOURCE');setCandidate(null);setNewId('');}}><option value="UNIT">{t('UNIT')}</option><option value="RESOURCE">{t('RESOURCE')}</option></select></label>
    <CandidateSearch key={mode+owner} locale={locale} name={mode==='UNIT'?'incident_unit_candidates':'incident_resource_candidates'} args={{...scope,p_organization_id:owner}} account={account} read={read} onError={fail} onChoose={c=>{setCandidate(c);setNewId(crypto.randomUUID());setManual(false);}}/>
    {candidate&&<><h4>{candidate.callsign} · {candidate.name}</h4>{candidate.unit_kind&&<p>{t(candidate.unit_kind)} · {candidate.capabilities?.join(' · ')}</p>}
     {candidate.vehicle&&<p>{candidate.vehicle.callsign} · {candidate.vehicle.name} · {t(candidate.vehicle.availability)} · {t('seats')}: {candidate.vehicle.seats} · {t('water_litres')}: {candidate.vehicle.water_litres} · {candidate.vehicle.capabilities.join(' · ')}</p>}
     {mode==='UNIT'?<><label>{t('sector')}<select value={sector} onChange={e=>setSector(e.target.value)}><option value="">{t('none')}</option>{view.sectors.map(s=><option key={s.id} value={s.id}>{s.code} · {s.name}</option>)}</select></label>
      <label><input type="checkbox" checked={manual} onChange={e=>setManual(e.target.checked)}/>{t('manualOnScene')}</label></>
      :<><p>{t('available_quantity')}: {candidate.available_quantity} · {t(candidate.unit_of_measure_code??'')}</p>
       <label>{t('quantity')}<input type="number" min="0.001" step="0.001" value={quantity} onChange={e=>setQuantity(e.target.value)}/></label>
       <label>{t('UNIT')}<select value={unit} onChange={e=>setUnit(e.target.value)}><option value="">{t('none')}</option>{view.units.filter(u=>u.organization_id===owner&&!['RELEASED','UNAVAILABLE'].includes(u.status)).map(u=><option key={u.id} value={u.id}>{u.callsign} · {u.name}</option>)}</select></label></>}
     <button disabled={mode==='UNIT'?!manual:!quantity||Number(quantity)<=0} onClick={propose}>{t(mode==='UNIT'?'deploy_unit':'allocate_resource')}</button>
    </>}
   </fieldset>}
  </>}
 </section></WorkspaceSection></WorkspaceSlot>;
}
function CandidateSearch({locale,name,args,account,read,onChoose,onError}:{locale:Locale;name:string;args:Record<string,unknown>;account:string;read:Read;onChoose:(c:ResourceCandidate)=>void;onError:(e:unknown)=>void}){
 const t=operationalText(locale),[query,setQuery]=useState(''),[rows,setRows]=useState<ResourceCandidate[]>([]),[busy,setBusy]=useState(false),controller=useRef<AbortController|null>(null);
 useEffect(()=>()=>controller.current?.abort(),[]);
 async function search(e:FormEvent){e.preventDefault();controller.current?.abort();const ac=new AbortController();controller.current=ac;setRows([]);setBusy(true);
  try{const result=await read<ResourceCandidate[]>(name,{...args,p_query:query},ac.signal,account);if(!ac.signal.aborted)setRows(result);}
  catch(e){if(!ac.signal.aborted)onError(e);}finally{if(!ac.signal.aborted)setBusy(false);}}
 return <div><form onSubmit={search}><label>{t('search')}<input value={query} maxLength={100} onChange={e=>setQuery(e.target.value)}/></label><button disabled={busy}>{t('find')}</button></form>
  {busy&&<p role="status">{t('loading')}</p>}<ul>{rows.map(c=><li key={c.id}><button type="button" onClick={()=>onChoose(c)}>{c.callsign} · {c.name}{c.available_quantity?' · '+c.available_quantity+' '+t(c.unit_of_measure_code??''):''}</button></li>)}</ul></div>;
}
type Ask=(action:Mutation,payload:Record<string,unknown>,description:string)=>void;
function UnitCard({unit:u,view,locale,locked,account,scope,read,ask,onError}:{unit:Unit;view:Resources;locale:Locale;locked:boolean;account:string;scope:Record<string,unknown>;read:Read;ask:Ask;onError:(e:unknown)=>void}){
 const t=operationalText(locale),[sector,setSector]=useState(u.sector_id??''),[reason,setReason]=useState(''),[endCrew,setEndCrew]=useState(false),[person,setPerson]=useState<ResourceCandidate|null>(null),[crewRole,setCrewRole]=useState('RESPONDER'),[joinId,setJoinId]=useState('');
 const [history,setHistory]=useState<{rows:{id:string;name:string;crew_role:string;joined_at:string;left_at:string;left_by:string|null}[];more:boolean}|null>(null),[page,setPage]=useState(0),[showHistory,setShowHistory]=useState(false);
 useEffect(()=>{if(!showHistory)return;const ac=new AbortController();setHistory(null);
  void read<NonNullable<typeof history>>('incident_crew_history',{...scope,p_unit_assignment_id:u.id,p_page:page},ac.signal,account).then(r=>{if(!ac.signal.aborted)setHistory(r);}).catch(e=>{if(!ac.signal.aborted)onError(e);});
  return()=>ac.abort();
 // Scope is stable for this keyed component.
 // eslint-disable-next-line react-hooks/exhaustive-deps
 },[showHistory,page,u.id,account,read]);
 function status(value:string){ask('update_unit_status',{id:u.id,version:u.version,status:value,reason,...(['RELEASED','UNAVAILABLE'].includes(value)?{end_crew:'CONFIRMED'}:{})},[u.callsign,u.organization_name,t(value),reason,...(['RELEASED','UNAVAILABLE'].includes(value)?[t('releaseCrew')]:[])].join(' · '));}
 return <article className="web-row"><h4>{u.callsign} · {u.name}</h4><p>{u.organization_name} · <strong>{t(u.status)}</strong> · {t(u.unit_kind)}</p>
  <p>{t('sector')}: {u.sector_name??t('none')} · {t('version')}: {u.version}</p><p>{u.assigned_at} — {u.released_at??'—'} · {u.end_reason}</p>
  {u.vehicle&&<p>{t('VEHICLE')}: {u.vehicle.callsign} · {u.vehicle.name} · {t(u.vehicle.category_code)} · {t(u.vehicle.availability)} · {t('seats')}: {u.vehicle.seats} · {t('water_litres')}: {u.vehicle.water_litres} · {u.vehicle.capabilities.join(' · ')}</p>}
  <p>{t('capabilities')}: {u.capabilities.join(' · ')||t('none')}</p><p>{t('UNIT_LEADER')}: {u.leader?.name??t('none')}{u.leader&&!u.leader.valid?' · '+t('inactive'):''}</p>
  {u.can_sector&&<fieldset disabled={locked}><legend>{t('assign_unit_sector')}</legend><label>{t('sector')}<select value={sector} onChange={e=>setSector(e.target.value)}><option value="">{t('none')}</option>{view.sectors.map(s=><option key={s.id} value={s.id}>{s.code} · {s.name}</option>)}</select></label>
   <button onClick={()=>ask('assign_unit_sector',{id:u.id,version:u.version,sector_id:sector||null},u.callsign+' · '+(view.sectors.find(s=>s.id===sector)?.name??t('none')))}>{t('assign_unit_sector')}</button></fieldset>}
  {u.can_status&&<fieldset disabled={locked}><legend>{t('update_unit_status')}</legend>
   <label>{t('reason')}<input maxLength={2000} value={reason} onChange={e=>setReason(e.target.value)}/></label>
   {u.can_end&&<label><input type="checkbox" checked={endCrew} onChange={e=>setEndCrew(e.target.checked)}/>{t('releaseCrew')}</label>}
   <div className="actions">{u.status==='ON_SCENE'&&<button onClick={()=>status('RETURNING')}>{t('RETURNING')}</button>}
    {u.status==='RETURNING'&&u.can_end&&<button disabled={!endCrew} onClick={()=>status('RELEASED')}>{t('RELEASED')}</button>}
    {['ON_SCENE','RETURNING'].includes(u.status)&&u.can_end&&<button disabled={!endCrew||!reason.trim()} onClick={()=>status('UNAVAILABLE')}>{t('UNAVAILABLE')}</button>}</div>
   {!u.can_end&&<p>{t('releaseCrew')}</p>}
  </fieldset>}
  <h5>{t('crew')}</h5><p>{t('crewAuthority')}</p><ul>{u.crew.map(c=><li key={c.id}>{c.name} · {t(c.crew_role)} · {c.joined_at}
   {c.can_leave&&<button disabled={locked} onClick={()=>ask('remove_crew_member',{id:c.id,version:c.version},u.callsign+' · '+c.name)}>{t('remove_crew_member')}</button>}</li>)}</ul>
  {u.can_crew&&<fieldset disabled={locked}><legend>{t('add_crew_member')}</legend><CandidateSearch locale={locale} name="incident_crew_candidates" args={{...scope,p_unit_assignment_id:u.id}} account={account} read={read} onError={onError} onChoose={c=>{setPerson(c);setJoinId(crypto.randomUUID());}}/>
   {person&&<><p>{person.name}</p><label>{t('crew_role')}<select value={crewRole} onChange={e=>setCrewRole(e.target.value)}>{['LEADER','DRIVER','RESPONDER','SPECIALIST'].map(r=><option key={r} value={r}>{t(r)}</option>)}</select></label>
    <button onClick={()=>ask('add_crew_member',{id:joinId,unit_assignment_id:u.id,user_id:person.id,crew_role:crewRole},u.callsign+' · '+person.name+' · '+t(crewRole))}>{t('add_crew_member')}</button></>}
  </fieldset>}
  <button onClick={()=>setShowHistory(v=>!v)}>{t('history')} · {t('crew')}</button>
  {showHistory&&<>{!history?<p>{t('loading')}</p>:<><ul>{history.rows.map(c=><li key={c.id}>{c.name} · {t(c.crew_role)} · {c.joined_at} — {c.left_at} · {c.left_by}</li>)}</ul><div className="actions"><button disabled={!page} onClick={()=>setPage(v=>v-1)}>{t('previous')}</button><button disabled={!history.more} onClick={()=>setPage(v=>v+1)}>{t('next')}</button></div></>}</>}
 </article>;
}
function AllocationCard({allocation:a,locale,locked,ask}:{allocation:Allocation;locale:Locale;locked:boolean;ask:Ask}){
 const t=operationalText(locale),[consume,setConsume]=useState(false);
 return <article className="web-row"><h4>{a.name} · {a.quantity} {t(a.unit_of_measure_code)}</h4><p>{a.organization_name} · {a.unit_name??t('none')} · <strong>{t(a.status)}</strong></p><p>{a.allocated_at} — {a.ended_at??'—'}</p>
  {a.can_transition&&<fieldset disabled={locked}><legend>{t('transition_resource_allocation')}</legend>
   {a.status==='DEPLOYED'&&<label><input type="checkbox" checked={consume} onChange={e=>setConsume(e.target.checked)}/>{t('consumeWarning')}</label>}
   <div className="actions">{(a.status==='RESERVED'?['DEPLOYED','CANCELLED']:['RETURNED','CONSUMED']).map(state=><button key={state} disabled={state==='CONSUMED'&&!consume}
    onClick={()=>ask('transition_resource_allocation',{id:a.id,version:a.version,status:state},[a.name,a.quantity,t(a.unit_of_measure_code),a.unit_name??t('none'),a.organization_name,t(state),state==='CONSUMED'?t('consumeWarning'):''].join(' · '))}>{t(state)}</button>)}</div>
  </fieldset>}
 </article>;
}
