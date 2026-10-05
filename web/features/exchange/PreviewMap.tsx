'use client';
import {useEffect,useRef,useState} from 'react';
import {Map,NavigationControl,setWorkerUrl,type GeoJSONSource} from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import type {Preview} from '@/lib/exchange/model';
import {exchangeText} from '@/lib/exchange/messages';
import type {Locale} from '@/lib/i18n';
export default function PreviewMap({rows,locale}:{rows:Preview[];locale:Locale}){
 const container=useRef<HTMLDivElement>(null),map=useRef<Map|null>(null);const [ready,setReady]=useState(false),[failed,setFailed]=useState(false);const t=exchangeText(locale);
 useEffect(()=>{const style=process.env.NEXT_PUBLIC_MAP_STYLE_URL;if(!style||!container.current){setFailed(true);return;}
  setWorkerUrl('/maplibre/maplibre-gl-worker.mjs');let m:Map;try{m=new Map({container:container.current,style,center:[14.8,46.1],zoom:7});}catch{setFailed(true);return;}
  map.current=m;m.addControl(new NavigationControl());m.on('load',()=>{m.addSource('import',{type:'geojson',data:{type:'FeatureCollection',features:[]}});
   m.addLayer({id:'import',type:'circle',source:'import',paint:{'circle-radius':7,'circle-color':['match',['get','state'],'CREATE','#176333','UPDATE','#00689d','WARNING','#936000','ERROR','#b4232b','CONFLICT','#b4232b','#68767e'],'circle-stroke-color':'#fff','circle-stroke-width':2}});setReady(true);});
  m.on('error',()=>setFailed(true));const resize=new ResizeObserver(()=>m.resize());resize.observe(container.current);return()=>{resize.disconnect();map.current=null;m.remove();};
 },[]);
 useEffect(()=>{const m=map.current;if(!m||!ready)return;const valid=rows.filter(r=>typeof r.latitude==='number'&&typeof r.longitude==='number'&&Number.isFinite(r.latitude)&&Number.isFinite(r.longitude)&&Math.abs(r.latitude)<=90&&Math.abs(r.longitude)<=180);
  (m.getSource('import') as GeoJSONSource).setData({type:'FeatureCollection',features:valid.map(r=>({type:'Feature',properties:{state:r.warnings?.length?'WARNING':r.action},geometry:{type:'Point',coordinates:[r.longitude!,r.latitude!]}}))});
  if(valid.length){let west=180,east=-180,south=90,north=-90;for(const r of valid){west=Math.min(west,r.longitude!);east=Math.max(east,r.longitude!);south=Math.min(south,r.latitude!);north=Math.max(north,r.latitude!);}m.fitBounds([[west,south],[east,north]],{padding:40,maxZoom:16,duration:0});}
 },[rows,ready]);
 return <section><h3>{t.map}</h3><div className="web-map" ref={container} aria-label={t.map}/>{failed&&<p role="status">{t.mapMissing}</p>}<p>{['CREATE','UPDATE','WARNING','ERROR','CONFLICT'].map(k=>t.codes[k]).join(' · ')}</p></section>;
}
