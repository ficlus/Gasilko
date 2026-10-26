'use client';
import {useEffect,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import type {Definition,TemplateRead} from '../../lib/operational/templates';
import {emptyOperationalConfig} from '../../lib/operational/operations';
import {operationText} from '../../lib/operational/operationMessages';
export function OperationalConfigEditor({locale,definition,onChange,disabled,read,account,org}:{locale:Locale;definition:Definition;onChange:(v:Definition)=>void;disabled:boolean;read:TemplateRead;account:string;org:string}){
 const t=operationText(locale),cfg=definition.operational??emptyOperationalConfig();
 const [actions,setActions]=useState<{id:string;label_sl:string;label_de:string;version_number:number}[]>([]),[error,setError]=useState(false),[chosen,setChosen]=useState('');
 useEffect(()=>{const ac=new AbortController();setActions([]);setChosen('');setError(false);void read<typeof actions>('simulation_operational_actions',{p_organization_id:org},ac.signal,account).then(v=>{if(!ac.signal.aborted)setActions(v);}).catch(()=>{if(!ac.signal.aborted)setError(true);});return()=>ac.abort();},[account,org,read]);
 const set=(next:typeof cfg)=>onChange({...definition,operational:next});
 return <section className="admin-card"><h3>{t('resources')}</h3><p>{t('disclaimer')}</p>
 <fieldset disabled={disabled}>
 {definition.virtual_units.map((unit,i)=>{const r=cfg.resources.find(v=>v.unit_key===unit.id);return <section key={unit.id}><h4>SIM-{i+1}</h4>
 {r?<><div className="web-form-grid">{(['capacity_l','initial_l','pump_lpm','range_m','efficiency'] as const).map(key=><label key={key}>{t(key)}<input type="number" step={['capacity_l','initial_l','pump_lpm'].includes(key)?'0.001':'any'} min={key==='range_m'?1:key==='efficiency'?0.000001:0} max={key==='range_m'?100:key==='efficiency'?0.001:key==='pump_lpm'?5000:100000} value={r[key]} onChange={e=>set({...cfg,resources:cfg.resources.map(v=>v.unit_key===unit.id?{...v,[key]:Number(e.target.value)}:v)})}/></label>)}</div>
 <button type="button" onClick={()=>set({...cfg,resources:cfg.resources.filter(v=>v.unit_key!==unit.id)})}>{t('remove')}</button></>:<button type="button" onClick={()=>set({...cfg,resources:[...cfg.resources,{unit_key:unit.id,capacity_l:0,initial_l:0,pump_lpm:0,range_m:25,efficiency:0.0001}]})}>{t('configure')}</button>}</section>;})}
 <h3>{t('bindings')}</h3><p>{t('bindingHelp')}</p>{error&&<p role="alert">{t('stale')}</p>}
 {cfg.bindings.map((b,i)=><section key={b.action_version_id}><strong>{actions.find(a=>a.id===b.action_version_id)?.[locale==='de'?'label_de':'label_sl']??b.action_version_id}</strong>
 <div className="web-form-grid">{(['flow_lpm','duration_seconds'] as const).map(key=><label key={key}>{t(key)}<input type="number" min={key==='flow_lpm'?0.012:5} max={key==='flow_lpm'?5000:3600} step={key==='flow_lpm'?0.001:5} value={b[key]} onChange={e=>set({...cfg,bindings:cfg.bindings.map((v,n)=>n===i?{...v,[key]:Number(e.target.value)}:v)})}/></label>)}</div>
 <button type="button" onClick={()=>set({...cfg,bindings:cfg.bindings.filter((_,n)=>n!==i)})}>{t('remove')}</button></section>)}
 <label>{t('action')}<select value={chosen} onChange={e=>setChosen(e.target.value)}><option value="">—</option>{actions.filter(a=>!cfg.bindings.some(b=>b.action_version_id===a.id)).map(a=><option key={a.id} value={a.id}>{a[locale==='de'?'label_de':'label_sl']} · {a.version_number}</option>)}</select></label>
 <button type="button" disabled={!chosen||cfg.bindings.length>=16||cfg.bindings.some(b=>b.action_version_id===chosen)} onClick={()=>{set({...cfg,bindings:[...cfg.bindings,{action_version_id:chosen,kernel:'APPLY_WATER',flow_lpm:200,duration_seconds:300}]});setChosen('');}}>{t('add')}</button>
 </fieldset></section>;
}
