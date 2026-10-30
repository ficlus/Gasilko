'use client';
import {useEffect,useRef,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import type {TaskRead} from '../../lib/operational/tasks';
import {browserClient} from '../../lib/supabase/browser';
import {evidenceText} from '../../lib/incidents/evidenceText';
import {useIncidentLive} from './IncidentLiveProvider';
type Kind='INCIDENT'|'TASK'|'MESSAGE';
type Item={operation_id:string;id:string;incident_id:string;target_kind:Kind;target_id:string|null;creator_user_id:string;acting_organization_id:string;filename:string;mime:string;size:string;status:string;created_at:string;sha256:string|null};
type Page={audience:{kind:Kind|'ORGANIZATION'|'UNIT';id:string};account:string;organization:string;incident_id:string;items:Item[];can_add:boolean;scope_fingerprint:string;has_more:boolean;next_created_at:string|null;next_id:string|null};
type Frozen={id:string;operation:string;finalize:string;file:File;metadata:{filename:string;mime:string;size:string;sha256:string}};
const cleanName=(s:string)=>s.replace(/[\x00-\x1f\x7f\/\\\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g,'').trim().slice(0,120)||'evidence';
const hash=async(file:Blob)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',await file.arrayBuffer()))).map(v=>v.toString(16).padStart(2,'0')).join('');
export function IncidentEvidence({locale,account,org,incidentId,kind,target=null,read}:{locale:Locale;account:string;org:string;incidentId:string;kind:Kind;target?:string|null;read:TaskRead}){
 const t=evidenceText(locale),live=useIncidentLive(),[page,setPage]=useState<Page|null>(null),[busy,setBusy]=useState(false),[denied,setDenied]=useState(false),[error,setError]=useState<string|null>(null);
 const [file,setFile]=useState<File|null>(null),[confirmed,setConfirmed]=useState(false),[frozen,setFrozen]=useState<Frozen|null>(null),[epoch,setEpoch]=useState(0),[image,setImage]=useState<string|null>(null);
 const generation=useRef(0),operation=useRef<Frozen|null>(null),transfer=useRef<AbortController|null>(null),url=useRef<string|null>(null),alive=useRef(false),running=useRef(false);
 const base={p_acting_organization_id:org,p_incident_id:incidentId,p_target_kind:kind,p_target_id:target};
 const clearImage=()=>{if(url.current)URL.revokeObjectURL(url.current);url.current=null;setImage(null);};
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;generation.current++;transfer.current?.abort();if(url.current)URL.revokeObjectURL(url.current);};},[account,org,incidentId,kind,target]);
 useEffect(()=>{
  const ac=new AbortController(),stamp=++generation.current;clearImage();setPage(null);setDenied(false);
  void read<Page>('incident_attachment_page',base,ac.signal,account).then(p=>{
   if(ac.signal.aborted||stamp!==generation.current)return;
   if(p.account!==account||p.organization!==org||p.incident_id!==incidentId)throw new Error('NOT_AUTHORIZED');
   setPage(p);setError(null);
  }).catch(e=>{if(!ac.signal.aborted&&stamp===generation.current){setError(String(e.message));if(['NOT_AUTHORIZED','SCOPE_CHANGED','EXPIRED'].includes(e.message)){setPage(null);setDenied(true);transfer.current?.abort();}}});
  return()=>ac.abort();
 // Parent is keyed by identity; B1/B2 success causes a fresh current-audience read.
 // eslint-disable-next-line react-hooks/exhaustive-deps
 },[account,org,incidentId,kind,target,live.lastSuccess,epoch]);
 async function endpoint(action:string,id:string,signal:AbortSignal,finalize?:string){
  const response=await fetch('/api/incidents/evidence',{method:'POST',cache:'no-store',signal,
   headers:{'Content-Type':'application/json','X-Gasilko-Account':account},
   body:JSON.stringify({action,organization:org,incident:incidentId,attachment:id,operation:finalize})});
  if(!response.ok){const body=await response.json();throw new Error(body.error??'STORAGE_TEMPORARILY_UNAVAILABLE');}
  return response;
 }
 function failure(e:unknown){
  const code=e instanceof Error?e.message:'STORAGE_TEMPORARILY_UNAVAILABLE';setError(code);
  if(['NOT_AUTHORIZED','SCOPE_CHANGED','EXPIRED'].includes(code)){setDenied(true);setPage(null);clearImage();generation.current++;}
 }
 async function send(){
  if(running.current||(!operation.current&&(!file||!confirmed)))return;
  running.current=true;setBusy(true);setError(null);
  const stamp=generation.current,ac=new AbortController();transfer.current=ac;
  const valid=()=>alive.current&&!ac.signal.aborted&&stamp===generation.current;
  try{
   let f=operation.current;
   if(!f){
    if(!file||!['image/jpeg','image/webp','application/pdf'].includes(file.type)||file.size<1||file.size>(file.type==='application/pdf'?20971520:10485760))throw new Error('ATTACHMENT_TYPE_UNSUPPORTED');
    f={id:crypto.randomUUID(),operation:crypto.randomUUID(),finalize:crypto.randomUUID(),file,
     metadata:{filename:cleanName(file.name),mime:file.type,size:String(file.size),sha256:await hash(file)}};
    if(!valid())return;operation.current=f;setFrozen(f);
   }
   const prepared=await read<Item&{bucket:string;path:string}>('incident_attachment_prepare',{...base,p_operation:f.operation,p_attachment_id:f.id,p_metadata:f.metadata},ac.signal,account);
   if(!valid())return;
   const ext=f.metadata.mime==='image/jpeg'?'jpg':f.metadata.mime==='image/webp'?'webp':'pdf';
   const path=incidentId+'/'+f.id+'/original.'+ext;
   if(prepared.id!==f.id||prepared.creator_user_id!==account||prepared.acting_organization_id!==org||prepared.bucket!=='incident-evidence'||prepared.path!==path)throw new Error('NOT_AUTHORIZED');
   let result:Item|null=prepared.status==='READY'?prepared:null;
   if(prepared.status==='REJECTED')throw new Error('ATTACHMENT_REJECTED');
   if(!result)try{result=(await (await endpoint('verify',f.id,ac.signal,f.finalize)).json()).data;}catch(e){if(!(e instanceof Error)||e.message!=='ATTACHMENT_NOT_UPLOADED')throw e;}
   if(!valid())return;
   if(!result){
    const client=browserClient();if(!client)throw new Error('EXPIRED');
    const {data:{user}}=await client.auth.getUser();if(user?.id!==account)throw new Error('EXPIRED');
    if(!valid())return;
    // Existing SDK standard upload, insert-only. A conflict is recovered through verification.
    const uploaded=await client.storage.from('incident-evidence').upload(path,f.file,{contentType:f.metadata.mime,upsert:false,cacheControl:'0'});
    if(!valid())return;
    if(uploaded.error&&!/already|duplicate|exist/i.test(uploaded.error.message))throw new Error('STORAGE_TEMPORARILY_UNAVAILABLE');
    result=(await (await endpoint('verify',f.id,ac.signal,f.finalize)).json()).data;
   }
   if(!valid())return;
   if(result?.status!=='READY'||result.id!==f.id||result.operation_id!==f.operation||result.creator_user_id!==account||result.acting_organization_id!==org||result.sha256!==f.metadata.sha256)throw new Error('ATTACHMENT_REJECTED');
   operation.current=null;setFrozen(null);setFile(null);setConfirmed(false);setEpoch(x=>x+1);
  }catch(e){if(valid())failure(e);}
  finally{running.current=false;if(alive.current)setBusy(false);}
 }
 async function open(item:Item,preview:boolean){
  if(running.current)return;running.current=true;setBusy(true);clearImage();
  const stamp=generation.current,ac=new AbortController();transfer.current=ac;
  try{
   const response=await endpoint('download',item.id,ac.signal),blob=await response.blob();
   if(!alive.current||ac.signal.aborted||stamp!==generation.current)return;
   if(blob.size!==Number(item.size)||blob.size>20971520||await hash(blob)!==item.sha256)throw new Error('ATTACHMENT_MALFORMED');
   if(!alive.current||ac.signal.aborted||stamp!==generation.current)return;
   const objectUrl=URL.createObjectURL(blob);url.current=objectUrl;
   if(preview&&['image/jpeg','image/webp'].includes(item.mime))setImage(objectUrl);
   else {const a=document.createElement('a');a.href=objectUrl;a.download='evidence-'+item.id+(item.mime==='application/pdf'?'.pdf':item.mime==='image/jpeg'?'.jpg':'.webp');a.rel='noreferrer';a.click();setTimeout(()=>{URL.revokeObjectURL(objectUrl);if(url.current===objectUrl)url.current=null;},1000);}
  }catch(e){if(alive.current&&!ac.signal.aborted&&stamp===generation.current)failure(e);}
  finally{running.current=false;if(alive.current)setBusy(false);}
 }
 async function older(){
  if(!page||busy)return;const stamp=generation.current,ac=new AbortController();setBusy(true);transfer.current=ac;
  try{const next=await read<Page>('incident_attachment_page',{...base,p_before_created_at:page.next_created_at,p_before_id:page.next_id},ac.signal,account);
   if(!alive.current||ac.signal.aborted||stamp!==generation.current)return;
   if(next.account!==account||next.organization!==org||next.incident_id!==incidentId||next.scope_fingerprint!==page.scope_fingerprint){setPage(null);setEpoch(x=>x+1);return;}
   const items=[...page.items,...next.items].filter((x,i,a)=>a.findIndex(y=>y.id===x.id)===i).slice(0,100);
   setPage({...next,items,has_more:next.has_more&&items.length<100});
  }catch(e){if(alive.current&&!ac.signal.aborted&&stamp===generation.current)failure(e);}finally{if(alive.current)setBusy(false);}
 }
 return <section className="admin-card" aria-label={t('title')}>
  <h3>{t('title')}</h3><p>{t('scope')}: <strong>{t(kind)}</strong> · {target??incidentId}</p>{page&&<p>{t(page.audience.kind)} · {page.audience.id}</p>}<p>{t('limits')}</p>
  {denied?<p role="alert">{t('denied')}</p>:<>
   {error&&<p role="alert">{t(error.includes('MALFORMED')||error.includes('LARGE')||error.includes('UNSUPPORTED')?'invalid':'error')}</p>}
   {page?.can_add&&<><label>{t('file')}<input type="file" accept="image/jpeg,image/webp,application/pdf" disabled={busy||!!frozen} onChange={e=>{setFile(e.target.files?.[0]??null);setConfirmed(false);}}/></label>
    {file&&<p>{cleanName(file.name)} · {file.size} B</p>}
    <label><input type="checkbox" checked={confirmed} disabled={busy||!!frozen} onChange={e=>setConfirmed(e.target.checked)}/>{t('confirm')}</label>
    <button type="button" disabled={busy||(!frozen&&(!file||!confirmed))} onClick={()=>void send()}>{t(frozen?'retry':'upload')}</button></>}
   {frozen&&<p role="status">{t('frozen')} · {frozen.id}</p>}
   {busy&&<><p role="status">{t('pending')}</p><button type="button" onClick={()=>transfer.current?.abort()}>{t('cancel')}</button></>}
   <ul>{page?.items.map(item=><li key={item.id}><strong>{item.filename}</strong><p>{item.mime} · {item.size} B · {item.created_at} · {item.creator_user_id}</p>
    <p>{t(item.status==='READY'?'ready':item.status==='REJECTED'?'rejected':'pending')}</p>
    {item.status==='READY'&&<><button type="button" disabled={busy} onClick={()=>void open(item,false)}>{t('download')}</button>
     {item.mime!=='application/pdf'&&<button type="button" disabled={busy} onClick={()=>void open(item,true)}>{t('preview')}</button>}</>}
   </li>)}</ul>
   {page&&!page.items.length&&<p>{t('empty')}</p>}
   {page?.has_more&&<button type="button" disabled={busy} onClick={()=>void older()}>{t('older')}</button>}
   {image&&<div role="dialog" aria-modal="true" aria-label={t('preview')}><img src={image} alt={t('preview')} style={{maxWidth:'100%',maxHeight:'65vh'}}/><button type="button" onClick={clearImage}>{t('close')}</button></div>}
  </>}
 </section>;
}
