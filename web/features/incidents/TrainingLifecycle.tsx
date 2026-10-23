'use client';
import type {Locale} from '../../lib/i18n';
import type {Incident,Mutation} from '../../lib/incidents/model';
import {workflowText} from '../../lib/operational/workflowMessages';
import {incidentText} from '../../lib/incidents/messages';
import {simulationText} from '../../lib/operational/simulationMessages';
import type {Initialization} from '../../lib/operational/templates';
import {useIncidentLive} from './IncidentLiveProvider';
import {useCommandMap} from './CommandMapProvider';
import {useSimulation} from './SimulationProvider';
import {useAutonomousSimulation} from './AutonomousSimulationProvider';
import {useScenarioEvents} from './ScenarioEvents';
import {useSimulationHazards} from './SimulationHazards';
export function TrainingLifecycle({locale,incident,disabled,onAction,initialization}:{locale:Locale;incident:Incident;disabled:boolean;onAction:(m:Mutation)=>void;initialization?:Initialization|null}){
 const live=useIncidentLive(),routes=useCommandMap(),sim=useSimulation(),agents=useAutonomousSimulation(),events=useScenarioEvents(),hazards=useSimulationHazards(),w=workflowText(locale),t=incidentText(locale),st=simulationText(locale);
 const s=sim?.data?.scenario;
 return <section className="admin-card"><h3>{w('lifecycle')}</h3>
 <p>{w('incidentStatus')}: {t(incident.status)} · {w('simStatus')}: {s?st(s.status):'—'}</p>
 <p role="status">{w('next')}: {w(['CLOSED','CANCELLED'].includes(incident.status)?'history':s?.status==='FINISHED'?'closeStep':!incident.commander?.valid?'commandStep':incident.status==='DRAFT'?'activateStep':initialization!==null&&initialization?.state!=='READY'?'initializeStep':s?.status==='RUNNING'||s?.status==='PAUSED'?'simStatus':'startStep')}</p>
 {initialization&&initialization.state!=='READY'&&<p>{w('hazardUninitialized')}</p>}
 <ol><li>{incident.commander?.valid?'✓ ':''}<button onClick={()=>{const el=document.getElementById('sim-command');el?.scrollIntoView({block:'center'});el?.querySelector('details')?.setAttribute('open','');}}>{w('commandStep')}</button></li>
 <li>{['ACTIVE','STABILIZED','CLOSED'].includes(incident.status)?'✓ ':''}{w('activateStep')}</li>{initialization!==null&&<li>{initialization?.state==='READY'?'✓ ':''}{w('initializeStep')}</li>}<li>{s&&s.status!=='DRAFT'?'✓ ':''}{w('startStep')}</li></ol>
 {agents?.data&&<dl className="command-route-facts"><dt>{w('clock')}</dt><dd>{Math.floor(agents.data.clock.seconds)} s · {agents.data.clock.scale}×</dd>
 <dt>{st('positions')}</dt><dd>{agents.data.counts.total} · {agents.data.counts.moving} →</dd>
 <dt>{w('updated')}</dt><dd>{agents.data.clock.last_runner_at?new Date(agents.data.clock.last_runner_at).toLocaleString(locale):'—'}</dd></dl>}
 {hazards?.data&&<p>{w('hazards')}: {hazards.data.models.filter(m=>m.enabled).length} · {w('events')}: {events?.data?.events.filter(e=>['PLANNED','BLOCKED','RETRYABLE_FAILURE'].includes(e.state)).length??'—'}</p>}
 <p>{w('navigationJobs')}: {agents?.data?.automation.jobs.length??'—'}{agents?.data?.automation.more?' +':''}</p><p>{w('lastRefresh')}: {live?.lastSuccess?new Date(live.lastSuccess).toLocaleString(locale):'—'} · {routes?.data?.observedAt?new Date(routes.data.observedAt).toLocaleString(locale):'—'}</p>
 {s?.status==='FINISHED'&&<p className="admin-notice">{w('closeStep')} <button onClick={()=>document.getElementById('sim-resources')?.scrollIntoView({block:'start'})}>{w('resources')}</button></p>}
 <div className="actions">{(['activate','stabilize','reactivate','close','cancel'] as const).filter(action=>incident.actions[action]).map(action=><button key={action} disabled={disabled} onClick={()=>onAction(action)}>{t(action)}</button>)}</div>
 </section>;
}
