'use client';
import {useEffect,useRef,useState,type FormEvent,type ReactNode} from 'react';
import {WorkspaceSlot,WorkspaceSection} from './workspace';
import type {Locale} from '../../lib/i18n';
import {incidentText} from '../../lib/incidents/messages';
import type {Candidate,CommandRequest,CommandRole,CommandView,Incident,Mutation,InboxItem} from '../../lib/incidents/model';

type Read = <T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,account?:string)=>Promise<T>;
export type CommandAction = (action:Mutation,payload:Record<string,unknown>,item?:InboxItem,description?:string)=>void;
export function CommandRequests({locale,items,disabled,onAction}:{locale:Locale;items:CommandRequest[];disabled:boolean;onAction:CommandAction}) {
 const t=incidentText(locale);
 return <>{items.map(item=><article className="web-row" key={item.id}>
  {item.title&&<strong>{item.reference_number} · {item.title}</strong>}
  <h3>{t(item.kind)} · {item.name??'—'}</h3><p>{t(item.role)} · {item.organization_name} · <span className="admin-badge">{t(item.status)}</span></p>
  {item.unit_name&&<p>{t('UNIT_LEADER')}: {item.unit_name}</p>}
  {item.sector_name&&<p>{t('copSector')}: {item.sector_name}</p>}
  <p>{t('commander')}: {item.outgoing_name??'—'} · {t('lead')}: {item.lead_name}</p>
  <p>{t(item.transfer_lead?'combinedTransfer':'commandOnly')}</p>
  {item.transfer_lead&&<p>{t(item.lead_consented?'leadApproved':'leadWaiting')}</p>}
  <p>{t('expiresAt')}: {item.expires_at?new Date(item.expires_at).toLocaleString(locale):'—'}</p>{item.reason&&<p>{item.reason}</p>}
  <div className="actions">{([
   ['accept_command',item.can_accept&&(!item.transfer_lead||item.lead_consented)],
   ['decline_command',item.can_accept],['consent_lead',item.can_lead_consent&&!item.lead_consented],['cancel_command',item.can_cancel],
  ] as [Mutation,boolean][]).filter(([,allowed])=>allowed).map(([action])=><button key={action} disabled={disabled}
   onClick={()=>onAction(action,{request_id:item.id},item,[t('commander'),item.outgoing_name,t('proposed'),item.name,t(item.role),item.sector_name,item.unit_name,item.organization_name,t('lead'),item.lead_name,t(item.transfer_lead?'combinedTransfer':'commandOnly'),item.reason].filter(Boolean).join(' · '))}>{t(action)}</button>)}</div>
 </article>)}</>;
}

