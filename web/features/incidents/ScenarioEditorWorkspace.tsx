'use client';
import {useState} from 'react';
import dynamic from 'next/dynamic';
import type {Locale} from '../../lib/i18n';
import type {Definition,Template} from '../../lib/operational/templates';
import type {EventPlan} from '../../lib/operational/scenarioEvents';
import type {HazardPlan} from '../../lib/operational/hazards';
import {scenarioReadiness,type EditorSection} from '../../lib/operational/scenarioReadiness';
import {workflowText} from '../../lib/operational/workflowMessages';
import {templateText} from '../../lib/operational/templateMessages';
import {ScenarioEditorContext} from './ScenarioEditorContext';
import {TemplateEditor} from './TemplateEditor';
import {EventPlanEditor} from './EventPlanEditor';
import {HazardPlanEditor} from './HazardPlanEditor';
const TemplateMap=dynamic(()=>import('./TemplateMap'),{ssr:false});
export function ScenarioEditorWorkspace({locale,value,draft,events,hazards,onDraft,onEvents,onHazards,disabled}:{locale:Locale;value:Template;draft:Definition;events:EventPlan;hazards:HazardPlan;onDraft:(d:Definition)=>void;onEvents:(p:EventPlan)=>void;onHazards:(p:HazardPlan)=>void;disabled:boolean}){
 const [section,setSection]=useState<EditorSection>('overview'),[selected,setSelected]=useState('center'),w=workflowText(locale),t=templateText(locale);
 const select=(next:EditorSection,id:string)=>{setSection(next);setSelected(id);};
 const readonly=disabled||value.builtin||value.archived||value.state==='PUBLISHED',issues=scenarioReadiness(draft,events,hazards);
 return <ScenarioEditorContext.Provider value={{definition:draft,events,hazards,selected,select}}>
 <nav className="actions scenario-sections" aria-label={t('configuration')}>{(['overview','area','units','objects','hazards','events','settings','review'] as EditorSection[]).map(s=><button type="button" key={s} aria-current={s===section?'step':undefined} onClick={()=>setSection(s)}>{w(s)}</button>)}</nav>
 {['overview','area','units','objects','settings'].includes(section)&&<TemplateEditor locale={locale} value={value} draft={draft} onChange={onDraft} disabled={readonly} section={section}/>}
 {section==='events'&&<EventPlanEditor locale={locale} definition={draft} plan={events} onChange={onEvents} disabled={readonly}/>}
 {section==='hazards'&&<HazardPlanEditor locale={locale} definition={draft} events={events} plan={hazards} onChange={onHazards} disabled={readonly}/>}
 {section==='review'&&<section className="admin-card"><h3>{w('review')}</h3><p>{draft.metadata.title} · {t('version')} {value.version} · {t('duration')}: {draft.metadata.duration_minutes}</p>
 <p>{w('units')}: {draft.virtual_units.length} · {w('objects')}: {draft.initial_objects.length} · {w('hazards')}: {hazards.models.filter(m=>m.enabled).length} · {w('events')}: {events.events.length}</p>
 <p>{t('setupHelp')}</p>{!issues.length?<p>{w('ready')}</p>:<ul>{issues.map(i=><li key={i.section+i.code}><button type="button" onClick={()=>setSection(i.section)}>{w(i.section)}: {t(i.code)}</button></li>)}</ul>}
 <TemplateMap locale={locale} definition={draft} selected={selected} editable={false} placing={false} vertices={[]} onSelect={id=>select('area',id)} onMove={()=>{}} onPoint={()=>{}}/>
 </section>}
 </ScenarioEditorContext.Provider>;
}
