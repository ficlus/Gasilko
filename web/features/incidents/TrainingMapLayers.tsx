'use client';
import type {Locale} from '../../lib/i18n';
import {workflowText} from '../../lib/operational/workflowMessages';
import {useSimulation} from './SimulationProvider';
import {useSimulationHazards} from './SimulationHazards';
import {useScenarioEvents} from './ScenarioEvents';
import {useCommandMap} from './CommandMapProvider';
import {commandMapText} from '../../lib/operational/commandMapMessages';
import {hazardText} from '../../lib/operational/hazardMessages';
export function TrainingMapLayers({locale}:{locale:Locale}){
 const sim=useSimulation(),hazards=useSimulationHazards(),events=useScenarioEvents(),routes=useCommandMap(),w=workflowText(locale),h=hazardText(locale);
 if(!sim?.data?.scenario)return null;
 return <details><summary>{w('area')} · SIM</summary><div className="actions">
 <label><input type="checkbox" checked={sim.unitsVisible} onChange={e=>sim.setUnitsVisible(e.target.checked)}/>{w('units')}</label>
 {routes&&<label><input type="checkbox" checked={routes.visible} onChange={e=>routes.setVisible(e.target.checked)}/>{commandMapText(locale)('routes')}</label>}
 {events&&<label><input type="checkbox" checked={events.visible} onChange={e=>events.setVisible(e.target.checked)}/>{w('events')}</label>}
 {hazards&&(['fire','smoke','hazards'] as const).map(k=><label key={k}><input type="checkbox" checked={hazards.layers[k]} onChange={e=>hazards.setLayer(k,e.target.checked)}/>{h(k)}</label>)}
 </div><p>{w('emptyLayers')}</p>
 {hazards?.layers.fire&&!hazards.data?.models.some(m=>m.features.some(f=>f.properties?.kind==='FIRE'))&&<p>{w('noFire')}</p>}
 {hazards?.layers.smoke&&!hazards.data?.models.some(m=>m.features.some(f=>f.properties?.kind==='SMOKE'))&&<p>{w('noSmoke')}</p>}
 </details>;
}