export function CommandSection({locale,account,org,incident,disabled,read,onAction}:{locale:Locale;account:string;org:string;incident:Incident;disabled:boolean;read:Read;onAction:CommandAction}) {
 const t=incidentText(locale);
 const [view,setView]=useState<CommandView|null>(null),[error,setError]=useState(false);
 const [page,setPage]=useState<{created:string;id:string}|null>(null);
 const [mode,setMode]=useState(''),[role,setRole]=useState('DEPUTY_COMMANDER'),[target,setTarget]=useState(org),[parent,setParent]=useState('');
 const [query,setQuery]=useState(''),[candidates,setCandidates]=useState<Candidate[]>([]),[selected,setSelected]=useState('');
 const [finding,setFinding]=useState(false),[candidateError,setCandidateError]=useState(false);
 const [sector,setSector]=useState('');
 const [unitScope,setUnitScope]=useState('');
 const searchController=useRef<AbortController|null>(null);
 useEffect(()=>{
  const ac=new AbortController();setView(null);setError(false);
  read<CommandView>('incident_command_view',{p_incident_id:incident.id,p_acting_organization_id:org,p_before_created:page?.created??null,p_before_id:page?.id??null},ac.signal,account)
   .then(value=>{if(!ac.signal.aborted)setView(value);}).catch(()=>{if(!ac.signal.aborted)setError(true);});
  return()=>ac.abort();
 },[incident.id,incident.version,org,account,page,read]);
 useEffect(()=>{searchController.current?.abort();setCandidates([]);setSelected('');setFinding(false);setCandidateError(false);},[mode,role,target,unitScope]);
 useEffect(()=>()=>searchController.current?.abort(),[]);
 async function search(e:FormEvent) {
  e.preventDefault();searchController.current?.abort();const ac=new AbortController();searchController.current=ac;
  setCandidates([]);setSelected('');setFinding(true);setCandidateError(false);
  try {const value=await read<Candidate[]>(mode==='offer_role'&&role==='UNIT_LEADER'?'incident_unit_leader_candidates':'incident_command_candidates',
   mode==='offer_role'&&role==='UNIT_LEADER'?{p_incident_id:incident.id,p_acting_organization_id:org,p_unit_assignment_id:unitScope,p_query:query}:{p_incident_id:incident.id,p_acting_organization_id:org,p_organization_id:target,p_role:mode==='offer_role'?role:'INCIDENT_COMMANDER',p_query:query},ac.signal,account);if(!ac.signal.aborted)setCandidates(value);}
  catch {if(!ac.signal.aborted)setCandidateError(true);}finally{if(!ac.signal.aborted)setFinding(false);}
 }
 const current=view?.roles.find(r=>r.role==='INCIDENT_COMMANDER');
 const eligibleParents=view?.roles.filter(r=>r.valid&&view.can_assign&&(role==='UNIT_LEADER'?r.id===view.units.find(u=>u.id===unitScope&&u.organization_id===target)?.parent_id:r.role==='INCIDENT_COMMANDER'))??[];
 const chosenParent=eligibleParents.find(r=>r.id===parent)?.id??eligibleParents[0]?.id;
 const participantChoices=incident.participants.filter(p=>p.status==='ACTIVE'&&(mode!=='recover_command'||p.organization_id===incident.lead_organization_id));
 const targetValid=participantChoices.some(p=>p.organization_id===target);
 function propose() {
  const person=candidates.find(c=>c.id===selected);if(!person||!targetValid)return;
  const payload:Record<string,unknown>={user_id:person.id,organization_id:target};
  if(mode==='offer_role'){payload.role=role;payload.parent_assignment_id=chosenParent;}
  if(mode==='offer_role'&&role==='SECTOR_COMMANDER')payload.sector_id=sector;
  if(mode==='offer_role'&&role==='UNIT_LEADER')payload.unit_assignment_id=unitScope;
  if(mode==='transfer_command')payload.mode=target===incident.lead_organization_id?'COMMAND':'LEAD_AND_COMMAND';
  onAction(mode as Mutation,payload,undefined,[t('commander'),current?.name??'—',t('proposed'),person.name,participantChoices.find(p=>p.organization_id===target)?.name,
   mode==='offer_role'?t(role):t(target===incident.lead_organization_id?'commandOnly':'combinedTransfer'),role==='SECTOR_COMMANDER'?view?.sectors.find(s=>s.id===sector)?.name:role==='UNIT_LEADER'?view?.units.find(u=>u.id===unitScope)?.name:''].filter(Boolean).join(' · '));
 }
 function tree(rows:CommandRole[],visited:string[]=[]):ReactNode {
  return <ul>{rows.filter(r=>!visited.includes(r.id)).map(r=><li key={r.id}><strong>{r.name??'—'}</strong> · {t(r.role)}
   <p>{r.organization_name} · {t(r.valid?'ACTIVE':'invalidAuthority')}</p>
   {r.unit_name&&<p>{t('UNIT_LEADER')}: {r.unit_name}</p>}
   {r.sector_name&&<p>{t('copSector')}: {r.sector_name}</p>}
   {r.can_end&&<button disabled={disabled} onClick={()=>onAction('end_role',{assignment_id:r.id},undefined,[r.name,t(r.role),r.organization_name].join(' · '))}>{t('end_role')}</button>}
   {view&&tree(view.roles.filter(c=>c.parent_id===r.id),[...visited,r.id])}</li>)}</ul>;
 }
 return <section className="admin-card"><h2>{t('commandTree')}</h2>
  <p>{t('capabilityNotice')}</p>
  {error?<p role="alert">{t('unavailable')}</p>:!view?<p role="status">{t('loading')}</p>:<>
   {view.operational&&!view.valid_commander&&<p role="alert">{t('recoveryWarning')}</p>}
   {tree(view.roles.filter(r=>!r.parent_id||!view.roles.some(p=>p.id===r.parent_id)))}
   {(view.can_assign||view.can_transfer||view.can_recover)&&<fieldset disabled={disabled}>
    <legend>{t('commandActions')}</legend><label>{t('action')}<select value={mode} onChange={e=>{setMode(e.target.value);setTarget(e.target.value==='recover_command'?incident.lead_organization_id:org);}}>
     <option value="">{t('select')}</option>{view.can_assign&&<option value="offer_role">{t('offer_role')}</option>}
     {view.can_transfer&&<option value="transfer_command">{t('transfer_command')}</option>}{view.can_recover&&<option value="recover_command">{t('recover_command')}</option>}
    </select></label>
    {mode&&((mode==='offer_role'&&view.can_assign)||(mode==='transfer_command'&&view.can_transfer)||(mode==='recover_command'&&view.can_recover))&&<>
     {mode==='recover_command'&&<p role="alert">{t('recoveryWarning')}</p>}
     {mode==='offer_role'&&<label>{t('role')}<select value={role} onChange={e=>setRole(e.target.value)}>
      {['DEPUTY_COMMANDER','AGENCY_COMMANDER','SECTOR_COMMANDER','UNIT_LEADER'].map(r=><option key={r} value={r}>{t(r)}</option>)}</select></label>}
     {mode==='offer_role'&&role==='SECTOR_COMMANDER'&&<label>{t('copSector')}<select value={sector} onChange={e=>setSector(e.target.value)}><option value="">{t('select')}</option>{view.sectors.map(s=><option key={s.id} value={s.id}>{s.code} · {s.name}</option>)}</select></label>}
     {mode==='offer_role'&&role==='UNIT_LEADER'&&<label>{t('UNIT')}<select value={unitScope} onChange={e=>{setUnitScope(e.target.value);setTarget(view.units.find(u=>u.id===e.target.value)?.organization_id??'');}}><option value="">{t('select')}</option>{view.units.map(u=><option key={u.id} value={u.id}>{u.name}</option>)}</select></label>}
     <label>{t('organization')}<select disabled={mode==='offer_role'&&role==='UNIT_LEADER'} value={target} onChange={e=>setTarget(e.target.value)}><option value="">{t('select')}</option>{participantChoices.map(p=><option key={p.id} value={p.organization_id}>{p.name}</option>)}</select></label>
     {mode==='offer_role'&&<label>{t('parentRole')}<select value={chosenParent??''} onChange={e=>setParent(e.target.value)}><option value="">{t('select')}</option>{eligibleParents.map(p=><option key={p.id} value={p.id}>{p.name} · {t(p.role)}</option>)}</select></label>}
     {mode==='transfer_command'&&<p>{t(target===incident.lead_organization_id?'commandOnly':'combinedTransfer')}</p>}
     <form onSubmit={search}><label>{t('search')}<input maxLength={100} value={query} onChange={e=>setQuery(e.target.value)}/></label><button disabled={!targetValid||finding||(mode==='offer_role'&&role==='UNIT_LEADER'&&!unitScope)}>{t('find')}</button></form>
     {finding&&<p role="status">{t('loading')}</p>}{candidateError&&<p role="alert">{t('unavailable')}</p>}
     <label>{t('proposed')}<select value={selected} onChange={e=>setSelected(e.target.value)}><option value="">{t('select')}</option>{candidates.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
     <button disabled={!selected||!targetValid||(mode==='offer_role'&&(!chosenParent||(role==='SECTOR_COMMANDER'&&!sector)||(role==='UNIT_LEADER'&&!unitScope)))} onClick={propose}>{t(mode)}</button>
    </>}
   </fieldset>}
   <WorkspaceSlot name="bottom"><WorkspaceSection title={t('commandInbox')+' · '+view.requests.length}>
   <h3>{t('commandInbox')}</h3><p>{t('commandInboxLimit')}</p><CommandRequests locale={locale} items={view.requests.map(r=>({...r,organization_id:org}))} disabled={disabled} onAction={onAction}/>
   </WorkspaceSection><WorkspaceSection title={t('commandHistory')}>
   <h3>{t('commandHistory')}</h3>{view.history.length===0&&<p>{t('noEvents')}</p>}
   {view.history.map(h=><article className="web-row" key={h.id}><strong>{h.name??'—'} · {t(h.role)}</strong><p>{h.organization_name} · {t(h.status)}</p>
    {h.unit_name&&<p>{t('UNIT_LEADER')}: {h.unit_name}</p>}
    {h.sector_name&&<p>{t('copSector')}: {h.sector_name}</p>}
    <p>{new Date(h.valid_from).toLocaleString(locale)} — {h.ended_at?new Date(h.ended_at).toLocaleString(locale):'—'}</p>
    <p>{t('assignedBy')}: {h.assigned_by??'—'}</p><p>{h.reason==='COMMAND_HIERARCHY_REBASED'?t('hierarchyRebased'):h.reason==='COMMAND_TRANSFER'?t('transfer_command'):h.reason}</p></article>)}
   <div className="actions">{page&&<button onClick={()=>setPage(null)}>{t('first')}</button>}{view.history.length===50&&<button onClick={()=>{const last=view.history[view.history.length-1];setPage({id:last.id,created:last.created_at});}}>{t('more')}</button>}</div>
   </WorkspaceSection></WorkspaceSlot>
  </>}
 </section>;
}
