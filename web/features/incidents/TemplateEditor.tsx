'use client';
import dynamic from 'next/dynamic';
import {useState,useEffect} from 'react';
import type {Locale} from '../../lib/i18n';
import type {Position,Geometry,MapKind} from '../../lib/incidents/cop';
import {placeUnset,placementMissing,templateCategories,templateProfiles,type Definition,type Template} from '../../lib/operational/templates';
import {templateText} from '../../lib/operational/templateMessages';
const TemplateMap=dynamic(()=>import('./TemplateMap'),{ssr:false});
type Props={locale:Locale;value:Template;draft:Definition;onChange:(d:Definition)=>void;disabled:boolean};
const kinds:MapKind[]=['COMMAND_POST','STAGING','TRIAGE_POINT','WATER_SOURCE','ACCESS_POINT','NOTE','HAZARD','PERIMETER'];
export function TemplateEditor({locale,value,draft:d,onChange,disabled}:Props){
 const t=templateText(locale),[preview,setPreview]=useState(value.builtin||value.state==='PUBLISHED'),[selected,setSelected]=useState('center');
 const [placing,setPlacing]=useState(false),[drawing,setDrawing]=useState(false),[vertices,setVertices]=useState<Position[]>([]);
 const [kind,setKind]=useState<MapKind>('COMMAND_POST');
 const [configurationOpen,setConfigurationOpen]=useState(true),[inspectorOpen,setInspectorOpen]=useState(true);
 useEffect(()=>{if(window.matchMedia('(max-width:1100px)').matches){setConfigurationOpen(false);setInspectorOpen(false);}},[]);
 const previewOnly=preview||value.builtin||value.archived||value.state==='PUBLISHED';
 const canEdit=!disabled&&!previewOnly;
 const object=d.initial_objects.find(o=>o.id===selected),unit=d.virtual_units.find(u=>u.id===selected);
 const point=selected==='center'?d.world.center:selected==='incident'?d.world.incident_location:unit?.position??(object?.geometry?.type==='Point'?object.geometry.coordinates:null);
 function choose(id:string){setSelected(id);setInspectorOpen(true);setPlacing(false);setDrawing(false);setVertices([]);}
 function move(p:Position){
  if(!canEdit)return;
  if(selected==='center')onChange(placeUnset(d,p));
  else if(selected==='incident')onChange({...d,world:{...d.world,incident_location:p}});
  else if(unit)onChange({...d,virtual_units:d.virtual_units.map(u=>u.id===selected?{...u,position:p}:u)});
  else if(object)onChange({...d,initial_objects:d.initial_objects.map(o=>o.id===selected?{...o,geometry:{type:'Point',coordinates:p}}:o)});
 }
 function geometry(g:Geometry){
  onChange({...d,initial_objects:d.initial_objects.map(o=>o.id===selected?{...o,geometry:g}:o)});
 }
 function finish(){
  if(!canEdit||vertices.length<3||!object)return;
  geometry({type:'Polygon',coordinates:[[...vertices,vertices[0]]]});setDrawing(false);setPlacing(false);setVertices([]);
 }
 function addObject(){
  const id=crypto.randomUUID();onChange({...d,initial_objects:[...d.initial_objects,{id,kind,label:t(kind),description:'',geometry:
   kind==='PERIMETER'?null:d.world.center?{type:'Point',coordinates:d.world.center}:null}]});choose(id);
 }
 const meta=(key:keyof Definition['metadata'],val:unknown)=>onChange({...d,metadata:{...d.metadata,[key]:val}});
 const ring=object?.geometry?.type==='Polygon'?object.geometry.coordinates[0]:object?.geometry?.type==='LineString'?object.geometry.coordinates:null;
 return <section className="template-editor">
  <div className="actions template-mode"><strong>{t(previewOnly?'preview':'edit')}</strong>
   {!value.builtin&&!value.archived&&value.state==='DRAFT'&&<button type="button" disabled={disabled} aria-pressed={preview}
    onClick={()=>{setPreview(!preview);setPlacing(false);setDrawing(false);setVertices([]);}}>{t(preview?'edit':'preview')}</button>}
   <p>{t('reviewDefaults')}</p></div>
  {placementMissing(d)&&<p className="admin-notice" role="status">{t('missing')}</p>}
  <div className="template-editor-grid">
   <details className="admin-card template-configuration" open={configurationOpen} onToggle={e=>setConfigurationOpen(e.currentTarget.open)}><summary>{t('configuration')}</summary>
    <fieldset disabled={!canEdit}>
     <label>{t('title')}<input maxLength={200} value={d.metadata.title} onChange={e=>meta('title',e.target.value)}/></label>
     <label>{t('description')}<textarea maxLength={2000} value={d.metadata.description} onChange={e=>meta('description',e.target.value)}/></label>
     <label>{t('category')}<select value={d.metadata.category} onChange={e=>meta('category',e.target.value)}>{templateCategories.map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
     <label>{t('difficulty')}<select value={d.metadata.difficulty} onChange={e=>meta('difficulty',e.target.value)}>{['BEGINNER','INTERMEDIATE','ADVANCED'].map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
     <label>{t('objectives')}<textarea maxLength={10000} value={d.metadata.objectives.join('\n')} onChange={e=>meta('objectives',e.target.value?e.target.value.split('\n'):[])}/></label>
     <label>{t('duration')}<input type="number" min={5} max={480} value={d.metadata.duration_minutes} onChange={e=>meta('duration_minutes',Number(e.target.value))}/></label>
     <label>{t('situation')}<textarea maxLength={4000} value={d.metadata.initial_situation} onChange={e=>meta('initial_situation',e.target.value)}/></label>
     {(['commander','instructor'] as const).map(k=><label key={k}>{t(k)}<textarea maxLength={4000} value={d.briefings[k]} onChange={e=>onChange({...d,briefings:{...d.briefings,[k]:e.target.value}})}/></label>)}
     <label>{t('radius')}<input type="number" min={10} max={5000} value={d.world.radius_m} onChange={e=>onChange({...d,world:{...d.world,radius_m:Number(e.target.value)}})}/></label>
     <label>{t('clock')}<select value={d.simulation_defaults.clock_scale} onChange={e=>onChange({...d,simulation_defaults:{...d.simulation_defaults,clock_scale:Number(e.target.value) as 1|5|10}})}>{[1,5,10].map(n=><option key={n} value={n}>{n}×</option>)}</select></label>
     <label>{t('profile')}<select value={d.simulation_defaults.response_profile} onChange={e=>onChange({...d,simulation_defaults:{...d.simulation_defaults,response_profile:e.target.value as Definition['simulation_defaults']['response_profile']}})}>{templateProfiles.map(p=><option key={p} value={p}>{t(p)}</option>)}</select></label>
    </fieldset><p>{t('defaultsHelp')}</p>
   </details>
   <div className="template-map-pane">
    <div className="actions"><button type="button" onClick={()=>choose('center')}>{t('center')}</button><button type="button" onClick={()=>choose('incident')}>{t('incident')}</button>
     <button type="button" disabled={!canEdit||object?.kind==='PERIMETER'||(!!object?.geometry&&object.geometry.type!=='Point')} aria-pressed={placing&&!drawing}
      onClick={()=>{setPlacing(!placing);setDrawing(false);setVertices([]);}}>{t('place')}</button>
     {(drawing||placing)&&<button type="button" onClick={()=>{setDrawing(false);setPlacing(false);setVertices([]);}}>{t('cancel')}</button>}
    </div>
    <p role="status">{t('placeHelp')}</p>
    {drawing&&<div className="actions"><CoordinateEditor locale={locale} value={null} disabled={!canEdit||vertices.length>=32} onApply={p=>{if(vertices.length<32)setVertices(v=>[...v,p]);}}/><span>{vertices.length}/32</span><button type="button" disabled={vertices.length<3} onClick={finish}>{t('finish')}</button><button type="button" disabled={!vertices.length} onClick={()=>setVertices(v=>v.slice(0,-1))}>{t('undo')}</button></div>}
    <TemplateMap locale={locale} definition={d} selected={selected} editable={canEdit} placing={placing} vertices={vertices} onSelect={choose} onMove={move}
     onPoint={p=>{if(drawing){if(vertices.length<32)setVertices(v=>[...v,p]);}else{move(p);setPlacing(false);}}}/>
   </div>
   <details className="admin-card template-inspector" open={inspectorOpen} onToggle={e=>setInspectorOpen(e.currentTarget.open)}><summary>{t('inspector')}</summary>
    {!canEdit&&<p>{t('readonly')}</p>}
    <strong>{selected==='center'?t('center'):selected==='incident'?t('incident'):object?.label??(unit?'SIM-'+(d.virtual_units.indexOf(unit)+1):t('select'))}</strong>
    {(selected==='center'||selected==='incident'||unit||object?.kind!=='PERIMETER'&&(!object?.geometry||object.geometry.type==='Point'))&&
     <CoordinateEditor key={selected} locale={locale} value={point??null} disabled={!canEdit} onApply={move}/>}
    {object&&<fieldset disabled={!canEdit}>
     <p>{t(object.kind)}</p><label>{t('label')}<input maxLength={200} value={object.label} onChange={e=>onChange({...d,initial_objects:d.initial_objects.map(o=>o.id===selected?{...o,label:e.target.value}:o)})}/></label>
     <label>{t('description')}<textarea maxLength={2000} value={object.description} onChange={e=>onChange({...d,initial_objects:d.initial_objects.map(o=>o.id===selected?{...o,description:e.target.value}:o)})}/></label>
     {['HAZARD','PERIMETER'].includes(object.kind)&&<button type="button" onClick={()=>{setDrawing(true);setPlacing(true);setVertices([]);}}>{t('draw')}</button>}
     {ring&&ring.slice(0,object.geometry?.type==='Polygon'?-1:undefined).map((p,i)=><div key={i}><strong>{t('vertex')} {i+1}</strong><CoordinateEditor locale={locale} value={p} disabled={!canEdit} onApply={value=>{
      const points=ring.map((q,n)=>n===i?value:q);
      if(object.geometry?.type==='Polygon'){points[points.length-1]=points[0];geometry({type:'Polygon',coordinates:[points]});}
      else geometry({type:'LineString',coordinates:points});
     }}/></div>)}
    </fieldset>}
    {unit&&<label>{t('heading')}<input disabled={!canEdit} type="number" min={0} max={359.99} step="any" value={unit.heading}
     onChange={e=>onChange({...d,virtual_units:d.virtual_units.map(u=>u.id===selected?{...u,heading:Number(e.target.value)}:u)})}/></label>}
    {(object||unit)&&<button type="button" disabled={!canEdit} onClick={()=>{onChange({...d,initial_objects:d.initial_objects.filter(o=>o.id!==selected),virtual_units:d.virtual_units.filter(u=>u.id!==selected)});choose('center');}}>{t('remove')}</button>}
    <h3>{t('objects')} ({d.initial_objects.length}/40)</h3>
    <ul className="template-items">{d.initial_objects.map(o=><li key={o.id}><button type="button" aria-pressed={selected===o.id} onClick={()=>choose(o.id)}>{o.label} · {t(o.kind)}</button></li>)}</ul>
    <label>{t('kind')}<select disabled={!canEdit} value={kind} onChange={e=>setKind(e.target.value as MapKind)}>{kinds.map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
    <button type="button" disabled={!canEdit||d.initial_objects.length>=40} onClick={addObject}>{t('addObject')}</button>
    <h3>{t('units')} ({d.virtual_units.length}/30)</h3><p>{t('unitHelp')}</p>
    <ul className="template-items">{d.virtual_units.map((u,i)=><li key={u.id}><button type="button" aria-pressed={selected===u.id} onClick={()=>choose(u.id)}>SIM-{i+1}</button></li>)}</ul>
    <button type="button" disabled={!canEdit||d.virtual_units.length>=30} onClick={()=>{
     const id=crypto.randomUUID();onChange({...d,virtual_units:[...d.virtual_units,{id,kind:'OTHER',heading:0,position:d.world.center}]});choose(id);
    }}>{t('addUnit')}</button>
   </details>
  </div>
 </section>;
}
export function CoordinateEditor({locale,value,disabled,onApply}:{locale:Locale;value:Position|null;disabled:boolean;onApply:(v:Position)=>void}){
 const t=templateText(locale),[x,setX]=useState(value?.[0].toString()??''),[y,setY]=useState(value?.[1].toString()??'');
 useEffect(()=>{setX(value?.[0].toString()??'');setY(value?.[1].toString()??'');},[value?.[0],value?.[1]]);
 const valid=x.trim()!==''&&y.trim()!==''&&Number.isFinite(Number(x))&&Number.isFinite(Number(y))&&Math.abs(Number(x))<=180&&Math.abs(Number(y))<=90;
 return <fieldset disabled={disabled} className="template-coordinates"><legend>{t('coordinates')}</legend>
  <label>{t('longitude')}<input type="number" step="any" min={-180} max={180} value={x} onChange={e=>setX(e.target.value)}/></label>
  <label>{t('latitude')}<input type="number" step="any" min={-90} max={90} value={y} onChange={e=>setY(e.target.value)}/></label>
  <button type="button" disabled={!valid} onClick={()=>onApply([Number(x),Number(y)])}>{t('confirm')}</button>
 </fieldset>;
}
