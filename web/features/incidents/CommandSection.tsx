'use client';
import {SimulationBanner} from './SimulationProvider';
import {useEffect,useMemo,useRef,useState,type FormEvent,type ReactNode} from 'react';
import {WorkspaceSlot,WorkspaceSection,useWorkspace} from './workspace';
import type {Locale} from '../../lib/i18n';
import {incidentText} from '../../lib/incidents/messages';
import type {Candidate,CommandRequest,CommandRole,CommandView,Incident,Mutation,InboxItem} from '../../lib/incidents/model';

type Read = <T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,account?:string)=>Promise<T>;
export type CommandAction = (action:Mutation,payload:Record<string,unknown>,item?:InboxItem,description?:string)=>void;
export function CommandRequests({locale,items,disabled,onAction}:{locale:Locale;items:CommandRequest[];disabled:boolean;onAction:CommandAction}) {
 const t=incidentText(locale);
 return <>{items.map(item=><article className="web-row" key={item.id}>{item.training&&<SimulationBanner locale={locale}/>}
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
 const t=incidentText(locale),workspace=useWorkspace();
 const [expanded,setExpanded]=useState<Set<string>>(()=>new Set());
 const [filter,setFilter]=useState(''),[selectedRole,setSelectedRole]=useState<string|null>(null),[draftVersion,setDraftVersion]=useState<string|null>(null);
 const [view,setView]=useState<CommandView|null>(null),[error,setError]=useState(false);
 const [page,setPage]=useState<{created:string;id:string}|null>(null);
 const [mode,setMode]=useState(''),[role,setRole]=useState('DEPUTY_COMMANDER'),[target,setTarget]=useState(org),[parent,setParent]=useState('');
 const [query,setQuery]=useState(''),[candidates,setCandidates]=useState<Candidate[]>([]),[selected,setSelected]=useState('');
 const [finding,setFinding]=useState(false),[candidateError,setCandidateError]=useState(false);
 const [sector,setSector]=useState('');
 const [unitScope,setUnitScope]=useState('');
 const management=useRef<HTMLFieldSetElement>(null);
 const searchController=useRef<AbortController|null>(null);
 useEffect(()=>{
  const ac=new AbortController();setError(false);
  read<CommandView>('incident_command_view',{p_incident_id:incident.id,p_acting_organization_id:org,p_before_created:page?.created??null,p_before_id:page?.id??null},ac.signal,account)
   .then(value=>{if(!ac.signal.aborted)setView(value);}).catch(error=>{if(!ac.signal.aborted){setError(true);if(error instanceof Error&&['NOT_AUTHORIZED','EXPIRED'].includes(error.message)){setView(null);setMode('');setCandidates([]);setSelected('');setSelectedRole(null);}}});
  return()=>ac.abort();
 },[incident.id,incident.version,org,account,page,read]);
 useEffect(()=>{searchController.current?.abort();setCandidates([]);setSelected('');setFinding(false);setCandidateError(false);},[mode,role,target,unitScope,sector]);
 useEffect(()=>()=>searchController.current?.abort(),[]);
 useEffect(()=>{setExpanded(new Set());setFilter('');},[incident.id,org,account]);
 async function search(e:FormEvent) {
  e.preventDefault();searchController.current?.abort();const ac=new AbortController();searchController.current=ac;
  setCandidates([]);setSelected('');setFinding(true);setCandidateError(false);
  try {const value=await read<Candidate[]>(mode==='offer_role'&&role==='UNIT_LEADER'?'incident_unit_leader_candidates':'incident_command_candidates',
   mode==='offer_role'&&role==='UNIT_LEADER'?{p_incident_id:incident.id,p_acting_organization_id:org,p_unit_assignment_id:unitScope,p_query:query}:{p_incident_id:incident.id,p_acting_organization_id:org,p_organization_id:target,p_role:mode==='offer_role'?role:'INCIDENT_COMMANDER',p_query:query},ac.signal,account);if(!ac.signal.aborted)setCandidates(value);}
  catch {if(!ac.signal.aborted)setCandidateError(true);}finally{if(!ac.signal.aborted)setFinding(false);}
 }
 const childrenByParent=useMemo(()=>{const result=new Map<string,CommandRole[]>();for(const item of view?.roles??[]){if(item.parent_id)result.set(item.parent_id,[...(result.get(item.parent_id)??[]),item]);}return result;},[view?.roles]);
 const current=view?.roles.find(r=>r.role==='INCIDENT_COMMANDER');
 const eligibleParents=view?.roles.filter(r=>r.valid&&view.can_assign&&(role==='UNIT_LEADER'?r.id===view.units.find(u=>u.id===unitScope&&u.organization_id===target)?.parent_id:r.role==='INCIDENT_COMMANDER'))??[];
 const chosenParent=eligibleParents.find(r=>r.id===parent)?.id??eligibleParents[0]?.id;
 const participantChoices=incident.participants.filter(p=>p.status==='ACTIVE'&&(mode!=='recover_command'||p.organization_id===incident.lead_organization_id));
 const targetValid=participantChoices.some(p=>p.organization_id===target);
 function sectorManagement(id:string){
  if(disabled||!view?.can_assign)return;
  setSector(id);setRole('SECTOR_COMMANDER');setMode('offer_role');setDraftVersion(view.version);setTarget(org);
  workspace?.showOperations();
  requestAnimationFrame(()=>{let parent=management.current?.parentElement;while(parent){if(parent instanceof HTMLDetailsElement)parent.open=true;parent=parent.parentElement;}management.current?.querySelector<HTMLElement>('select')?.focus();});
 }

 function propose() {
  const person=candidates.find(c=>c.id===selected);if(!person||!targetValid||!view||draftVersion!==view.version)return;
  const payload:Record<string,unknown>={user_id:person.id,organization_id:target};
  if(mode==='offer_role'){payload.role=role;payload.parent_assignment_id=chosenParent;}
  if(mode==='offer_role'&&role==='SECTOR_COMMANDER')payload.sector_id=sector;
  if(mode==='offer_role'&&role==='UNIT_LEADER')payload.unit_assignment_id=unitScope;
  if(mode==='transfer_command')payload.mode=target===incident.lead_organization_id?'COMMAND':'LEAD_AND_COMMAND';
  onAction(mode as Mutation,payload,{id:incident.id,incident_id:incident.id,organization_id:org,version:draftVersion!,title:incident.title,reference_number:incident.reference_number},[t('commander'),current?.name??'—',t('proposed'),person.name,participantChoices.find(p=>p.organization_id===target)?.name,
   mode==='offer_role'?t(role):t(target===incident.lead_organization_id?'commandOnly':'combinedTransfer'),role==='SECTOR_COMMANDER'?view?.sectors.find(s=>s.id===sector)?.name:role==='UNIT_LEADER'?view?.units.find(u=>u.id===unitScope)?.name:''].filter(Boolean).join(' · '));
 }
 function matchesRole(item:CommandRole):boolean {
  const needle=filter.trim().toLocaleLowerCase();
  if(!needle)return true;
  return [item.name,item.organization_name,item.role,item.sector_name,item.unit_name].some(value=>value?.toLocaleLowerCase().includes(needle));
 }
 function hasMatch(item:CommandRole,visited:string[]=[]):boolean {
  if(matchesRole(item))return true;
  return (childrenByParent.get(item.id)??[]).filter(child=>!visited.includes(child.id)).some(child=>hasMatch(child,[...visited,item.id]))??false;
 }
 function selectRole(item:CommandRole){
  setSelectedRole(item.id);
  if(item.sector_id)workspace?.select({kind:'INCIDENT_SECTOR',id:item.sector_id});
  else {workspace?.select(null);workspace?.showDetails();}
 }
 function tree(rows:CommandRole[],visited:string[]=[],nested=false):ReactNode {
  return <ul className="command-hierarchy-tree" role={nested?'group':'tree'} aria-label={nested?undefined:t('commandTree')}>{rows.filter(r=>!visited.includes(r.id)&&hasMatch(r,visited)).map(r=>{
   const children=(childrenByParent.get(r.id)??[]).filter(child=>!visited.includes(child.id)&&child.id!==r.id);
   const forced=filter.trim()!==''&&children.some(child=>hasMatch(child,[...visited,r.id]));
   const open=expanded.has(r.id)||forced;
   return <li key={r.id} role="treeitem" tabIndex={0} aria-selected={selectedRole===r.id} aria-label={(r.name??'—')+' · '+t(r.role)} aria-expanded={children.length?open:undefined} onKeyDown={event=>{
     if(event.target!==event.currentTarget)return;
     const node=event.currentTarget,root=node.closest('[role="tree"]'),items=Array.from(root?.querySelectorAll<HTMLElement>('[role="treeitem"]')??[]),index=items.indexOf(node);
     if(['ArrowDown','ArrowUp','Home','End','ArrowRight','ArrowLeft','Enter',' '].includes(event.key)){event.preventDefault();event.stopPropagation();
      if(event.key==='ArrowDown')items[Math.min(items.length-1,index+1)]?.focus();
      else if(event.key==='ArrowUp')items[Math.max(0,index-1)]?.focus();
      else if(event.key==='Home')items[0]?.focus();else if(event.key==='End')items[items.length-1]?.focus();
      else if(event.key==='ArrowRight'){if(!open)setExpanded(current=>new Set([...current,r.id]));else node.querySelector<HTMLElement>('[role="group"] [role="treeitem"]')?.focus();}
      else if(event.key==='ArrowLeft'){if(open&&!filter.trim())setExpanded(current=>{const next=new Set(current);next.delete(r.id);return next;});else node.parentElement?.closest<HTMLElement>('[role="treeitem"]')?.focus();}
      else selectRole(r);
     }
    }}>
    <div className="command-hierarchy-node">
     {children.length>0&&<button type="button" className="command-hierarchy-expand" disabled={forced} aria-expanded={open} aria-label={open?t('dismiss'):t('more')} onClick={()=>setExpanded(current=>{const next=new Set(current);if(next.has(r.id))next.delete(r.id);else next.add(r.id);return next;})}>{open?'−':'+'}</button>}
     <button type="button" className="command-hierarchy-select" onClick={()=>selectRole(r)}><strong>{r.name??'—'}</strong> · {t(r.role)}</button>
    </div>
    <p>{r.organization_name} · {t(r.valid?'ACTIVE':'invalidAuthority')}</p>
    {r.sector_name&&<p>{t('copSector')}: <button type="button" onClick={()=>workspace?.select(r.sector_id?{kind:'INCIDENT_SECTOR',id:r.sector_id}:null)}>{r.sector_name}</button></p>}
    {r.unit_name&&<p>{t('UNIT_LEADER')}: {r.unit_name}</p>}
    {r.can_end&&<button disabled={disabled||error} onClick={()=>onAction('end_role',{assignment_id:r.id},{id:incident.id,incident_id:incident.id,organization_id:org,version:view!.version,title:incident.title,reference_number:incident.reference_number},[r.name,t(r.role),r.organization_name].join(' · '))}>{t('end_role')}</button>}
    {children.length>0&&open&&tree(children,[...visited,r.id],true)}
   </li>;
  })}</ul>;
 }
 return <section className="admin-card"><h2>{t('commandTree')}</h2>
  <p>{t('capabilityNotice')}</p>
  {error?<p role="alert">{t('unavailable')}</p>:!view?<p role="status">{t('loading')}</p>:<>
   {view.operational&&!view.valid_commander&&<p role="alert">{t('recoveryWarning')}</p>}
   <div className="command-hierarchy-toolbar"><label>{t('search')}<input value={filter} maxLength={100} onChange={event=>setFilter(event.target.value)}/></label><span>{view.roles.filter(role=>role.valid).length} · {view.sectors.length}</span></div>
   {view.roles.length===0?<p>{t('noCommandRoles')}</p>:tree(view.roles.filter(r=>!r.parent_id||!view.roles.some(p=>p.id===r.parent_id)))}
   {selectedRole&&(!workspace?.selected||view.roles.some(item=>item.id===selectedRole&&item.sector_id===workspace.selected?.id))&&view.roles.find(item=>item.id===selectedRole)&&<WorkspaceSlot name="selectedPane">
    {view.roles.filter(item=>item.id===selectedRole).map(item=><section className="admin-notice" key={item.id}><h3>{item.name??'—'}</h3><p>{t(item.role)} · {item.organization_name}</p><p>{t(item.valid?'ACTIVE':'invalidAuthority')}</p>{item.sector_name&&<p>{t('copSector')}: {item.sector_name}</p>}{item.unit_name&&<p>{t('UNIT')}: {item.unit_name}</p>}</section>)}
   </WorkspaceSlot>}
   {workspace?.selected?.kind==='INCIDENT_SECTOR'&&view.sectors.some(item=>item.id===workspace.selected?.id)&&<WorkspaceSlot name="selectedPane"><section className="admin-notice">
    <h3>{t('commandTree')}</h3>
    {view.roles.filter(item=>item.sector_id===workspace.selected?.id).map(item=><button type="button" key={item.id} onClick={()=>selectRole(item)}>{item.name??'—'} · {t(item.role)} · {t(item.valid?'ACTIVE':'invalidAuthority')}</button>)}
    {!view.roles.some(item=>item.valid&&item.role==='SECTOR_COMMANDER'&&item.sector_id===workspace.selected?.id)&&<p>{t('sectorWithoutCommander')}</p>}
    {view.can_assign&&<button disabled={disabled} onClick={()=>sectorManagement(workspace.selected!.id)}>{t('offer_role')} · {t('SECTOR_COMMANDER')}</button>}
   </section></WorkspaceSlot>}
   <section className="command-sector-summary"><h3>{t('copSectors')}</h3>{view.sectors.length===0?<p>{t('copEmpty')}</p>:<ul>{view.sectors.map(item=>{const holder=view.roles.find(role=>role.valid&&role.role==='SECTOR_COMMANDER'&&role.sector_id===item.id);return <li key={item.id}><button type="button" aria-pressed={workspace?.selected?.kind==='INCIDENT_SECTOR'&&workspace.selected.id===item.id} onClick={()=>workspace?.select({kind:'INCIDENT_SECTOR',id:item.id})}>{item.code} · {item.name}</button><small> · {holder?(holder.name??'—')+' · '+t(holder.role):t('sectorWithoutCommander')}</small></li>;})}</ul>}</section>
   {(view.can_assign||view.can_transfer||view.can_recover)&&<fieldset ref={management} disabled={disabled||error}>
    <legend>{t('commandActions')}</legend><label>{t('action')}<select value={mode} onChange={e=>{setDraftVersion(view.version);setMode(e.target.value);setTarget(e.target.value==='recover_command'?incident.lead_organization_id:org);}}>
     <option value="">{t('select')}</option>{view.can_assign&&<option value="offer_role">{t('offer_role')}</option>}
     {view.can_transfer&&<option value="transfer_command">{t('transfer_command')}</option>}{view.can_recover&&<option value="recover_command">{t('recover_command')}</option>}
    </select></label>
    {mode&&((mode==='offer_role'&&view.can_assign)||(mode==='transfer_command'&&view.can_transfer)||(mode==='recover_command'&&view.can_recover))&&<>
     {draftVersion!==view.version&&<p role="alert">{t('stale')} <button type="button" onClick={()=>{setDraftVersion(view.version);setCandidates([]);setSelected('');}}>{t('refresh')}</button></p>}
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
     <button disabled={draftVersion!==view.version||!selected||!targetValid||(mode==='offer_role'&&(!chosenParent||(role==='SECTOR_COMMANDER'&&!sector)||(role==='UNIT_LEADER'&&!unitScope)))} onClick={propose}>{t(mode)}</button>
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
