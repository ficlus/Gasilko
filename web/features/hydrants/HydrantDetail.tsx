'use client';
import Link from 'next/link';
import {useEffect,useRef,useState} from 'react';
import {dictionary,type Locale} from '@/lib/i18n';
import {rpc,type Detail,type Scope} from '@/lib/hydrants/admin';
import {failure,statuses,type Status} from '@/lib/hydrants/domain';
import {statusLabel,typeLabel} from './Registry';
import {HydrantEditor} from './HydrantEditor';
import {ManualInspection,modeLabel,resultLabel} from './ManualInspection';
import {PhotoGallery,PhotoStaging,upload,type Prepared} from './PrivatePhotos';
export function dueLabel(t:ReturnType<typeof dictionary>,v:string){return ({CURRENT:t.wCurrent,DUE_SOON:t.wDueSoon,OVERDUE:t.wOverdue,NEVER_INSPECTED:t.wNeverInspected} as Record<string,string>)[v]??t.hMissing;}
export function HydrantDetail({locale,root,id,scope,onBack,onChanged}:{locale:Locale;root:string;id:string;scope:Scope;onBack:()=>void;onChanged:()=>void}){
 const t=dictionary(locale),[detail,setDetail]=useState<Detail|null>(null),[page,setPage]=useState(0),[revision,setRevision]=useState(0),[error,setError]=useState('');
 const [edit,setEdit]=useState(false),[manual,setManual]=useState(false),[photos,setPhotos]=useState<Prepared[]>([]),[busy,setBusy]=useState(false),[photoLocked,setPhotoLocked]=useState(false);
 const [status,setStatus]=useState<Status>('UNKNOWN'),[reason,setReason]=useState(''),[operationLocked,setOperationLocked]=useState(false);
 const [preparing,setPreparing]=useState(false);
 const op=useRef<{id:string;action:string;data:Record<string,unknown>;version:number}|null>(null);
 const refresh=()=>{setRevision(v=>v+1);onChanged();};
 useEffect(()=>{if(!detail)return;const org=scope.organizations.find(o=>o.id===detail.hydrant.organization_id);
 if(!org){setDetail(null);setEdit(false);setManual(false);setPhotos([]);setError(t.hForbidden);}
 else if(detail.writable!==org.writable){setDetail(d=>d?{...d,writable:org.writable}:d);if(!org.writable){setEdit(false);setManual(false);setPhotos([]);}}
 },[scope,detail?.hydrant.organization_id,detail?.writable,t.hForbidden]);
 useEffect(()=>{let alive=true;setError('');void rpc<Detail>('web_hydrant_detail',{root,hydrant:id,history_page:page}).then(d=>{if(alive){setDetail(d);setStatus(d.hydrant.status);}}).catch(()=>{if(alive){setDetail(null);setEdit(false);setManual(false);setPhotos([]);setError(t.hForbidden);}});return()=>{alive=false;};},[root,id,page,revision,t.hForbidden]);
 // Revalidate visible data while idle. Never replace a dirty editor or submission.
 useEffect(()=>{if(edit||manual||busy||operationLocked||photos.length||reason)return;const timer=setInterval(()=>setRevision(v=>v+1),60000);return()=>clearInterval(timer);},[edit,manual,busy,operationLocked,photos.length,reason]);
 async function mutate(action:string,data:Record<string,unknown>){if(!detail)return;setBusy(true);setError('');try{
 if(!op.current){op.current={id:crypto.randomUUID(),action,data,version:detail.hydrant.version};setOperationLocked(true);}
 await rpc('web_hydrant_write',{organization:detail.hydrant.organization_id,hydrant:id,operation:op.current.id,action:op.current.action,data:op.current.data,expected_version:op.current.version});
 op.current=null;setOperationLocked(false);setReason('');refresh();
 }catch(e){setError(failure(e)==='conflict'?t.hConflict:t.wSaveRetry);}finally{setBusy(false);}}
 async function savePhotos(){if(!detail)return;setBusy(true);setPhotoLocked(true);setError('');try{for(const p of photos)await upload(p,detail.hydrant.organization_id,id);setPhotos([]);setPhotoLocked(false);refresh();}catch{setError(t.wSaveRetry);}finally{setBusy(false);}}
 if(!detail)return <section><button onClick={onBack}>{t.hBack}</button><p role={error?'alert':'status'}>{error||t.loading}</p></section>;
 const h=detail.hydrant;const closeEditor=()=>{setEdit(false);refresh();};
 if(edit)return <HydrantEditor locale={locale} scope={scope} hydrant={h} onCancel={closeEditor} onSaved={closeEditor}/>;
 return <section className="web-detail"><div className="actions"><button onClick={onBack}>{t.hBack}</button><button disabled={busy||manual} onClick={()=>{op.current=null;setOperationLocked(false);refresh();}}>{t.hRefresh}</button>{detail.writable&&<button disabled={busy||operationLocked||manual} onClick={()=>setEdit(true)}>{t.hEdit}</button>}</div>
 {error&&<p role="alert">{error}</p>}<h2>{h.code??t.hMissing}</h2><p className="admin-badge">{statusLabel(t,h.status)}</p><p>{h.organization_name}</p>
 <dl className="hydrant-fields">{([[t.hType,typeLabel(t,{name:h.type_name,code:h.type_code,organization_id:h.type_organization_id,names:h.type_names},locale)],[t.hActive,h.active?t.hActive:t.hInactive],[t.hAddress,h.address],[t.hDescription,h.location_description],[t.hLatitude,h.latitude],[t.hLongitude,h.longitude],[t.hNotes,h.notes],[t.hInterval,h.inspection_interval_months],[t.wDue,dueLabel(t,h.due_state)],[t.wNextDue,h.next_due?new Date(h.next_due).toLocaleDateString(locale):null],[t.wLatestInspection,h.last_inspection_at?new Date(h.last_inspection_at).toLocaleString(locale):null],[t.wUuid,h.id]] as [string,unknown][]).map(([label,value])=><div key={label}><dt>{label}</dt><dd>{value==null?t.hMissing:String(value)}</dd></div>)}</dl>
 {detail.writable&&<section className="admin-card"><h3>{t.wPermanentStatus}</h3><p>{t.wStatusNotice}</p><fieldset disabled={busy||operationLocked}><label>{t.hStatus}<select value={status} onChange={e=>setStatus(e.target.value as Status)}>{statuses.map(s=><option key={s} value={s}>{statusLabel(t,s)}</option>)}</select></label><label>{t.wReason}<input value={reason} onChange={e=>setReason(e.target.value)}/></label></fieldset>
 <div className="actions"><button disabled={busy||(!operationLocked&&!reason.trim())} onClick={()=>void mutate('status',{status,reason})}>{operationLocked?t.hRetry:t.hSave}</button>
 <button disabled={busy||operationLocked} onClick={()=>{if(window.confirm(t.wActiveConfirm))void mutate('active',{active:!h.active});}}>{h.active?t.hDeactivate:t.hReactivate}</button></div></section>}
 <section className="admin-card"><h3>{t.wPermanentPhotos}</h3><PhotoGallery key={h.id} locale={locale} org={h.organization_id} hydrant={id} refresh={revision}/>
 {detail.writable&&<><PhotoStaging locale={locale} photos={photos} onChange={setPhotos} disabled={busy||photoLocked} permanent onPreparing={setPreparing}/><button disabled={busy||preparing||!photos.length} onClick={()=>void savePhotos()}>{photoLocked?t.hRetry:t.wUpload}</button></>}</section>
 <section className="admin-card"><h3>{t.wInspectionHistory}</h3>{detail.writable&&<button disabled={busy} onClick={()=>setManual(v=>!v)}>{manual?t.wClose:t.wManualInspection}</button>}
 {manual&&<ManualInspection key={id} locale={locale} hydrant={h} onDone={()=>{setManual(false);refresh();}}/>}
 {detail.history.map(i=><article className="web-history" key={i.id}><h4>{modeLabel(t,i.mode)} · {resultLabel(t,i.result)}</h4><p>{new Date(i.completed_at).toLocaleString(locale)} · {i.performer??t.hMissing} {i.performer_organization}</p><p>{t.wEnteredBy}: {i.entered_by??t.hMissing} · {i.source==='WEB_MANUAL'?t.wPaperSource:t.wFieldSource}</p>
 <p>{t.wPressure}: {i.pressure_bar??t.hMissing} · {t.wFlow}: {i.flow_l_min??t.hMissing}</p><p>{i.notes}</p>{i.corrects_inspection_id&&<p>{t.wCorrects}: {i.corrects_inspection_id}</p>}
 <small>{t.wUuid}: {i.id}</small>
 <LazySection label={`${t.wInspectionPhotos} (${i.photo_count})`}><PhotoGallery locale={locale} org={h.organization_id} hydrant={id} inspection={i.id} refresh={revision}/></LazySection>
 {i.source==='WEB_MANUAL'&&<LazySection label={t.wPaperDocuments}><PhotoGallery locale={locale} org={h.organization_id} hydrant={id} inspection={i.id} documents refresh={revision}/></LazySection>}</article>)}
 {!detail.history.length&&<p>{t.wNoInspections}</p>}<div className="actions"><button disabled={!page} onClick={()=>setPage(v=>v-1)}>{t.wPrevious}</button><button disabled={detail.history.length<25} onClick={()=>setPage(v=>v+1)}>{t.wNext}</button></div></section>
 <section className="admin-card"><h3>{t.wRecentAudit}</h3>{detail.audit.map((a,i)=><article key={i}><strong>{auditLabel(t,a.action)}</strong><p>{a.actor??t.hMissing} · {new Date(a.created_at).toLocaleString(locale)}</p>
 {typeof a.new_data?.reason==='string'&&<p>{t.wReason}: {a.new_data.reason}</p>}
 {typeof a.old_data?.status==='string'&&typeof a.new_data?.status==='string'&&<p>{statusLabel(t,a.old_data.status as Status)} → {statusLabel(t,a.new_data.status as Status)}</p>}
 {Array.isArray(a.new_data?.changed_fields)&&<p>{a.new_data.changed_fields.map(String).map(k=>fieldLabel(t,k)).join(', ')}</p>}</article>)}<Link href={`/${locale}/admin/org/${root}/audit`}>{t.wShowAll}</Link></section>
 </section>;
}
function fieldLabel(t:ReturnType<typeof dictionary>,k:string){return ({latitude:t.hLatitude,longitude:t.hLongitude,address:t.hAddress,location_description:t.hDescription,notes:t.hNotes,status:t.hStatus,active:t.hActive,hydrant_type_id:t.hType,inspection_interval_months:t.hInterval,code:t.hCode} as Record<string,string>)[k]??t.wOtherChange;}
function LazySection({label,children}:{label:string;children:React.ReactNode}){const [open,setOpen]=useState(false);return <details onToggle={e=>setOpen(e.currentTarget.open)}><summary>{label}</summary>{open&&children}</details>;}
function auditLabel(t:ReturnType<typeof dictionary>,action:string){if(action.includes('INSPECTION'))return t.wInspectionChange;if(action.includes('PHOTO'))return t.wPhotoChange;if(action.includes('DOCUMENT'))return t.wDocumentChange;if(action.includes('STATUS'))return t.wStatusChange;if(action.includes('REACTIVATED'))return t.hReactivate;if(action.includes('DEACTIVATED'))return t.hDeactivate;if(action.includes('CREATED'))return t.hAdd;return t.hEdit;}
