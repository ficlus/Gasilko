'use client';
import {useEffect,useLayoutEffect,useMemo,useRef,useState} from 'react';
import type {Map,GeoJSONSource} from 'maplibre-gl';
import type {Locale} from '../../lib/i18n';
type Read=<T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,account?:string)=>Promise<T>;
export type VehiclePosition={vehicle:string;deployment:string;label:string;latitudeE7:number;longitudeE7:number;accuracyCm:number;
 observedAt:string;receivedAt:string;expiresAt:string;validUntil:string;source:'ANDROID_REAL_GNSS';freshness:'CURRENT'|'LAST_KNOWN'};
type Page={account:string;organization:string;incident:string;fingerprint:string;serverTime:string;positions:VehiclePosition[]};
export function useVehiclePositions(account:string,org:string,incident:string,fingerprint:string,locked:boolean,read:Read) {
 const scope=[account,org,incident,fingerprint,String(locked)].join('/');
 const key=useMemo(()=>scope+'/'+crypto.randomUUID(),[scope]),current=useRef(key);current.current=key;
 const [state,setState]=useState<{key:string;positions:VehiclePosition[];now:number;at:number;authorized:boolean}>({key:'',positions:[],now:0,at:0,authorized:false});
 const [tick,setTick]=useState(0);
 useEffect(()=>{
  let alive=true,timer:ReturnType<typeof setTimeout>|undefined,request:AbortController|undefined;
  function clear(){setState({key,positions:[],now:0,at:0,authorized:false});}
  async function load(first:boolean){
   if(!alive||locked||document.hidden||!fingerprint)return;
   request?.abort();const rc=new AbortController();request=rc;
   const timeout=setTimeout(()=>rc.abort(),8000);
   try {
    if(first){
     const c=await read<Record<string,unknown>>('incident_vehicle_location_capabilities',{p_acting_organization_id:org,p_incident_id:incident},rc.signal,account);
     if(c.account!==account||c.organization!==org||c.incident_id!==incident||c.scope_fingerprint!==fingerprint||c.mode!=='REAL'||
      !['enabled','producer_available','reader_available','policy_approved','retention_ready','device_binding_ready'].every(k=>c[k]===true))return;
    }
    const started=performance.now();
    const p=await read<Page>('vehicle_location_positions',{p_acting_organization_id:org,p_incident_id:incident},rc.signal,account);
    if(p.account!==account||p.organization!==org||p.incident!==incident||p.fingerprint!==fingerprint||!Array.isArray(p.positions)||p.positions.length>100)throw Error();
    const now=Date.parse(p.serverTime)+Math.max(0,performance.now()-started);if(!Number.isFinite(now))throw Error();
    const positions=p.positions.filter(v=>v.source==='ANDROID_REAL_GNSS'&&Number.isInteger(v.latitudeE7)&&Math.abs(v.latitudeE7)<=900000000&&
     Number.isInteger(v.longitudeE7)&&Math.abs(v.longitudeE7)<=1800000000&&Number.isInteger(v.accuracyCm)&&v.accuracyCm>0&&v.accuracyCm<=10000&&
     Number.isFinite(Date.parse(v.observedAt))&&Date.parse(v.observedAt)<=now&&Date.parse(v.validUntil)>now);
    if(alive&&!rc.signal.aborted&&current.current===key) {
     setState({key,positions,now,at:performance.now(),authorized:true});timer=setTimeout(()=>void load(false),10000);
    }
   }catch{if(alive&&current.current===key)clear();}
   finally {clearTimeout(timeout);}
  }
  function visibility(){request?.abort();if(timer)clearTimeout(timer);clear();if(!document.hidden)void load(true);}
  clear();if(!locked)void load(true);
  document.addEventListener('visibilitychange',visibility);
  return()=>{alive=false;request?.abort();if(timer)clearTimeout(timer);document.removeEventListener('visibilitychange',visibility);};
 },[key,read]);
 useEffect(()=>{if(!state.authorized)return;const timer=setInterval(()=>setTick(n=>n+1),1000);return()=>clearInterval(timer);},[state.authorized]);
 void tick;
 const now=state.now+Math.max(0,performanceNow()-state.at);
 const positions=state.key===key&&!locked?state.positions.filter(v=>Date.parse(v.validUntil)>now&&now-Date.parse(v.observedAt)<900000)
  .map(v=>({...v,freshness:(now-Date.parse(v.observedAt)<120000?'CURRENT':'LAST_KNOWN') as VehiclePosition['freshness']})):[];
 return {positions,authorized:state.key===key&&state.authorized&&!locked,now};
}
function performanceNow(){return typeof performance==='undefined'?0:performance.now();}
export function vehicleGpsText(locale:Locale,key:'title'|'current'|'stale'|'source'|'empty'){
 const sl={title:'Položaji vozil',current:'Trenutno',stale:'Zadnji znani položaj',source:'REAL · telefon voznika · prijavljen GNSS',empty:'Položaj ni na voljo'};
 const de={title:'Fahrzeugpositionen',current:'Aktuell',stale:'Letzte bekannte Position',source:'REAL · Fahrertelefon · gemeldetes GNSS',empty:'Position nicht verfügbar'};
 const en={title:'Vehicle positions',current:'Current',stale:'Last known position',source:'REAL · driver phone · reported GNSS',empty:'Position unavailable'};
 return (locale==='de'?de:locale==='sl'?sl:en)[key];
}
export function VehicleLocationLegend({locale,positions,now}:{locale:Locale;positions:VehiclePosition[];now:number}){
 return <section aria-label={vehicleGpsText(locale,'title')}><details><summary>{vehicleGpsText(locale,'title')} · {positions.length}</summary>
  <p>{vehicleGpsText(locale,'source')}</p>
  {positions.length===0?<p>{vehicleGpsText(locale,'empty')}</p>:<ul style={{maxHeight:240,overflowY:'auto'}}>{positions.map(p=><li key={p.vehicle}>
   {p.freshness==='CURRENT'?'●':'▧'} {p.label} · {vehicleGpsText(locale,p.freshness==='CURRENT'?'current':'stale')} ·
   {' '}{Math.max(0,Math.floor((now-Date.parse(p.observedAt))/1000))} s · ±{Math.ceil(p.accuracyCm/100)} m
  </li>)}</ul>}
 </details></section>;
}
export function VehicleLocationLayer({map,positions}:{map:Map;positions:VehiclePosition[]}) {
 const id='real-vehicle-locations';
 useLayoutEffect(()=>{
  map.addSource(id,{type:'geojson',data:{type:'FeatureCollection',features:[]}});
  map.addLayer({id:id+'-point',type:'circle',source:id,paint:{'circle-radius':9,'circle-color':['case',['==',['get','freshness'],'CURRENT'],'#16803c','#cb8500'],'circle-stroke-width':3,'circle-stroke-color':'#ffffff'}});
  map.addLayer({id:id+'-label',type:'symbol',source:id,layout:{'text-field':['concat',['case',['==',['get','freshness'],'CURRENT'],'● ','▧ '],['get','label']],'text-size':13,'text-offset':[0,1.6]},
   paint:{'text-color':'#152027','text-halo-color':'#ffffff','text-halo-width':2}});
  return()=>{for(const layer of [id+'-label',id+'-point'])if(map.getLayer(layer))map.removeLayer(layer);if(map.getSource(id))map.removeSource(id);};
 },[map]);
 useLayoutEffect(()=>{
  (map.getSource(id) as GeoJSONSource|undefined)?.setData({type:'FeatureCollection',features:positions.map(p=>({type:'Feature',id:p.vehicle,
   geometry:{type:'Point',coordinates:[p.longitudeE7/1e7,p.latitudeE7/1e7]},properties:{label:p.label,freshness:p.freshness}}))});
 },[map,positions]);
 return null;
}
