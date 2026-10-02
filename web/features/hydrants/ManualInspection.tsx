'use client';
import {useEffect,useRef,useState} from 'react';
import {dictionary,type Locale} from '@/lib/i18n';
import {rpc,type Row} from '@/lib/hydrants/admin';
import {failure} from '@/lib/hydrants/domain';
import {PhotoStaging,upload,type Prepared} from './PrivatePhotos';
export const resultLabel=(t:ReturnType<typeof dictionary>,v:string)=>(({PASS:t.wPass,PASS_WITH_ISSUES:t.wIssues,FAIL:t.wFail,NOT_INSPECTED:t.wNotInspected} as Record<string,string>)[v]??t.hMissing);
export const modeLabel=(t:ReturnType<typeof dictionary>,v:string)=>(({QUICK:t.wQuick,GUIDED:t.wGuided,CLASSIC:t.wClassic} as Record<string,string>)[v]??t.hMissing);
export function ManualInspection({locale,hydrant,onDone}:{locale:Locale;hydrant:Row;onDone:()=>void}){
 const t=dictionary(locale),[mode,setMode]=useState('CLASSIC'),[result,setResult]=useState('PASS'),[performed,setPerformed]=useState('');
 const [performer,setPerformer]=useState(''),[name,setName]=useState(''),[external,setExternal]=useState(''),[notes,setNotes]=useState(''),[correction,setCorrection]=useState('');
 const [pressure,setPressure]=useState(''),[flow,setFlow]=useState(''),[search,setSearch]=useState('');
 const [members,setMembers]=useState<{id:string;display_name:string}[]>([]),[photos,setPhotos]=useState<Prepared[]>([]),[documents,setDocuments]=useState<Prepared[]>([]);
 const [busy,setBusy]=useState(false),[locked,setLocked]=useState(false),[error,setError]=useState(''),[committed,setCommitted]=useState(false);
 const frozen=useRef<{event:Record<string,unknown>;files:Prepared[]}|null>(null);
 const persisted=useRef(false);
 const [preparingPhotos,setPreparingPhotos]=useState(false),[preparingDocuments,setPreparingDocuments]=useState(false);
 useEffect(()=>{let alive=true;const timer=setTimeout(()=>{void rpc<{id:string;display_name:string}[]>('web_inspection_performers',{organization:hydrant.organization_id,search}).then(v=>{if(alive)setMembers(v);}).catch(()=>{if(alive)setMembers([]);});},300);return()=>{alive=false;clearTimeout(timer);};},[hydrant.organization_id,search]);
 async function complete(){setBusy(true);setError('');try{
 if(!frozen.current){frozen.current={event:{id:crypto.randomUUID(),mode,result,performed_at:new Date(performed).toISOString(),performer_id:performer||null,performer_name:name,performer_organization:external,notes,pressure_bar:pressure||null,flow_l_min:flow||null,corrects_inspection_id:correction||null},files:[...photos,...documents]};setLocked(true);}
 const record=await rpc<{id:string}>('web_manual_inspection',{organization:hydrant.organization_id,hydrant:hydrant.id,event:frozen.current.event});persisted.current=true;setCommitted(true);
 for(const p of frozen.current.files)await upload(p,hydrant.organization_id,hydrant.id,record.id);
 onDone();
 }catch(e){if(!persisted.current&&failure(e)==='validation'){frozen.current=null;setLocked(false);setError(t.hValidation);}else setError(t.wInspectionRetry);}finally{setBusy(false);}}
 return <form className="admin-card" onSubmit={e=>{e.preventDefault();void complete();}}><h3>{t.wManualInspection}</h3><p>{t.wManualNotice}</p>
 {error&&<p role="alert">{error}</p>}{committed&&<p role="status">{t.wInspectionCommitted}</p>}{locked&&<p>{t.wFrozenRetry}</p>}
 <fieldset disabled={busy||locked}><div className="web-form-grid">
 <label>{t.wMode}<select value={mode} onChange={e=>setMode(e.target.value)}>{['QUICK','GUIDED','CLASSIC'].map(v=><option key={v} value={v}>{modeLabel(t,v)}</option>)}</select></label>
 <label>{t.wResult}<select value={result} onChange={e=>setResult(e.target.value)}>{['PASS','PASS_WITH_ISSUES','FAIL','NOT_INSPECTED'].map(v=><option key={v} value={v}>{resultLabel(t,v)}</option>)}</select></label>
 <label>{t.wPerformedAt}<input type="datetime-local" required value={performed} onChange={e=>setPerformed(e.target.value)}/></label>
 <label>{t.wMemberSearch}<input value={search} onChange={e=>setSearch(e.target.value)}/></label>
 <label>{t.wPerformer}<select value={performer} onChange={e=>setPerformer(e.target.value)}><option value="">{t.wExternalPerformer}</option>{members.map(m=><option key={m.id} value={m.id}>{m.display_name||t.hMissing}</option>)}</select></label>
 {!performer&&<><label>{t.wPerformerName}<input required value={name} onChange={e=>setName(e.target.value)}/></label><label>{t.wExternalOrganization}<input value={external} onChange={e=>setExternal(e.target.value)}/></label></>}
 <label>{t.wPressure}<input type="number" min="0" max="999.99" step="0.01" value={pressure} onChange={e=>setPressure(e.target.value)}/></label>
 <label>{t.wFlow}<input type="number" min="0" max="999999.99" step="0.01" value={flow} onChange={e=>setFlow(e.target.value)}/></label>
 <label>{t.hNotes}<textarea value={notes} onChange={e=>setNotes(e.target.value)}/></label>
 <label>{t.wCorrects}<input placeholder={t.wOptionalUuid} value={correction} onChange={e=>setCorrection(e.target.value)}/></label>
 </div></fieldset><PhotoStaging locale={locale} photos={photos} onChange={setPhotos} disabled={busy||locked} onPreparing={setPreparingPhotos}/><PhotoStaging locale={locale} photos={documents} onChange={setDocuments} documents disabled={busy||locked} onPreparing={setPreparingDocuments}/>
 <button type="submit" disabled={busy||preparingPhotos||preparingDocuments}>{busy?t.hSaving:locked?t.hRetry:t.wCompleteInspection}</button></form>;
}
