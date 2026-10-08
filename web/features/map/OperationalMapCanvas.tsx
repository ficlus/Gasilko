'use client';
import {useEffect,useRef,useState,type ReactNode} from 'react';
import {Map,NavigationControl,setWorkerUrl,type MapMouseEvent} from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import {dictionary,type Locale} from '../../lib/i18n';

export type ViewportBounds=[number,number,number,number];
export type MapPosition=[number,number];
// The order is a presentation contract, not a list of implemented domain layers.
export const operationalLayerGroups=['CONTEXT','AREAS','OPERATIONS','FUTURE_OPERATIONS','ATTENTION','SELECTION'] as const;
export type LayerGroup=typeof operationalLayerGroups[number];
export function orderOperationalLayers(map:Map,groups:Partial<Record<LayerGroup,string[]>>) {
 for(const group of operationalLayerGroups)for(const id of groups[group]??[])if(map.getLayer(id))map.moveLayer(id);
}
type Props={locale:Locale;label:string;initialPoints:MapPosition[];onBounds?:(b:ViewportBounds)=>void;
 onClick?:(map:Map,event:MapMouseEvent)=>void;children:(map:Map)=>ReactNode};
/** Infrastructure only. Domain children install/update sources and resolve clicked IDs. */
export function OperationalMapCanvas(props:Props){
 const host=useRef<HTMLDivElement>(null),latest=useRef(props),fitted=useRef(false);
 latest.current=props;
 const [map,setMap]=useState<Map|null>(null),[error,setError]=useState(false),[attempt,setAttempt]=useState(0);
 const style=process.env.NEXT_PUBLIC_MAP_STYLE_URL,t=dictionary(props.locale);
 useEffect(()=>{
  if(!host.current||!style)return;setError(false);fitted.current=false;
  setWorkerUrl('/maplibre/maplibre-gl-worker.mjs');
  const labels=dictionary(latest.current.locale);
  let m:Map;
  try{m=new Map({container:host.current,style,center:[14.8,46.1],zoom:7,renderWorldCopies:false,
   locale:{'NavigationControl.ZoomIn':labels.wZoomIn,'NavigationControl.ZoomOut':labels.wZoomOut,
    'NavigationControl.ResetBearing':labels.wResetBearing,'AttributionControl.ToggleAttribution':labels.wAttribution}});
  }catch{setError(true);return;}
  let disposed=false,loaded=false,timer:ReturnType<typeof setTimeout>|undefined;
  m.addControl(new NavigationControl(),'top-right');
  const bounds=()=>{clearTimeout(timer);timer=setTimeout(()=>{
   if(disposed)return;const b=m.getBounds();
   latest.current.onBounds?.([Math.max(-180,b.getWest()),Math.max(-90,b.getSouth()),Math.min(180,b.getEast()),Math.min(90,b.getNorth())]);
  },300);};
  m.on('load',()=>{if(!disposed){loaded=true;setMap(m);bounds();}});
  m.on('moveend',bounds);
  m.on('click',event=>{if(loaded)latest.current.onClick?.(m,event);});
  m.on('error',()=>{if(!disposed)setError(true);});
  const resize=new ResizeObserver(()=>m.resize());resize.observe(host.current);
  return()=>{disposed=true;clearTimeout(timer);resize.disconnect();m.remove();};
 },[style,attempt]);
 useEffect(()=>{
  if(!map||fitted.current)return;fitted.current=true;
  const points=props.initialPoints.filter(([x,y])=>Number.isFinite(x)&&Number.isFinite(y)&&Math.abs(x)<=180&&Math.abs(y)<=90);
  if(points.length===1)map.jumpTo({center:points[0],zoom:14});
  else if(points.length){
   let west=180,east=-180,south=90,north=-90;
   for(const [x,y]of points){west=Math.min(west,x);east=Math.max(east,x);south=Math.min(south,y);north=Math.max(north,y);}
   map.fitBounds([[west,south],[east,north]],{padding:45,maxZoom:15,duration:0});
  }
 },[map,props.initialPoints]);
 return <div className="web-map-wrap"><div className="web-map" ref={host} aria-label={props.label}/>
  {map&&props.children(map)}
  {(!style||!map||error)&&<div className="web-map-notice" role="status">{!style?t.wMapUnconfigured:error?t.wMapError:t.loading}
   {error&&<button type="button" onClick={()=>{setMap(null);setAttempt(v=>v+1);}}>{t.hRetry}</button>}</div>}
 </div>;
}
