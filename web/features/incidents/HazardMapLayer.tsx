'use client';
import {useEffect,useRef} from 'react';
import type {Map,GeoJSONSource} from 'maplibre-gl';
import {useSimulationHazards} from './SimulationHazards';
const source='simulation-hazards';
const layers=['sim-hazard-burned','sim-hazard-fire','sim-hazard-smoke','sim-hazard-zones','sim-hazard-origin'];
/** Passive overlays: no hit-test registration, pointer handlers or camera changes. */
export function HazardMapLayer({map}:{map:Map}){
 const ctx=useSimulationHazards(),signature=useRef(''),rows=ctx?.data?.models;
 useEffect(()=>{
  signature.current='';
  const before=map.getStyle().layers.find(l=>l.id.startsWith('cop-')||l.id.startsWith('incident-command-')||l.id.startsWith('simulation-units-'))?.id;
  map.addSource(source,{type:'geojson',data:{type:'FeatureCollection',features:[]}});
  map.addLayer({id:layers[0],source,type:'fill',filter:['==',['get','kind'],'BURNED'],paint:{'fill-color':'#38302a','fill-opacity':0.2}},before);
  map.addLayer({id:layers[1],source,type:'fill',filter:['==',['get','kind'],'FIRE'],paint:{'fill-color':['interpolate',['linear'],['get','intensity'],0,'#ffd35c',1,'#c62b16'],'fill-opacity':0.28,'fill-outline-color':'#b83919'}},before);
  map.addLayer({id:layers[2],source,type:'fill',filter:['==',['get','kind'],'SMOKE'],paint:{'fill-color':'#5b6470','fill-opacity':['interpolate',['linear'],['get','intensity'],0,0.03,1,0.2]}},before);
  map.addLayer({id:layers[3],source,type:'line',filter:['in',['get','kind'],['literal',['HEAT_ZONE','SMOKE_ZONE','COLLAPSE_RISK','HAZARDOUS_MATERIAL','ACCESS_HAZARD']]],paint:{'line-color':'#9e4f9a','line-width':2,'line-dasharray':[2,2]}},before);
  map.addLayer({id:layers[4],source,type:'circle',filter:['==',['get','kind'],'ORIGIN'],paint:{'circle-radius':5,'circle-color':'#c62b16','circle-stroke-color':'#ffffff','circle-stroke-width':1}},before);
  return()=>{for(const id of [...layers].reverse())if(map.getLayer(id))map.removeLayer(id);if(map.getSource(source))map.removeSource(source);};
 },[map]);
 const key=(rows??[]).map(r=>r.id+':'+r.version).join('|');
 useEffect(()=>{
  if(signature.current===key)return;
  const frame=requestAnimationFrame(()=>{
   (map.getSource(source) as GeoJSONSource|undefined)?.setData({type:'FeatureCollection',features:(rows??[]).flatMap(r=>r.features)});
   signature.current=key;
  });
  return()=>cancelAnimationFrame(frame);
 },[map,key,rows]);
 useEffect(()=>{
  for(const [id,visible] of [[layers[0],ctx?.layers.fire],[layers[1],ctx?.layers.fire],[layers[2],ctx?.layers.smoke],[layers[3],ctx?.layers.hazards],[layers[4],ctx?.layers.fire]] as const)
   if(map.getLayer(id))map.setLayoutProperty(id,'visibility',visible?'visible':'none');
 },[map,ctx?.layers.fire,ctx?.layers.smoke,ctx?.layers.hazards]);
 return null;
}
