'use client';
import {createContext,useContext,type MutableRefObject} from 'react';
import type {Definition} from '../../lib/operational/templates';
import type {EventPlan} from '../../lib/operational/scenarioEvents';
import type {HazardPlan} from '../../lib/operational/hazards';
import type {EditorSection} from '../../lib/operational/scenarioReadiness';
export const ScenarioEditorContext=createContext<{definition:Definition;events:EventPlan;hazards:HazardPlan;selected:string;viewport:MutableRefObject<{center:[number,number];zoom:number;bearing:number;pitch:number}|null>;select:(section:EditorSection,id:string)=>void}|null>(null);
export const useScenarioEditor=()=>useContext(ScenarioEditorContext);
