'use client';
import type {Locale} from '../../lib/i18n';
import {workflowText} from '../../lib/operational/workflowMessages';
import {useSimulation} from './SimulationProvider';
import {useSimulationHazards} from './SimulationHazards';
import {useScenarioEvents} from './ScenarioEvents';
import {useCommandMap} from './CommandMapProvider';
import {hazardText} from '../../lib/operational/hazardMessages';
export function TrainingMapLayers({locale}:{locale:Locale}){
 const sim=useSimulation(),hazards=useSimulationHazards(),events=useScenarioEvents(),routes=useCommandMap(),w=workflowText(locale),h=hazardText(locale);
 if(!sim?.data?.scenario)return null;
 return <details><summary>{w('area')} · SIM</summary><div className="actions">
 <label><input type="checkbox" checked={sim.unitsVisible} onChange={e=>sim.setUnitsVisible(e.target.checked)}/>{w('units')}</label>
 {routes&&<label><input type="checkbox" checked={routes.visible} onChange={e=>routes.setVisible(e.target.checked)}/>{w('routes')}</label>}
 {events&&<label><input type="checkbox" checked={events.visible} onChange={e=>events.setVisible(e.target.checked)}/>{w('events')}</label>}
 {hazards&&(['fire','smoke','hazards'] as const).map(k=><label key={k}><input type="checkbox" checked={hazards.layers[k]} onChange={e=>hazards.setLayer(k,e.target.checked)}/>{h(k)}</label>)}
 </div><p>{w('emptyLayers')}</p>
 {hazards?.error?<p role="alert">{w('hazardUnavailable')}</p>:!hazards?.data?<p role="status">{w('hazardLoading')}</p>:<>
 {hazards.data.status==='FINISHED'&&<p>{w('hazardHistory')}</p>}
 {hazards.data.initialization_state&&hazards.data.initialization_state!=='READY'?<p>{w('hazardUninitialized')}</p>:!hazards.data.models.length&&<p>{w(hazards.instructor&&hazards.data.can_control?'hazardNone':'hazardUnrevealed')}</p>}
 {hazards.data.models.some(m=>m.error||m.lag_steps>0)&&<p>{w('hazardStale')}</p>}
 {hazards.instructor&&hazards.data.can_control&&hazards.data.models.map(m=><div key={m.id}><strong>{m.title}</strong>
 {!m.enabled&&<p>{w('hazardDisabled')}</p>}{m.revealed===false&&<p>{w('hazardHidden')}</p>}
 {m.enabled&&m.configuration&&!m.configuration.origins.some(o=>o.initial)&&<p>{w('noIgnition')}</p>}
 {m.last_scan_at&&<small>{w('updated')}: {new Date(m.last_scan_at).toLocaleString(locale)}</small>}</div>)}
 {hazards?.layers.fire&&!hazards.data?.models.some(m=>m.features.some(f=>f.properties?.kind==='FIRE'))&&<p>{w('noFire')}</p>}
 {hazards?.layers.smoke&&!hazards.data?.models.some(m=>m.features.some(f=>f.properties?.kind==='SMOKE'))&&<p>{w('noSmoke')}</p>}
 </>}
 </details>;
}
