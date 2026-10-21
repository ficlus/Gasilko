'use client';
import {createContext,useContext} from 'react';
import type {Definition} from '../../lib/operational/templates';
import type {EventPlan} from '../../lib/operational/scenarioEvents';
import type {HazardPlan} from '../../lib/operational/hazards';
import type {EditorSection} from '../../lib/operational/scenarioReadiness';
export const ScenarioEditorContext=createContext<{definition:Definition;events:EventPlan;hazards:HazardPlan;selected:string;select:(section:EditorSection,id:string)=>void}|null>(null);
export const useScenarioEditor=()=>useContext(ScenarioEditorContext);
