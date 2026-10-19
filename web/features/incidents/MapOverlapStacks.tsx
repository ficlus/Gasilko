'use client';
import {useEffect,useRef,useState} from 'react';
import type {Map as LibreMap} from 'maplibre-gl';
import type {Cop} from '../../lib/incidents/cop';
import type {ContextHydrant} from '../../lib/hydrants/viewport';
import type {Locale} from '../../lib/i18n';
import {recipientKey,type RtsRecipient} from '../../lib/operational/rts';
import {commandMapText} from '../../lib/operational/commandMapMessages';
import {incidentText} from '../../lib/incidents/messages';
import {operationalText} from '../../lib/operational/messages';
import {recipientFeature,type RecipientPositionLayer} from './RtsMapInteraction';
import {useRtsSession} from './rtsSession';
import {useWorkspace,type SelectedEntity} from './workspace';
type Item={key:string;label:string;entity:SelectedEntity;unit?:RtsRecipient;x:number;y:number};
type Stack={key:string;x:number;y:number;items:Item[]};
type Props={map:LibreMap;locale:Locale;cop:Cop;hydrants:ContextHydrant[];layers:readonly RecipientPositionLayer[];busy:boolean};
/** Authorized rendered points only. Original features remain available to box/lasso. */
export function MapOverlapStacks(props:Props){
 const {map,locale}=props,rts=useRtsSession(),workspace=useWorkspace(),t=commandMapText(locale);
 const [stacks,setStacks]=useState<Stack[]>([]),[open,setOpen]=useState<string|null>(null),[hover,setHover]=useState<string|null>(null),[fan,setFan]=useState(false);
 const panel=useRef<HTMLDivElement>(null),root=useRef<HTMLDivElement>(null),latest=useRef(props);latest.current=props;
 const disabled=props.busy||rts.locked||rts.blocked||rts.externalEditing||rts.copEditing||rts.open||rts.mode!=='NORMAL';
 useEffect(()=>{
  if(disabled){setStacks([]);setOpen(null);return;}
  let frame=0,last='',disposed=false;
  function collect(){
   frame=0;if(disposed||!map.getStyle())return;
   const {cop,hydrants,layers,locale}=latest.current,it=incidentText(locale),ot=operationalText(locale);
   const ids=[...layers.map(l=>l.id),'cop-hydrants-point','context-hydrants-point','cop-markers-point','cop-zones-point'].filter(id=>map.getLayer(id));
   const items=new globalThis.Map<string,Item>();
   for(const f of ids.length?map.queryRenderedFeatures([[0,0],[map.getCanvas().clientWidth,map.getCanvas().clientHeight]],{layers:ids}):[]){
    if(f.geometry.type!=='Point')continue;
    const unit=recipientFeature(f,layers),id=f.properties?.id;
    const object=['cop-markers','cop-zones'].includes(f.source)?cop.objects.find(o=>o.id===id):null;
    const hydrant=['cop-hydrants','context-hydrants'].includes(f.source)?cop.links.find(l=>l.hydrant?.id===id)?.hydrant??hydrants.find(h=>h.id===id):null;
    const entity:SelectedEntity|null=unit?{kind:'INCIDENT_UNIT',id:unit.id}:object?{kind:'MAP_OBJECT',id:object.id}:hydrant?{kind:'HYDRANT',id:hydrant.id}:null;
    if(!entity)continue;
    const point=map.project([f.geometry.coordinates[0],f.geometry.coordinates[1]]);
    if(point.x<0||point.y<0||point.x>map.getCanvas().clientWidth||point.y>map.getCanvas().clientHeight)continue;
    const key=entity.kind+':'+entity.id;
    items.set(key,{key,entity,unit:unit??undefined,label:unit?unit.name+' · '+ot(unit.status??''):object?it(object.kind)+' · '+object.label:hydrant!.code??it('copPendingCode'),x:point.x,y:point.y});
   }
   const groups:Stack[]=[],grid=new globalThis.Map<string,Stack[]>();
   for(const item of [...items.values()].sort((a,b)=>a.key.localeCompare(b.key))){
    const x=Math.floor(item.x/22),y=Math.floor(item.y/22);let group:Stack|undefined;
    for(let dx=-1;dx<=1&&!group;dx++)for(let dy=-1;dy<=1&&!group;dy++)
     group=grid.get((x+dx)+':'+(y+dy))?.find(g=>Math.hypot(g.x-item.x,g.y-item.y)<=22);
    if(group)group.items.push(item);
    else{group={key:item.key,x:item.x,y:item.y,items:[item]};groups.push(group);const cell=x+':'+y;grid.set(cell,[...(grid.get(cell)??[]),group]);}
   }
   const next=groups.filter(g=>g.items.length>1);
   const signature=JSON.stringify(next.map(g=>[g.key,Math.round(g.x),Math.round(g.y),g.items.map(i=>[i.key,i.label,i.unit?.eligibility])]));
   if(signature!==last){last=signature;setStacks(next);}
  }
  const schedule=()=>{if(!frame)frame=requestAnimationFrame(collect);};
  schedule();map.on('move',schedule);map.on('resize',schedule);map.on('sourcedata',schedule);
  return()=>{disposed=true;cancelAnimationFrame(frame);map.off('move',schedule);map.off('resize',schedule);map.off('sourcedata',schedule);};
 },[map,props.cop,props.hydrants,props.layers,locale,disabled]);
 const stack=stacks.find(g=>g.key===open),preview=stacks.find(g=>g.key===hover);
 useEffect(()=>{if(open&&!stack)setOpen(null);},[open,!!stack]);
 useEffect(()=>{
  setFan(false);if(!open)return;
  const frame=requestAnimationFrame(()=>panel.current?.focus());
  const outside=(e:PointerEvent)=>{if(!root.current?.contains(e.target as Node))setOpen(null);};
  const escape=(e:KeyboardEvent)=>{if(e.key==='Escape'){e.preventDefault();e.stopPropagation();setOpen(null);map.getCanvas().focus();}};
  document.addEventListener('pointerdown',outside,true);document.addEventListener('keydown',escape,true);
  return()=>{cancelAnimationFrame(frame);document.removeEventListener('pointerdown',outside,true);document.removeEventListener('keydown',escape,true);};
 },[open,map]);
 if(disabled)return null;
 function choose(item:Item,toggle=false){
  if(item.unit)rts.pick(item.unit,[item.unit],{list:'map-overlap',toggle});
  workspace?.select(item.entity);
 }
 const width=map.getCanvas().clientWidth,height=map.getCanvas().clientHeight;
 const left=stack?Math.max(4,Math.min(stack.x+22,width-300)):4,top=stack?Math.max(4,Math.min(stack.y+22,height-240)):4;
 return <div ref={root} className="map-overlap-host">
  {stacks.map(group=><button key={group.key} type="button" className="map-overlap-badge"
   style={{left:group.x,top:group.y}} aria-label={t('stack')+' · '+group.items.length} aria-expanded={open===group.key}
   data-selected={group.items.some(i=>i.unit&&rts.recipients.some(r=>recipientKey(r)===recipientKey(i.unit!)))}
   onPointerEnter={()=>setHover(group.key)} onPointerLeave={()=>setHover(null)}
   onClick={e=>{e.stopPropagation();setOpen(open===group.key?null:group.key);setHover(null);}}>
   {group.items.some(i=>!i.unit)?'◈':'●'} {group.items.length}
  </button>)}
  {preview&&!stack&&<div className="map-overlap-preview" style={{left:Math.max(4,Math.min(preview.x+24,width-250)),top:Math.max(4,Math.min(preview.y+24,height-160))}}>
   {preview.items.slice(0,8).map(item=><div key={item.key}>{item.label}</div>)}{preview.items.length>8&&<small>+{preview.items.length-8}</small>}
  </div>}
  {stack&&<div ref={panel} className="map-overlap-chooser" role="dialog" aria-modal="false" aria-label={t('stack')} tabIndex={-1}
   style={{left,top,maxHeight:Math.max(100,height-top-8)}} onClick={e=>e.stopPropagation()}>
   <header><strong>{t('stack')} · {stack.items.length}</strong><button onClick={()=>setOpen(null)}>{t('close')}</button></header>
   <div className="actions"><button disabled={!stack.items.some(i=>i.unit&&i.unit.eligibility!=='UNAVAILABLE')} onClick={()=>rts.selectMany(stack.items.flatMap(i=>i.unit&&i.unit.eligibility!=='UNAVAILABLE'?[i.unit]:[]),true)}>{t('selectAll')}</button>
   <button onClick={rts.clear}>{t('clearSelection')}</button><button aria-pressed={fan} onClick={()=>setFan(v=>!v)}>{t('fan')}</button></div>
   <small>{t('stackHelp')}</small>
   {stack.items.map(item=><button key={item.key} type="button" className="map-overlap-item"
    aria-pressed={item.unit?rts.recipients.some(r=>recipientKey(r)===recipientKey(item.unit!)):undefined}
    onClick={e=>choose(item,e.ctrlKey||e.metaKey||e.shiftKey)}>{item.label}</button>)}
  </div>}
  {stack&&fan&&stack.items.slice(0,16).map((item,index)=>{
   const angle=index*2*Math.PI/Math.min(16,stack.items.length),x=Math.max(24,Math.min(width-24,stack.x+90*Math.cos(angle))),y=Math.max(24,Math.min(height-24,stack.y+90*Math.sin(angle)));
   return <div key={item.key}><svg className="map-overlap-leaders" aria-hidden="true"><line x1={item.x} y1={item.y} x2={x} y2={y}/></svg>
    <button type="button" className="map-overlap-fan" style={{left:x,top:y}} title={item.label} aria-label={item.label} onClick={e=>{e.stopPropagation();choose(item,e.ctrlKey||e.metaKey||e.shiftKey);}}>{index+1}</button></div>;
  })}
 </div>;
}
