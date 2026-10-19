'use client';
import dynamic from 'next/dynamic';
import {useState} from 'react';
import type {Locale} from '../../lib/i18n';
import type {Position} from '../../lib/incidents/cop';
import {offsetPosition,type Definition} from '../../lib/operational/templates';
import type {EventPlan} from '../../lib/operational/scenarioEvents';
import {newHazard,effectDefault,type HazardPlan,type HazardModel,type HazardEffect} from '../../lib/operational/hazards';
import {hazardText} from '../../lib/operational/hazardMessages';
import {CoordinateEditor} from './TemplateEditor';
const TemplateMap=dynamic(()=>import('./TemplateMap'),{ssr:false});
export function HazardEffectFields({locale,value,model,onChange,disabled=false}:{locale:Locale;value:HazardEffect;model:HazardModel;onChange:(v:HazardEffect)=>void;disabled?:boolean}){
 const t=hazardText(locale),wind=value.value as {direction:number;speed:number};
 return <fieldset disabled={disabled}>
  <label>{t('effect')}<select value={value.type} onChange={e=>onChange(effectDefault(e.target.value as HazardEffect['type'],model))}>
   {(['IGNITE','WIND','SPREAD','BOOST','ENABLE','REVEAL','STOP'] as const).map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
  {value.type==='IGNITE'&&<label>{t('origins')}<select value={String(value.value)} onChange={e=>onChange({...value,value:e.target.value})}>{model.origins.map((o,i)=><option key={o.id} value={o.id}>{t('origins')} {i+1}</option>)}</select></label>}
  {value.type==='WIND'&&<>{(['direction','speed'] as const).map(k=><label key={k}>{t(k==='direction'?'wind_direction':'wind_speed')}<input type="number" min={0} max={k==='direction'?359.99:20} step="any" value={wind[k]} onChange={e=>onChange({...value,value:{...wind,[k]:Number(e.target.value)}})}/></label>)}</>}
  {['SPREAD','BOOST'].includes(value.type)&&<label>{t(value.type)}<input type="number" min={0} max={value.type==='SPREAD'?2:1} step="0.05" value={Number(value.value)} onChange={e=>onChange({...value,value:Number(e.target.value)})}/></label>}
  {value.type==='ENABLE'&&<label><input type="checkbox" checked={value.value===true} onChange={e=>onChange({...value,value:e.target.checked})}/>{t('enabled')}</label>}
 </fieldset>;
}
export function HazardPlanEditor({locale,definition,events,plan,onChange,disabled}:{locale:Locale;definition:Definition;events:EventPlan;plan:HazardPlan;onChange:(p:HazardPlan)=>void;disabled:boolean}){
 const t=hazardText(locale),[selected,setSelected]=useState(''),[placing,setPlacing]=useState(''),[eventId,setEventId]=useState('');
 const m=plan.models.find(v=>v.id===selected);
 function patch(value:Partial<HazardModel>){if(m&&!disabled)onChange({...plan,models:plan.models.map(v=>v.id===m.id?{...v,...value}:v)});}
 function point(position:Position){
  if(!m||disabled)return;
  if(placing==='center')patch({center:position});
  else if(placing==='blocked'){
   const r=Math.PI/180,x=Math.round((position[0]-m.center[0])*r*6371008.8*Math.cos(m.center[1]*r)/m.cell_m),y=Math.round((position[1]-m.center[1])*r*6371008.8/m.cell_m);
   if(Math.abs(x)<=m.radius_m/m.cell_m&&Math.abs(y)<=m.radius_m/m.cell_m)patch({blocked:m.blocked.some(b=>b[0]===x&&b[1]===y)?m.blocked.filter(b=>b[0]!==x||b[1]!==y):[...m.blocked,[x,y]]});
   return;
  }else if(m.origins.some(o=>o.id===placing))patch({origins:m.origins.map(o=>o.id===placing?{...o,position}:o)});
  else patch({zones:m.zones.map(z=>z.id===placing?{...z,position}:z)});
  setPlacing('');
 }
 const preview:Definition=m?{...definition,world:{...definition.world,center:m.center,radius_m:m.radius_m},virtual_units:[],initial_objects:[
  ...m.origins.map((o,i)=>({id:o.id,kind:'HAZARD' as const,label:t('origins')+' '+(i+1),description:'',geometry:{type:'Point' as const,coordinates:o.position}})),
  ...m.origins.filter(o=>o.initial).map(o=>({id:'extent:'+o.id,kind:'HAZARD' as const,label:t('preview'),description:'',geometry:{type:'Polygon' as const,coordinates:[Array.from({length:17},(_,i)=>offsetPosition(o.position,5+15*o.intensity,i*360/16))]}})),
  ...m.zones.map(z=>({id:z.id,kind:'HAZARD' as const,label:t(z.kind),description:'',geometry:{type:'Polygon' as const,coordinates:[Array.from({length:17},(_,i)=>offsetPosition(z.position,z.radius_m,i*360/16))]}})),
  ...m.blocked.map(b=>{const r=Math.PI/180,center:Position=[m.center[0]+b[0]*m.cell_m/6371008.8/Math.cos(m.center[1]*r)/r,m.center[1]+b[1]*m.cell_m/6371008.8/r];return {id:'blocked:'+b.join(':'),kind:'NOTE' as const,label:t('blocked'),description:'',geometry:{type:'Point' as const,coordinates:center}};})
 ]}:definition;
 return <details className="admin-card"><summary>{t('title')} ({plan.models.length}/4)</summary><p>{t('disclaimer')}</p><p>{t('limits')}</p>
  <div className="actions">{plan.models.map(model=><button type="button" key={model.id} aria-pressed={selected===model.id} onClick={()=>{setSelected(model.id);setPlacing('');}}>{model.title}</button>)}
   <button type="button" disabled={disabled||plan.models.length>=4} onClick={()=>{const value=newHazard(definition.world.center??[14.5,46.1],t('STRUCTURE_FIRE'));onChange({...plan,models:[...plan.models,value]});setSelected(value.id);}}>{t('add')}</button></div>
  {m&&<>
   <fieldset disabled={disabled} className="web-form-grid">
    <label>{t('name')}<input maxLength={100} value={m.title} onChange={e=>patch({title:e.target.value})}/></label>
    <label>{t('type')}<select value={m.type} onChange={e=>patch({type:e.target.value as HazardModel['type']})}><option value="STRUCTURE_FIRE">{t('STRUCTURE_FIRE')}</option><option value="WILDFIRE" disabled={plan.models.some(x=>x.id!==m.id&&x.type==='WILDFIRE')}>{t('WILDFIRE')}</option></select></label>
    <label><input type="checkbox" checked={m.enabled} onChange={e=>patch({enabled:e.target.checked})}/>{t('enabled')}</label>
    <label>{t('visibility')}<select value={m.visibility} onChange={e=>patch({visibility:e.target.value as HazardModel['visibility']})}>{['START','HIDDEN'].map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
    {(['radius_m','wind_direction','wind_speed','fuel','moisture','spread','decline_seconds'] as const).map(k=><label key={k}>{t(k)}<input type="number" step={k==='radius_m'?m.cell_m:'any'} min={k==='radius_m'?25:k==='fuel'?0.1:0} max={k==='radius_m'?250:k==='wind_direction'?359.99:k==='wind_speed'?20:k==='decline_seconds'?28800:k==='spread'?2:1} value={m[k]} onChange={e=>patch({[k]:Number(e.target.value)})}/></label>)}
    {m.type==='WILDFIRE'&&<label>{t('cell_m')}<select value={m.cell_m} onChange={e=>patch({cell_m:Number(e.target.value) as 25|50,blocked:[]})}><option>25</option><option>50</option></select></label>}
    <button type="button" onClick={()=>setPlacing('center')}>{t('center')} · {t('place')}</button>
   </fieldset>
   <h4>{t('origins')}</h4>
   {m.origins.map((o,i)=><fieldset key={o.id} disabled={disabled}><legend>{t('origins')} {i+1}</legend><label>{t('intensity')}<input type="number" min={0.05} max={1} step={0.05} value={o.intensity} onChange={e=>patch({origins:m.origins.map(v=>v.id===o.id?{...v,intensity:Number(e.target.value)}:v)})}/></label>
    <label><input type="checkbox" checked={o.initial} onChange={e=>patch({origins:m.origins.map(v=>v.id===o.id?{...v,initial:e.target.checked}:v)})}/>{t('initial')}</label>
    <button type="button" onClick={()=>setPlacing(o.id)}>{t('place')}</button><button type="button" disabled={m.origins.length<=1} onClick={()=>patch({origins:m.origins.filter(v=>v.id!==o.id)})}>{t('remove')}</button>
   </fieldset>)}
   <button type="button" disabled={disabled||m.origins.length>=8} onClick={()=>patch({origins:[...m.origins,{id:crypto.randomUUID(),position:m.center,intensity:0.2,initial:true}]})}>{t('addOrigin')}</button>
   {m.type==='WILDFIRE'&&<><button type="button" disabled={disabled} aria-pressed={placing==='blocked'} onClick={()=>setPlacing(placing==='blocked'?'':'blocked')}>{t('blocked')} ({m.blocked.length})</button><p>{t('blockHelp')}</p></>}
   <h4>{t('zones')}</h4>
   {m.zones.map(z=><fieldset key={z.id} disabled={disabled}><label>{t('type')}<select value={z.kind} onChange={e=>patch({zones:m.zones.map(v=>v.id===z.id?{...v,kind:e.target.value as typeof z.kind}:v)})}>{['HEAT_ZONE','SMOKE_ZONE','COLLAPSE_RISK','HAZARDOUS_MATERIAL','ACCESS_HAZARD'].map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
    <label>{t('radius_m')}<input type="number" min={5} max={250} value={z.radius_m} onChange={e=>patch({zones:m.zones.map(v=>v.id===z.id?{...v,radius_m:Number(e.target.value)}:v)})}/></label>
    <button type="button" onClick={()=>setPlacing(z.id)}>{t('place')}</button><button type="button" onClick={()=>patch({zones:m.zones.filter(v=>v.id!==z.id)})}>{t('remove')}</button></fieldset>)}
   <button type="button" disabled={disabled||m.zones.length>=8} onClick={()=>patch({zones:[...m.zones,{id:crypto.randomUUID(),kind:'COLLAPSE_RISK',position:m.center,radius_m:10}]})}>{t('addZone')}</button>
   <div className="template-map-pane"><p>{t('preview')}</p>{placing&&<><CoordinateEditor locale={locale} value={null} disabled={disabled} onApply={point}/><button type="button" onClick={()=>setPlacing('')}>{t('cancel')}</button></>}
    <TemplateMap locale={locale} definition={preview} selected={placing} editable={!disabled&&!!placing} placing={!disabled&&!!placing} vertices={[]} onSelect={()=>{}} onPoint={point} onMove={point}/>
   </div>
   <h4>{t('effects')}</h4>
   {m.effects.map((e,i)=><fieldset key={e.event_id} disabled={disabled}><legend>{events.events.find(v=>v.id===e.event_id)?.title??t('event')}</legend>
    <HazardEffectFields locale={locale} value={e.effect} model={m} onChange={effect=>patch({effects:m.effects.map((v,n)=>n===i?{...v,effect}:v)})}/>
    <button type="button" onClick={()=>patch({effects:m.effects.filter((_,n)=>n!==i)})}>{t('remove')}</button></fieldset>)}
   <label>{t('event')}<select disabled={disabled} value={eventId} onChange={e=>setEventId(e.target.value)}><option value="">—</option>{events.events.filter(e=>!m.effects.some(v=>v.event_id===e.id)).map(e=><option key={e.id} value={e.id}>{e.title}</option>)}</select></label>
   <button type="button" disabled={disabled||!eventId||m.effects.some(e=>e.event_id===eventId)||!events.events.some(e=>e.id===eventId)} onClick={()=>{patch({effects:[...m.effects,{event_id:eventId,effect:effectDefault('REVEAL',m)}]});setEventId('');}}>{t('addEffect')}</button>
   <button type="button" disabled={disabled} onClick={()=>{onChange({...plan,models:plan.models.filter(v=>v.id!==m.id)});setSelected('');setPlacing('');}}>{t('remove')} · {m.title}</button>
  </>}
 </details>;
}
