'use client';
import {useEffect,useRef,useState} from 'react';
import {useRouter} from 'next/navigation';
import type {Locale} from '../../lib/i18n';
import type {IncidentType} from '../../lib/incidents/model';
import {blankDefinition,placementMissing,templateCategories,type Definition,type Template,type TemplateRead,type TemplateRow} from '../../lib/operational/templates';
import {templateError,templateText} from '../../lib/operational/templateMessages';
import {emptyEventPlan,type EventPlan} from '../../lib/operational/scenarioEvents';
import {EventPlanEditor} from './EventPlanEditor';
import {TemplateEditor} from './TemplateEditor';
import {useTemplateMutation} from './useTemplateMutation';
import './templates.css';
type Action='CREATE'|'COPY'|'REVISE'|'SAVE'|'PUBLISH'|'ARCHIVE'|'START';
export function TemplateLibrary({locale,account,org,organizationName,types,read}:{locale:Locale;account:string;org:string;organizationName:string;types:IncidentType[];read:TemplateRead}){
 const t=templateText(locale),router=useRouter(),alive=useRef(true);
 const [rows,setRows]=useState<TemplateRow[]>([]),[value,setValue]=useState<Template|null>(null),[draft,setDraft]=useState<Definition|null>(null);
 const [eventPlan,setEventPlan]=useState<EventPlan>(emptyEventPlan);
 const [query,setQuery]=useState(''),[category,setCategory]=useState(''),[status,setStatus]=useState(''),[after,setAfter]=useState<string|null>(null);
 const [loading,setLoading]=useState(false),[error,setError]=useState(''),[epoch,setEpoch]=useState(0),[confirm,setConfirm]=useState<Action|null>(null);
 const [type,setType]=useState(types[0]?.id??''),[blocked,setBlocked]=useState(false);
 const loader=useRef<AbortController|null>(null);
 const mutation=useTemplateMutation(account,org,'library',read,data=>{
  if(!alive.current)return;
  setConfirm(null);
  if(data&&typeof data==='object'&&'incident_id' in data){
   router.push('/'+locale+'/incidents/'+String(data.incident_id)+'?org='+encodeURIComponent(org));return;
  }
  const updated=data as Template;setValue(updated);setDraft(updated.definition);setEventPlan(updated.event_plan??emptyEventPlan());setEpoch(v=>v+1);
 });
 const dirty=!!value&&!!draft&&(JSON.stringify(value.definition)!==JSON.stringify(draft)||JSON.stringify(value.event_plan??emptyEventPlan())!==JSON.stringify(eventPlan));
 const busy=loading||mutation.busy||!!mutation.pending;
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;loader.current?.abort();};},[]);
 useEffect(()=>{
  const warn=(event:BeforeUnloadEvent)=>{if(dirty||mutation.pending){event.preventDefault();event.returnValue='';}};
  const link=(event:MouseEvent)=>{if(!dirty||event.defaultPrevented)return;const anchor=(event.target as Element)?.closest?.('a[href]');
   if(anchor&&!window.confirm(t('discard')))event.preventDefault();};
  window.addEventListener('beforeunload',warn);document.addEventListener('click',link,true);
  return()=>{window.removeEventListener('beforeunload',warn);document.removeEventListener('click',link,true);};
 },[dirty,mutation.pending,locale]);
 useEffect(()=>{
  const ac=new AbortController();setLoading(true);setError('');setRows([]);
  const timer=setTimeout(()=>{
   read<TemplateRow[]>('simulation_template_list',{p_organization_id:org,p_query:query,p_category:category,p_status:status,p_after:after},ac.signal,account)
    .then(data=>{if(!ac.signal.aborted){setRows(data);setBlocked(false);}})
    .catch(e=>{if(!ac.signal.aborted){const code=templateError(e instanceof Error?e.message:'SERVER');setError(code);if(code==='denied'){setBlocked(true);setValue(null);setDraft(null);setEventPlan(emptyEventPlan());}}})
    .finally(()=>{if(!ac.signal.aborted)setLoading(false);});
  },200);
  return()=>{clearTimeout(timer);ac.abort();};
 },[org,account,query,category,status,after,epoch,read]);
 // Revalidate scope on foreground return, without replacing unsaved editor values.
 useEffect(()=>{
  const focus=()=>setEpoch(n=>n+1);window.addEventListener('focus',focus);return()=>window.removeEventListener('focus',focus);
 },[]);
 async function open(id:string){
  if(busy||dirty&&!window.confirm(t('discard')))return;
  loader.current?.abort();const ac=new AbortController();loader.current=ac;setLoading(true);setError('');
  try{
   const item=await read<Template>('simulation_template_read',{p_organization_id:org,p_template_id:id},ac.signal,account);
   if(ac.signal.aborted)return;setValue(item);setDraft(item.definition);setEventPlan(item.event_plan??emptyEventPlan());mutation.setError('');setBlocked(false);
  }catch(e){if(!ac.signal.aborted){setValue(null);setDraft(null);setEventPlan(emptyEventPlan());setError(templateError(e instanceof Error?e.message:'SERVER'));}}
  finally{if(!ac.signal.aborted)setLoading(false);}
 }
 function command(action:Action){
  if(blocked||busy)return;
  let payload:Record<string,unknown>={};
  if(action==='CREATE')payload={definition:blankDefinition(t('blank'))};
  else if(!value||!draft)return;
  else if(action==='SAVE')payload={version_id:value.version_id,event_plan:eventPlan,definition:{...draft,metadata:{...draft.metadata,objectives:draft.metadata.objectives.filter(x=>x.trim())}}};
  else if(action==='COPY')payload={version_id:value.version_id};
  else if(action==='START')payload={version_id:value.version_id,incident_type_id:type};
  mutation.mutate('simulation_template_command',{p_action:action,p_template_id:action==='CREATE'?null:value!.id,p_expected_version:action==='CREATE'?'0':value!.revision,p_payload:payload});
 }
 const denied=blocked||mutation.error==='denied';
 return <section className="template-library">
  <h2>{t('library')}</h2>
  {(error||mutation.error)&&<p role="alert">{t(mutation.error||error)}</p>}
  {loading&&<p role="status">{t('loading')}</p>}
  {!denied&&mutation.pending&&<section className="admin-notice"><p>{t('pending')}</p><button disabled={mutation.busy||loading} onClick={mutation.retry}>{t('retry')}</button></section>}
  {denied?<button onClick={()=>{mutation.setError('');setEpoch(v=>v+1);}}>{t('refresh')}</button>:value&&draft?<>
   <div className="actions">
    <button
  disabled={busy}
  onClick={() => {
    if (!dirty || window.confirm(t('discard'))) {
      setValue(null);
      setDraft(null);
    }
  }}
>
  {t('back')}
</button>
    <span className="admin-badge">{t(value.archived?'ARCHIVED':value.state)} · {t('version')} {value.version}</span>
    <span role="status">{t(dirty?'unsaved':'saved')}</span>
    <button disabled={busy||dirty} onClick={()=>void open(value.id)}>{t('refresh')}</button>
    {!value.archived&&<button disabled={busy||dirty} onClick={()=>command('COPY')}>{t('copy')}</button>}
    {!value.builtin&&!value.archived&&value.state==='PUBLISHED'&&<button disabled={busy} onClick={()=>command('REVISE')}>{t('revise')}</button>}
    {!value.builtin&&!value.archived&&value.state==='DRAFT'&&<>
     <button disabled={busy||!dirty} onClick={()=>command('SAVE')}>{t('save')}</button>
     <button disabled={busy||dirty||placementMissing(draft)} onClick={()=>setConfirm('PUBLISH')}>{t('publish')}</button>
    </>}
    {!value.builtin&&!value.archived&&<>
     <button disabled={busy||dirty||placementMissing(draft)} onClick={()=>setConfirm('START')}>{t(value.state==='DRAFT'?'startPreview':'start')}</button>
     <button disabled={busy||dirty} onClick={()=>setConfirm('ARCHIVE')}>{t('archive')}</button>
    </>}
   </div>
   <TemplateEditor key={value.id+':'+value.version_id} locale={locale} value={value} draft={draft} onChange={setDraft} disabled={busy||!!confirm}/>
   <EventPlanEditor key={'events:'+value.id+':'+value.version_id} locale={locale} definition={draft} plan={eventPlan} onChange={setEventPlan} disabled={busy||!!confirm||value.builtin||value.archived||value.state==='PUBLISHED'}/>
   {confirm&&<TemplateConfirmation locale={locale} busy={busy} onCancel={()=>setConfirm(null)} onConfirm={()=>command(confirm)}>
    <h3>{draft.metadata.title}</h3><p>{t(value.state)} · {t('version')} {value.version}</p><p>{t('scope')}: {organizationName}</p><p>{t(confirm==='START'?'reviewStart':confirm==='PUBLISH'?'reviewPublish':'reviewArchive')}</p>
    <p>{t('objects')}: {draft.initial_objects.length} · {t('units')}: {draft.virtual_units.length}</p>
    <p>{t('center')}: {draft.world.center?.join(', ')} · {t('radius')}: {draft.world.radius_m}</p>
    {confirm==='START'&&<label>{t('type')}<select required value={type} onChange={e=>setType(e.target.value)}>{types.map(x=><option key={x.id} value={x.id}>{x.names[locale]??x.code}</option>)}</select></label>}
    {mutation.error&&<p role="alert">{t(mutation.error)}</p>}
    {mutation.pending&&<><p>{t('pending')}</p><button type="button" disabled={mutation.busy} onClick={mutation.retry}>{t('retry')}</button></>}
   </TemplateConfirmation>}
  </>:<>
   <div className="actions"><button disabled={busy} onClick={()=>command('CREATE')}>{t('blank')}</button><button disabled={busy} onClick={()=>setEpoch(v=>v+1)}>{t('refresh')}</button></div>
   <div className="web-form-grid">
    <label>{t('search')}<input maxLength={100} value={query} onChange={e=>{setQuery(e.target.value);setAfter(null);}}/></label>
    <label>{t('category')}<select value={category} onChange={e=>{setCategory(e.target.value);setAfter(null);}}><option value="">{t('all')}</option>{templateCategories.map(c=><option key={c} value={c}>{t(c)}</option>)}</select></label>
    <label>{t('templates')}<select value={status} onChange={e=>{setStatus(e.target.value);setAfter(null);}}><option value="">{t('all')}</option>{['BUILT_IN','ORGANIZATION','DRAFT','PUBLISHED','ARCHIVED'].map(s=><option key={s} value={s}>{t(s)}</option>)}</select></label>
   </div>
   {!loading&&!error&&!rows.length&&<p>{t('empty')}</p>}
   <div className="template-cards">{rows.map(row=><article className="admin-card" key={row.id}><h3>{row.title}</h3><p>{row.description}</p>
    <p><span className="admin-badge">{t(row.builtin?'BUILT_IN':row.archived?'ARCHIVED':row.state)}</span> · {t(row.category)} · {t('version')} {row.version}</p>
    <button disabled={busy} onClick={()=>void open(row.id)}>{t('open')}</button></article>)}</div>
   <div className="actions">{after&&<button disabled={busy} onClick={()=>setAfter(null)}>{t('first')}</button>}{rows.length===25&&<button disabled={busy} onClick={()=>setAfter(rows[rows.length-1].id)}>{t('more')}</button>}</div>
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
