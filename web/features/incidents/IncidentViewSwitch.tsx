'use client';
import {useEffect,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import {workspaceText} from '../../lib/incidents/workspaceMessages';
export type IncidentView='classic'|'command';
const preference='gasilko.incident.workspace.view.v1';
/** Browser presentation preference only; first server/client render is always classic. */
export function useIncidentView(){
 const [view,setView]=useState<IncidentView>('classic');
 useEffect(()=>{try{const value=localStorage.getItem(preference);if(value==='classic'||value==='command')setView(value);}catch{/* Storage is optional. */}},[]);
 function choose(value:IncidentView){setView(value);try{localStorage.setItem(preference,value);}catch{/* Keep this session's choice. */}}
 return {view,choose};
}
export function IncidentViewSwitch({locale,view,onChange}:{locale:Locale;view:IncidentView;onChange:(v:IncidentView)=>void}){
 const t=workspaceText(locale);
 return <div className="incident-view-switch" role="group" aria-label={t('view')}>
 {(['classic','command'] as const).map(value=><button type="button" key={value} aria-pressed={view===value} onClick={()=>onChange(value)}>{t(value)}</button>)}
 </div>;
}
