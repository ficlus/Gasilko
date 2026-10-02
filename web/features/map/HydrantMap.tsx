'use client';
import {useEffect,useRef,useState} from 'react';
import {Map,Marker,NavigationControl,setWorkerUrl,type GeoJSONSource} from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import {dictionary,type Locale} from '@/lib/i18n';
import {organizationColor,type Row} from '@/lib/hydrants/admin';
import {PrivatePhoto} from '../hydrants/PrivatePhotos';
import {statusLabel} from '../hydrants/Registry';
export type Bounds=[number,number,number,number];
type Props={locale:Locale;rows?:Row[];selected?:Row|null;onSelect?:(h:Row)=>void;onOpen?:(h:Row)=>void;
 onBounds?:(b:Bounds)=>void;point?:[number,number]|null;onPoint?:(p:[number,number])=>void};
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
 m.on('load',()=>{m.addSource('hydrants',{type:'geojson',data:{type:'FeatureCollection',features:[]},cluster:true,clusterRadius:45,clusterMaxZoom:16});
 m.addLayer({id:'clusters',type:'circle',source:'hydrants',filter:['has','point_count'],paint:{'circle-color':'#263238','circle-radius':22,'circle-stroke-color':'#fff','circle-stroke-width':2}});
 m.addLayer({id:'cluster-count',type:'symbol',source:'hydrants',filter:['has','point_count'],layout:{'text-field':['get','point_count_abbreviated'],'text-size':13},paint:{'text-color':'#fff'}});
 m.addLayer({id:'hydrants',type:'circle',source:'hydrants',filter:['!',['has','point_count']],paint:{'circle-radius':9,'circle-color':['match',['get','status'],'WORKING','#16803c','NOT_WORKING','#bb242b','NEEDS_INSPECTION','#f3ad18','#68767e'],'circle-stroke-width':4,'circle-stroke-color':['get','orgColor']}});
 m.on('click','clusters',async e=>{const f=e.features?.[0];if(!f||f.geometry.type!=='Point')return;try{const z=await(m.getSource('hydrants') as GeoJSONSource).getClusterExpansionZoom(Number(f.properties.cluster_id));m.easeTo({center:f.geometry.coordinates as [number,number],zoom:z});}catch{setError(true);}});
 m.on('click','hydrants',e=>{const id=e.features?.[0]?.properties.id;const h=latest.current.rows?.find(r=>r.id===id);if(h)latest.current.onSelect?.(h);});
 setReady(true);bounds();});
 m.on('moveend',bounds);m.on('error',()=>setError(true));m.on('click',e=>{if(latest.current.onPoint)latest.current.onPoint([e.lngLat.lng,e.lngLat.lat]);});
 const resize=new ResizeObserver(()=>m.resize());resize.observe(container.current);
 return()=>{clearTimeout(timer);resize.disconnect();map.current=null;m.remove();};},[style,attempt]);
 useEffect(()=>{if(!ready||!map.current)return;const source=map.current.getSource('hydrants') as GeoJSONSource;
 if(!source)return;
 source.setData({type:'FeatureCollection',features:rows.filter(h=>h.latitude!==null&&h.longitude!==null).map(h=>({type:'Feature',geometry:{type:'Point',coordinates:[h.longitude!,h.latitude!]},properties:{id:h.id,status:h.status,orgColor:organizationColor(h.organization_id)}}))});},[rows,ready]);
 useEffect(()=>{if(ready&&selected?.longitude!==null&&selected?.latitude!==null&&selected){map.current?.easeTo({center:[selected.longitude,selected.latitude],zoom:Math.max(15,map.current.getZoom())});}},[selected?.id,ready]);
 useEffect(()=>{const m=map.current;if(!m||!ready||!point)return;const marker=new Marker({draggable:true}).setLngLat(point).addTo(m);marker.on('dragend',()=>{const p=marker.getLngLat();latest.current.onPoint?.([p.lng,p.lat]);});m.easeTo({center:point,zoom:Math.max(m.getZoom(),14)});return()=>{marker.remove();};},[point?.[0],point?.[1],ready]);
 return <div className="web-map-wrap"><div className="web-map" ref={container} aria-label={t.adminMap}/>
 {(!style||!ready||error)&&<div className="web-map-notice" role="status">{!style?t.wMapUnconfigured:error?t.wMapError:t.loading}{error&&<button onClick={()=>setAttempt(v=>v+1)}>{t.hRetry}</button>}</div>}
 {selected&&<aside className="web-map-popup"><PrivatePhoto path={selected.preview_path} locale={locale}/><strong>{selected.code??t.hMissing}</strong><p>{statusLabel(t,selected.status)}</p><p>{selected.address||selected.location_description}</p><small>{selected.organization_name}</small><button onClick={()=>props.onOpen?.(selected)}>{t.hDetails}</button></aside>}
 </div>;
}
