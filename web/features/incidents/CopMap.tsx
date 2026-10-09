'use client';
import {useEffect,useRef} from 'react';
import {type Map,type GeoJSONSource} from 'maplibre-gl';
import {useRts} from './rtsSession';
import {useWorkspace} from './workspace';
import {SimulationMapLayer,useSimulationPositionLayer} from './SimulationMapLayer';
import {useSimulation} from './SimulationProvider';
import {pickPositionRecipient,RtsMapInteraction} from './RtsMapInteraction';
import {TaskIntentLayers} from './TaskIntentLayers';
import type {TaskTarget} from '../../lib/operational/tasks';
import {resolveTarget} from '../../lib/operational/target';
import type {Locale} from '../../lib/i18n';
import {incidentText} from '../../lib/incidents/messages';
import {geometryPositions,type Cop,type Geometry,type Position} from '../../lib/incidents/cop';
import type {ContextHydrant} from '../../lib/hydrants/viewport';
import {OperationalMapCanvas,orderOperationalLayers,type ViewportBounds} from '../map/OperationalMapCanvas';

export type CopLayers={sectors:boolean;markers:boolean;zones:boolean;hydrants:boolean};
type Props={locale:Locale;cop:Cop;layers:CopLayers;drawing:Geometry['type']|null;draft:Geometry|null;vertices:Position[];
 selected:string;contextHydrants:ContextHydrant[];onBounds:(b:ViewportBounds)=>void;onPoint:(p:Position)=>void;onSelect:(id:string)=>void};
const ids=['cop-primary','cop-sectors','cop-markers','cop-zones','cop-hydrants','cop-draft'] as const;
const features=(items:{id:string;geometry:Geometry;label:string;kind?:string;status?:string}[])=>({type:'FeatureCollection' as const,
 features:items.map(i=>({type:'Feature' as const,id:i.id,geometry:i.geometry,properties:{id:i.id,label:i.label,kind:i.kind??'',status:i.status??''}}))});
