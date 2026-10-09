'use client';
import {useEffect,useRef} from 'react';
import type {Map,MapGeoJSONFeature} from 'maplibre-gl';
import type {Locale} from '../../lib/i18n';
import {validPosition} from '../../lib/operational/target';
import {pixelInPolygon,recipientKey,type Pixel,type RtsRecipient} from '../../lib/operational/rts';
import {rtsText} from '../../lib/operational/rtsMessages';
import {useRts} from './rtsSession';

/** Explicit provenance; simulation adapters require the current training scope. */
export type RecipientPositionLayer={id:string;recipients:ReadonlyMap<string,RtsRecipient>}&(
 {origin:'ACTUAL_GPS'}|{origin:'SIMULATED';scenarioId:string;incidentId:string});
export type ActualRecipientLayer=RecipientPositionLayer&{origin:'ACTUAL_GPS'};
const noPositionLayers:readonly RecipientPositionLayer[]=[];
function recipientFeature(feature:MapGeoJSONFeature,layers:readonly RecipientPositionLayer[]):RtsRecipient|null{
 if(feature.geometry.type!=='Point'||!validPosition(feature.geometry.coordinates))return null;
 const type=feature.properties?.recipient_type,id=feature.properties?.recipient_id;
 if((type!=='INCIDENT_UNIT'&&type!=='INCIDENT_CREW_MEMBER')||typeof id!=='string')return null;
 const layer=layers.find(l=>l.id===feature.layer.id);
 if(!layer||feature.properties?.position_origin!==layer.origin)return null;
 if(layer.origin==='SIMULATED'&&(feature.properties?.scenario_id!==layer.scenarioId||feature.properties?.incident_id!==layer.incidentId))return null;
 return layer.recipients.get(type+':'+id)??null;
}
export function pickPositionRecipient(map:Map,point:{x:number;y:number},layers:readonly RecipientPositionLayer[]):RtsRecipient|null{
 const ids=layers.filter(l=>map.getLayer(l.id)).map(l=>l.id);if(!ids.length)return null;
 for(const feature of map.queryRenderedFeatures([point.x,point.y],{layers:ids})){const row=recipientFeature(feature,layers);if(row)return row;}
 return null;
}
type Gesture={pointer:number;points:Pixel[];origin:Pixel;handlers:{isEnabled:()=>boolean;disable:()=>unknown;enable:()=>unknown}[]};
export function RtsMapInteraction({map,locale,layers=noPositionLayers}:{map:Map;locale:Locale;layers?:readonly RecipientPositionLayer[]}){
 const rts=useRts(),latest=useRef({rts,layers});latest.current={rts,layers};
 const outline=useRef<SVGPathElement>(null),t=rtsText(locale);
 const mode=rts?.mode??'NORMAL',locked=!!rts?.locked||!!rts?.copEditing||!!rts?.externalEditing||!rts?.enabled;
 useEffect(()=>{
  const canvas=map.getCanvas();
  const previousCursor=canvas.style.cursor,previousTouchAction=canvas.style.touchAction;
  const selecting=mode==='SELECT_BOX'||mode==='SELECT_LASSO';
  if(locked||mode==='NORMAL')return;
  canvas.style.cursor=mode==='CHOOSE_TARGET'?'crosshair':'cell';
  if(!selecting)return()=>{canvas.style.cursor=previousCursor;};
  canvas.style.touchAction='pinch-zoom';
  let gesture:Gesture|null=null,frame=0;
  const pixel=(e:PointerEvent):Pixel=>{const box=canvas.getBoundingClientRect();return [Math.max(0,Math.min(box.width,e.clientX-box.left)),Math.max(0,Math.min(box.height,e.clientY-box.top))];};
  const paint=()=>{
   frame=0;if(!gesture)return;const points=gesture.points,last=points[points.length-1];
   const path=mode==='SELECT_BOX'?[gesture.origin,[last[0],gesture.origin[1]] as Pixel,last,[gesture.origin[0],last[1]] as Pixel]:points;
   outline.current?.setAttribute('d',path.map((p,i)=>(i?'L':'M')+p[0]+','+p[1]).join(' ')+' Z');
  };
  const restore=()=>{
   const old=gesture;gesture=null;cancelAnimationFrame(frame);frame=0;outline.current?.setAttribute('d','');
   old?.handlers.forEach(handler=>handler.enable());
   if(old&&canvas.hasPointerCapture(old.pointer))canvas.releasePointerCapture(old.pointer);
  };
  const down=(e:PointerEvent)=>{
   if(gesture){if(e.pointerId!==gesture.pointer)restore();return;}
   if(e.button!==0||!e.isPrimary||latest.current.rts?.locked)return;
   const origin=pixel(e);
   const handlers=[map.dragPan,map.dragRotate,map.boxZoom].filter(handler=>handler.isEnabled());
   handlers.forEach(handler=>handler.disable());
   gesture={pointer:e.pointerId,origin,points:[origin],handlers};
   e.preventDefault();e.stopPropagation();canvas.setPointerCapture(e.pointerId);paint();
  };
  const move=(e:PointerEvent)=>{
   if(!gesture||gesture.pointer!==e.pointerId)return;e.preventDefault();e.stopPropagation();
   const p=pixel(e),last=gesture.points[gesture.points.length-1];
   if(mode==='SELECT_BOX')gesture.points=[gesture.origin,p];
   else if(Math.hypot(p[0]-last[0],p[1]-last[1])>=4){if(gesture.points.length<256)gesture.points.push(p);else gesture.points[255]=p;}
   if(!frame)frame=requestAnimationFrame(paint);
  };
  const up=(e:PointerEvent)=>{
   if(!gesture||gesture.pointer!==e.pointerId)return;e.preventDefault();e.stopPropagation();
   const last=pixel(e),origin=gesture.origin;
   const polygon:Pixel[]=mode==='SELECT_BOX'?[origin,[last[0],origin[1]],last,[origin[0],last[1]]]:[...gesture.points,last];
   const state=latest.current.rts,adapters=latest.current.layers;restore();
   if(!state)return;
   const ids=adapters.filter(l=>map.getLayer(l.id)).map(l=>l.id);
   if(!ids.length){state.setMessage('noPositions');return;}
   if(polygon.length<3||Math.hypot(last[0]-origin[0],last[1]-origin[1])<2&&mode==='SELECT_BOX'){state.setMessage('noMatches');return;}
   const xs=polygon.map(p=>p[0]),ys=polygon.map(p=>p[1]);
   const box:[[number,number],[number,number]]=[[Math.min(...xs),Math.min(...ys)],[Math.max(...xs),Math.max(...ys)]];
   const features=map.queryRenderedFeatures(box,{layers:ids});
   if(features.length>5000){state.setMessage('selectionLimit');return;}
   const selected=new globalThis.Map<string,RtsRecipient>();
   for(const feature of features){
    const row=recipientFeature(feature,adapters);if(!row||feature.geometry.type!=='Point')continue;
    const p=map.project([feature.geometry.coordinates[0],feature.geometry.coordinates[1]]);
    if(pixelInPolygon([p.x,p.y],polygon))selected.set(recipientKey(row),row);
   }
   if(!selected.size)state.setMessage('noMatches');else state.setMessage('');
   state.selectMany([...selected.values()],state.merge);
  };
  const cancel=()=>restore();
  const stopTouch=(e:TouchEvent)=>{if(e.touches.length>1){restore();return;}if(gesture){e.preventDefault();e.stopPropagation();}};
  const stopDoubleClick=(e:MouseEvent)=>{e.preventDefault();e.stopPropagation();};
  canvas.addEventListener('pointerdown',down,true);canvas.addEventListener('pointermove',move,true);canvas.addEventListener('pointerup',up,true);
  canvas.addEventListener('pointercancel',cancel,true);canvas.addEventListener('lostpointercapture',cancel,true);
  canvas.addEventListener('touchstart',stopTouch,{capture:true,passive:false});canvas.addEventListener('touchmove',stopTouch,{capture:true,passive:false});
  canvas.addEventListener('dblclick',stopDoubleClick,true);
  return()=>{
   restore();canvas.style.cursor=previousCursor;canvas.style.touchAction=previousTouchAction;
   canvas.removeEventListener('pointerdown',down,true);canvas.removeEventListener('pointermove',move,true);canvas.removeEventListener('pointerup',up,true);
   canvas.removeEventListener('pointercancel',cancel,true);canvas.removeEventListener('lostpointercapture',cancel,true);
   canvas.removeEventListener('touchstart',stopTouch,true);canvas.removeEventListener('touchmove',stopTouch,true);canvas.removeEventListener('dblclick',stopDoubleClick,true);
  };
 },[map,mode,locked]);
 if(!rts||locked||mode==='NORMAL')return null;
 return <>
  <svg className="rts-gesture" aria-hidden="true"><path ref={outline}/></svg>
  <aside className="rts-map-mode" aria-live="polite"><strong>{t(mode==='CHOOSE_TARGET'?'targetMode':mode==='SELECT_BOX'?'box':'lasso')}</strong>
   <p>{t(mode==='CHOOSE_TARGET'?'targetResolvedLater':layers.length?'gestureHelp':'noPositions')}</p>
   <button type="button" onClick={rts.cancelMode}>{t('cancelMode')}</button>
  </aside>
 </>;
}
