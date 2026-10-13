'use client';
import {useEffect,useLayoutEffect,useRef,useState,useId} from 'react';
import type {Map as LibreMap} from 'maplibre-gl';
import type {Locale} from '../../lib/i18n';
import type {Cop,Position} from '../../lib/incidents/cop';
import type {ContextHydrant} from '../../lib/hydrants/viewport';
import {resolveTarget,validPosition} from '../../lib/operational/target';
import {actionLabel} from '../../lib/operational/tasks';
import {recipientKey} from '../../lib/operational/rts';
import {contextCommands,type MapCommandContext} from '../../lib/operational/contextCommands';
import {contextText} from '../../lib/operational/contextMessages';
import {operationalText} from '../../lib/operational/messages';
import {recipientFeature,type RecipientPositionLayer} from './RtsMapInteraction';
import {useRtsSession} from './rtsSession';
import {useWorkspace} from './workspace';

type Props={busy:boolean;map:LibreMap;locale:Locale;cop:Cop;hydrants:ContextHydrant[];layers:readonly RecipientPositionLayer[]};
type Menu={point:Position;choices:MapCommandContext[];selected:string|null};
const entityLayers:Record<string,string[]>={
 'cop-hydrants':['cop-hydrants-point','cop-hydrants-label'],
 'context-hydrants':['context-hydrants-point','context-hydrants-label'],
 'cop-markers':['cop-markers-point','cop-markers-label'],
 'cop-zones':['cop-zones-point','cop-zones-line','cop-zones-fill','cop-zones-label'],
 'cop-sectors':['cop-sectors-line','cop-sectors-fill','cop-sectors-label']
};
/** Visible registered layers + authorized DTOs only; labels/routes cannot impersonate units. */
function hitContexts({map,cop,hydrants,layers}:Props,point:Position,coordinate:Position,t:ReturnType<typeof contextText>):MapCommandContext[]{
 const units=new globalThis.Map<string,MapCommandContext>();
 const unitIds=layers.filter(l=>map.getLayer(l.id)).map(l=>l.id);
 for(const f of unitIds.length?map.queryRenderedFeatures(point,{layers:unitIds}):[]){
  const recipient=recipientFeature(f,layers);if(!recipient||recipient.type!=='INCIDENT_UNIT')continue;
  units.set(recipientKey(recipient),{kind:'UNIT',key:recipientKey(recipient),label:recipient.name,entity:{kind:'INCIDENT_UNIT',id:recipient.id},recipient});
 }
 if(units.size)return [...units.values()];
 const ids=Object.values(entityLayers).flat().filter(id=>map.getLayer(id));
 const entities=new globalThis.Map<string,MapCommandContext>();
 for(const f of ids.length?map.queryRenderedFeatures(point,{layers:ids}):[]){
  const id=f.properties?.id;
  if(typeof id!=='string'||!entityLayers[f.source]?.includes(f.layer.id))continue;
  const hydrant=['cop-hydrants','context-hydrants'].includes(f.source)?cop.links.find(l=>l.hydrant?.id===id)?.hydrant??hydrants.find(h=>h.id===id):null;
  const sector=f.source==='cop-sectors'?cop.sectors.find(s=>s.id===id):null;
  const object=['cop-markers','cop-zones'].includes(f.source)?cop.objects.find(o=>o.id===id):null;
  const target=hydrant?{kind:'HYDRANT' as const,entityId:id}:sector?{kind:'INCIDENT_SECTOR' as const,entityId:id,incidentId:cop.incident.id}:object?{kind:'INCIDENT_MAP_OBJECT' as const,entityId:id,incidentId:cop.incident.id}:null;
  if(!target)continue;
  const label=hydrant?hydrant.code??id:sector?sector.code+' · '+sector.name:object!.label;
  const geometry=resolveTarget(target,{cop,hydrants}),key=target.kind+':'+id;
  entities.set(key,{kind:'ENTITY',key,label,entity:{kind:target.kind==='INCIDENT_MAP_OBJECT'?'MAP_OBJECT':target.kind,id},preview:{target,geometry,label:label+' · '+id}});
 }
 if(entities.size)return [...entities.values()];
 return [{kind:'COORDINATE',key:'coordinate',label:t('location'),preview:{target:{kind:'COORDINATE',coordinate:[...coordinate]},geometry:{type:'Point',coordinates:[...coordinate]},label:coordinate.join(', ')}}];
}

