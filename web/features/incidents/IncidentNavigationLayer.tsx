'use client';
import {useEffect,useRef} from 'react';
import type {Map,GeoJSONSource} from 'maplibre-gl';
import type {Feature} from 'geojson';
import type {Locale} from '../../lib/i18n';
import {navigationText} from '../../lib/operational/navigationMessages';
import {useIncidentNavigation} from './IncidentNavigationProvider';
const empty={type:'FeatureCollection' as const,features:[]};
export function IncidentNavigationLayer({map,locale}:{map:Map;locale:Locale}){
 const nav=useIncidentNavigation(),t=navigationText(locale),fit=useRef(0);
 useEffect(()=>{
  const before=map.getStyle().layers.find(l=>l.id.startsWith('rts-')||l.id.startsWith('cop-selection'))?.id;
  map.addSource('incident-navigation',{type:'geojson',data:empty});
  map.addLayer({id:'incident-navigation-road',source:'incident-navigation',type:'line',filter:['==',['geometry-type'],'LineString'],
   paint:{'line-color':'#085b9b','line-width':5,'line-opacity':0.85}},before);
  map.addLayer({id:'incident-navigation-points',source:'incident-navigation',type:'circle',filter:['==',['geometry-type'],'Point'],
   paint:{'circle-radius':7,'circle-color':'#fff','circle-stroke-color':'#085b9b','circle-stroke-width':3}},before);
  map.addLayer({id:'incident-navigation-labels',source:'incident-navigation',type:'symbol',filter:['==',['geometry-type'],'Point'],
   layout:{'text-field':['get','label'],'text-size':12,'text-offset':[0,1.5]},paint:{'text-color':'#085b9b','text-halo-color':'#fff','text-halo-width':2}},before);
  return()=>{if(!map.getStyle())return;for(const id of ['incident-navigation-labels','incident-navigation-points','incident-navigation-road'])if(map.getLayer(id))map.removeLayer(id);if(map.getSource('incident-navigation'))map.removeSource('incident-navigation');};
 },[map]);
 useEffect(()=>{
  const features:Feature[]=[];const route=nav?.route;
  if(route){
   features.push({type:'Feature',properties:{},geometry:route.route_geometry});
   features.push({type:'Feature',properties:{label:t(route.origin_snapshot.source)},geometry:{type:'Point',coordinates:route.origin_snapshot.coordinate}});
   features.push({type:'Feature',properties:{label:route.destination_snapshot.label??'◉'},geometry:route.destination_snapshot.geometry});
  }
  if(nav?.candidate)features.push({type:'Feature',properties:{label:t('MANUAL_PLANNING_POINT')},geometry:{type:'Point',coordinates:nav.candidate}});
  (map.getSource('incident-navigation') as GeoJSONSource|undefined)?.setData({type:'FeatureCollection',features});
 },[map,nav?.route,nav?.candidate,locale]);
 useEffect(()=>{
  if(!nav?.route||!nav.fit||nav.fit===fit.current)return;fit.current=nav.fit;
  const points=[...nav.route.route_geometry.coordinates,nav.route.origin_snapshot.coordinate,nav.route.destination_snapshot.geometry.coordinates];
  let west=180,east=-180,south=90,north=-90;for(const p of points){west=Math.min(west,p[0]);east=Math.max(east,p[0]);south=Math.min(south,p[1]);north=Math.max(north,p[1]);}
  map.fitBounds([[west,south],[east,north]],{padding:60,maxZoom:16});
 },[map,nav?.fit,nav?.route]);
 useEffect(()=>{if(!nav?.picking)return;const canvas=map.getCanvas(),old=canvas.style.cursor;canvas.style.cursor='crosshair';return()=>{canvas.style.cursor=old;};},[map,nav?.picking]);
 if(!nav)return null;
 return <>{nav.picking&&<aside className="rts-map-mode"><strong>{t('MANUAL_PLANNING_POINT')}</strong><p>{t('originHelp')}</p>
  {nav.candidate&&<><p>{nav.candidate.join(', ')}</p><button onClick={()=>nav.prepare('MANUAL_PLANNING_POINT')}>{t('confirm')}</button></>}<button onClick={nav.cancelPick}>{t('cancel')}</button></aside>}
  {nav.route&&!nav.picking&&<aside className="navigation-map-note" role="note">{t(nav.history?'historical':'title')} · {nav.route.provider} · {t(nav.route.origin_snapshot.source)}<br/>{t('duration')}: {Math.ceil(nav.route.duration_s/60)} min</aside>}
 </>;
}
