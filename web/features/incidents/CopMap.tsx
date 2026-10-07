'use client';
import {useEffect,useRef,useState} from 'react';
import {Map,NavigationControl,setWorkerUrl,type GeoJSONSource} from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import {dictionary,type Locale} from '../../lib/i18n';
import {incidentText} from '../../lib/incidents/messages';
import {geometryPositions,type Cop,type Geometry,type Position} from '../../lib/incidents/cop';

export type CopLayers={sectors:boolean;markers:boolean;zones:boolean;hydrants:boolean};
type Props={locale:Locale;cop:Cop;layers:CopLayers;drawing:Geometry['type']|null;draft:Geometry|null;vertices:Position[];onPoint:(p:Position)=>void;onSelect:(id:string)=>void};
const ids=['cop-primary','cop-sectors','cop-markers','cop-zones','cop-hydrants','cop-draft'] as const;
const features=(items:{id:string;geometry:Geometry;label:string;kind?:string;status?:string}[])=>({type:'FeatureCollection' as const,features:items.map(i=>({type:'Feature' as const,id:i.id,geometry:i.geometry,properties:{id:i.id,label:i.label,kind:i.kind??'',status:i.status??''}}))});
export default function CopMap(props:Props){
 const host=useRef<HTMLDivElement>(null),map=useRef<Map|null>(null),latest=useRef(props),fitted=useRef(false);
 latest.current=props;const [ready,setReady]=useState(false),[error,setError]=useState(false),[attempt,setAttempt]=useState(0);
 const t=incidentText(props.locale),common=dictionary(props.locale),style=process.env.NEXT_PUBLIC_MAP_STYLE_URL;
 useEffect(()=>{
  if(!host.current||!style)return;setReady(false);setError(false);fitted.current=false;
  setWorkerUrl('/maplibre/maplibre-gl-worker.mjs');
  let m:Map;try{m=new Map({container:host.current,style,center:[14.8,46.1],zoom:7,renderWorldCopies:false,
   locale:{'NavigationControl.ZoomIn':common.wZoomIn,'NavigationControl.ZoomOut':common.wZoomOut,'NavigationControl.ResetBearing':common.wResetBearing,'AttributionControl.ToggleAttribution':common.wAttribution}});
  }catch{setError(true);return;}
  map.current=m;m.addControl(new NavigationControl(),'top-right');
  m.on('load',()=>{
   for(const id of ids)m.addSource(id,{type:'geojson',data:features([])});
   for(const source of ['cop-sectors','cop-zones','cop-draft']){
    m.addLayer({id:source+'-fill',type:'fill',source,filter:['==',['geometry-type'],'Polygon'],paint:{'fill-color':source==='cop-sectors'?'#1865a0':source==='cop-draft'?'#802ea5':'#b45200','fill-opacity':0.18}});
    m.addLayer({id:source+'-line',type:'line',source,filter:['!=',['geometry-type'],'Point'],paint:{'line-color':source==='cop-sectors'?'#1865a0':source==='cop-draft'?'#802ea5':'#b45200','line-width':3,...(source==='cop-draft'?{'line-dasharray':[2,2]}:{})}});
   }
   for(const source of ['cop-primary','cop-markers','cop-zones','cop-hydrants','cop-draft']){
    m.addLayer({id:source+'-point',type:'circle',source,filter:['==',['geometry-type'],'Point'],paint:{'circle-radius':source==='cop-primary'?12:9,'circle-color':
     source==='cop-hydrants'?['match',['get','status'],'WORKING','#16803c','NOT_WORKING','#bb242b','NEEDS_INSPECTION','#f3ad18','#68767e']:
      source==='cop-primary'?'#a9232e':source==='cop-draft'?'#802ea5':['match',['get','kind'],'COMMAND_POST','#a9232e','WATER_SOURCE','#1865a0','HAZARD','#b45200','#263238'],
     'circle-stroke-color':'#fff','circle-stroke-width':2}});
   }
   for(const source of ids.filter(s=>s!=='cop-draft')){
    m.addLayer({id:source+'-label',type:'symbol',source,layout:{'text-field':['get','label'],'text-size':12,'text-offset':[0,1.5]},paint:{'text-color':'#20252a','text-halo-color':'#fff','text-halo-width':2}});
   }
   m.on('click',event=>{
    if(latest.current.drawing){latest.current.onPoint([event.lngLat.lng,event.lngLat.lat]);return;}
    const clickable=m.getStyle().layers.filter(l=>l.id.startsWith('cop-')&&!l.id.startsWith('cop-draft')).map(l=>l.id);
    const hits=m.queryRenderedFeatures(event.point,{layers:clickable});const id=hits.find(f=>typeof f.properties?.id==='string')?.properties?.id;
    if(typeof id==='string')latest.current.onSelect(id);
   });
   setReady(true);
  });
  m.on('error',()=>setError(true));
  const observer=new ResizeObserver(()=>m.resize());observer.observe(host.current);
  return()=>{observer.disconnect();map.current=null;m.remove();};
 },[style,attempt]);
 useEffect(()=>{
  const m=map.current;if(!ready||!m)return;const t=incidentText(props.locale),c=props.cop;
  const put=(id:string,items:Parameters<typeof features>[0])=>(m.getSource(id) as GeoJSONSource|undefined)?.setData(features(items));
  const primary:Position|null=c.incident.longitude!==null&&c.incident.latitude!==null?[c.incident.longitude,c.incident.latitude]:null;
  put('cop-primary',primary?[{id:'primary',geometry:{type:'Point',coordinates:primary},label:t('copLocation')}]:[]);
  put('cop-sectors',c.sectors.flatMap(s=>s.geometry?[{id:s.id,geometry:s.geometry,label:s.code+' · '+s.name}]:[]));
  const objects=c.objects.map(o=>({id:o.id,geometry:o.geometry,label:t(o.kind)+' · '+o.label,kind:o.kind}));
  put('cop-markers',objects.filter(o=>!['HAZARD','PERIMETER'].includes(o.kind)));
  put('cop-zones',objects.filter(o=>['HAZARD','PERIMETER'].includes(o.kind)));
  put('cop-hydrants',c.links.flatMap(l=>{const h=l.hydrant;return h&&h.longitude!==null&&h.latitude!==null&&Number.isFinite(h.longitude)&&Number.isFinite(h.latitude)&&Math.abs(h.longitude)<=180&&Math.abs(h.latitude)<=90?
   [{id:l.id,geometry:{type:'Point' as const,coordinates:[h.longitude,h.latitude] as Position},label:h.code??t('copPendingCode'),status:h.status}]:[];}));
  if(!fitted.current){
   if(primary){m.jumpTo({center:primary,zoom:14});fitted.current=true;}
   else {const points=[...c.sectors.flatMap(s=>s.geometry?geometryPositions(s.geometry):[]),...c.objects.flatMap(o=>geometryPositions(o.geometry)),
    ...c.links.flatMap(l=>l.hydrant?.longitude!=null&&l.hydrant.latitude!=null?[[l.hydrant.longitude,l.hydrant.latitude] as Position]:[])];
    if(points.length){let west=180,east=-180,south=90,north=-90;for(const [x,y]of points){west=Math.min(west,x);east=Math.max(east,x);south=Math.min(south,y);north=Math.max(north,y);}m.fitBounds([[west,south],[east,north]],{padding:45,maxZoom:15,duration:0});}
    fitted.current=true;
   }
  }
 },[props.cop,props.locale,ready]);
 useEffect(()=>{
  const m=map.current;if(!m||!ready)return;
  for(const [group,visible]of Object.entries(props.layers)){
   const prefix='cop-'+group;
   for(const layer of m.getStyle().layers)if(layer.id.startsWith(prefix+'-'))m.setLayoutProperty(layer.id,'visibility',visible?'visible':'none');
  }
 },[props.layers,ready]);
 useEffect(()=>{
  const m=map.current;if(!m||!ready)return;
  m.getCanvas().style.cursor=props.drawing?'crosshair':'';
  const drawingGeometry:Geometry|null=props.vertices.length>1?{type:'LineString',coordinates:props.vertices}:props.vertices.length===1?{type:'Point',coordinates:props.vertices[0]}:props.draft;
  (m.getSource('cop-draft') as GeoJSONSource|undefined)?.setData(features(drawingGeometry?[{id:'draft',geometry:drawingGeometry,label:''}]:[]));
 },[props.draft,props.vertices,props.drawing,ready]);
 return <div className="web-map-wrap"><div className="web-map" ref={host} aria-label={t('copTitle')}/>
  {(!style||!ready||error)&&<div className="web-map-notice" role="status">{!style?common.wMapUnconfigured:error?common.wMapError:common.loading}
   {error&&<button type="button" onClick={()=>setAttempt(n=>n+1)}>{common.hRetry}</button>}</div>}
 </div>;
}