export default function CopMap(props:Props){
 const rts=useRts(),workspace=useWorkspace(),sim=useSimulation(),positionLayer=useSimulationPositionLayer();
 const recipientLayers=positionLayer?[positionLayer]:[];
 const c=props.cop,primary:Position|null=c.incident.longitude!==null&&c.incident.latitude!==null?[c.incident.longitude,c.incident.latitude]:null;
 const selectedKind=c.sectors.some(s=>s.id===props.selected)?'INCIDENT_SECTOR':c.objects.some(o=>o.id===props.selected)?'INCIDENT_MAP_OBJECT':'HYDRANT';
 const selectedGeometry=resolveTarget(selectedKind==='HYDRANT'?{kind:selectedKind,entityId:props.selected}:{kind:selectedKind,entityId:props.selected,incidentId:c.incident.id},{cop:c,hydrants:props.contextHydrants});
 const points=selectedGeometry?geometryPositions(selectedGeometry):primary?[primary]:[...c.sectors.flatMap(s=>s.geometry?geometryPositions(s.geometry):[]),...c.objects.flatMap(o=>geometryPositions(o.geometry)),
  ...c.links.flatMap(l=>l.hydrant?.longitude!=null&&l.hydrant.latitude!=null?[[l.hydrant.longitude,l.hydrant.latitude] as Position]:[])];
 return <OperationalMapCanvas locale={props.locale} label={incidentText(props.locale)('copTitle')} initialPoints={points} onBounds={props.onBounds}
  onClick={(map,event)=>{
   if(sim?.move){if(!rts?.locked&&!props.drawing)sim.pickPosition([event.lngLat.lng,event.lngLat.lat]);return;}
   if(rts?.mode==='SELECT_BOX'||rts?.mode==='SELECT_LASSO')return;
   if(rts?.mode==='CHOOSE_TARGET'){
    if(rts.locked||rts.copEditing||!rts.enabled||!rts.action)return;
    const kind=rts.mapTargetKind;
    if(!rts.action.configuration.target_types.includes(kind)){rts.setMessage('wrongTarget');return;}
    let target:TaskTarget|null=null,label='';
    if(kind==='COORDINATE'){target={kind,coordinate:[event.lngLat.lng,event.lngLat.lat]};label=target.coordinate.join(', ');}
    else {
     const prefixes=kind==='HYDRANT'?['cop-hydrants-','context-hydrants-']:kind==='INCIDENT_SECTOR'?['cop-sectors-']:kind==='INCIDENT_MAP_OBJECT'?['cop-markers-','cop-zones-']:[];
     const layers=map.getStyle().layers.filter(l=>prefixes.some(prefix=>l.id.startsWith(prefix))).map(l=>l.id);
     const id=layers.length?map.queryRenderedFeatures(event.point,{layers}).find(f=>typeof f.properties?.id==='string')?.properties?.id:null;
     if(typeof id==='string'){
      if(kind==='HYDRANT'){const h=c.links.find(l=>l.hydrant?.id===id)?.hydrant??props.contextHydrants.find(h=>h.id===id);if(h){target={kind,entityId:id};label=h.code??id;}}
      else if(kind==='INCIDENT_SECTOR'){const sector=c.sectors.find(s=>s.id===id);if(sector){target={kind,entityId:id,incidentId:c.incident.id};label=sector.code+' · '+sector.name;}}
      else if(kind==='INCIDENT_MAP_OBJECT'){const object=c.objects.find(o=>o.id===id);if(object){target={kind,entityId:id,incidentId:c.incident.id};label=object.label;}}
     }
    }
    const geometry=target&&target.kind!=='NONE'?resolveTarget(target,{cop:c,hydrants:props.contextHydrants}):null;
    if(!target||!geometry){rts.setMessage('wrongTarget');return;}
    if(['MOVE_TO','WITHDRAW_TO'].includes(rts.action.configuration.native_behavior)&&geometry.type!=='Point'){rts.setMessage('pointRequired');return;}
    rts.setTarget(target,geometry,label);return;
   }
   if(props.drawing){props.onPoint([event.lngLat.lng,event.lngLat.lat]);return;}
   if(!rts?.externalEditing&&!rts?.locked&&positionLayer){
    const recipient=pickPositionRecipient(map,event.point,recipientLayers);
    if(recipient){workspace?.select({kind:'INCIDENT_UNIT',id:recipient.id});
     rts?.pick(recipient,[...positionLayer.recipients.values()],{list:'simulation:'+positionLayer.id,toggle:event.originalEvent.ctrlKey||event.originalEvent.metaKey});return;}
   }
   const taskLayers=map.getStyle().layers.filter(l=>l.id.startsWith('rts-task-target-')).map(l=>l.id);
   const task=taskLayers.length?map.queryRenderedFeatures(event.point,{layers:taskLayers}).find(f=>f.properties?.id===rts?.intent?.id):null;
   if(task&&rts?.intent){workspace?.select({kind:'TASK',id:rts.intent.id});return;}
   const clickable=map.getStyle().layers.filter(l=>(l.id.startsWith('cop-')||l.id.startsWith('context-'))&&!l.id.startsWith('cop-draft')).map(l=>l.id);
   const id=map.queryRenderedFeatures(event.point,{layers:clickable}).find(f=>typeof f.properties?.id==='string')?.properties?.id;
   if(typeof id==='string')props.onSelect(id);
  }}>{map=><><CopRendering map={map} props={props}/><TaskIntentLayers map={map} locale={props.locale}/><SimulationMapLayer map={map} locale={props.locale}/><RtsMapInteraction map={map} locale={props.locale} layers={recipientLayers}/></>}</OperationalMapCanvas>;
}
function CopRendering({map,props}:{map:Map;props:Props}){
 const fitted=useRef('');
 useEffect(()=>{
  if(!props.selected){fitted.current='';return;}if(fitted.current===props.selected)return;
  const c=props.cop;
  const kind=c.sectors.some(s=>s.id===props.selected)?'INCIDENT_SECTOR':c.objects.some(o=>o.id===props.selected)?'INCIDENT_MAP_OBJECT':'HYDRANT';
  const g=resolveTarget(kind==='HYDRANT'?{kind,entityId:props.selected}:{kind,entityId:props.selected,incidentId:c.incident.id},{cop:c,hydrants:props.contextHydrants});
  if(!g)return;const points=geometryPositions(g);if(!points.length)return;
  const xs=points.map(p=>p[0]),ys=points.map(p=>p[1]);
  map.fitBounds([[Math.min(...xs),Math.min(...ys)],[Math.max(...xs),Math.max(...ys)]],{padding:60,maxZoom:16});
  fitted.current=props.selected;
 },[map,props.selected,props.cop,props.contextHydrants]);
 useEffect(()=>{
  const m=map;
   for(const id of ids)m.addSource(id,{type:'geojson',data:features([])});
   for(const source of ['cop-sectors','cop-zones','cop-draft']){
    m.addLayer({id:source+'-fill',type:'fill',source,filter:['==',['geometry-type'],'Polygon'],paint:{'fill-color':source==='cop-sectors'?'#1865a0':source==='cop-draft'?'#802ea5':'#b45200','fill-opacity':0.18}});
    m.addLayer({id:source+'-line',type:'line',source,filter:['!=',['geometry-type'],'Point'],paint:{'line-color':source==='cop-sectors'?'#1865a0':source==='cop-draft'?'#802ea5':'#b45200','line-width':3,...(source==='cop-draft'?{'line-dasharray':[2,2]}:{})}});
   }
   for(const source of ['cop-primary','cop-markers','cop-zones','cop-hydrants','cop-draft']){
    m.addLayer({id:source+'-point',type:'circle',source,filter:['==',['geometry-type'],'Point'],paint:{'circle-radius':source==='cop-primary'?12:9,'circle-color':
     source==='cop-hydrants'?['match',['get','status'],'WORKING','#16803c','NOT_WORKING','#bb242b','NEEDS_INSPECTION','#f3ad18','#68767e']:
      source==='cop-primary'?'#a9232e':source==='cop-draft'?'#802ea5':['match',['get','kind'],'COMMAND_POST','#a9232e','WATER_SOURCE','#1865a0','HAZARD','#b45200','#263238'],
     'circle-stroke-color':source==='cop-hydrants'?'#1865a0':'#fff','circle-stroke-width':source==='cop-hydrants'?4:2}});
   }
   for(const source of ids.filter(s=>s!=='cop-draft')){
    m.addLayer({id:source+'-label',type:'symbol',source,layout:{'text-field':['get','label'],'text-size':12,'text-offset':[0,1.5]},paint:{'text-color':'#20252a','text-halo-color':'#fff','text-halo-width':2}});
   }

  m.addSource('context-hydrants',{type:'geojson',data:features([])});
  m.addLayer({id:'context-hydrants-point',type:'circle',source:'context-hydrants',paint:{
   'circle-radius':5,'circle-color':['match',['get','status'],'WORKING','#16803c','NOT_WORKING','#bb242b','NEEDS_INSPECTION','#f3ad18','#68767e'],
   'circle-stroke-color':'#fff','circle-stroke-width':1}});
  m.addLayer({id:'context-hydrants-label',type:'symbol',source:'context-hydrants',minzoom:16,
   layout:{'text-field':['get','label'],'text-size':11,'text-offset':[0,1.2]},paint:{'text-color':'#20252a','text-halo-color':'#fff','text-halo-width':2}});
  m.addSource('cop-selection',{type:'geojson',data:features([])});
  m.addLayer({id:'cop-selection-line',type:'line',source:'cop-selection',filter:['!=',['geometry-type'],'Point'],
   paint:{'line-color':'#802ea5','line-width':6}});
  m.addLayer({id:'cop-selection-point',type:'circle',source:'cop-selection',filter:['==',['geometry-type'],'Point'],
   paint:{'circle-radius':16,'circle-color':'#fff','circle-opacity':0,'circle-stroke-color':'#802ea5','circle-stroke-width':3}});
  m.addLayer({id:'cop-selection-label',type:'symbol',source:'cop-selection',layout:{'text-field':['get','label'],'text-size':13,'text-offset':[0,2],'text-allow-overlap':true},
   paint:{'text-color':'#20252a','text-halo-color':'#fff','text-halo-width':2}});
  const layerIds=m.getStyle().layers.map(l=>l.id);
  orderOperationalLayers(m,{
   CONTEXT:layerIds.filter(id=>id.startsWith('context-')),
   AREAS:layerIds.filter(id=>id.startsWith('cop-sectors')||id==='cop-zones-fill'||id==='cop-zones-line'),
   OPERATIONS:layerIds.filter(id=>id.startsWith('cop-primary')||id.startsWith('cop-markers')||id.startsWith('cop-hydrants')||id==='cop-zones-point'||id==='cop-zones-label'),
   SELECTION:layerIds.filter(id=>id.startsWith('cop-draft')||id.startsWith('cop-selection'))
  });
  return()=>{
   // Canvas owns destruction; when only this domain unmounts remove its own layers.
   if(!m.getStyle())return;
   for(const layer of [...m.getStyle().layers].reverse())if(layer.id.startsWith('cop-')||layer.id.startsWith('context-'))m.removeLayer(layer.id);
   for(const id of [...ids,'context-hydrants','cop-selection'])if(m.getSource(id))m.removeSource(id);
  };
 },[map]);
 useEffect(()=>{
  const m=map;const t=incidentText(props.locale),c=props.cop;
  const put=(id:string,items:Parameters<typeof features>[0])=>(m.getSource(id) as GeoJSONSource|undefined)?.setData(features(items));
  const primary:Position|null=c.incident.longitude!==null&&c.incident.latitude!==null?[c.incident.longitude,c.incident.latitude]:null;
  put('cop-primary',primary?[{id:'primary',geometry:{type:'Point',coordinates:primary},label:t('copLocation')}]:[]);
  put('cop-sectors',c.sectors.flatMap(s=>s.geometry?[{id:s.id,geometry:s.geometry,label:s.code+' · '+s.name}]:[]));
  const objects=c.objects.map(o=>({id:o.id,geometry:o.geometry,label:t(o.kind)+' · '+o.label,kind:o.kind}));
  put('cop-markers',objects.filter(o=>!['HAZARD','PERIMETER'].includes(o.kind)));
  put('cop-zones',objects.filter(o=>['HAZARD','PERIMETER'].includes(o.kind)));
  put('cop-hydrants',c.links.flatMap(l=>{const h=l.hydrant;return h&&h.longitude!==null&&h.latitude!==null&&Number.isFinite(h.longitude)&&Number.isFinite(h.latitude)&&Math.abs(h.longitude)<=180&&Math.abs(h.latitude)<=90?
   [{id:h.id,geometry:{type:'Point' as const,coordinates:[h.longitude,h.latitude] as Position},label:h.code??t('copPendingCode'),status:h.status}]:[];}));

 },[props.cop,props.locale,map]);
 useEffect(()=>{
  const m=map;
  for(const [group,visible]of Object.entries(props.layers)){
   const prefix='cop-'+group;
   for(const layer of m.getStyle().layers)if(layer.id.startsWith(prefix+'-'))m.setLayoutProperty(layer.id,'visibility',visible?'visible':'none');
  }
 },[props.layers,map]);
 useEffect(()=>{
  const m=map;
  m.getCanvas().style.cursor=props.drawing?'crosshair':'';
  const drawingGeometry:Geometry|null=props.vertices.length>1?{type:'LineString',coordinates:props.vertices}:props.vertices.length===1?{type:'Point',coordinates:props.vertices[0]}:props.draft;
  (m.getSource('cop-draft') as GeoJSONSource|undefined)?.setData(features(drawingGeometry?[{id:'draft',geometry:drawingGeometry,label:''}]:[]));
 },[props.draft,props.vertices,props.drawing,map]);

 useEffect(()=>{
  const linked=new Set(props.cop.links.flatMap(l=>l.hydrant?[l.hydrant.id]:[]));
  const rows=props.contextHydrants.filter(h=>!linked.has(h.id));
  (map.getSource('context-hydrants') as GeoJSONSource|undefined)?.setData(features(rows.map(h=>({
   id:h.id,geometry:{type:'Point' as const,coordinates:[h.longitude,h.latitude] as Position},label:h.code??incidentText(props.locale)('copPendingCode'),status:h.status
  }))));
 },[map,props.contextHydrants,props.cop.links,props.locale]);
 useEffect(()=>{
  const c=props.cop,s=c.sectors.find(v=>v.id===props.selected),o=c.objects.find(v=>v.id===props.selected);
  const h=c.links.find(l=>l.hydrant?.id===props.selected)?.hydrant??props.contextHydrants.find(v=>v.id===props.selected);
  const geometry=s?.geometry??o?.geometry??(h&&h.longitude!==null&&h.latitude!==null?{type:'Point' as const,coordinates:[h.longitude,h.latitude] as Position}:null);
  const label=s?s.code+' · '+s.name:o?o.label:h?h.code??incidentText(props.locale)('copPendingCode'):'';
  (map.getSource('cop-selection') as GeoJSONSource|undefined)?.setData(features(geometry?[{id:props.selected,geometry,label}]:[]));
 },[map,props.selected,props.cop,props.contextHydrants,props.locale]);
 return null;
}
