'use client';
import {useEffect,useRef} from 'react';
import {Marker,type Map,type GeoJSONSource} from 'maplibre-gl';
import type {FeatureCollection,Feature,Geometry as GeoGeometry} from 'geojson';
import type {Locale} from '../../lib/i18n';
import type {Position} from '../../lib/incidents/cop';
import {offsetPosition,type Definition} from '../../lib/operational/templates';
import {templateText} from '../../lib/operational/templateMessages';
import {OperationalMapCanvas} from '../map/OperationalMapCanvas';
type Props={locale:Locale;definition:Definition;selected:string;editable:boolean;placing:boolean;vertices:Position[];
 onSelect:(id:string)=>void;onPoint:(p:Position)=>void;onMove:(p:Position)=>void};
export default function TemplateMap(props:Props){
 const initial=useRef<Position[]>(props.definition.world.center?[props.definition.world.center]:[]);
 return <OperationalMapCanvas locale={props.locale} label={templateText(props.locale)('map')} initialPoints={initial.current}
  onClick={(map,e)=>{
   if(props.editable&&props.placing){props.onPoint([e.lngLat.lng,e.lngLat.lat]);return;}
   const hit=map.getLayer('template-points')?map.queryRenderedFeatures(e.point,{layers:['template-points','template-fill']})[0]:null;
   if(hit?.properties?.id)props.onSelect(String(hit.properties.id));
  }}>{map=><Layers map={map} {...props}/>}</OperationalMapCanvas>;
}
function Layers({map,definition:d,selected,editable,placing,vertices,onMove,locale}:Props&{map:Map}){
 const move=useRef(onMove);move.current=onMove;
 const items:Feature<GeoGeometry>[]=[];
 const add=(id:string,label:string,geometry:GeoGeometry,color:string)=>items.push({type:'Feature',geometry,properties:{id,label,color}});
 const t=templateText(locale);
 if(d.world.center){
  const ring=Array.from({length:65},(_,i)=>offsetPosition(d.world.center!,d.world.radius_m,i*360/64));
  add('bounds','',{type:'Polygon',coordinates:[ring]},'#64748b');
  add('center',t('center'),{type:'Point',coordinates:d.world.center},'#64748b');
 }
 if(d.world.incident_location)add('incident',t('incident'),{type:'Point',coordinates:d.world.incident_location},'#dc2626');
 d.initial_objects.forEach(o=>{if(o.geometry)add(o.id,o.label,o.geometry,'#d97706');});
 d.virtual_units.forEach((u,i)=>{if(u.position)add(u.id,'SIM-'+(i+1),{type:'Point',coordinates:u.position},'#2563eb');});
 if(vertices.length>1)add('drawing','',{type:'LineString',coordinates:vertices},'#dc2626');
 const data:FeatureCollection={type:'FeatureCollection',features:items};
 useEffect(()=>{
  map.addSource('template-data',{type:'geojson',data:{type:'FeatureCollection',features:[]}});
  map.addLayer({id:'template-fill',type:'fill',source:'template-data',filter:['==',['geometry-type'],'Polygon'],paint:{'fill-color':['get','color'],'fill-opacity':0.12}});
  map.addLayer({id:'template-lines',type:'line',source:'template-data',filter:['!=',['geometry-type'],'Point'],paint:{'line-color':['get','color'],'line-width':2}});
  map.addLayer({id:'template-points',type:'circle',source:'template-data',filter:['==',['geometry-type'],'Point'],paint:{'circle-radius':9,'circle-color':['get','color'],'circle-stroke-color':'#ffffff','circle-stroke-width':2}});
  map.addLayer({id:'template-labels',type:'symbol',source:'template-data',layout:{'text-field':['get','label'],'text-size':12,'text-offset':[0,1.7],'text-anchor':'top'},paint:{'text-color':'#111827','text-halo-color':'#ffffff','text-halo-width':2}});
  return()=>{try{for(const id of ['template-labels','template-points','template-lines','template-fill'])if(map.getLayer(id))map.removeLayer(id);if(map.getSource('template-data'))map.removeSource('template-data');}catch{/* Canvas may already be disposed. */}};
 },[map]);
 useEffect(()=>{(map.getSource('template-data') as GeoJSONSource|undefined)?.setData(data);},[map,d,vertices,locale]);
 const geometry=items.find(f=>f.properties?.id===selected)?.geometry;
 const point=geometry?.type==='Point'?geometry.coordinates:null;
 const x=point?.[0],y=point?.[1];
 useEffect(()=>{
  if(!editable||placing||x===undefined||y===undefined)return;
  // One editor-only drag handle. MapLibre supplies mouse and touch dragging.
  const marker=new Marker({draggable:true,color:'#111827'}).setLngLat([x,y]).addTo(map);
  marker.getElement().setAttribute('aria-hidden','true');
  marker.on('dragend',()=>{const p=marker.getLngLat();move.current([p.lng,p.lat]);});
  return()=>{marker.remove();};
 },[map,selected,x,y,editable,placing]);
 return null;
}
