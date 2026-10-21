'use client';
import {useEffect,useRef,useState} from 'react';
import {useRouter} from 'next/navigation';
import type {Locale} from '../../lib/i18n';
import type {IncidentType} from '../../lib/incidents/model';
import {blankDefinition,templateCategories,type Definition,type Template,type TemplateRead,type TemplateRow} from '../../lib/operational/templates';
import {templateError,templateText} from '../../lib/operational/templateMessages';
import {emptyEventPlan,type EventPlan} from '../../lib/operational/scenarioEvents';
import {emptyHazardPlan,type HazardPlan} from '../../lib/operational/hazards';
import {useTemplateMutation} from './useTemplateMutation';
import {ScenarioEditorWorkspace} from './ScenarioEditorWorkspace';
import {SimOperationRecovery} from './SimOperationRecovery';
import {preserveDraft,readDraft,removeDraft,type DraftSnapshot} from './draftRecovery';
import {scenarioReadiness} from '../../lib/operational/scenarioReadiness';
import {workflowText} from '../../lib/operational/workflowMessages';
import './templates.css';
import './simWorkflow.css';
type Action='CREATE'|'COPY'|'REVISE'|'SAVE'|'PUBLISH'|'ARCHIVE'|'START';
export function TemplateLibrary({locale,account,org,organizationName,types,read,initialStatus=''}:{locale:Locale;account:string;org:string;organizationName:string;types:IncidentType[];read:TemplateRead;initialStatus?:string}){
 const w=workflowText(locale),t=templateText(locale),router=useRouter(),alive=useRef(true);
 const [rows,setRows]=useState<TemplateRow[]>([]),[value,setValue]=useState<Template|null>(null),[draft,setDraft]=useState<Definition|null>(null);
 const [hazardPlan,setHazardPlan]=useState<HazardPlan>(emptyHazardPlan);
 const [eventPlan,setEventPlan]=useState<EventPlan>(emptyEventPlan);
 const [query,setQuery]=useState(''),[category,setCategory]=useState(''),[status,setStatus]=useState(initialStatus),[after,setAfter]=useState<string|null>(null);
 const [loading,setLoading]=useState(false),[error,setError]=useState(''),[epoch,setEpoch]=useState(0),[confirm,setConfirm]=useState<Action|null>(null);
 const [type,setType]=useState(types[0]?.id??''),[blocked,setBlocked]=useState(false);
 const [editorLoading,setEditorLoading]=useState(false),[recovery,setRecovery]=useState<DraftSnapshot|null>(null),[compared,setCompared]=useState(false);
 const selection=useRef<string|null>(null);
 const loader=useRef<AbortController|null>(null);
 const mutation=useTemplateMutation(account,org,'library',read,(data,request)=>{
  if(!alive.current)return;setConfirm(null);setEpoch(v=>v+1);
  if(data&&typeof data==='object'&&'incident_id' in data){
   router.push('/'+locale+'/incidents/'+String(data.incident_id)+'?org='+encodeURIComponent(org));return;
  }
  const updated=data as Template;
  if(request.args.p_action==='SAVE')try{removeDraft(account,org,String(request.args.p_template_id));}catch{}
  if(['CREATE','COPY','REVISE'].includes(String(request.args.p_action))||selection.current===updated.id)void open(updated.id,false);
 });
 const dirty=!!value&&!!draft&&(JSON.stringify(value.definition)!==JSON.stringify(draft)||JSON.stringify(value.event_plan??emptyEventPlan())!==JSON.stringify(eventPlan)||JSON.stringify(value.hazard_plan??emptyHazardPlan())!==JSON.stringify(hazardPlan));
 const busy=editorLoading||mutation.busy||!!mutation.pending||!mutation.ready||!!recovery;
 const issues=draft?scenarioReadiness(draft,eventPlan,hazardPlan):[];
 function preserve(){
  if(!dirty||!value||!draft)return true;
  try{preserveDraft(account,org,{base:value,definition:draft,event_plan:eventPlan,hazard_plan:hazardPlan,at:new Date().toISOString()});return true;}
  catch{setError('storage');return false;}
 }
 useEffect(()=>{if(dirty)preserve();},[draft,eventPlan,hazardPlan,dirty]);

 useEffect(()=>{alive.current=true;return()=>{alive.current=false;loader.current?.abort();};},[]);
 useEffect(()=>{
  const warn=(event:BeforeUnloadEvent)=>{if(dirty||mutation.pending){event.preventDefault();event.returnValue='';}};
  const link=(event:MouseEvent)=>{if(!dirty||event.defaultPrevented)return;const anchor=(event.target as Element)?.closest?.('a[href]');
   if(anchor&&!preserve())event.preventDefault();};
  window.addEventListener('beforeunload',warn);document.addEventListener('click',link,true);
  return()=>{window.removeEventListener('beforeunload',warn);document.removeEventListener('click',link,true);};
 },[dirty,mutation.pending,locale]);
 useEffect(()=>{
  const ac=new AbortController();setLoading(true);setError('');setRows([]);
  const timer=setTimeout(()=>{
   read<TemplateRow[]>('simulation_template_list',{p_organization_id:org,p_query:query,p_category:category,p_status:status,p_after:after},ac.signal,account)
    .then(data=>{if(!ac.signal.aborted){setRows(data);setBlocked(false);}})
    .catch(e=>{if(!ac.signal.aborted){const code=templateError(e instanceof Error?e.message:'SERVER');setError(code);if(code==='denied'){setBlocked(true);setValue(null);setDraft(null);setEventPlan(emptyEventPlan());setHazardPlan(emptyHazardPlan());}}})
    .finally(()=>{if(!ac.signal.aborted)setLoading(false);});
  },200);
  return()=>{clearTimeout(timer);ac.abort();};
 },[org,account,query,category,status,after,epoch,read]);
 // Revalidate scope on foreground return, without replacing unsaved editor values.
 useEffect(()=>{
  const focus=()=>setEpoch(n=>n+1);window.addEventListener('focus',focus);return()=>window.removeEventListener('focus',focus);
 },[]);
 async function open(id:string,saveCurrent=true){
  if(saveCurrent&&!preserve())return;
  loader.current?.abort();const ac=new AbortController();loader.current=ac;setEditorLoading(true);setError('');setConfirm(null);
  try{
   const item=await read<Template>('simulation_template_read',{p_organization_id:org,p_template_id:id},ac.signal,account);
   if(ac.signal.aborted)return;selection.current=item.id;setRecovery(null);setCompared(false);try{setRecovery(readDraft(account,org,item.id));}catch{setError('storage');}setValue(item);setDraft(item.definition);setEventPlan(item.event_plan??emptyEventPlan());setHazardPlan(item.hazard_plan??emptyHazardPlan());mutation.setError('');setBlocked(false);
  }catch(e){if(!ac.signal.aborted){setValue(null);setDraft(null);setEventPlan(emptyEventPlan());setHazardPlan(emptyHazardPlan());setError(templateError(e instanceof Error?e.message:'SERVER'));}}
  finally{if(!ac.signal.aborted)setEditorLoading(false);}
 }
 function command(action:Action){
  if(blocked||busy)return;
  let payload:Record<string,unknown>={};
  if(action==='CREATE')payload={definition:blankDefinition(t('blank'))};
  else if(!value||!draft)return;
  else if(action==='SAVE')payload={version_id:value.version_id,event_plan:eventPlan,hazard_plan:hazardPlan,definition:{...draft,metadata:{...draft.metadata,objectives:draft.metadata.objectives.filter(x=>x.trim())}}};
  else if(action==='COPY')payload={version_id:value.version_id};
  else if(action==='START')payload={version_id:value.version_id,incident_type_id:type};
  mutation.mutate('simulation_template_command',{p_action:action,p_template_id:action==='CREATE'?null:value!.id,p_expected_version:action==='CREATE'?'0':value!.revision,p_payload:payload});
 }
 const denied=blocked||mutation.error==='denied';
 return <section className="template-library">
  <h2>{t('library')}</h2>
  {(error||mutation.error)&&<p role="alert">{t(mutation.error||error)}</p>}
  {(loading||editorLoading)&&<p role="status">{t('loading')}</p>}
  {!denied&&<SimOperationRecovery locale={locale} mutation={mutation}/>}
  {denied?<button onClick={()=>{mutation.setError('');setEpoch(v=>v+1);}}>{t('refresh')}</button>:value&&draft?<>
   <div className="actions">
    <button
  disabled={false}
  onClick={() => {
    if (preserve()) {
      selection.current=null;setRecovery(null);setConfirm(null);
      setValue(null);
      setDraft(null);
    }
  }}
>
  {t('back')}
</button>
    <span className="admin-badge">{t(value.archived?'ARCHIVED':value.state)} · {t('version')} {value.version}</span>
    <span role="status">{mutation.busy?w(mutation.state):mutation.pending?w('OUTCOME_UNKNOWN'):t(mutation.error==='stale'?'stale':dirty?'unsaved':'saved')}</span>
    <button disabled={editorLoading} onClick={()=>void open(value.id)}>{t('refresh')}</button>
    {!value.archived&&<button disabled={busy||dirty} onClick={()=>command('COPY')}>{t('copy')}</button>}
    {!value.builtin&&!value.archived&&value.state==='PUBLISHED'&&<button disabled={busy} onClick={()=>command('REVISE')}>{t('revise')}</button>}
    {!value.builtin&&!value.archived&&value.state==='DRAFT'&&<>
     <button disabled={busy||!dirty} onClick={()=>command('SAVE')}>{t('save')}</button>
     <button disabled={busy||dirty||issues.length>0} onClick={()=>setConfirm('PUBLISH')}>{t('publish')}</button>
    </>}
    {!value.builtin&&!value.archived&&<>
     <button disabled={busy||dirty||issues.length>0} onClick={()=>setConfirm('START')}>{t(value.state==='DRAFT'?'startPreview':'start')}</button>
     <button disabled={busy||dirty} onClick={()=>setConfirm('ARCHIVE')}>{t('archive')}</button>
    </>}
   </div>
   {issues.length>0&&<p className="admin-notice">{w('reviewIssues')}: {[...new Set(issues.map(i=>w(i.section)))].join(', ')} · {w('review')}</p>}
   {recovery&&<section className="admin-notice">
    <h3>{w('recovery')}</h3><p>{recovery.at}</p>{recovery.base.revision!==value.revision&&<p>{w('revisionWarning')}</p>}
    <button type="button" onClick={()=>setCompared(true)}>{w('compare')}</button>
    {compared&&<div className="sim-compare"><section><h4>{w('local')}</h4><pre>{JSON.stringify({definition:recovery.definition,event_plan:recovery.event_plan,hazard_plan:recovery.hazard_plan},null,2)}</pre></section><section><h4>{w('server')}</h4><pre>{JSON.stringify({definition:value.definition,event_plan:value.event_plan,hazard_plan:value.hazard_plan},null,2)}</pre></section></div>}
    <div className="actions"><button type="button" disabled={!!mutation.pending||!compared||value.state!=='DRAFT'||value.builtin||value.archived} onClick={()=>{setDraft(recovery.definition);setEventPlan(recovery.event_plan);setHazardPlan(recovery.hazard_plan);setRecovery(null);}}>{w('restore')}</button>
    <button type="button" disabled={!!mutation.pending} onClick={()=>{try{removeDraft(account,org,value.id);setRecovery(null);}catch{setError('storage');}}}>{w('discardLocal')}</button></div>
   </section>}
   <ScenarioEditorWorkspace key={value.id+':'+value.version_id} locale={locale} value={value} draft={draft} events={eventPlan} hazards={hazardPlan} onDraft={setDraft} onEvents={setEventPlan} onHazards={setHazardPlan} disabled={busy||!!confirm}/>
   {confirm&&<TemplateConfirmation locale={locale} busy={mutation.busy} onCancel={()=>setConfirm(null)} onConfirm={()=>command(confirm)}>
    <h3>{draft.metadata.title}</h3><p>{t(value.state)} · {t('version')} {value.version}</p><p>{t('scope')}: {organizationName}</p><p>{t(confirm==='START'?'reviewStart':confirm==='PUBLISH'?'reviewPublish':'reviewArchive')}</p>
    <p>{w('events')}: {eventPlan.events.length} · {w('hazards')}: {hazardPlan.models.filter(m=>m.enabled).length} · {t('duration')}: {draft.metadata.duration_minutes}</p><p>{t('setupHelp')}</p><p>{w('source')}: {value.version_id}</p>
    <p>{t('objects')}: {draft.initial_objects.length} · {t('units')}: {draft.virtual_units.length}</p>
    <p>{t('center')}: {draft.world.center?.join(', ')} · {t('radius')}: {draft.world.radius_m}</p>
    {confirm==='START'&&<label>{t('type')}<select required value={type} onChange={e=>setType(e.target.value)}>{types.map(x=><option key={x.id} value={x.id}>{x.names[locale]??x.code}</option>)}</select></label>}
    <SimOperationRecovery locale={locale} mutation={mutation}/>
   </TemplateConfirmation>}
  </>:<>
   <div className="actions"><button disabled={busy} onClick={()=>command('CREATE')}>{t('blank')}</button><button disabled={loading} onClick={()=>setEpoch(v=>v+1)}>{t('refresh')}</button></div>
   <div className="web-form-grid">
    <label>{t('search')}<input maxLength={100} value={query} onChange={e=>{setQuery(e.target.value);setAfter(null);}}/></label>
    <label>{t('category')}<select value={category} onChange={e=>{setCategory(e.target.value);setAfter(null);}}><option value="">{t('all')}</option>{templateCategories.map(c=><option key={c} value={c}>{t(c)}</option>)}</select></label>
    <label>{t('templates')}<select value={status} onChange={e=>{setStatus(e.target.value);setAfter(null);}}><option value="">{t('all')}</option>{['BUILT_IN','ORGANIZATION','DRAFT','PUBLISHED','ARCHIVED'].map(s=><option key={s} value={s}>{t(s)}</option>)}</select></label>
   </div>
   {!loading&&!error&&!rows.length&&<p>{t('empty')}</p>}
   <div className="template-cards">{rows.map(row=><article className="admin-card" key={row.id}><h3>{row.title}</h3><p>{row.description}</p><small>{row.id} · {row.builtin?t('BUILT_IN'):organizationName}{row.updated_at?' · '+w('updated')+': '+new Date(row.updated_at).toLocaleString(locale):''}</small>
    <p><span className="admin-badge">{t(row.builtin?'BUILT_IN':row.archived?'ARCHIVED':row.state)}</span> · {t(row.category)} · {t('version')} {row.version}</p>
    <button disabled={editorLoading} onClick={()=>void open(row.id)}>{t('open')}</button></article>)}</div>
   <div className="actions">{after&&<button disabled={loading} onClick={()=>setAfter(null)}>{t('first')}</button>}{rows.length===25&&<button disabled={loading} onClick={()=>setAfter(rows[rows.length-1].id)}>{t('more')}</button>}</div>
  </>}
 </section>;
}
export function TemplateConfirmation({locale,busy,onCancel,onConfirm,children}:{locale:Locale;busy:boolean;onCancel:()=>void;onConfirm:()=>void;children:React.ReactNode}){
 const ref=useRef<HTMLDialogElement>(null),t=templateText(locale);
 useEffect(()=>{const d=ref.current;d?.showModal();return()=>d?.close();},[]);
 return <dialog ref={ref} className="template-confirm" aria-labelledby="template-confirm-title" onCancel={e=>{e.preventDefault();if(!busy)onCancel();}}>
  <h2 id="template-confirm-title">{t('review')}</h2><form onSubmit={e=>{e.preventDefault();onConfirm();}}>
   {children}<label><input required type="checkbox" disabled={busy}/>{t('confirm')}</label>
   <div className="actions"><button disabled={busy} type="submit">{t('confirm')}</button><button disabled={busy} type="button" onClick={onCancel}>{t('cancel')}</button></div>
  </form>
 </dialog>;
}
