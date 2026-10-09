'use client';
import {useEffect,useRef,useState} from 'react';
import {useRouter} from 'next/navigation';
import type {Locale} from '../../lib/i18n';
import {browserClient} from '../../lib/supabase/browser';
import {inventoryRpc} from '../../lib/operational/api';
import {actionLabel,blankConfiguration,taskErrorCode,type ActionDefinition,type TaskPage} from '../../lib/operational/tasks';
import {taskText} from '../../lib/operational/taskMessages';
import {ActionFields} from './ActionFields';

type Draft=ActionDefinition&{version_id:string};
type Pending={p_organization_id:string;p_operation:string;p_payload:Record<string,unknown>};
export function ActionCatalog({locale,org}:{locale:Locale;org:string}){
 const t=taskText(locale),router=useRouter(),alive=useRef(true),sending=useRef(false),blocked=useRef(false);
 const [account,setAccount]=useState(''),[data,setData]=useState<TaskPage<ActionDefinition>|null>(null),[query,setQuery]=useState(''),[page,setPage]=useState(0),[refresh,setRefresh]=useState(0);
 const [draft,setDraft]=useState<Draft|null>(null),[review,setReview]=useState(false),[pending,setPending]=useState<Pending|null>(null),[busy,setBusy]=useState(false),[error,setError]=useState(''),[stale,setStale]=useState(false);
 useEffect(()=>{alive.current=true;const client=browserClient();let original='';
  void client?.auth.getUser().then(r=>{if(alive.current){original=r.data.user?.id??'';setAccount(original);}});
  const sub=client?.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT'||(original&&session?.user.id!==original)){blocked.current=true;setData(null);setDraft(null);setPending(null);router.replace('/'+locale+'/account');}});
  return()=>{alive.current=false;sub?.data.subscription.unsubscribe();};
 },[locale,router]);
 function failure(e:unknown){const code=taskErrorCode(e);setError(code==='STALE_VERSION'?'stale':code);
  if(['NOT_AUTHORIZED','EXPIRED'].includes(code)){blocked.current=true;setData(null);setDraft(null);setPending(null);}return code;}
 useEffect(()=>{if(!account||blocked.current)return;const ac=new AbortController();setData(null);
  void inventoryRpc<TaskPage<ActionDefinition>>('operational_action_catalog',{p_organization_id:org,p_admin:true,p_query:query,p_page:page},account,ac.signal)
   .then(r=>{if(!ac.signal.aborted&&!blocked.current)setData(r);}).catch(e=>{if(!ac.signal.aborted)failure(e);});
  return()=>ac.abort();
 },[account,org,query,page,refresh]);
 function begin(d?:ActionDefinition){setError('');setStale(false);setReview(false);setDraft(d?{...d,configuration:structuredClone(d.configuration),version_id:crypto.randomUUID()}:
  {id:crypto.randomUUID(),owner_organization_id:org,code:'',active:true,version:'0',version_id:crypto.randomUUID(),configuration:blankConfiguration()});}
 async function save(){
  if(!draft||sending.current||blocked.current||stale)return;
  // Exact prepared request survives uncertain responses; no rebase on retry.
  const configuration=Object.fromEntries(Object.keys(blankConfiguration()).map(key=>[key,draft.configuration[key as keyof typeof draft.configuration]]));
  const request=pending??{p_organization_id:org,p_operation:crypto.randomUUID(),p_payload:{id:draft.id,version:draft.version,version_id:draft.version_id,code:draft.code,active:draft.active,configuration}};
  sending.current=true;setBusy(true);setPending(request);setError('');
  try{await inventoryRpc('operational_action_save',request,account);
   if(alive.current&&!blocked.current){setDraft(null);setPending(null);setReview(false);setRefresh(v=>v+1);}
  }catch(e){if(alive.current&&!blocked.current){const code=failure(e);if(code!=='SERVER'){setPending(null);if(code==='STALE_VERSION'){setStale(true);setRefresh(v=>v+1);}}}}
  finally{sending.current=false;if(alive.current)setBusy(false);}
 }
 function reedit(){if(!draft)return;const current=data?.rows.find(d=>d.id===draft.id);if(!current)return;
  setDraft({...draft,version:current.version,version_id:crypto.randomUUID()});setReview(false);setStale(false);setError('');}
 return <section className="admin-card action-catalog"><h2>{t('catalog')}</h2><p>{t('catalogNotice')}</p>
  {error&&<p role="alert">{t(error)}</p>}
  {!blocked.current&&<>
   <label>{t('search')}<input maxLength={100} value={query} disabled={!!pending||busy} onChange={e=>{setQuery(e.target.value);setPage(0);}}/></label>
   <div className="actions"><button disabled={!!pending||busy} onClick={()=>begin()}>{t('newAction')}</button><button disabled={busy} onClick={()=>setRefresh(v=>v+1)}>{t('refresh')}</button></div>
   {!data?<p>{t('loading')}</p>:<>{!data.rows.length&&<p>{t('empty')}</p>}{data.rows.map(d=><article className="web-row" key={d.id}>
    <strong>{actionLabel(d.configuration,locale)}</strong><p>{d.code} · {t('version')} {d.version} · {t(d.active?'active':'inactive')}</p>
    <p>{t(d.owner_organization_id===null?'system':'custom')} · {t(d.configuration.native_behavior)}</p>
    {d.owner_organization_id===org&&<button disabled={!!pending||busy} onClick={()=>begin(d)}>{t('editVersion')}</button>}
   </article>)}<div className="actions"><button disabled={page===0||!!pending||busy} onClick={()=>setPage(v=>v-1)}>{t('previous')}</button><button disabled={!data.more||!!pending||busy} onClick={()=>setPage(v=>v+1)}>{t('next')}</button></div></>}
   {draft&&<form onSubmit={e=>{e.preventDefault();setReview(true);}}><fieldset disabled={busy||!!pending||stale||review}>
    <legend>{t('editVersion')}</legend><label>{t('code')}<input required pattern="[A-Z][A-Z0-9_-]{0,63}" maxLength={64} readOnly={draft.version!=='0'} value={draft.code} onChange={e=>setDraft({...draft,code:e.target.value})}/></label>
    <label><input type="checkbox" checked={draft.active} onChange={e=>setDraft({...draft,active:e.target.checked})}/>{t('active')}</label>
    <ActionFields locale={locale} value={draft.configuration} onChange={configuration=>setDraft({...draft,configuration})}/>
    <button type="submit">{t('review')}</button>
   </fieldset></form>}
   {review&&draft&&<section className="admin-card"><h3>{t('review')}</h3><p>{draft.configuration.label_sl} / {draft.configuration.label_de}</p>
    <p>{t(draft.configuration.native_behavior)} · {t(draft.configuration.default_priority)} · {t('ack')}: {t(draft.configuration.requires_acknowledgement?'yes':'no')}</p>
    <p>{t('recipients')}: {draft.configuration.recipient_types.map(t).join(', ')}</p><p>{t('targets')}: {draft.configuration.target_types.map(t).join(', ')}</p>
    <div className="actions"><button disabled={busy||stale} onClick={()=>void save()}>{t(pending?'retry':'save')}</button><button disabled={busy||!!pending} onClick={()=>setReview(false)}>{t('back')}</button></div>
   </section>}
   {pending&&<p role="status">{t('pending')}</p>}
   {stale&&<><p role="alert">{t('stale')}</p><button disabled={!data?.rows.some(d=>d.id===draft?.id)} onClick={reedit}>{t('reedit')}</button></>}
   {draft&&<button disabled={busy||!!pending} onClick={()=>{setDraft(null);setReview(false);setStale(false);}}>{t('dismiss')}</button>}
  </>}
 </section>;
}
