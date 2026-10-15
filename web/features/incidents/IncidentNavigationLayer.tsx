'use client';
import {useEffect,useRef} from 'react';
import type {Map,GeoJSONSource} from 'maplibre-gl';
import type {Feature} from 'geojson';
import type {Locale} from '../../lib/i18n';
import {navigationText} from '../../lib/operational/navigationMessages';
import {remainingPath} from '../../lib/operational/commandMap';
import {commandMapText} from '../../lib/operational/commandMapMessages';
import {useCommandMap} from './CommandMapProvider';
import {useWorkspace} from './workspace';
import {useIncidentNavigation} from './IncidentNavigationProvider';
const empty={type:'FeatureCollection' as const,features:[]};
export function IncidentNavigationLayer({map,locale,representedTargets}:{map:Map;locale:Locale;representedTargets:ReadonlyMap<string,readonly number[]>}){
 const nav=useIncidentNavigation(),t=navigationText(locale),fit=useRef(0),command=useCommandMap(),workspace=useWorkspace(),ct=commandMapText(locale);
 const updated=useRef(''),manualText=useRef(''),focus=useRef(0);
 const lines=useRef(new globalThis.Map<string,{key:string;feature:Feature|null}>());
 const selected=workspace?.selected?.kind==='INCIDENT_UNIT'?workspace.selected.id:null;
 useEffect(()=>{
  const before=map.getStyle().layers.find(l=>l.id.startsWith('rts-')||l.id.startsWith('cop-selection'))?.id;
  map.addSource('incident-command-routes',{type:'geojson',data:empty});
  map.addLayer({id:'incident-command-road',source:'incident-command-routes',type:'line',filter:['==',['geometry-type'],'LineString'],
   paint:{'line-color':['case',['get','simulation'],'#7b3fa1','#085b9b'],'line-width':3,'line-opacity':0.45}},before);
  map.addLayer({id:'incident-command-selected',source:'incident-command-routes',type:'line',filter:['==',['get','unit_id'],''],
   paint:{'line-color':['case',['get','simulation'],'#7b3fa1','#085b9b'],'line-width':6,'line-opacity':0.95}},before);
  map.addLayer({id:'incident-command-target',source:'incident-command-routes',type:'circle',filter:['all',['==',['geometry-type'],'Point'],['!', ['get','represented']]],
   paint:{'circle-radius':8,'circle-color':'#fff','circle-stroke-color':['case',['get','simulation'],'#7b3fa1','#085b9b'],'circle-stroke-width':3}},before);
  map.addLayer({id:'incident-command-selected-target',source:'incident-command-routes',type:'circle',filter:['==',['get','unused'],''],
   paint:{'circle-radius':13,'circle-color':'#fff','circle-opacity':0,'circle-stroke-color':'#075f93','circle-stroke-width':4}},before);
  map.addLayer({id:'incident-command-label',source:'incident-command-routes',type:'symbol',filter:['==',['geometry-type'],'Point'],
   layout:{'text-field':['get','label'],'text-size':12,'text-max-width':18,'text-offset':[0,1.5]},
   paint:{'text-color':'#263238','text-halo-color':'#fff','text-halo-width':2}},before);
  updated.current='';manualText.current='';lines.current.clear();
  map.addSource('incident-navigation',{type:'geojson',data:empty});
  map.addLayer({id:'incident-navigation-road',source:'incident-navigation',type:'line',filter:['==',['geometry-type'],'LineString'],
   paint:{'line-color':'#085b9b','line-width':5,'line-opacity':0.85}},before);
  map.addLayer({id:'incident-navigation-points',source:'incident-navigation',type:'circle',filter:['==',['geometry-type'],'Point'],
   paint:{'circle-radius':7,'circle-color':'#fff','circle-stroke-color':'#085b9b','circle-stroke-width':3}},before);
  map.addLayer({id:'incident-navigation-labels',source:'incident-navigation',type:'symbol',filter:['==',['geometry-type'],'Point'],
   layout:{'text-field':['get','label'],'text-size':12,'text-offset':[0,1.5]},paint:{'text-color':'#085b9b','text-halo-color':'#fff','text-halo-width':2}},before);
  return()=>{if(!map.getStyle())return;for(const id of ['incident-navigation-labels','incident-navigation-points','incident-navigation-road'])if(map.getLayer(id))map.removeLayer(id);if(map.getSource('incident-navigation'))map.removeSource('incident-navigation');for(const id of ['incident-command-label','incident-command-selected-target','incident-command-target','incident-command-selected','incident-command-road'])if(map.getLayer(id))map.removeLayer(id);if(map.getSource('incident-command-routes'))map.removeSource('incident-command-routes');lines.current.clear();};
 },[map]);
 useEffect(()=>{
  const features:Feature[]=[];const route=nav?.history&&command?.visible?nav.route:null;
  if(route){
   features.push({type:'Feature',properties:{},geometry:route.route_geometry});
   features.push({type:'Feature',properties:{label:t(route.origin_snapshot.source)},geometry:{type:'Point',coordinates:route.origin_snapshot.coordinate}});
   features.push({type:'Feature',properties:{label:route.destination_snapshot.label??'◉'},geometry:route.destination_snapshot.geometry});
  }
  if(nav?.candidate)features.push({type:'Feature',properties:{label:t('MANUAL_PLANNING_POINT')},geometry:{type:'Point',coordinates:nav.candidate}});
  const text=JSON.stringify(features);if(text!==manualText.current){manualText.current=text;(map.getSource('incident-navigation') as GeoJSONSource|undefined)?.setData({type:'FeatureCollection',features});}
 },[map,nav?.route,nav?.history,nav?.candidate,command?.visible,locale]);
 useEffect(()=>{
  const rows=command?.visible?command.data?.rows??[]:[];
  const features:Feature[]=[],next=new globalThis.Map<string,{key:string;feature:Feature|null}>();
  const destinations=new globalThis.Map<string,{point:number[];ids:string[];labels:string[];represented:boolean;units:string[]}>();
  const signatures:string[]=[String(command?.visible),locale,String(command?.data?.simulation)];
  for(const row of rows){
   const route=row.route;if(!route)continue;
   const path=command?.data?.paths.get(route.id);if(!path)continue;
   const meters=row.run?.route_id===route.id?row.run.progress_m:0;
   const key=route.id+':'+(row.run?.id??'planned')+':'+meters;
   let entry=lines.current.get(row.id);
   if(!entry||entry.key!==key){
    const coordinates=remainingPath(path,meters);
    entry={key,feature:coordinates.length>=2?{type:'Feature',id:row.id,properties:{unit_id:row.unit_id,assignments:JSON.stringify([row.id]),simulation:!!command?.data?.simulation},geometry:{type:'LineString',coordinates}}:null};
   }
   next.set(row.id,entry);if(entry.feature)features.push(entry.feature);
   const point=route.destination_snapshot.geometry.coordinates,k=point.join(',');
   const existing=representedTargets.get(row.target_type+':'+row.target_entity_id),represented=!!existing&&existing.join(',')===k;
   const destination=destinations.get(k)??{point,ids:[],labels:[],represented:false,units:[]};
   destination.ids.push(row.id);destination.labels.push(row.callsign+(row.target?' → '+row.target.slice(0,80):''));destination.represented||=represented;destination.units.push(row.unit_id);destinations.set(k,destination);
   signatures.push(row.id+':'+key+':'+row.callsign+':'+row.target+':'+k+':'+represented);
  }
  for(const [id,d] of destinations)features.push({type:'Feature',id:'target:'+id,properties:{
   assignments:JSON.stringify(d.ids),simulation:!!command?.data?.simulation,represented:d.represented,units:d.units,
   label:(command?.data?.simulation?'SIM · ':'')+[...new Set(d.labels)].slice(0,3).join(' / ')+(d.labels.length>3?' +'+(d.labels.length-3):'')
  },geometry:{type:'Point',coordinates:d.point}});
  lines.current=next;
  const signature=signatures.join('|');
  if(signature!==updated.current){updated.current=signature;(map.getSource('incident-command-routes') as GeoJSONSource|undefined)?.setData({type:'FeatureCollection',features});}
 },[map,command?.data,command?.visible,locale,representedTargets]);
 useEffect(()=>{
  // Selection changes filters only, not geometry or the base map.
  map.setFilter('incident-command-selected',['all',['==',['geometry-type'],'LineString'],['==',['get','unit_id'],selected??'']]);
  map.setFilter('incident-command-selected-target',['all',['==',['geometry-type'],'Point'],['in',selected??'',['get','units']]]);
 },[map,selected,command?.data,command?.visible]);
 useEffect(()=>{
  if(!command?.focus||command.focus.sequence===focus.current)return;
  focus.current=command.focus.sequence;map.easeTo({center:command.focus.point,zoom:Math.max(map.getZoom(),14)});
 },[map,command?.focus]);
 useEffect(()=>{
  if(!nav?.route||!nav.fit||nav.fit===fit.current)return;fit.current=nav.fit;
  const points=[...nav.route.route_geometry.coordinates,nav.route.origin_snapshot.coordinate,nav.route.destination_snapshot.geometry.coordinates];
  let west=180,east=-180,south=90,north=-90;for(const p of points){west=Math.min(west,p[0]);east=Math.max(east,p[0]);south=Math.min(south,p[1]);north=Math.max(north,p[1]);}
  map.fitBounds([[west,south],[east,north]],{padding:60,maxZoom:16});
 },[map,nav?.fit,nav?.route]);
 useEffect(()=>{if(!nav?.picking)return;const canvas=map.getCanvas(),old=canvas.style.cursor;canvas.style.cursor='crosshair';return()=>{canvas.style.cursor=old;};},[map,nav?.picking]);
 if(!nav)return null;
 const targets=command?.visible?command.data?.rows.filter(row=>command.targets.includes(row.id))??[]:[];
 return <>
 {targets.length>0&&<aside className="command-target-inspector"><strong>{ct('overlap')}</strong>
 {targets.map(row=><div key={row.id}><button onClick={()=>{workspace?.select({kind:'INCIDENT_UNIT',id:row.unit_id});workspace?.showDetails();command?.inspectTargets([]);}}>{row.callsign} · {locale==='de'?row.label_de:row.label_sl} · {row.target}</button>
 <button onClick={()=>{workspace?.select({kind:'TASK',id:row.task_id});workspace?.showDetails();command?.inspectTargets([]);}}>{ct('details')}</button></div>)}
 <button onClick={()=>command?.inspectTargets([])}>{ct('close')}</button></aside>}
 {command?.visible&&command.data?.rows.some(row=>row.route)&&!nav.history&&<aside className="navigation-map-note" role="note">{command.data.simulation?'SIM':ct('real')} · {ct('planned')}</aside>}
 {nav.picking&&<aside className="rts-map-mode"><strong>{t('MANUAL_PLANNING_POINT')}</strong><p>{t('originHelp')}</p>
  {nav.candidate&&<><p>{nav.candidate.join(', ')}</p><button onClick={()=>nav.prepare('MANUAL_PLANNING_POINT')}>{t('confirm')}</button></>}<button onClick={nav.cancelPick}>{t('cancel')}</button></aside>}
  {nav.history&&nav.route&&command?.visible&&!nav.picking&&<aside className="navigation-map-note" role="note">{t(nav.history?'historical':'title')} · {nav.route.provider} · {t(nav.route.origin_snapshot.source)}<br/>{t('duration')}: {Math.ceil(nav.route.duration_s/60)} min</aside>}
 </>;
}
