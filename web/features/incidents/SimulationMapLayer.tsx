'use client';
import {useEffect,useMemo,useRef,useState} from 'react';
import type {Map,GeoJSONSource} from 'maplibre-gl';
import type {Locale} from '../../lib/i18n';
import {validPosition} from '../../lib/operational/target';
import {recipientKey,type RtsRecipient} from '../../lib/operational/rts';
import {simulationText} from '../../lib/operational/simulationMessages';
import {useSimulation,SimulationBanner} from './SimulationProvider';
import {useAutonomousSimulation} from './AutonomousSimulationProvider';
import {agentText} from '../../lib/operational/agentMessages';
import {MapOverlaySlot} from './workspace';
import {useCommandMap} from './CommandMapProvider';
import {pointAtProgress} from '../../lib/operational/commandMap';
import {useIncidentLive} from './IncidentLiveProvider';
import {commandMapText} from '../../lib/operational/commandMapMessages';
import {useRtsSession} from './rtsSession';
import type {RecipientPositionLayer} from './RtsMapInteraction';
const empty={type:'FeatureCollection' as const,features:[]};
export function useSimulationPositionLayer():RecipientPositionLayer|null{
 const sim=useSimulation(),s=sim?.data?.scenario,ids=useRef(new globalThis.Map<string,string>());
 const positions=sim?.sample?.positions??sim?.data?.positions;
 return useMemo(()=>{
  if(!sim?.data?.enabled||!s||s.status==='FINISHED'||sim?.sample?.status==='FINISHED')return null;
  const recipients=new globalThis.Map<string,RtsRecipient>();
  for(const p of positions??[]){
   if(p.incident_id!==s.incident_id||p.scenario_id!==s.id||p.source!=='SIMULATED'||!validPosition([p.longitude,p.latitude]))continue;
   const recipient:RtsRecipient={id:p.incident_unit_id,type:'INCIDENT_UNIT',name:'SIM · '+p.callsign,organization_id:p.organization_id,organization_name:p.organization_name,sector_id:p.sector_id,
    assignmentId:ids.current.get(p.incident_unit_id)??(()=>{const id=crypto.randomUUID();ids.current.set(p.incident_unit_id,id);return id;})(),eligibility:p.can_command?'ELIGIBLE':'UNAVAILABLE',status:p.deployment_status};
   recipients.set(recipientKey(recipient),recipient);
  }
  return {id:'simulation-units-point',origin:'SIMULATED',scenarioId:s.id,incidentId:s.incident_id,recipients};
 },[sim?.data?.enabled,s,positions,sim?.sample?.status]);
}
export function SimulationMapLayer({map,locale}:{map:Map;locale:Locale}){
 const sim=useSimulation(),agents=useAutonomousSimulation(),rts=useRtsSession(),t=simulationText(locale),at=agentText(locale),s=sim?.data?.scenario;
 const command=useCommandMap(),live=useIncidentLive(),ct=commandMapText(locale),[smooth,setSmooth]=useState(true);
 const positions=sim?.sample?.positions??sim?.data?.positions;
 const confirmed=useRef(new globalThis.Map<string,{run:string;route:string;scenario:string;status:string;progress:number;sample:string}>());
 const sourceText=useRef('');
 const stale=!!sim?.sampleStale||!!live&&['STALE','OFFLINE','ACCESS_LOST'].includes(live.status);
 const oldest=positions?.length?Math.min(...positions.map(p=>Date.parse(p.observed_at))):null;
 const visible=!!sim?.data?.enabled&&!!s&&s.status!=='FINISHED'&&sim?.sample?.status!=='FINISHED'&&!rts.blocked&&live?.status!=='ACCESS_LOST';
 useEffect(()=>{
  if(!visible)return;
  const before=map.getStyle().layers.find(l=>l.id.startsWith('rts-')||l.id.startsWith('cop-selection'))?.id;
  sourceText.current='';
  map.addSource('simulation-units',{type:'geojson',data:empty});
  map.addLayer({id:'simulation-units-point',source:'simulation-units',type:'circle',paint:{'circle-radius':11,'circle-color':'#fff1ca','circle-stroke-width':['case',['get','selected'],5,2],'circle-stroke-color':['case',['get','selected'],'#075f93','#74510b']}},before);
  map.addLayer({id:'simulation-units-label',source:'simulation-units',type:'symbol',layout:{'text-field':['get','label'],'text-size':12,'text-offset':[0,1.6]},paint:{'text-color':'#513805','text-halo-color':'#fff','text-halo-width':2}},before);
  return()=>{if(!map.getStyle())return;for(const id of ['simulation-units-label','simulation-units-point'])if(map.getLayer(id))map.removeLayer(id);if(map.getSource('simulation-units'))map.removeSource('simulation-units');};
 },[map,visible,s?.id]);
 useEffect(()=>{
  rts.setHasPositionLayers(visible&&!!positions?.length);
  return()=>rts.setHasPositionLayers(false);
 },[visible,positions?.length,rts.setHasPositionLayers]);
 useEffect(()=>{
  if(!visible||!s)return;
  let frame=0,lastFrame=0;
  const animations=new globalThis.Map<string,{path:import('../../lib/operational/commandMap').RoutePath;from:number;to:number}>();
  const nextConfirmed=new globalThis.Map<string,{run:string;route:string;scenario:string;status:string;progress:number;sample:string}>();
  for(const run of sim?.sample?.runs??[]){
   const p=positions?.find(p=>p.incident_unit_id===run.unit_id),row=command?.data?.rows.find(row=>row.id===run.assignment_id&&row.run?.id===run.id&&row.route?.id===run.route_id);
   const path=run.route_id?command?.data?.paths.get(run.route_id):null,old=confirmed.current.get(run.unit_id);
   if(!p||!path||!row||run.position_version!==p.version||run.confirmed===false)continue;
   const identity=s.id+':'+s.version+':'+sim?.sample?.scenario_version;
   nextConfirmed.set(run.unit_id,{run:run.id,route:run.route_id!,scenario:identity,status:run.status,progress:run.progress_m,sample:p.observed_at});
   if(smooth&&!stale&&s.status==='RUNNING'&&sim?.sample?.status==='RUNNING'&&run.status==='SIM_IN_PROGRESS'&&old?.status==='SIM_IN_PROGRESS'&&
    old.scenario===identity&&old.run===run.id&&old.route===run.route_id&&old.sample!==p.observed_at&&run.progress_m>=old.progress&&
    Date.parse(p.observed_at)-Date.parse(old.sample)<=10000&&Date.now()-Date.parse(p.observed_at)<10000&&!window.matchMedia('(prefers-reduced-motion: reduce)').matches){
    animations.set(run.unit_id,{path,from:old.progress,to:run.progress_m});
   }
  }
  confirmed.current=nextConfirmed;
  const features=(positions??[]).filter(p=>p.scenario_id===s.id&&p.incident_id===s.incident_id&&validPosition([p.longitude,p.latitude])).map(p=>({
   type:'Feature' as const,id:p.incident_unit_id,geometry:{type:'Point' as const,coordinates:[p.longitude,p.latitude]},
   properties:{id:p.incident_unit_id,recipient_id:p.incident_unit_id,recipient_type:'INCIDENT_UNIT',position_origin:'SIMULATED',scenario_id:s.id,incident_id:s.incident_id,
    selected:rts.recipients.some(r=>r.type==='INCIDENT_UNIT'&&r.id===p.incident_unit_id),label:'SIM · '+p.callsign+' · '+at(agents?.data?.signals[p.incident_unit_id]??(!Number.isFinite(Date.parse(p.observed_at))?'unknown':Date.now()-Date.parse(p.observed_at)>30000?'stalePosition':'current'))}
  }));
  const source=map.getSource('simulation-units') as GeoJSONSource|undefined;
  // 750 ms maximum, two confirmed route samples only. No extrapolation.
  const started=performance.now();
  const paint=(now:number)=>{
   if(document.visibilityState!=='visible')return;
   if(now-lastFrame<32){frame=requestAnimationFrame(paint);return;}lastFrame=now;
   const fraction=Math.min(1,(now-started)/750);
   const rendered=features.map(feature=>{
    const animation=animations.get(feature.id);
    return animation?{...feature,geometry:{type:'Point' as const,coordinates:pointAtProgress(animation.path,animation.from+(animation.to-animation.from)*fraction)}}:feature;
   });
   const data={type:'FeatureCollection' as const,features:rendered},text=JSON.stringify(data);
   if(text!==sourceText.current){sourceText.current=text;source?.setData(data);}
   if(animations.size&&fraction<1)frame=requestAnimationFrame(paint);
  };
  paint(animations.size?started:started+750);
  return()=>cancelAnimationFrame(frame);
 },[map,visible,s,positions,sim?.sample?.runs,sim?.sample?.status,sim?.sample?.scenario_version,stale,smooth,rts.recipients,locale,agents?.data?.signals,command?.data?.paths]);
 useEffect(()=>{
  if(!sim?.move)return;const canvas=map.getCanvas(),previous=canvas.style.cursor;canvas.style.cursor='crosshair';
  return()=>{canvas.style.cursor=previous;};
 },[map,!!sim?.move]);
 if(!s)return null;
 return <><MapOverlaySlot name="mapStatus"><div className="simulation-map-banner"><SimulationBanner locale={locale}/>
  {oldest!==null&&Number.isFinite(oldest)&&<small>{ct('sampleAge')}: {!stale?Math.max(0,Math.floor((Date.now()-oldest)/1000))+' s · ':''}<time dateTime={new Date(oldest).toISOString()}>{new Date(oldest).toLocaleTimeString(locale)}</time>{stale?' · '+ct('stale'):''}</small>}
  <label><input type="checkbox" checked={smooth} onChange={e=>setSmooth(e.target.checked)}/>{ct('smooth')}</label>
  </div></MapOverlaySlot>
  {sim?.move&&<MapOverlaySlot name="mapStatus"><aside className="rts-map-mode"><strong>{t('move')}</strong><p>{t('moveHelp')}</p><button onClick={sim.cancelMove}>{t('cancel')}</button></aside></MapOverlaySlot>}
 </>;
}
