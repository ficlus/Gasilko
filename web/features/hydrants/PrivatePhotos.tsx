'use client';
import {useEffect,useRef,useState} from 'react';
import {browserClient} from '@/lib/supabase/browser';
import {dictionary,type Locale} from '@/lib/i18n';
import {rpc,type Photo} from '@/lib/hydrants/admin';
import {RegistryError} from '@/lib/hydrants/domain';

// Authenticated downloads, short-lived object URLs; no public/signed bearer URLs.
export function PrivatePhoto({path,locale,bucket='hydrant-photos',document=false}:{path:string|null;locale:Locale;bucket?:string;document?:boolean}) {
 const [url,setUrl]=useState<string>(); const [failed,setFailed]=useState(false); const [open,setOpen]=useState(false);
 const dialog=useRef<HTMLDialogElement>(null); const t=dictionary(locale);
 useEffect(()=>{let alive=true,objectUrl:string|undefined; setUrl(undefined);setFailed(false);setOpen(false);
 const c=browserClient(); if(path&&c) void c.storage.from(bucket).download(path).then(({data,error})=>{
 if(!alive)return; if(error||!data){setFailed(true);return;}objectUrl=URL.createObjectURL(data);setUrl(objectUrl);
 }).catch(()=>{if(alive)setFailed(true);});
 const auth=c?.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT'){alive=false;if(objectUrl)URL.revokeObjectURL(objectUrl);setUrl(undefined);setOpen(false);}});
 return()=>{alive=false;auth?.data.subscription.unsubscribe();if(objectUrl)URL.revokeObjectURL(objectUrl);};},[path,bucket]);
 useEffect(()=>{if(open)dialog.current?.showModal();else dialog.current?.close();},[open]);
 return <div className="web-photo">{url?<>
 {document?<a href={url} download rel="noreferrer">{t.wDownloadDocument}</a>:<button type="button" onClick={()=>setOpen(true)}><img src={url} alt={t.wPhoto} onError={()=>{setFailed(true);setUrl(undefined);}}/></button>}
 <dialog ref={dialog} onCancel={()=>setOpen(false)} className="web-photo-viewer"><button type="button" onClick={()=>setOpen(false)}>{t.wClose}</button><img src={url} alt={t.wPhoto}/></dialog>
 </>:<span>{failed?t.wPhotoUnavailable:path?t.loading:t.wNoPhoto}</span>}</div>;
}
export function PhotoGallery({org,hydrant,inspection,locale,documents=false,refresh=0}:{org:string;hydrant:string;inspection?:string;locale:Locale;documents?:boolean;refresh?:number}) {
 const [rows,setRows]=useState<Photo[]>([]),[page,setPage]=useState(0),[error,setError]=useState(false); const t=dictionary(locale);
 useEffect(()=>{let live=true;setRows([]);setError(false);const c=browserClient();if(!c)return;
 let q=c.from(documents?'inspection_documents':inspection?'inspection_photos':'hydrant_photos').select('id,storage_path,mime_type,uploaded_at,created_at')
 .eq('organization_id',org).eq('hydrant_id',hydrant).order(documents?'created_at':'captured_at',{ascending:false}).order('id',{ascending:false}).range(page*12,page*12+11);
 if(inspection)q=q.eq('inspection_id',inspection);if(!documents)q=q.eq('active',true);
 void q.then(r=>{if(live){setRows(r.data??[]);setError(!!r.error);}});return()=>{live=false;};},[org,hydrant,inspection,documents,page,refresh]);
 return <section><div className="web-gallery">{rows.map(p=><article key={p.id}><PrivatePhoto locale={locale} path={p.uploaded_at?p.storage_path:null} bucket={documents?'inspection-documents':'hydrant-photos'} document={p.mime_type==='application/pdf'}/><small>{p.uploaded_at?t.wUploaded:t.wPendingUpload}</small></article>)}</div>
 {error?<p role="alert">{t.hForbidden}</p>:!rows.length&&<p>{t.wNoPhoto}</p>}<div className="actions"><button disabled={!page} onClick={()=>setPage(p=>p-1)}>{t.wPrevious}</button><button disabled={rows.length<12} onClick={()=>setPage(p=>p+1)}>{t.wNext}</button></div></section>;
}
export type Prepared={id:string;blob:Blob;mime:string;sha256:string;at:string;document:boolean};
export async function prepare(file:File,document=false):Promise<Prepared>{
 if(file.size>20*1024*1024)throw new RegistryError('validation');
 let blob:Blob;
 if(document&&file.type==='application/pdf'){
 if(file.size>10*1024*1024||!new TextDecoder().decode(await file.slice(0,5).arrayBuffer()).startsWith('%PDF-'))throw new RegistryError('validation');blob=file;
 }else{
 if(!['image/jpeg','image/png','image/webp'].includes(file.type))throw new RegistryError('validation');
 const bitmap=await createImageBitmap(file,{imageOrientation:'from-image'});
 try{const scale=Math.min(1,1920/Math.max(bitmap.width,bitmap.height)),canvas=window.document.createElement('canvas');
 canvas.width=Math.max(1,Math.round(bitmap.width*scale));canvas.height=Math.max(1,Math.round(bitmap.height*scale));
 const ctx=canvas.getContext('2d');if(!ctx)throw new RegistryError('unavailable');ctx.fillStyle='#fff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(bitmap,0,0,canvas.width,canvas.height);
 blob=await new Promise<Blob>((resolve,reject)=>canvas.toBlob(b=>b?resolve(b):reject(new RegistryError('validation')),'image/jpeg',0.82));}finally{bitmap.close();}
 if(blob.size>5*1024*1024)throw new RegistryError('validation');
 }
 const hash=await crypto.subtle.digest('SHA-256',await blob.arrayBuffer());
 return {id:crypto.randomUUID(),blob,mime:blob.type,sha256:Array.from(new Uint8Array(hash)).map(v=>v.toString(16).padStart(2,'0')).join(''),at:new Date().toISOString(),document};
}
export async function upload(p:Prepared,org:string,hydrant:string,inspection?:string){
 const c=browserClient();if(!c)throw new RegistryError('unavailable');const {data}=await c.auth.getUser();if(!data.user)throw new RegistryError('expired');
 const doc={id:p.id,organization_id:org,hydrant_id:hydrant,inspection_id:inspection??null,mime_type:p.mime,byte_size:p.blob.size,sha256:p.sha256};
 const path=`hydrants/${org}/${hydrant}/${inspection?'inspections/'+inspection:'main'}/${p.id}.jpg`;
 const receipt= p.document? await rpc<Photo>('web_document',{document:doc}):await rpc<Photo>('web_reserve_photo',{photo:{...doc,created_by:data.user.id,category:inspection?'INSPECTION':'HYDRANT',captured_at:p.at,storage_path:path}});
 if(receipt.uploaded_at)return;
 const r=await c.storage.from(p.document?'inspection-documents':'hydrant-photos').upload(receipt.storage_path,p.blob,{contentType:p.mime,upsert:false});
 // A lost acknowledgement can leave the immutable object present. Confirm its
 // reserved metadata; never overwrite it on retry.
 if(r.error&& !['409','400'].includes(String('statusCode' in r.error?r.error.statusCode:'status' in r.error?r.error.status:undefined)))throw new RegistryError('network');
 const confirmed=p.document?await rpc<Photo>('web_document',{document:doc,confirm:true}):await rpc<Photo>('web_confirm_photo',{organization:org,photo_id:p.id});
 if(!confirmed.uploaded_at)throw new RegistryError('network');
}
function Staged({photo}:{photo:Prepared}){const [url,setUrl]=useState('');useEffect(()=>{const u=URL.createObjectURL(photo.blob);setUrl(u);return()=>URL.revokeObjectURL(u);},[photo]);return photo.mime==='application/pdf'?<span>PDF</span>:<img src={url} alt=""/>;}
export function PhotoStaging({photos,onChange,locale,documents=false,disabled=false,permanent=false,onPreparing}:{photos:Prepared[];onChange:(p:Prepared[])=>void;locale:Locale;documents?:boolean;disabled?:boolean;permanent?:boolean;onPreparing?:(busy:boolean)=>void}){
 const [error,setError]=useState(false),[busy,setBusy]=useState(false);const t=dictionary(locale);
 return <fieldset disabled={disabled||busy}><legend>{documents?t.wPaperDocuments:permanent?t.wPermanentPhotos:t.wInspectionPhotos}</legend><p>{t.wFilesNotice}</p>
 <input aria-label={documents?t.wPaperDocuments:t.wAddPhoto} type="file" multiple accept={documents?'image/jpeg,image/png,image/webp,application/pdf':'image/jpeg,image/png,image/webp'} onChange={async e=>{const files=Array.from(e.target.files??[]);e.target.value='';setBusy(true);onPreparing?.(true);setError(false);try{if(photos.length+files.length>5)throw Error();onChange([...photos,...await Promise.all(files.map(f=>prepare(f,documents)))]);}catch{setError(true);}finally{setBusy(false);onPreparing?.(false);}}}/>
 {error&&<p role="alert">{t.wFileError}</p>}<div className="web-gallery">{photos.map(p=><div key={p.id}><Staged photo={p}/><button type="button" onClick={()=>onChange(photos.filter(v=>v.id!==p.id))}>{t.wRemove}</button></div>)}</div></fieldset>;
}
