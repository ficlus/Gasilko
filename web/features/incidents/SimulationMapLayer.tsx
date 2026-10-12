'use client';
import {useEffect,useMemo,useRef} from 'react';
import type {Map,GeoJSONSource} from 'maplibre-gl';
import type {Locale} from '../../lib/i18n';
import {validPosition} from '../../lib/operational/target';
import {recipientKey,type RtsRecipient} from '../../lib/operational/rts';
import {simulationText} from '../../lib/operational/simulationMessages';
import {useSimulation,SimulationBanner} from './SimulationProvider';
import {useAutonomousSimulation} from './AutonomousSimulationProvider';
import {agentText} from '../../lib/operational/agentMessages';
import {useRtsSession} from './rtsSession';
import type {RecipientPositionLayer} from './RtsMapInteraction';
const empty={type:'FeatureCollection' as const,features:[]};
export function useSimulationPositionLayer():RecipientPositionLayer|null{
 const sim=useSimulation(),s=sim?.data?.scenario;
 return useMemo(()=>{
  if(!sim?.data?.enabled||!s||s.status==='FINISHED')return null;
  const recipients=new globalThis.Map<string,RtsRecipient>();
  for(const p of sim.data.positions){
   if(p.incident_id!==s.incident_id||p.scenario_id!==s.id||p.source!=='SIMULATED'||!validPosition([p.longitude,p.latitude]))continue;
   const recipient:RtsRecipient={id:p.incident_unit_id,type:'INCIDENT_UNIT',name:'SIM · '+p.callsign,organization_id:p.organization_id,organization_name:p.organization_name,sector_id:p.sector_id,
    assignmentId:crypto.randomUUID(),eligibility:p.can_command?'ELIGIBLE':'UNAVAILABLE',status:p.deployment_status};
   recipients.set(recipientKey(recipient),recipient);
  }
  return {id:'simulation-units-point',origin:'SIMULATED',scenarioId:s.id,incidentId:s.incident_id,recipients};
 },[sim?.data]);
}
export function SimulationMapLayer({map,locale}:{map:Map;locale:Locale}){
 const sim=useSimulation(),agents=useAutonomousSimulation(),rts=useRtsSession(),t=simulationText(locale),at=agentText(locale),s=sim?.data?.scenario;
 const previous=useRef<globalThis.Map<string,{coordinate:number[];version:string}>>(new globalThis.Map());
 const visible=!!sim?.data?.enabled&&!!s&&s.status!=='FINISHED';
 useEffect(()=>{
  if(!visible)return;
  const before=map.getStyle().layers.find(l=>l.id.startsWith('rts-')||l.id.startsWith('cop-selection'))?.id;
  map.addSource('simulation-units',{type:'geojson',data:empty});
  map.addLayer({id:'simulation-units-point',source:'simulation-units',type:'circle',paint:{'circle-radius':11,'circle-color':'#fff1ca','circle-stroke-width':['case',['get','selected'],5,2],'circle-stroke-color':['case',['get','selected'],'#075f93','#74510b']}},before);
  map.addLayer({id:'simulation-units-label',source:'simulation-units',type:'symbol',layout:{'text-field':['get','label'],'text-size':12,'text-offset':[0,1.6]},paint:{'text-color':'#513805','text-halo-color':'#fff','text-halo-width':2}},before);
  return()=>{if(!map.getStyle())return;for(const id of ['simulation-units-label','simulation-units-point'])if(map.getLayer(id))map.removeLayer(id);if(map.getSource('simulation-units'))map.removeSource('simulation-units');};
 },[map,visible,s?.id]);
 useEffect(()=>{
  rts.setHasPositionLayers(visible&&!!sim?.data?.positions.length);
  return()=>rts.setHasPositionLayers(false);
 },[visible,sim?.data?.positions.length,rts.setHasPositionLayers]);
 useEffect(()=>{
  if(!visible||!s)return;
  const features=(sim?.data?.positions??[]).filter(p=>p.scenario_id===s.id&&p.incident_id===s.incident_id&&validPosition([p.longitude,p.latitude])).map(p=>({
   type:'Feature' as const,id:p.incident_unit_id,geometry:{type:'Point' as const,coordinates:[p.longitude,p.latitude]},
   properties:{id:p.incident_unit_id,recipient_id:p.incident_unit_id,recipient_type:'INCIDENT_UNIT',position_origin:'SIMULATED',scenario_id:s.id,incident_id:s.incident_id,
    selected:rts.recipients.some(r=>r.type==='INCIDENT_UNIT'&&r.id===p.incident_unit_id),label:'SIM · '+p.callsign+' · '+at(agents?.data?.signals[p.incident_unit_id]??(!Number.isFinite(Date.parse(p.observed_at))?'unknown':Date.now()-Date.parse(p.observed_at)>30000?'stalePosition':'current'))}
  }));
  const source=map.getSource('simulation-units') as GeoJSONSource|undefined;
  const old=previous.current,next=new globalThis.Map<string,{coordinate:number[];version:string}>();
  for(const p of sim?.data?.positions??[])next.set(p.incident_unit_id,{coordinate:[p.longitude,p.latitude],version:p.version});
  previous.current=next;
  let frame=0;const start=performance.now();
  const reduced=window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const animate=(now:number)=>{
   const fraction=Math.min(1,(now-start)/800);
   source?.setData({type:'FeatureCollection',features:features.map(f=>{
    const prior=old.get(f.id),current=next.get(f.id);
    if(!prior||!current||prior.version===current.version||reduced||agents?.data?.signals[f.id]||document.visibilityState!=='visible')return f;
    const delta=((current.coordinate[0]-prior.coordinate[0]+540)%360)-180;
    const longitude=prior.coordinate[0]+delta*fraction;
    return {...f,geometry:{...f.geometry,coordinates:[longitude-360*Math.floor((longitude+180)/360),prior.coordinate[1]+(current.coordinate[1]-prior.coordinate[1])*fraction]}};
   })});
   if(fraction<1&&document.visibilityState==='visible')frame=requestAnimationFrame(animate);
  };
  frame=requestAnimationFrame(animate);
  return()=>cancelAnimationFrame(frame);
 },[map,visible,s,sim?.data?.positions,rts.recipients,locale,agents?.data?.signals]);
 useEffect(()=>{
  if(!sim?.move)return;const canvas=map.getCanvas(),previous=canvas.style.cursor;canvas.style.cursor='crosshair';
  return()=>{canvas.style.cursor=previous;};
 },[map,!!sim?.move]);
 if(!s)return null;
 return <><div className="simulation-map-banner"><SimulationBanner locale={locale}/></div>
  {sim?.move&&<aside className="rts-map-mode"><strong>{t('move')}</strong><p>{t('moveHelp')}</p><button onClick={sim.cancelMove}>{t('cancel')}</button></aside>}
 </>;
}
