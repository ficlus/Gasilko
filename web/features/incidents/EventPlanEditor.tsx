'use client';
import {useScenarioEditor} from './ScenarioEditorContext';
import {workflowText} from '../../lib/operational/workflowMessages';
import dynamic from 'next/dynamic';
import {useState,useEffect} from 'react';
import type {Locale} from '../../lib/i18n';
import type {Geometry,Position} from '../../lib/incidents/cop';
import type {Definition} from '../../lib/operational/templates';
import {eventTime,geographicEvent,newEvent,scenarioEventTypes,type EventDefinition,type EventPlan} from '../../lib/operational/scenarioEvents';
import {scenarioEventText} from '../../lib/operational/scenarioEventMessages';
import {CoordinateEditor} from './TemplateEditor';
const TemplateMap=dynamic(()=>import('./TemplateMap'),{ssr:false});
export function EventPlanEditor({locale,definition,plan,onChange,disabled}:{locale:Locale;definition:Definition;plan:EventPlan;onChange:(p:EventPlan)=>void;disabled:boolean}){
 const t=scenarioEventText(locale),[selected,setSelected]=useState(''),[placing,setPlacing]=useState(false),[drawing,setDrawing]=useState(false),[vertices,setVertices]=useState<Position[]>([]);
 const context=useScenarioEditor();
 useEffect(()=>{if(context?.selected)setSelected(context.selected);},[context?.selected]);
 const index=plan.events.findIndex(e=>e.id===selected),event=plan.events[index],prior=plan.events.slice(0,Math.max(index,0));
 const geometry=event?.effect?.source_object_id?definition.initial_objects.find(o=>o.id===event.effect?.source_object_id)?.geometry:event?.effect?.geometry;
 const mapDefinition:Definition={...definition,virtual_units:definition.virtual_units,initial_objects:[...definition.initial_objects,...(event&&geographicEvent(event.type)?[{id:'event-'+event.id,kind:'HAZARD' as const,label:event.title,description:event.description,geometry:geometry??null}]:[])]};
 function choose(id:string){setSelected(id);setPlacing(false);setDrawing(false);setVertices([]);}
 function patch(value:Partial<EventDefinition>){if(!disabled&&event)onChange({...plan,events:plan.events.map(e=>e.id===event.id?{...e,...value}:e)});}
 function setGeometry(g:Geometry){if(event?.effect)patch({effect:{...event.effect,source_object_id:null,geometry:g}});}
 function move(p:Position){setGeometry({type:'Point',coordinates:p});}
 function reorder(from:number,to:number){if(disabled||to<0||to>=plan.events.length)return;const events=[...plan.events];[events[from],events[to]]=[events[to],events[from]];onChange({...plan,events});}
 return <section className="admin-card scenario-event-editor">
  <h3>{t('title')}</h3><p>{workflowText(locale)('referenceWarning')}</p><p>{t('help')}</p>{disabled&&<p>{t('readonly')}</p>}
  <ol className="template-items">{plan.events.map((e,i)=><li key={e.id}>
   <button type="button" aria-pressed={selected===e.id} onClick={()=>choose(e.id)}>{e.trigger.mode==='SIMULATION_TIME'?eventTime(e.trigger.offset_seconds??0):t(e.trigger.mode)} · {e.title} · {t(e.type)}</button>
   <div className="actions"><button type="button" aria-label={t('up')+' · '+e.title} disabled={disabled||i===0} onClick={()=>reorder(i,i-1)}>{t('up')}</button>
    <button type="button" aria-label={t('down')+' · '+e.title} disabled={disabled||i===plan.events.length-1} onClick={()=>reorder(i,i+1)}>{t('down')}</button></div>
  </li>)}</ol>
  <button type="button" disabled={disabled||plan.events.length>=40} onClick={()=>{const e=newEvent(t('INCIDENT_REPORT'));onChange({...plan,events:[...plan.events,e]});choose(e.id);}}>{t('add')} ({plan.events.length}/40)</button>
  {event&&<>
   <fieldset disabled={disabled} className="web-form-grid">
    <label>{t('name')}<input maxLength={200} value={event.title} onChange={e=>patch({title:e.target.value})}/></label>
    <label>{t('description')}<textarea maxLength={2000} value={event.description} onChange={e=>patch({description:e.target.value})}/></label>
    <label>{t('type')}<select value={event.type} onChange={e=>{const type=e.target.value as EventDefinition['type'];patch({type,effect:geographicEvent(type)?{geometry:null,source_object_id:null,target_event_id:null,expected_version:type==='HAZARD_UPDATE'?1:null}:null});}}>{scenarioEventTypes.map(v=><option key={v} value={v}>{t(v)}</option>)}</select></label>
    <label>{t('trigger')}<select value={event.trigger.mode} onChange={e=>{const mode=e.target.value as EventDefinition['trigger']['mode'];patch({trigger:{mode,offset_seconds:mode==='SIMULATION_TIME'?0:null,event_id:null}});}}>{['SIMULATION_TIME','MANUAL','AFTER_EVENT'].map(v=><option key={v} value={v}>{t(v)}</option>)}</select></label>
    {event.trigger.mode==='SIMULATION_TIME'&&<label>{t('seconds')}<input type="number" min={0} max={28800} step={1} value={event.trigger.offset_seconds??0} onChange={e=>patch({trigger:{...event.trigger,offset_seconds:Number(e.target.value)}})}/><span>{eventTime(event.trigger.offset_seconds??0)}</span></label>}
    {event.trigger.mode==='AFTER_EVENT'&&<label>{t('prior')}<select value={event.trigger.event_id??''} onChange={e=>patch({trigger:{...event.trigger,event_id:e.target.value||null}})}><option value="">{t('select')}</option>{prior.map(e=><option key={e.id} value={e.id}>{e.title}</option>)}</select></label>}
    {event.effect&&<>
     <label>{t('source')}<select value={event.effect.source_object_id??''} onChange={e=>patch({effect:{...event.effect!,source_object_id:e.target.value||null,geometry:null}})}><option value="">{t('own')}</option>{definition.initial_objects.filter(o=>o.geometry?.type==='Point'||o.geometry?.type==='Polygon').map(o=><option key={o.id} value={o.id}>{o.label}</option>)}</select></label>
     {event.type==='HAZARD_UPDATE'&&<>
      <label>{t('target')}<select value={event.effect.target_event_id??''} onChange={e=>patch({effect:{...event.effect!,target_event_id:e.target.value||null}})}><option value="">{t('select')}</option>{prior.filter(e=>e.type==='HAZARD_REVEAL').map(e=><option key={e.id} value={e.id}>{e.title}</option>)}</select></label>
      <label>{t('expectedVersion')}<input type="number" min={1} max={40} value={event.effect.expected_version??1} onChange={e=>patch({effect:{...event.effect!,expected_version:Number(e.target.value)}})}/></label>
     </>}
    </>}
   </fieldset>
   {event.effect&&<section aria-label={t('geometry')}>
    <div className="actions"><button type="button" disabled={disabled} onClick={()=>{setPlacing(true);setDrawing(false);setVertices([]);}}>{t('point')}</button>
     <button type="button" disabled={disabled} onClick={()=>{setPlacing(true);setDrawing(true);setVertices([]);}}>{t('polygon')}</button>
     {placing&&<button type="button" onClick={()=>{setPlacing(false);setDrawing(false);setVertices([]);}}>{t('cancel')}</button>}</div>
    <CoordinateEditor locale={locale} value={drawing?null:geometry?.type==='Point'?geometry.coordinates:null} disabled={disabled||drawing&&vertices.length>=32} onApply={p=>{if(drawing){if(vertices.length<32)setVertices(v=>[...v,p]);}else move(p);}}/>
    {drawing&&<div className="actions"><span>{vertices.length}/32</span><button type="button" disabled={disabled||vertices.length<3} onClick={()=>{setGeometry({type:'Polygon',coordinates:[[...vertices,vertices[0]]]});setDrawing(false);setPlacing(false);setVertices([]);}}>{t('finish')}</button><button type="button" disabled={disabled||!vertices.length} onClick={()=>setVertices(v=>v.slice(0,-1))}>{t('undo')}</button></div>}
    <div className="template-map-pane"><TemplateMap locale={locale} definition={mapDefinition} selected={'event-'+event.id} editable={!disabled} placing={placing&&!disabled} vertices={vertices}
     onSelect={()=>{}} onMove={move} onPoint={p=>{if(disabled)return;if(drawing){if(vertices.length<32)setVertices(v=>[...v,p]);}else{move(p);setPlacing(false);}}}/></div>
   </section>}
   <button type="button" disabled={disabled} onClick={()=>{onChange({...plan,events:plan.events.filter(e=>e.id!==event.id)});choose('');}}>{t('remove')}</button>
  </>}
 </section>;
}
