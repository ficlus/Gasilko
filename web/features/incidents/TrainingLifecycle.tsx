'use client';
import type {Locale} from '../../lib/i18n';
import type {Incident,Mutation} from '../../lib/incidents/model';
import {workflowText} from '../../lib/operational/workflowMessages';
import {incidentText} from '../../lib/incidents/messages';
import {simulationText} from '../../lib/operational/simulationMessages';
import {useSimulation} from './SimulationProvider';
import {useAutonomousSimulation} from './AutonomousSimulationProvider';
import {useScenarioEvents} from './ScenarioEvents';
import {useSimulationHazards} from './SimulationHazards';
export function TrainingLifecycle({locale,incident,disabled,onAction}:{locale:Locale;incident:Incident;disabled:boolean;onAction:(m:Mutation)=>void}){
 const sim=useSimulation(),agents=useAutonomousSimulation(),events=useScenarioEvents(),hazards=useSimulationHazards(),w=workflowText(locale),t=incidentText(locale),st=simulationText(locale);
 const s=sim?.data?.scenario;
 return <section className="admin-card"><h3>{w('lifecycle')}</h3>
 <p>{w('incidentStatus')}: {t(incident.status)} · {w('simStatus')}: {s?st(s.status):'—'}</p>
 <ol><li>{incident.commander?.valid?'✓ ':''}<button onClick={()=>{const el=document.getElementById('sim-command');el?.scrollIntoView({block:'center'});el?.querySelector('details')?.setAttribute('open','');}}>{w('commandStep')}</button></li>
 <li>{incident.status!=='DRAFT'?'✓ ':''}{w('activateStep')}</li><li>{w('initializeStep')}</li><li>{w('startStep')}</li></ol>
 {agents?.data&&<dl className="command-route-facts"><dt>{st('clock')}</dt><dd>{Math.floor(agents.data.clock.seconds)} s · {agents.data.clock.scale}×</dd>
 <dt>{st('positions')}</dt><dd>{agents.data.counts.total} · {agents.data.counts.moving} →</dd>
 <dt>{w('updated')}</dt><dd>{agents.data.clock.last_runner_at?new Date(agents.data.clock.last_runner_at).toLocaleString(locale):'—'}</dd></dl>}
 {hazards?.data&&<p>{w('hazards')}: {hazards.data.models.filter(m=>m.enabled).length} · {w('events')}: {events?.data?.events.filter(e=>['PLANNED','BLOCKED','RETRYABLE_FAILURE'].includes(e.state)).length??'—'}</p>}
 {s?.status==='FINISHED'&&<p className="admin-notice">{w('closeStep')}</p>}
 <div className="actions">{(['activate','stabilize','close','cancel'] as const).filter(action=>incident.actions[action]).map(action=><button key={action} disabled={disabled} onClick={()=>onAction(action)}>{t(action)}</button>)}</div>
 </section>;
}
