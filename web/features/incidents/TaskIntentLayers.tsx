'use client';
import {useEffect} from 'react';
import type {Map,GeoJSONSource,ExpressionSpecification} from 'maplibre-gl';
import type {Locale} from '../../lib/i18n';
import type {Geometry} from '../../lib/incidents/cop';
import {taskText} from '../../lib/operational/taskMessages';
import {rtsText} from '../../lib/operational/rtsMessages';
import {useRts} from './rtsSession';

const sources=['rts-task-target','rts-draft-target'];
const data=(id:string,geometry:Geometry|null,label:string,historical=false)=>({type:'FeatureCollection' as const,features:geometry?[{
 type:'Feature' as const,id,geometry,properties:{id,label,historical}
}]:[]});
/** Snapshots and draft intent only. No origin coordinates, trajectories or routes. */
export function TaskIntentLayers({map,locale}:{map:Map;locale:Locale}){
 const rts=useRts(),t=rtsText(locale),tt=taskText(locale);
 useEffect(()=>{
  const before=map.getLayer('cop-selection-line')?'cop-selection-line':undefined;
  for(const source of sources){
   map.addSource(source,{type:'geojson',data:data('',null,'')});
   const color:string|ExpressionSpecification=source==='rts-draft-target'?'#802ea5':['case',['get','historical'],'#59656b','#075f93'];
   map.addLayer({id:source+'-fill',type:'fill',source,filter:['==',['geometry-type'],'Polygon'],paint:{'fill-color':color,'fill-opacity':0.12}},before);
   map.addLayer({id:source+'-line',type:'line',source,filter:['!=',['geometry-type'],'Point'],paint:{'line-color':color,'line-width':4,'line-dasharray':[2,2]}},before);
   map.addLayer({id:source+'-point',type:'circle',source,filter:['==',['geometry-type'],'Point'],paint:{'circle-radius':19,'circle-color':'#fff','circle-opacity':0.12,'circle-stroke-color':color,'circle-stroke-width':4}},before);
   map.addLayer({id:source+'-label',type:'symbol',source,layout:{'text-field':['get','label'],'text-size':12,'text-offset':[0,-2]},paint:{'text-color':'#263238','text-halo-color':'#fff','text-halo-width':2}},before);
  }
  return()=>{if(!map.getStyle())return;for(const source of [...sources].reverse()){
   for(const suffix of ['label','point','line','fill'])if(map.getLayer(source+'-'+suffix))map.removeLayer(source+'-'+suffix);
   if(map.getSource(source))map.removeSource(source);
  }};
 },[map]);
 const preview=rts?.open?rts.preview:null,intent=rts?.intent;
 useEffect(()=>{
  (map.getSource('rts-draft-target') as GeoJSONSource|undefined)?.setData(data('draft-task-target',preview?.geometry??null,t('draftTarget')));
 },[map,preview,locale]);
 useEffect(()=>{
  (map.getSource('rts-task-target') as GeoJSONSource|undefined)?.setData(data(intent?.id??'',intent?.target_geometry_snapshot??null,
   intent?t(intent.status==='OPEN'?'issuedTarget':'historyTarget')+' · '+intent.label:'',intent?.status!=='OPEN'));
 },[map,intent,locale]);
 if(!preview?.geometry&&!intent?.target_geometry_snapshot)return null;
 return <aside className="rts-intent-legend" aria-live="polite">
  {preview?.geometry&&<p><strong>{t('draftTarget')}</strong> · {preview.label}
   {preview.geometry.type==='Point'&&<span> · {preview.geometry.coordinates.join(', ')}</span>}</p>}
  {intent?.target_geometry_snapshot&&<p><strong>{t(intent.status==='OPEN'?'issuedTarget':'historyTarget')}</strong> · {intent.label}
   <span className="task-priority" data-priority={intent.priority}>{tt(intent.priority)}</span> · {tt(intent.status)}{intent.outcome?' · '+tt(intent.outcome):''}</p>}
 </aside>;
}
