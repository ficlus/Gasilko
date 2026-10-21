'use client';
import {useEffect,useRef} from 'react';
import type {Map,GeoJSONSource} from 'maplibre-gl';
import {geometryPositions} from '../../lib/incidents/cop';
import {useScenarioEvents} from './ScenarioEvents';
const source='scenario-events';
export const scenarioEventLayers=['scenario-events-fill','scenario-events-line','scenario-events-point','scenario-events-label'];
export function ScenarioEventMapLayer({map}:{map:Map}){
 const ctx=useScenarioEvents(),rows=ctx?.data?.annotations,focus=ctx?.focus,focused=useRef(0),bytes=useRef('');
 useEffect(()=>{
  bytes.current='';
  map.addSource(source,{type:'geojson',data:{type:'FeatureCollection',features:[]}});
  map.addLayer({id:scenarioEventLayers[0],type:'fill',source,filter:['==',['geometry-type'],'Polygon'],paint:{'fill-color':'#b05b00','fill-opacity':0.2}});
  map.addLayer({id:scenarioEventLayers[1],type:'line',source,filter:['==',['geometry-type'],'Polygon'],paint:{'line-color':'#b05b00','line-width':3,'line-dasharray':[2,2]}});
  map.addLayer({id:scenarioEventLayers[2],type:'circle',source,filter:['==',['geometry-type'],'Point'],paint:{'circle-color':'#b05b00','circle-radius':12,'circle-stroke-color':'#fff','circle-stroke-width':3}});
  map.addLayer({id:scenarioEventLayers[3],type:'symbol',source,layout:{'text-field':['concat','SIM · ',['get','title']],'text-size':12,'text-offset':[0,1.6],'text-anchor':'top'},paint:{'text-color':'#633000','text-halo-color':'#fff','text-halo-width':2}});
  return()=>{for(const id of [...scenarioEventLayers].reverse())if(map.getLayer(id))map.removeLayer(id);if(map.getSource(source))map.removeSource(source);};
 },[map]);
 useEffect(()=>{for(const id of scenarioEventLayers)if(map.getLayer(id))map.setLayoutProperty(id,'visibility',ctx?.visible===false?'none':'visible');},[map,ctx?.visible]);
 useEffect(()=>{
  const features={type:'FeatureCollection' as const,features:(rows??[]).map(a=>({type:'Feature' as const,id:a.id,geometry:a.geometry,properties:{id:a.id,title:a.title}}))};
  const next=JSON.stringify(features);if(bytes.current===next)return;
  (map.getSource(source) as GeoJSONSource|undefined)?.setData(features);bytes.current=next;
 },[map,rows]);
 useEffect(()=>{
  if(!focus||focused.current===focus.nonce)return;focused.current=focus.nonce;
  const annotation=rows?.find(a=>a.id===focus.id);if(!annotation)return;
  const points=geometryPositions(annotation.geometry);if(!points.length)return;
  const x=points.map(p=>p[0]),y=points.map(p=>p[1]);
  map.fitBounds([[Math.min(...x),Math.min(...y)],[Math.max(...x),Math.max(...y)]],{padding:60,maxZoom:16});
 },[map,focus,rows]);
 return null;
}
