'use client';
import {useEffect,useRef,useState} from 'react';
import {Map,Marker,NavigationControl,setWorkerUrl,type GeoJSONSource} from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import {dictionary,type Locale} from '@/lib/i18n';
import {organizationColor,type Row} from '@/lib/hydrants/admin';
import {PrivatePhoto} from '../hydrants/PrivatePhotos';
import {statusLabel} from '../hydrants/Registry';
import type {RoadGeometry} from '@/lib/mapGeometry';
export type Bounds=[number,number,number,number];
export type PlanOverlay={fitKey:string;stops:Record<string,{color:string;number:number|null;completed:boolean;skipped:boolean}>;
 routes:{color:string;valid:boolean;geometry:RoadGeometry}[]};
type Props={locale:Locale;rows?:Row[];selected?:Row|null;onSelect?:(h:Row)=>void;onOpen?:(h:Row)=>void;
 onBounds?:(b:Bounds)=>void;point?:[number,number]|null;onPoint?:(p:[number,number])=>void;plan?:PlanOverlay;actionLabel?:string;highlightedIds?:string[]};
export default function HydrantMap(props:Props){
 const {locale,rows=[],selected,point}=props,t=dictionary(locale);const container=useRef<HTMLDivElement>(null),map=useRef<Map|null>(null),latest=useRef(props);
 latest.current=props;const [ready,setReady]=useState(false),[error,setError]=useState(false),[attempt,setAttempt]=useState(0);
 const style=process.env.NEXT_PUBLIC_MAP_STYLE_URL;
 useEffect(()=>{if(!container.current||!style)return;setReady(false);setError(false);
 setWorkerUrl('/maplibre/maplibre-gl-worker.mjs');
 let m:Map;try{m=new Map({container:container.current,style,center:[14.8,46.1],zoom:7,renderWorldCopies:false,
 locale:{'NavigationControl.ZoomIn':t.wZoomIn,'NavigationControl.ZoomOut':t.wZoomOut,'NavigationControl.ResetBearing':t.wResetBearing,'AttributionControl.ToggleAttribution':t.wAttribution}});}catch{setError(true);return;}
 map.current=m;m.addControl(new NavigationControl(),'top-right');
 let timer:ReturnType<typeof setTimeout>;
 const bounds=()=>{clearTimeout(timer);timer=setTimeout(()=>{const b=m.getBounds();latest.current.onBounds?.([Math.max(-180,b.getWest()),Math.max(-90,b.getSouth()),Math.min(180,b.getEast()),Math.min(90,b.getNorth())]);},300);};
 m.on('load',()=>{m.addSource('hydrants',{type:'geojson',data:{type:'FeatureCollection',features:[]},cluster:!latest.current.plan,clusterRadius:45,clusterMaxZoom:16});
 m.addSource('plan-roads',{type:'geojson',data:{type:'FeatureCollection',features:[]}});
 m.addLayer({id:'plan-roads',type:'line',source:'plan-roads',filter:['==',['geometry-type'],'LineString'],paint:{'line-color':['get','teamColor'],'line-width':5,'line-opacity':['case',['get','valid'],0.9,0.45]},layout:{'line-cap':'round','line-join':'round'}});
 m.addLayer({id:'clusters',type:'circle',source:'hydrants',filter:['has','point_count'],paint:{'circle-color':'#263238','circle-radius':22,'circle-stroke-color':'#fff','circle-stroke-width':2}});
 m.addLayer({id:'cluster-count',type:'symbol',source:'hydrants',filter:['has','point_count'],layout:{'text-field':['get','point_count_abbreviated'],'text-size':13},paint:{'text-color':'#fff'}});
 m.addLayer({id:'hydrants',type:'circle',source:'hydrants',filter:['!',['has','point_count']],paint:{'circle-radius':['case',['has','number'],14,['==',['get','chosen'],true],12,['==',['get','background'],true],5,9],'circle-color':['case',['==',['get','completed'],true],'#176333',['==',['get','skipped'],true],'#6b5000',['match',['get','status'],'WORKING','#16803c','NOT_WORKING','#bb242b','NEEDS_INSPECTION','#f3ad18','#68767e']],'circle-stroke-width':['case',['==',['get','chosen'],true],6,['==',['get','background'],true],1,4],'circle-stroke-color':['case',['==',['get','chosen'],true],'#a9232e',['get','orgColor']]}});
 m.addLayer({id:'plan-stop-labels',type:'symbol',source:'hydrants',filter:['has','number'],layout:{'text-field':['concat',['case',['==',['get','completed'],true],'✓ ',['==',['get','skipped'],true],'! ',''],['to-string',['get','number']]],'text-size':12,'text-allow-overlap':true},paint:{'text-color':'#fff','text-halo-color':'#263238','text-halo-width':1}});
 m.on('click','clusters',async e=>{const f=e.features?.[0];if(!f||f.geometry.type!=='Point')return;try{const z=await(m.getSource('hydrants') as GeoJSONSource).getClusterExpansionZoom(Number(f.properties.cluster_id));m.easeTo({center:f.geometry.coordinates as [number,number],zoom:z});}catch{setError(true);}});
 m.on('click','hydrants',e=>{const id=e.features?.[0]?.properties.id;const h=latest.current.rows?.find(r=>r.id===id);if(h)latest.current.onSelect?.(h);});
 setReady(true);bounds();});
 m.on('moveend',bounds);m.on('error',()=>setError(true));m.on('click',e=>{if(latest.current.onPoint)latest.current.onPoint([e.lngLat.lng,e.lngLat.lat]);});
 const resize=new ResizeObserver(()=>m.resize());resize.observe(container.current);
 return()=>{clearTimeout(timer);resize.disconnect();map.current=null;m.remove();};},[style,attempt]);
 useEffect(()=>{if(!ready||!map.current)return;const source=map.current.getSource('hydrants') as GeoJSONSource;
 if(!source)return;
 const highlighted=new Set(props.highlightedIds??[]);
 source.setData({type:'FeatureCollection',features:rows.filter(h=>h.latitude!==null&&h.longitude!==null&&Math.abs(h.latitude)<=90&&Math.abs(h.longitude)<=180).map(h=>{const stop=props.plan?.stops[h.id];return {type:'Feature',geometry:{type:'Point',coordinates:[h.longitude!,h.latitude!]},properties:{id:h.id,status:h.status,background:!!props.plan&&!stop,chosen:highlighted.has(h.id),orgColor:stop?.color??organizationColor(h.organization_id),...(stop?{number:stop.number??'',completed:stop.completed,skipped:stop.skipped}:{})}};})});},[rows,ready,props.plan,props.highlightedIds]);
 useEffect(()=>{if(!ready||!map.current)return;const source=map.current.getSource('plan-roads') as GeoJSONSource;
 source?.setData({type:'FeatureCollection',features:(props.plan?.routes??[]).flatMap(r=>r.geometry.features.filter(f=>f.geometry.type==='LineString').map(f=>({...f,properties:{...f.properties,teamColor:r.color,valid:r.valid}})))});
 },[props.plan,ready]);
 useEffect(()=>{const m=map.current;if(!ready||!m||!props.plan)return;const points:[number,number][]=[];
 for(const h of latest.current.rows??[])if((!latest.current.plan||!!latest.current.plan.stops[h.id])&&h.latitude!==null&&h.longitude!==null&&Math.abs(h.latitude)<=90&&Math.abs(h.longitude)<=180)points.push([h.longitude,h.latitude]);
 for(const r of latest.current.plan?.routes??[])for(const f of r.geometry.features)if(f.geometry.type==='LineString')for(const p of f.geometry.coordinates)if(Number.isFinite(p[0])&&Number.isFinite(p[1]))points.push([p[0],p[1]]);
 if(latest.current.point)points.push(latest.current.point);if(points.length){let west=180,east=-180,south=90,north=-90;for(const [x,y] of points){west=Math.min(west,x);east=Math.max(east,x);south=Math.min(south,y);north=Math.max(north,y);}m.fitBounds([[west,south],[east,north]],{padding:55,maxZoom:16,duration:0});}
 },[props.plan?.fitKey,ready]);
 useEffect(()=>{if(ready&&selected?.longitude!==null&&selected?.latitude!==null&&selected){map.current?.easeTo({center:[selected.longitude,selected.latitude],zoom:Math.max(15,map.current.getZoom())});}},[selected?.id,ready]);
 useEffect(()=>{const m=map.current;if(!m||!ready||!point)return;const marker=new Marker({draggable:!!props.onPoint}).setLngLat(point).addTo(m);marker.on('dragend',()=>{const p=marker.getLngLat();latest.current.onPoint?.([p.lng,p.lat]);});if(!latest.current.plan)m.easeTo({center:point,zoom:Math.max(m.getZoom(),14)});return()=>{marker.remove();};},[point?.[0],point?.[1],ready,!!props.onPoint]);
 return <div className="web-map-wrap"><div className="web-map" ref={container} aria-label={t.adminMap}/>
 {(!style||!ready||error)&&<div className="web-map-notice" role="status">{!style?t.wMapUnconfigured:error?t.wMapError:t.loading}{error&&<button onClick={()=>setAttempt(v=>v+1)}>{t.hRetry}</button>}</div>}
 {selected&&<aside className="web-map-popup"><PrivatePhoto path={selected.preview_path} locale={locale}/><strong>{selected.code??t.hMissing}</strong><p>{statusLabel(t,selected.status)}</p><p>{selected.address||selected.location_description}</p><small>{selected.organization_name}</small><button onClick={()=>props.onOpen?.(selected)}>{props.actionLabel??t.hDetails}</button></aside>}
 </div>;
}
