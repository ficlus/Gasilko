'use client';
import {useEffect} from 'react';
import type {Map,GeoJSONSource} from 'maplibre-gl';
import type {Feature,Geometry} from 'geojson';
import {offsetPosition} from '../../lib/operational/templates';
import {useOperationalEffects} from './OperationalEffects';
const source='simulation-operational-effects',layers=['sim-water-area','sim-water-links','sim-water-sources'];
export function OperationalEffectsMap({map}:{map:Map}){
 const ctx=useOperationalEffects(),data=ctx?.data;
 const features:Feature<Geometry>[]=[];
 if(data){
  for(const r of data.resources)if(r.position)features.push({type:'Feature',geometry:{type:'Point',coordinates:r.position},properties:{kind:'SOURCE',empty:r.remaining_l<=0}});
  for(const c of data.connections){
   const a=data.resources.find(r=>r.id===c.source_id)?.position,b=data.resources.find(r=>r.id===c.consumer_id)?.position;
   if(a&&b)features.push({type:'Feature',geometry:{type:'LineString',coordinates:[a,b]},properties:{kind:'SUPPLY'}});
  }
  for(const e of data.executions)if(e.state==='ACTIVE'){
   const r=data.resources.find(r=>r.id===e.resource_id);
   if(r?.position)features.push({type:'Feature',geometry:{type:'LineString',coordinates:[r.position,e.target]},properties:{kind:'APPLICATION'}});
   features.push({type:'Feature',geometry:{type:'Polygon',coordinates:[Array.from({length:33},(_,i)=>offsetPosition(e.target,25,i*360/32))]},properties:{kind:'AREA'}});
  }
 }
 const serialized=JSON.stringify({type:'FeatureCollection',features});
 useEffect(()=>{
  map.addSource(source,{type:'geojson',data:{type:'FeatureCollection',features:[]}});
  map.addLayer({id:layers[0],type:'fill',source,filter:['==',['geometry-type'],'Polygon'],paint:{'fill-color':'#0284c7','fill-opacity':0.12}});
  map.addLayer({id:layers[1],type:'line',source,filter:['==',['geometry-type'],'LineString'],paint:{'line-color':'#0284c7','line-width':3,'line-dasharray':[2,2]}});
  map.addLayer({id:layers[2],type:'circle',source,filter:['==',['geometry-type'],'Point'],paint:{'circle-color':['case',['get','empty'],'#b45309','#0284c7'],'circle-radius':12,'circle-opacity':0.35}});
  return()=>{for(const id of [...layers].reverse())if(map.getLayer(id))map.removeLayer(id);if(map.getSource(source))map.removeSource(source);};
 },[map]);
 useEffect(()=>{(map.getSource(source) as GeoJSONSource|undefined)?.setData(JSON.parse(serialized));},[map,serialized]);
 return null;
}
