'use client';
import {createContext,useContext,useState,useEffect,type ReactNode} from 'react';
import {useSearchParams} from 'next/navigation';
import {parseEntityRef} from '../../lib/operational/entity';
import {createPortal} from 'react-dom';
import type {Locale} from '../../lib/i18n';
import {RtsProvider} from './rtsSession';
import {RtsSelectionToolbar} from './RtsSelectionToolbar';
import {incidentText} from '../../lib/incidents/messages';

// Identity references only; DTOs and permissions remain owned by their domain readers.
export type SelectedEntity={kind:'INCIDENT_SECTOR'|'MAP_OBJECT'|'HYDRANT'|'INCIDENT_UNIT'|'TASK'|'ALLOCATION';id:string};
export type ContextAction={id:string;label:string;enabled:boolean;disabledReason?:string;requiresConfirmation:boolean;execute:()=>void};
// execute opens the existing domain confirmation when requiresConfirmation is true.
export function ContextActions({actions}:{actions:ContextAction[]}){
 return <div className="actions">{actions.map(a=><div key={a.id}><button type="button" disabled={!a.enabled} title={!a.enabled?a.disabledReason:undefined}
  onClick={a.execute}>{a.label}</button>{!a.enabled&&a.disabledReason&&<small>{a.disabledReason}</small>}</div>)}</div>;
}
type Workspace={selected:SelectedEntity|null;select:(entity:SelectedEntity|null)=>void;operational:HTMLElement|null;selectedPane:HTMLElement|null;bottom:HTMLElement|null};
const Context=createContext<Workspace|null>(null);
export const useWorkspace=()=>useContext(Context);
export function WorkspaceSlot({name,children}:{name:'operational'|'selectedPane'|'bottom';children:ReactNode}){
 const workspace=useWorkspace();if(!workspace)return <>{children}</>;
 return workspace[name]?createPortal(children,workspace[name]):null;
}
export function WorkspaceSection({title,children,open=false}:{title:string;children:ReactNode;open?:boolean}){
 return <details className="workspace-section" open={open||undefined}><summary>{title}</summary>{children}</details>;
}
export function IncidentWorkspace({locale,header,operations,secondary,children}:{locale:Locale;header:ReactNode;operations:ReactNode;secondary:ReactNode;children:ReactNode}){
 const query=useSearchParams();
 const t=incidentText(locale),[selected,setSelected]=useState<SelectedEntity|null>(null);
 function fromUrl(){
  const url=new URL(window.location.href),incidentId=url.pathname.split('/').at(-1);
  const ref=parseEntityRef(url.searchParams.get('selected'),{incidentId,organizationId:url.searchParams.get('org')??undefined});
  const kind=ref?.type==='INCIDENT_MAP_OBJECT'?'MAP_OBJECT':ref?.type;
  setSelected(current=>ref&&kind&&['INCIDENT_SECTOR','MAP_OBJECT','HYDRANT','INCIDENT_UNIT','TASK','ALLOCATION'].includes(kind)?{kind:kind as SelectedEntity['kind'],id:ref.id}:!url.searchParams.has('selected')&&current?.id==='primary'?current:null);
 }
 useEffect(()=>{fromUrl();window.addEventListener('popstate',fromUrl);return()=>window.removeEventListener('popstate',fromUrl);},[query.get('selected'),query.get('org')]);
 function select(entity:SelectedEntity|null){
  setSelected(entity);const url=new URL(window.location.href);
  if(entity&&entity.id!=='primary')url.searchParams.set('selected',(entity.kind==='MAP_OBJECT'?'INCIDENT_MAP_OBJECT':entity.kind)+':'+entity.id);
  else url.searchParams.delete('selected');
  window.history.replaceState(window.history.state,'',url);
 }
 const [bottom,setBottom]=useState<HTMLElement|null>(null);
 const [operational,setOperational]=useState<HTMLElement|null>(null),[selectedPane,setSelectedPane]=useState<HTMLElement|null>(null);
 return <Context.Provider value={{selected,select,operational,selectedPane,bottom}}>
  <section className="incident-workspace">{header}<RtsSelectionToolbar locale={locale}/>
   <div className="workspace-grid">
    <aside className="workspace-operational" aria-label={t('workspaceOperations')}>{operations}<div ref={setOperational}/></aside>
    <div className="workspace-map">{children}</div>
    <aside className="workspace-selected" aria-label={t('copSelected')}><h3>{t('copSelected')}</h3>
     {selected?<button type="button" onClick={()=>select(null)}>{t('workspaceClear')}</button>:<p>{t('workspaceSelect')}</p>}
     <div ref={setSelectedPane} aria-live="polite"/>
    </aside>
   </div>
   <div className="workspace-bottom"><div ref={setBottom}/>{secondary}</div>
  </section>
 </Context.Provider>;
}

export function IncidentLayout({operational,locked,onAccessLost,...props}:{operational:boolean;locked:boolean;onAccessLost:()=>void;locale:Locale;header:ReactNode;operations:ReactNode;secondary:ReactNode;children:ReactNode}){
 return <RtsProvider enabled={operational} locked={locked} onAccessLost={onAccessLost}>{operational?<IncidentWorkspace {...props}/>:<>{props.header}{props.operations}{props.children}{props.secondary}</>}</RtsProvider>;
}
