'use client';
import {useState} from 'react';
import type {Locale} from '../../lib/i18n';
import {simulationInitialPosition,type SimulationPosition,type SimulationAction} from '../../lib/operational/simulation';
import {simulationText} from '../../lib/operational/simulationMessages';
import {useSimulation,SimulationBanner} from './SimulationProvider';
import {useWorkspace,WorkspaceSlot,WorkspaceSection} from './workspace';

export function SimulationPanel({locale}:{locale:Locale}){
 const sim=useSimulation(),workspace=useWorkspace(),t=simulationText(locale);
 const [count,setCount]=useState(3),[chosen,setChosen]=useState<string[]>([]),[local,setLocal]=useState('');
 if(!sim)return null;
 const data=sim.data,s=data?.scenario;
 if(!s)return sim.error?<WorkspaceSlot name="operational"><p role="alert">{t(sim.error)}</p><button onClick={sim.refresh}>{t('refresh')}</button></WorkspaceSlot>:null;
 const selected=workspace?.selected?.kind==='INCIDENT_UNIT'?workspace.selected.id:local;
 const position=data.positions.find(p=>p.incident_unit_id===selected);
 const locked=sim.busy||sim.pending||!!sim.proposal||!data.can_control||!data.enabled;
 const setup=['DRAFT','PAUSED'].includes(s.status);
 const preview=Array.from({length:count},(_,i)=>simulationInitialPosition(s.seed,s.template,[s.center_longitude,s.center_latitude],s.radius_m,(data.next_ordinal??1)+i));
 const actions:SimulationAction[]=s.status==='DRAFT'?['START','RESET','FINISH']:s.status==='RUNNING'?['PAUSE','RESET','FINISH']:s.status==='PAUSED'?['RESUME','RESET','FINISH']:[];
 return <>
  <WorkspaceSlot name="operational"><WorkspaceSection title={t('title')} open>
   <SimulationBanner locale={locale}/><h3>{s.title}</h3><p>{t(s.template)} · {t(s.status)}</p>
   <p>{t('setup')}</p><p>{t('ack')}</p>
   {!data.enabled&&<p role="alert">{t('SIMULATION_DISABLED')}</p>}
   {sim.error&&<p role="alert">{t(sim.error)}</p>}
   <button disabled={sim.busy} onClick={sim.refresh}>{t('refresh')}</button>
   <div className="actions">{actions.map(action=><button key={action} disabled={locked} onClick={()=>sim.propose(action,{},t(action)+' · '+s.title)}>{t(action)}</button>)}</div>
   {setup&&<fieldset disabled={locked}><legend>{t('PROVISION')}</legend><p>{t('fixtures')}</p>
    <select aria-label={t('count')} value={count} onChange={e=>setCount(Number(e.target.value))}>{([3,5,10,30] as const).map((n,index)=><option key={n} value={n}>{t(['small','structure','large','stress'][index])}</option>)}</select>
    <details><summary>{t('preview')}</summary><ol>{preview.map((p,i)=><li key={i}>SIM {(data.next_ordinal??1)+i}: {p.map(v=>v.toFixed(6)).join(', ')}</li>)}</ol></details>
    <button disabled={!data.can_provision||count>(data.capacity_remaining??0)} onClick={()=>sim.propose('PROVISION',{count},t('PROVISION')+' · '+count+'\n'+preview.map(p=>p.join(', ')).join('\n'))}>{t('review')}</button>
    <details><summary>{t('candidates')}</summary>
     {data.candidates.map(u=><label key={u.id}><input type="checkbox" checked={chosen.includes(u.id)} onChange={e=>setChosen(v=>e.target.checked?[...v,u.id]:v.filter(id=>id!==u.id))}/>{u.name}</label>)}
     <button disabled={!chosen.length||chosen.some(id=>!data.candidates.some(c=>c.id===id))} onClick={()=>sim.propose('ATTACH',{unit_ids:[...chosen].sort()},t('ATTACH')+'\n'+chosen.map(id=>data.candidates.find(c=>c.id===id)?.name??id).join('\n'))}>{t('ATTACH')}</button>
    </details>
   </fieldset>}
   <h4>{t('positions')} · {data.positions.length}</h4>{!data.positions.length&&<p>{t('noUnits')}</p>}
   {data.positions.map(p=><button className="web-row simulation-unit" key={p.incident_unit_id} aria-pressed={selected===p.incident_unit_id}
    onClick={()=>{setLocal(p.incident_unit_id);workspace?.select({kind:'INCIDENT_UNIT',id:p.incident_unit_id});}}>
    <strong>SIM · {p.callsign}</strong><span>{p.organization_name}</span><small>{new Date(p.observed_at).toLocaleString(locale)} · {t(Date.now()-Date.parse(p.observed_at)>300000?'older':'current')}</small>
   </button>)}
   <p>{t('roster')}</p>
  </WorkspaceSection></WorkspaceSlot>
  {position&&<WorkspaceSlot name="selectedPane"><PositionEditor key={position.incident_unit_id} locale={locale} position={position} locked={locked} status={s.status}/></WorkspaceSlot>}
  <WorkspaceSlot name="bottom"><WorkspaceSection title={t('history')}>
   <p>{t('resetWarning')}</p>
   {data.events.map(e=><article className="web-row" key={e.id}><strong>{t(e.event_type)}</strong><p>{new Date(e.created_at).toLocaleString(locale)} · {e.sequence}</p>
    <details><summary>{t('history')}</summary><pre className="simulation-event">{JSON.stringify(e.payload,null,2)}</pre></details></article>)}
   <div className="actions"><button disabled={!sim.before} onClick={()=>sim.older(null)}>{t('first')}</button><button disabled={data.events.length<50} onClick={()=>sim.older(data.events.at(-1)?.sequence??null)}>{t('olderEvents')}</button></div>
  </WorkspaceSection></WorkspaceSlot>
 </>;
}
function PositionEditor({locale,position:p,locked,status}:{locale:Locale;position:SimulationPosition;locked:boolean;status:string}){
 const sim=useSimulation()!,t=simulationText(locale);
 const [lon,setLon]=useState(String(p.longitude)),[lat,setLat]=useState(String(p.latitude)),[heading,setHeading]=useState(String(p.heading_degrees)),[speed,setSpeed]=useState(String(p.speed_mps)),[version,setVersion]=useState(p.version);
 const payload={unit_id:p.incident_unit_id,position_version:version,longitude:Number(lon),latitude:Number(lat),heading_degrees:Number(heading),speed_mps:Number(speed)};
 const valid=[lon,lat,heading,speed].every(x=>x.trim()!==''&&Number.isFinite(Number(x)))&&Math.abs(Number(lon))<=180&&Math.abs(Number(lat))<=90&&Number(heading)>=0&&Number(heading)<360&&Number(speed)>=0&&Number(speed)<=100;
 return <section className="admin-card"><SimulationBanner locale={locale}/><h3>SIM · {p.callsign}</h3>
  <p>{t('timestamp')}: {new Date(p.observed_at).toLocaleString(locale)}</p><p>{p.longitude}, {p.latitude}</p>
  <form onSubmit={e=>{e.preventDefault();if(valid)sim.propose('SET_POSITION',payload,t('SET_POSITION')+' · '+p.callsign+'\n'+lon+', '+lat);}}>
   <fieldset disabled={locked}><legend>{t('SET_POSITION')}</legend>
    <label>{t('longitude')}<input required type="number" step="any" min={-180} max={180} value={lon} onChange={e=>setLon(e.target.value)}/></label>
    <label>{t('latitude')}<input required type="number" step="any" min={-90} max={90} value={lat} onChange={e=>setLat(e.target.value)}/></label>
    <label>{t('heading')}<input required type="number" step="any" min={0} max={359.9999} value={heading} onChange={e=>setHeading(e.target.value)}/></label>
    <label>{t('speed')}<input required type="number" step="any" min={0} max={100} value={speed} onChange={e=>setSpeed(e.target.value)}/></label>
    {version!==p.version&&<p role="alert">{t('STALE_VERSION')}</p>}
    <button type="button" onClick={()=>{setLon(String(p.longitude));setLat(String(p.latitude));setHeading(String(p.heading_degrees));setSpeed(String(p.speed_mps));setVersion(p.version);}}>{t('refresh')}</button>
    <button type="submit" disabled={!valid||!['DRAFT','RUNNING'].includes(status)||version!==p.version}>{t('review')}</button>
    <button type="button" disabled={!valid||!['DRAFT','RUNNING'].includes(status)||version!==p.version} onClick={()=>sim.startMove({unitId:p.incident_unit_id,positionVersion:version,longitude:lon,latitude:lat,heading,speed})}>{t('move')}</button>
    <button type="button" onClick={()=>sim.propose('RESET_POSITION',{unit_id:p.incident_unit_id,position_version:p.version},t('RESET_POSITION')+' · '+p.callsign)}>{t('RESET_POSITION')}</button>
    <button type="button" onClick={()=>sim.propose('REMOVE',{unit_id:p.incident_unit_id,position_version:p.version},t('REMOVE')+' · '+p.callsign)}>{t('REMOVE')}</button>
   </fieldset>
  </form>
 </section>;
}
