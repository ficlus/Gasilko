'use client';
import type {Locale} from '../../lib/i18n';
import {commandMapText} from '../../lib/operational/commandMapMessages';
import {agentText} from '../../lib/operational/agentMessages';
import {taskText} from '../../lib/operational/taskMessages';
import {navigationText} from '../../lib/operational/navigationMessages';
import {useCommandMap} from './CommandMapProvider';
import {useIncidentLive} from './IncidentLiveProvider';
import {useIncidentNavigation} from './IncidentNavigationProvider';
import {useSimulation} from './SimulationProvider';
import {simulationText} from '../../lib/operational/simulationMessages';
import {useWorkspace} from './workspace';
export function CommandMapControls({locale}:{locale:Locale}){
 const sim=useSimulation(),map=useCommandMap(),live=useIncidentLive(),t=commandMapText(locale);
 if(!map)return null;
 return <div className="command-route-controls">
 <label><input type="checkbox" checked={map.visible} onChange={e=>map.setVisible(e.target.checked)}/>{t('routes')}</label>
 {map.data?.simulation&&<strong>SIM · {t('automation')}: {t(map.data.automation?'on':'off')}{sim?.data?.scenario?' · '+simulationText(locale)(sim.data.scenario.status):''}</strong>}
 {map.error&&<span role="alert">{t('unavailable')}</span>}
 {!map.error&&!map.data&&map.state==='loading'&&<span role="status">{t('loading')}</span>}
 {map.data&&(map.state==='stale'||live&&['OFFLINE','STALE','CONNECTING'].includes(live.status))&&<span role="status">{t('stale')}</span>}
 {map.data?.removals.length? <small>{[...new Set(map.data.removals.map(r=>r.reason))].map(reason=>t('removed_'+reason)+' ('+map.data!.removals.filter(r=>r.reason===reason).length+')').join(' · ')}</small>:null}
 {map.state==='incomplete'&&<span role="status">{t('incomplete')}</span>}
 {map.state==='revoked'&&<span role="alert">{t('revoked')}</span>}
 {map.data?.limited&&<span role="status">{t('limited')}</span>}
 </div>;
}
export function CommandMapDetails({locale}:{locale:Locale}){
 const sim=useSimulation(),nav=useIncidentNavigation(),map=useCommandMap(),workspace=useWorkspace(),t=commandMapText(locale),at=agentText(locale),tt=taskText(locale),nt=navigationText(locale);
 const unit=workspace?.selected?.kind==='INCIDENT_UNIT'?workspace.selected.id:null;
 if(!unit||!map)return null;
 const data=map.data,position=(sim?.sample?.positions??sim?.data?.positions)?.find(p=>p.incident_unit_id===unit);
 const rows=data?.rows.filter(r=>r.unit_id===unit)??[];
 return <section className="command-unit-tasks" aria-live="polite"><h3>{t('tasks')}</h3>
 {position&&<p>{t('currentPosition')}: {position.latitude.toFixed(5)}, {position.longitude.toFixed(5)} · {new Date(position.observed_at).toLocaleTimeString(locale)}</p>}
 {map.state!=='complete'&&<p role="status">{t(map.state==='incomplete'?'incomplete':'stale')}</p>}
 {!data?<p role="status">{t(map.error?'unavailable':'loading')}</p>:<>
 {data.limited&&<p role="status">{t('limited')}</p>}
 {!rows.length&&!data.limited&&map.state==='complete'&&<p>{t('empty')}</p>}
 {rows.map(row=><article className="operational-card" key={row.id}>
 <h4>{row.callsign} · {locale==='de'?row.label_de:row.label_sl}</h4>
 <p>{row.title} · {tt(row.status)}</p><p>{row.target??'—'}</p>
 <strong>{row.run?t('movement'):row.navigation_state==='ACTIVE'?t('realMovement'):t('waiting')}</strong>
 {row.run&&<p>SIM · {at(row.run.status)}</p>}
 {row.automation&&<p>{t('automation')}: {at('auto_'+row.automation.state)}{row.automation.error?' · '+at(row.automation.error):''}</p>}
 {row.automation?.queued_at&&['QUEUED','RETRY','PLANNING'].includes(row.automation.state)&&<small>{t('queuedAt')}: {new Date(row.automation.queued_at).toLocaleTimeString(locale)}</small>}
 {row.automation?.error&&<button onClick={()=>workspace?.showTools()}>{t('correction')}</button>}
 {row.automation&&row.route&&!row.run&&<p>{t('routeReady')}</p>}
 {row.run&&['WAITING_TO_ACK','SIM_ACKNOWLEDGED'].includes(row.run.status)&&<p>{t('starting')}</p>}
 {row.navigation_state&&<p>{nt('title')}: {nt(row.navigation_state)}</p>}
 {row.route&&<><dl className="command-route-facts">
 <dt>{t('origin')}</dt><dd>{nt(row.route.origin_snapshot.source)} · {row.route.origin_snapshot.coordinate.join(', ')}</dd>
 <dt>{t('observed')}</dt><dd>{row.route.origin_snapshot.observed_at?new Date(row.route.origin_snapshot.observed_at).toLocaleString(locale):'—'}</dd>
 <dt>{t('target')}</dt><dd>{row.route.destination_snapshot.label??row.target??'—'} · {row.route.destination_snapshot.geometry.coordinates.join(', ')}</dd>
 <dt>{t('roadEndpoint')}</dt><dd>{row.route.snapped_destination.map(n=>n.toFixed(5)).join(', ')} · {t('snapNotice')}</dd>
 <dt>{t('original')}</dt><dd>{(row.route.distance_m/1000).toFixed(2)} km · {Math.ceil(row.route.duration_s/60)} min · {row.route.provider}</dd>
 {row.run?.route_id===row.route.id&&row.run.confirmed!==false&&<><dt>{t('progress')}</dt><dd>{(row.run.progress_m/1000).toFixed(2)} km</dd>
 <dt>{t('remaining')}</dt><dd>{(Math.max(0,row.run.length_m-row.run.progress_m)/1000).toFixed(2)} km</dd>
 {row.run.remaining_s!=null&&<><dt>{t('eta')}</dt><dd>{Math.ceil(row.run.remaining_s/60)} min</dd></>}</>}
 </dl><details><summary>{t('references')}</summary>
 <p>{t('task')}: {row.task_id}<br/>{t('assignment')}: {row.id}<br/>{t('session')}: {row.session_id}<br/>{t('route')}: {row.route.id} · {t('revision')}: {row.route.revision}</p>
 <button onClick={()=>{nav?.select(row.id);nav?.viewRoute(row.route!.id);}}>{t('originalView')}</button>
 </details>{!data.simulation&&<p>{t('noTelemetry')}</p>}
 <div className="actions"><button onClick={()=>map.focusPoint(row.route!.origin_snapshot.coordinate)}>{t('focusOrigin')}</button>
 <button onClick={()=>map.focusPoint(row.route!.destination_snapshot.geometry.coordinates)}>{t('focusTarget')}</button></div></>}
 <button onClick={()=>workspace?.select({kind:'TASK',id:row.task_id})}>{t('details')}</button>
 </article>)}</>}
 </section>;
}