/** Menu presentation only. Operational draft, selection and sending stay in RTS/IncidentTasks. */
export function RtsContextMenu(props:Props){
 const {map,locale}=props,rts=useRtsSession(),workspace=useWorkspace(),t=contextText(locale),ot=operationalText(locale),id=useId();
 const [menu,setMenu]=useState<Menu|null>(null),[placement,setPlacement]=useState({left:8,top:8,maxHeight:300});
 const panel=useRef<HTMLDivElement>(null),entry=useRef<HTMLButtonElement>(null),returnFocus=useRef<HTMLElement|null>(null),swallowClick=useRef(false);
 const latest=useRef({props,rts,menu});latest.current={props,rts,menu};
 const blocked=props.busy||rts.blocked||rts.locked||rts.copEditing||rts.externalEditing||rts.mode!=='NORMAL'||rts.open;
 function close(focus=true){setMenu(null);if(focus)(returnFocus.current?.isConnected?returnFocus.current:map.getCanvas())?.focus({preventScroll:true});}
 const closeRef=useRef(close);closeRef.current=close;
 function openAt(point:Position,coordinate:Position){
  const state=latest.current.rts;
  if(latest.current.props.busy||state.blocked||state.locked||state.copEditing||state.externalEditing||state.mode!=='NORMAL'||state.open||document.querySelector('dialog[open]')||!validPosition(coordinate))return;
  if(!latest.current.menu)returnFocus.current=document.activeElement instanceof HTMLElement&&document.activeElement!==document.body?document.activeElement:map.getCanvas();
  const choices=hitContexts(latest.current.props,point,coordinate,contextText(latest.current.props.locale));
  setMenu({point:[...point],choices,selected:choices.length===1?choices[0].key:null});
 }
 const openRef=useRef(openAt);openRef.current=openAt;
 useEffect(()=>{if(blocked)setMenu(null);},[blocked]);
 useEffect(()=>{
  const canvas=map.getCanvas();
  let timer:ReturnType<typeof setTimeout>|undefined,held:{pointer:number;point:Position;coordinate:Position}|null=null,suppressUntil=0;
  const touches=new Set<number>();
  const pixel=(e:{clientX:number;clientY:number}):Position=>{const rect=canvas.getBoundingClientRect();return [e.clientX-rect.left,e.clientY-rect.top];};
  const cancel=()=>{clearTimeout(timer);timer=undefined;held=null;};
  const context=(event:MouseEvent)=>{
   const state=latest.current.rts;
   if(latest.current.props.busy||state.blocked||state.locked||state.copEditing||state.externalEditing||state.mode!=='NORMAL'||state.open)return;
   event.preventDefault();event.stopPropagation();cancel();
   if(Date.now()<suppressUntil)return;
   const p=pixel(event),g=map.unproject(p);openRef.current(p,[g.lng,g.lat]);
  };
  const down=(event:PointerEvent)=>{
   if(event.pointerType!=='touch')return;touches.add(event.pointerId);
   if(touches.size!==1){cancel();return;}
   const state=latest.current.rts;
   if(latest.current.props.busy||state.blocked||state.locked||state.copEditing||state.externalEditing||state.mode!=='NORMAL'||state.open)return;
   const point=pixel(event),g=map.unproject(point);held={pointer:event.pointerId,point,coordinate:[g.lng,g.lat]};
   timer=setTimeout(()=>{const value=held;cancel();if(value&&touches.size===1){suppressUntil=Date.now()+1200;openRef.current(value.point,value.coordinate);}},600);
  };
  const move=(event:PointerEvent)=>{if(held&&held.pointer===event.pointerId){const p=pixel(event);if(Math.hypot(p[0]-held.point[0],p[1]-held.point[1])>8)cancel();}};
  const up=(event:PointerEvent)=>{touches.delete(event.pointerId);cancel();};
  const click=(event:MouseEvent)=>{if(swallowClick.current||Date.now()<suppressUntil||latest.current.menu){swallowClick.current=false;event.preventDefault();event.stopImmediatePropagation();}};
  canvas.addEventListener('contextmenu',context,true);canvas.addEventListener('pointerdown',down,true);canvas.addEventListener('pointermove',move,true);
  canvas.addEventListener('pointerup',up,true);canvas.addEventListener('pointercancel',up,true);canvas.addEventListener('click',click,true);
  map.on('movestart',cancel);window.addEventListener('blur',cancel);
  return()=>{cancel();canvas.removeEventListener('contextmenu',context,true);canvas.removeEventListener('pointerdown',down,true);canvas.removeEventListener('pointermove',move,true);
   canvas.removeEventListener('pointerup',up,true);canvas.removeEventListener('pointercancel',up,true);canvas.removeEventListener('click',click,true);map.off('movestart',cancel);window.removeEventListener('blur',cancel);};
 },[map]);
 useEffect(()=>{
  if(!menu)return;
  const frame=requestAnimationFrame(()=>panel.current?.focus({preventScroll:true}));
  const outside=(event:PointerEvent)=>{if(!panel.current?.contains(event.target as Node)&&!entry.current?.contains(event.target as Node)){swallowClick.current=event.target===map.getCanvas();closeRef.current(false);}};
  const escape=(event:KeyboardEvent)=>{if(event.key==='Escape'&&!document.querySelector('dialog[open]')){event.preventDefault();event.stopPropagation();closeRef.current();}};
  document.addEventListener('pointerdown',outside,true);document.addEventListener('keydown',escape,true);
  return()=>{cancelAnimationFrame(frame);document.removeEventListener('pointerdown',outside,true);document.removeEventListener('keydown',escape,true);};
 },[map,!!menu,menu?.selected]);
 // Resize/reposition the surface only. Captured target coordinates never depend on camera/layout.
 useLayoutEffect(()=>{
  if(!menu||!panel.current)return;
  const measure=()=>{
   const canvas=map.getCanvas().getBoundingClientRect(),size=panel.current!.getBoundingClientRect();
   const heading=map.getContainer().closest('.command-workspace')?.querySelector('.workspace-heading')?.getBoundingClientRect();
   const topVisible=Math.max(8,-canvas.top+8,(heading?.bottom??0)-canvas.top+8),bottomVisible=Math.min(canvas.height,window.innerHeight-canvas.top)-8;
   const maxHeight=Math.max(44,bottomVisible-topVisible);
   const next={left:Math.max(8,Math.min(menu.point[0],canvas.width-size.width-8)),top:Math.max(topVisible,Math.min(menu.point[1],bottomVisible-Math.min(size.height,maxHeight))),maxHeight};
   setPlacement(old=>old.left===next.left&&old.top===next.top&&old.maxHeight===next.maxHeight?old:next);
  };
  measure();const observer=new ResizeObserver(measure);observer.observe(map.getContainer());observer.observe(panel.current);
  window.addEventListener('scroll',measure,{passive:true});window.addEventListener('resize',measure);
  return()=>{observer.disconnect();window.removeEventListener('scroll',measure);window.removeEventListener('resize',measure);};
 },[map,menu]);
 const context=menu?.choices.find(c=>c.key===menu.selected);
 const included=context?.kind==='UNIT'&&rts.recipients.some(r=>recipientKey(r)===recipientKey(context.recipient));
 const recipients=context?.kind==='UNIT'&&!included?[context.recipient]:rts.recipients;
 const commands=context?contextCommands(context,rts.catalog?.rows??[],recipients,rts.commandTypes):[];
 const showDetails=()=>{if(context&&context.kind!=='COORDINATE'){workspace?.select(context.entity);workspace?.showDetails();close(false);}};
 return <>
  <button type="button" className="rts-context-entry" ref={entry} aria-haspopup="dialog" aria-expanded={!!menu} aria-controls={menu?id:undefined}
   disabled={blocked} title={blocked?t('busy'):t('center')} onClick={()=>{if(menu){close();return;}const canvas=map.getCanvas(),point:Position=[canvas.clientWidth/2,canvas.clientHeight/2],g=map.unproject(point);openAt(point,[g.lng,g.lat]);}}>{t('actions')} ({rts.recipients.length})</button>
  {menu&&<div ref={panel} id={id} className="rts-context-menu" role="dialog" aria-modal="false" aria-label={t('context')} tabIndex={-1}
   style={{left:placement.left,top:placement.top,maxHeight:placement.maxHeight}}
   onKeyDown={event=>{
    if(event.key==='Escape'){event.preventDefault();event.stopPropagation();close();return;}
    if(['ArrowDown','ArrowUp','Home','End'].includes(event.key)){
     const buttons=Array.from(event.currentTarget.querySelectorAll<HTMLButtonElement>('button:not(:disabled)'));
     if(!buttons.length)return;event.preventDefault();event.stopPropagation();
     const current=buttons.indexOf(document.activeElement as HTMLButtonElement),next=event.key==='Home'?0:event.key==='End'?buttons.length-1:(current+(event.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length;buttons[next]?.focus();
    }
   }} onBlur={event=>{if(event.relatedTarget&&!event.currentTarget.contains(event.relatedTarget as Node))close(false);}}>
   <div className="rts-context-heading"><strong>{context?.label??t('chooseObject')}</strong><button type="button" onClick={()=>close()}>{t('close')}</button></div>
   {!context?menu.choices.map(choice=><button key={choice.key} type="button" onClick={()=>setMenu({...menu,selected:choice.key})}>{choice.label} · {choice.key}</button>):<>
    {context.kind!=='COORDINATE'&&<button type="button" onClick={showDetails}>{t('details')} · {context.label}</button>}
    {context.kind==='UNIT'?<>
     {context.recipient.status&&<p>{ot(context.recipient.status)}</p>}
     <button type="button" disabled={!rts.enabled} onClick={()=>{rts.selectMany([context.recipient],false);close();}}>{t('select')}</button>
     <button type="button" disabled={!rts.enabled} onClick={()=>{if(included)rts.remove(recipientKey(context.recipient));else rts.selectMany([context.recipient],true);close();}}>{t(included?'remove':'add')}</button>
     <p>{t(included?'group':'single')} · {recipients.length}</p>
    </>:<p className="rts-context-target">{context.preview.label}</p>}
    {!rts.catalog&&<p role="status">{t(rts.catalogError?'unavailable':'checking')}</p>}
    {!rts.enabled&&<p>{t('noAuthority')}</p>}
    {!!rts.catalog&&!commands.length&&<p>{t('noActions')}</p>}
    {commands.map(command=><div key={command.action.id}>
     <button type="button" disabled={!!command.reason||!rts.enabled} onClick={()=>{
      if(blocked||command.reason)return;rts.openContext(command.action,command.preview,context.kind==='UNIT'&&!included?[context.recipient]:undefined);close(false);
     }}>{command.action.configuration.native_behavior==='MOVE_TO'&&context.kind!=='UNIT'?t('move')+' · ':''}{actionLabel(command.action.configuration,locale)}</button>
     {command.reason&&<small>{t(command.reason)}</small>}
    </div>)}
    <button type="button" disabled={!rts.enabled||!rts.commandTypes?.length||(context.kind==='UNIT'&&!included&&context.recipient.eligibility==='UNAVAILABLE')} onClick={()=>{
     rts.openContext(null,context.kind==='UNIT'?{target:{kind:'NONE'},geometry:null,label:''}:context.preview,context.kind==='UNIT'&&!included?[context.recipient]:undefined);close(false);
    }}>{t('browse')}</button>
    <small>{t('intent')}</small>
   </>}
  </div>}
 </>;
}
