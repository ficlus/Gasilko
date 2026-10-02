'use client';
import dynamic from 'next/dynamic';
import {useRef,useState} from 'react';
import {dictionary,type Locale} from '@/lib/i18n';
import {draftFrom,emptyDraft,fields,payload,statuses,failure,type Draft,type Hydrant} from '@/lib/hydrants/domain';
import {rpc,type Scope,type Row} from '@/lib/hydrants/admin';
import {statusLabel,typeLabel} from './Registry';
import {PhotoStaging,upload,type Prepared} from './PrivatePhotos';
const Map=dynamic(()=>import('../map/HydrantMap'),{ssr:false});
export function HydrantEditor({locale,scope,hydrant,onSaved,onCancel}:{locale:Locale;scope:Scope;hydrant?:Row;onSaved:(h:Hydrant)=>void;onCancel:()=>void}){
 const t=dictionary(locale);const [draft,setDraft]=useState<Draft>(()=>hydrant?draftFrom(hydrant):emptyDraft(crypto.randomUUID()));
 const [org,setOrg]=useState(hydrant?.organization_id??scope.organizations.find(o=>o.writable)?.id??'');
 const [photos,setPhotos]=useState<Prepared[]>([]),[busy,setBusy]=useState(false),[error,setError]=useState('');
 const frozen=useRef<{operation:string;data:Record<string,unknown>;photos:Prepared[]}|null>(null);
 const committed=useRef(false);
 const [preparing,setPreparing]=useState(false);
 const [locked,setLocked]=useState(false);const [suggestions,setSuggestions]=useState<{label:string;latitude:number;longitude:number;addressOnly:boolean}[]>([]);
 const [geoMessage,setGeoMessage]=useState('');
 const change=(key:keyof Draft,value:string)=>{if(!locked)setDraft(d=>({...d,[key]:value}));};
 async function geocode(reverse:boolean){setGeoMessage('');try{const q=new URLSearchParams({organization:org,locale,...(reverse?{lat:draft.latitude,lon:draft.longitude}:{q:draft.address})});
 const r=await fetch('/api/geocode?'+q,{cache:'no-store'});if(r.status===503){setGeoMessage(t.wGeocodingOff);return;}if(!r.ok)throw Error();const values:{label:string;latitude:number;longitude:number}[]=await r.json();setSuggestions(values.map(s=>({...s,addressOnly:reverse})));}catch{setGeoMessage(t.wGeocodingError);}}
 async function save(){setBusy(true);setError('');try{
 if(!frozen.current){const f=fields(draft);frozen.current={operation:crypto.randomUUID(),data:hydrant?payload(f,false):{...payload(f,true),hydrant_type_id:f.hydrant_type_id},photos};setLocked(true);}
 const h=await rpc<Hydrant>('web_hydrant_write',{organization:org,hydrant:draft.id,operation:frozen.current.operation,action:hydrant?'edit':'create',data:frozen.current.data,expected_version:draft.version??null});
 committed.current=true;
 for(const p of frozen.current.photos)await upload(p,org,h.id);
 onSaved(h);
 }catch(e){const why=failure(e);if(why==='validation'&&!committed.current){frozen.current=null;setLocked(false);}setError(why==='conflict'?t.hConflict:why==='forbidden'?t.hForbidden:why==='validation'?t.hValidation:t.wSaveRetry);}finally{setBusy(false);}}
 const lat=Number(draft.latitude),lon=Number(draft.longitude),point=draft.latitude!==''&&draft.longitude!==''&&Number.isFinite(lat)&&Number.isFinite(lon)&&Math.abs(lat)<=90&&Math.abs(lon)<=180?[lon,lat] as [number,number]:null;
 return <section className="admin-card"><h2>{hydrant?t.hEdit:t.hAdd}</h2><p>{t.hOnline}</p>{error&&<p role="alert">{error}</p>}
 {locked&&<p>{t.wFrozenRetry}</p>}<form onSubmit={e=>{e.preventDefault();void save();}}><fieldset disabled={busy||locked}>
 <div className="web-form-grid"><label>{t.selectOrganization}<select value={org} disabled={!!hydrant} onChange={e=>{setOrg(e.target.value);change('type','');}}>{scope.organizations.filter(o=>o.writable).map(o=><option key={o.id} value={o.id}>{o.name}</option>)}</select></label>
 <label>{t.hType}<select required value={draft.type} onChange={e=>change('type',e.target.value)}><option value="">{t.hType}</option>{scope.types.filter(v=>(v.active||v.id===draft.type)&&(!v.organization_id||v.organization_id===org)).map(v=><option value={v.id} key={v.id}>{typeLabel(t,v)}</option>)}</select></label>
 {!hydrant&&<label>{t.hStatus}<select value={draft.status} onChange={e=>change('status',e.target.value)}>{statuses.map(s=><option key={s} value={s}>{statusLabel(t,s)}</option>)}</select></label>}
 {([['address',t.hAddress],['description',t.hDescription],['notes',t.hNotes],['interval',t.hInterval],['latitude',t.hLatitude],['longitude',t.hLongitude]] as const).map(([k,label])=><label key={k}>{label}<input value={draft[k]} onChange={e=>change(k,e.target.value)}/></label>)}</div>
 <p>{t.wChooseLocation}</p><Map locale={locale} point={point} onPoint={busy||locked?undefined:p=>{setDraft(d=>({...d,longitude:p[0].toFixed(6),latitude:p[1].toFixed(6)}));}}/>
 <div className="actions"><button type="button" onClick={()=>void geocode(false)}>{t.wAddressSearch}</button><button type="button" disabled={!point} onClick={()=>void geocode(true)}>{t.wReverseAddress}</button></div>
 {geoMessage&&<p role="status">{geoMessage}</p>}{suggestions.map((s,i)=><button type="button" key={i} onClick={()=>{setDraft(d=>({...d,address:s.label,...(!s.addressOnly?{latitude:String(s.latitude),longitude:String(s.longitude)}:{})}));setSuggestions([]);}}>{s.label}</button>)}
 </fieldset>{!hydrant&&<PhotoStaging locale={locale} photos={photos} onChange={setPhotos} disabled={busy||locked} permanent onPreparing={setPreparing}/>}
 <div className="actions"><button disabled={busy||preparing||!org} type="submit">{busy?t.hSaving:locked?t.hRetry:t.hSave}</button><button type="button" disabled={busy||preparing} onClick={onCancel}>{error===t.hConflict?t.hRefresh:locked?t.wClose:t.hCancel}</button></div></form></section>;
}
