'use client';
import type {Locale} from '../../lib/i18n';
import {incidentPriorities} from '../../lib/incidents/model';
import {nativeBehaviors,recipientTypes,targetTypes,parameterTypes,parameterLabel,type ActionConfiguration,type Parameter} from '../../lib/operational/tasks';
import {taskText} from '../../lib/operational/taskMessages';

export function ActionFields({locale,value,onChange}:{locale:Locale;value:ActionConfiguration;onChange:(v:ActionConfiguration)=>void}){
 const t=taskText(locale),set=<K extends keyof ActionConfiguration>(key:K,v:ActionConfiguration[K])=>onChange({...value,[key]:v});
 const setParameter=(index:number,p:Parameter)=>set('parameter_definitions',value.parameter_definitions.map((v,i)=>i===index?p:v));
 function choices(key:'recipient_types'|'target_types',all:readonly string[]){return <fieldset><legend>{t(key==='recipient_types'?'recipients':'targets')}</legend>
  {all.map(kind=><label key={kind}><input type="checkbox" checked={value[key].includes(kind)} onChange={e=>set(key,e.target.checked?[...value[key],kind]:value[key].filter(v=>v!==kind))}/>{t(kind)}</label>)}</fieldset>;}
 return <>
  {(['label_sl','label_de','description_sl','description_de'] as const).map(key=><label key={key}>{t(key)}<input required={key.startsWith('label')} maxLength={key.startsWith('label')?200:2000} value={value[key]??''} onChange={e=>set(key,e.target.value)}/></label>)}
  <label>{t('native')}<select value={value.native_behavior} onChange={e=>set('native_behavior',e.target.value as ActionConfiguration['native_behavior'])}>{nativeBehaviors.map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
  <label>{t('priority')}<select value={value.default_priority} onChange={e=>set('default_priority',e.target.value)}>{incidentPriorities.map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
  <label><input type="checkbox" checked={value.requires_acknowledgement} onChange={e=>set('requires_acknowledgement',e.target.checked)}/>{t('ack')}</label>
  <label><input type="checkbox" checked={value.active_for_new_commands} onChange={e=>set('active_for_new_commands',e.target.checked)}/>{t('futureActive')}</label>
  {choices('recipient_types',recipientTypes)}{choices('target_types',targetTypes)}
  {['MOVE_TO','WITHDRAW_TO'].includes(value.native_behavior)&&<p role="note">{t('pointNotice')}</p>}
  <fieldset><legend>{t('parameters')} ({value.parameter_definitions.length}/10)</legend>
   {value.parameter_definitions.map((p,index)=><fieldset key={index}><legend>{t('parameters')} {index+1}</legend>
    <label>{t('code')}<input required pattern="[A-Z][A-Z0-9_-]{0,63}" maxLength={64} value={p.code} onChange={e=>setParameter(index,{...p,code:e.target.value})}/></label>
    {(['label_sl','label_de'] as const).map(key=><label key={key}>{t(key)}<input required maxLength={200} value={p[key]} onChange={e=>setParameter(index,{...p,[key]:e.target.value})}/></label>)}
    <label>{t('parameterType')}<select value={p.type} onChange={e=>{const type=e.target.value as Parameter['type'];setParameter(index,{code:p.code,label_sl:p.label_sl,label_de:p.label_de,required:p.required,sort_order:p.sort_order,type,...(type==='TEXT'?{max_length:200}:{}),...(type==='CHOICE'?{options:[{code:'',label_sl:'',label_de:''}]}:{})});}}>{parameterTypes.map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
    <label><input type="checkbox" checked={p.required} onChange={e=>setParameter(index,{...p,required:e.target.checked})}/>{t('required')}</label>
    <label>{t('sort_order')}<input type="number" required min={0} max={999} step={1} value={p.sort_order} onChange={e=>setParameter(index,{...p,sort_order:Number(e.target.value)})}/></label>
    {['INTEGER','DECIMAL'].includes(p.type)&&(['min','max'] as const).map(key=><label key={key}>{t(key)}<input type="number" step={p.type==='INTEGER'?1:'any'} value={p[key]??''} onChange={e=>{const next={...p};if(e.target.value==='')delete next[key];else next[key]=Number(e.target.value);setParameter(index,next);}}/></label>)}
    {p.type==='TEXT'&&<label>{t('max_length')}<input type="number" required min={1} max={2000} step={1} value={p.max_length??200} onChange={e=>setParameter(index,{...p,max_length:Number(e.target.value)})}/></label>}
    {p.type==='CHOICE'&&<fieldset><legend>{t('options')}</legend>{(p.options??[]).map((o,oi)=><div className="web-row" key={oi}>
     {(['code','label_sl','label_de'] as const).map(key=><label key={key}>{t(key)}<input required pattern={key==='code'?'[A-Z][A-Z0-9_-]{0,63}':undefined} maxLength={key==='code'?64:200} value={o[key]} onChange={e=>setParameter(index,{...p,options:p.options?.map((v,i)=>i===oi?{...v,[key]:e.target.value}:v)})}/></label>)}
     <button type="button" onClick={()=>setParameter(index,{...p,options:p.options?.filter((_,i)=>i!==oi)})}>{t('remove')}</button>
    </div>)}<button type="button" disabled={(p.options?.length??0)>=20} onClick={()=>setParameter(index,{...p,options:[...(p.options??[]),{code:'',label_sl:'',label_de:''}]})}>{t('addOption')}</button></fieldset>}
    <button type="button" onClick={()=>set('parameter_definitions',value.parameter_definitions.filter((_,i)=>i!==index))}>{t('remove')}</button>
   </fieldset>)}
   <button type="button" disabled={value.parameter_definitions.length>=10} onClick={()=>set('parameter_definitions',[...value.parameter_definitions,{code:'',label_sl:'',label_de:'',type:'TEXT',max_length:200,required:false,sort_order:value.parameter_definitions.length}])}>{t('addParameter')}</button>
  </fieldset>
 </>;
}

/** Metadata-only inputs; no tactical action-code branching. Optional unset values are omitted. */
export function ParameterInputs({locale,definitions,value,onChange}:{locale:Locale;definitions:Parameter[];value:Record<string,unknown>;onChange:(v:Record<string,unknown>)=>void}){
 const t=taskText(locale);
 function change(code:string,v:unknown){const next={...value};if(v===undefined)delete next[code];else next[code]=v;onChange(next);}
 return <fieldset><legend>{t('parameters')}</legend>{[...definitions].sort((a,b)=>a.sort_order-b.sort_order||a.code.localeCompare(b.code)).map(p=><label key={p.code}>
  {parameterLabel(p,locale)}{p.required?' *':''}
  {p.type==='BOOLEAN'||p.type==='CHOICE'?<select required={p.required} value={value[p.code]===undefined?'':String(value[p.code])} onChange={e=>change(p.code,e.target.value===''?undefined:p.type==='BOOLEAN'?e.target.value==='true':e.target.value)}>
   <option value="">{t('select')}</option>{p.type==='BOOLEAN'?<><option value="true">{t('yes')}</option><option value="false">{t('no')}</option></>:(p.options??[]).map(o=><option value={o.code} key={o.code}>{parameterLabel(o,locale)}</option>)}
  </select>:<input required={p.required} type={p.type==='TEXT'?'text':'number'} step={p.type==='INTEGER'?1:'any'} min={p.min} max={p.max} maxLength={p.max_length}
   value={String(value[p.code]??'')} onChange={e=>change(p.code,e.target.value===''?undefined:p.type==='TEXT'?e.target.value:Number(e.target.value))}/>}
 </label>)}</fieldset>;
}
