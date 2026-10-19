'use client';
import {ScenarioEventsProvider,ScenarioEventsPanel,ScenarioEventDetails} from './ScenarioEvents';
import {createContext,useContext,useState,useEffect,useRef,useId,useCallback,useMemo,type ReactNode,type CSSProperties} from 'react';
import {useSearchParams} from 'next/navigation';
import {parseEntityRef} from '../../lib/operational/entity';
import {createPortal} from 'react-dom';
import type {Locale} from '../../lib/i18n';
import {IncidentLiveProvider} from './IncidentLiveProvider';
import {CommandMapProvider} from './CommandMapProvider';
import {CommandMapControls,CommandMapDetails} from './CommandMapDetails';
import {IncidentNavigationProvider} from './IncidentNavigationProvider';
import {IncidentNavigationPanel} from './IncidentNavigationPanel';
import {AutonomousSimulationProvider} from './AutonomousSimulationProvider';
import {AutonomousSimulationPanel} from './AutonomousSimulationPanel';
import {SimulationProvider} from './SimulationProvider';
import {SimulationPanel} from './SimulationPanel';
import type {TaskRead} from '../../lib/operational/tasks';
import {RtsProvider} from './rtsSession';
import {RtsSelectionToolbar} from './RtsSelectionToolbar';
import {IncidentViewSwitch,useIncidentView,type IncidentView} from './IncidentViewSwitch';
import {workspaceText} from '../../lib/incidents/workspaceMessages';
import {useRts} from './rtsSession';
import {incidentText} from '../../lib/incidents/messages';
// Identity references only; DTOs and permissions remain owned by their domain readers.
export type SelectedEntity={kind:'INCIDENT_SECTOR'|'MAP_OBJECT'|'HYDRANT'|'INCIDENT_UNIT'|'TASK'|'ALLOCATION';id:string};
export type ContextAction={id:string;label:string;enabled:boolean;disabledReason?:string;requiresConfirmation:boolean;execute:()=>void};
// execute opens the existing domain confirmation when requiresConfirmation is true.
export function ContextActions({actions}:{actions:ContextAction[]}){
 return <div className="actions">{actions.map(a=><div key={a.id}><button type="button" disabled={!a.enabled} title={!a.enabled?a.disabledReason:undefined}
  onClick={a.execute}>{a.label}</button>{!a.enabled&&a.disabledReason&&<small>{a.disabledReason}</small>}</div>)}</div>;
}
type Workspace={setMapActions:(node:HTMLElement|null)=>void;setMapStatus:(node:HTMLElement|null)=>void;mapActions:HTMLElement|null;mapStatus:HTMLElement|null;view:IncidentView;selected:SelectedEntity|null;showTools:()=>void;showDetails:()=>void;showOperations:()=>void;select:(entity:SelectedEntity|null)=>void;operational:HTMLElement|null;selectedPane:HTMLElement|null;bottom:HTMLElement|null};
const Context=createContext<Workspace|null>(null);
export const useWorkspace=()=>useContext(Context);
export function WorkspaceSlot({name,children}:{name:'operational'|'selectedPane'|'bottom';children:ReactNode}){
 const workspace=useWorkspace();if(!workspace)return <>{children}</>;
 return workspace[name]?createPortal(children,workspace[name]):null;
}
export function MapOverlayHosts(){
 const workspace=useWorkspace();
 if(workspace?.view!=='command')return null;
 return <div className="command-map-chrome"><div className="command-map-action-zone" ref={workspace.setMapActions}/><div className="command-map-status-zone" ref={workspace.setMapStatus}/></div>;
}
export function MapOverlaySlot({name,children}:{name:'mapActions'|'mapStatus';children:ReactNode}){
 const workspace=useWorkspace();
 if(workspace?.view!=='command')return <>{children}</>;
 return workspace[name]?createPortal(children,workspace[name]):null;
}
export function WorkspaceHeaderDetails({locale,children}:{locale:Locale;children:ReactNode}){
 const workspace=useWorkspace();
 return <details className="workspace-identity-details" open={workspace?.view!=='command'}><summary>{incidentText(locale)('summary')}</summary>{children}</details>;
}
export function WorkspaceSection({title,children,open=false}:{title:string;children:ReactNode;open?:boolean}){
 return <details className="workspace-section" open={open||undefined}><summary>{title}</summary>{children}</details>;
}
export function IncidentWorkspace({locale,header,operations,secondary,children,view,onView}:{locale:Locale;header:ReactNode;operations:ReactNode;secondary:ReactNode;children:ReactNode;view:IncidentView;onView:(view:IncidentView)=>void}){
 const query=useSearchParams(),wt=workspaceText(locale),rts=useRts();
 const root=useRef<HTMLElement>(null),heading=useRef<HTMLDivElement>(null),switchHost=useRef<HTMLDivElement>(null);
 const [wide,setWide]=useState(false),[left,setLeft]=useState<boolean|null>(null),[right,setRight]=useState<boolean|null>(null);
 const [tools,setTools]=useState(false),[history,setHistory]=useState(false),[expanded,setExpanded]=useState(false);
 const [headerHeight,setHeaderHeight]=useState(0);
 const ids=useId(),command=view==='command';
 const leftOpen=!expanded&&(left??wide),rightOpen=!expanded&&(right??false),toolsOpen=!expanded&&tools,historyOpen=!expanded&&history;
 const buttons=useRef<Partial<Record<'left'|'right'|'tools'|'history',HTMLButtonElement|null>>>({});
 const close=(panel:'left'|'right'|'tools'|'history')=>{
  if(panel==='left')setLeft(false);if(panel==='right')setRight(false);if(panel==='tools')setTools(false);if(panel==='history')setHistory(false);
  buttons.current[panel]?.focus();
 };
 function toggle(panel:'left'|'right'|'tools'|'history'){
  const opening=!(panel==='left'?leftOpen:panel==='right'?rightOpen:panel==='tools'?toolsOpen:historyOpen);
  if(!wide&&opening){setLeft(false);setRight(false);setTools(false);setHistory(false);}
  if(panel==='left')setLeft(opening);
  if(panel==='right'){setRight(opening);setTools(false);}
  if(panel==='tools'){setTools(opening);setRight(false);}
  if(panel==='history')setHistory(opening);
  if(opening)requestAnimationFrame(()=>document.getElementById(ids+'-'+panel)?.querySelector<HTMLButtonElement>('.command-panel-close')?.focus());
 }
 useEffect(()=>{
  if(!command)return;
  let frame=0;
  const measure=()=>{
   cancelAnimationFrame(frame);
   frame=requestAnimationFrame(()=>{
    if(!root.current||!heading.current)return;
    // Only the heading's own size matters. Its position changes while scrolling,
    // but that must never change the map's height.
    const measuredHeight=heading.current.getBoundingClientRect().height;
    const nextWide=root.current.clientWidth>=1200;
    setHeaderHeight(current=>current===measuredHeight?current:measuredHeight);
    setWide(current=>current===nextWide?current:nextWide);
   });
  };
  const observer=new ResizeObserver(measure);
  if(root.current)observer.observe(root.current);
  if(heading.current)observer.observe(heading.current);
  measure();
  window.addEventListener('resize',measure);
  return()=>{cancelAnimationFrame(frame);observer.disconnect();window.removeEventListener('resize',measure);};
 },[command]);
 useEffect(()=>{if(!wide){setLeft(false);setRight(false);setTools(false);setHistory(false);}else setLeft(null);},[wide]);
 useEffect(()=>{if(!command)setExpanded(false);},[command]);
 useEffect(()=>{
  if(!expanded)return;
  const escape=(event:KeyboardEvent)=>{if(event.key==='Escape'&&!event.defaultPrevented&&!document.querySelector('dialog[open]')){
   setExpanded(false);switchHost.current?.querySelector<HTMLButtonElement>('[data-expand]')?.focus();
  }};
  document.addEventListener('keydown',escape);return()=>document.removeEventListener('keydown',escape);
 },[expanded]);
 const t=incidentText(locale),[selected,setSelected]=useState<SelectedEntity|null>(null);
 function fromUrl(){
  const url=new URL(window.location.href),incidentId=url.pathname.split('/').at(-1);
  const ref=parseEntityRef(url.searchParams.get('selected'),{incidentId,organizationId:url.searchParams.get('org')??undefined});
  const kind=ref?.type==='INCIDENT_MAP_OBJECT'?'MAP_OBJECT':ref?.type;
  setSelected(current=>ref&&kind&&['INCIDENT_SECTOR','MAP_OBJECT','HYDRANT','INCIDENT_UNIT','TASK','ALLOCATION'].includes(kind)?{kind:kind as SelectedEntity['kind'],id:ref.id}:!url.searchParams.has('selected')&&current?.id==='primary'?current:null);
 }
 useEffect(()=>{fromUrl();window.addEventListener('popstate',fromUrl);return()=>window.removeEventListener('popstate',fromUrl);},[query.get('selected'),query.get('org')]);
 const select=useCallback((entity:SelectedEntity|null)=>{
  setSelected(entity);const url=new URL(window.location.href);
  if(entity&&entity.id!=='primary')url.searchParams.set('selected',(entity.kind==='MAP_OBJECT'?'INCIDENT_MAP_OBJECT':entity.kind)+':'+entity.id);
  else url.searchParams.delete('selected');
  window.history.replaceState(window.history.state,'',url);
 },[]);
 useEffect(()=>{if(command&&selected&&!expanded){setRight(true);setTools(false);if(!wide){setLeft(false);setHistory(false);}}},[selected?.kind,selected?.id,command,wide]);
 useEffect(()=>{if(command&&rts?.open){setExpanded(false);setRight(true);setTools(false);if(!wide){setLeft(false);setHistory(false);}}},[command,rts?.open,wide]);
 const [mapActions,setMapActions]=useState<HTMLElement|null>(null),[mapStatus,setMapStatus]=useState<HTMLElement|null>(null);
 const [bottom,setBottom]=useState<HTMLElement|null>(null);
 const [operational,setOperational]=useState<HTMLElement|null>(null),[selectedPane,setSelectedPane]=useState<HTMLElement|null>(null);
 const showDetails=useCallback(()=>{setExpanded(false);setRight(true);setTools(false);if(!wide){setLeft(false);setHistory(false);}
  requestAnimationFrame(()=>document.getElementById(ids+'-right')?.querySelector<HTMLButtonElement>('.command-panel-close')?.focus());
 },[wide,ids]);
 const showTools=useCallback(()=>{setExpanded(false);setTools(true);setRight(false);if(!wide){setLeft(false);setHistory(false);}},[wide]);
 const showOperations=useCallback(()=>{setExpanded(false);setLeft(true);if(!wide){setRight(false);setTools(false);setHistory(false);}},[wide]);
 const context=useMemo(()=>({setMapActions,setMapStatus,mapActions,mapStatus,view,selected,select,showTools,showDetails,showOperations,operational,selectedPane,bottom}),[mapActions,mapStatus,view,selected,select,showTools,showDetails,showOperations,operational,selectedPane,bottom]);
 return <Context.Provider value={context}>
  <section ref={root} className={'incident-workspace'+(command?' command-workspace':'')+(expanded?' command-expanded':'')}
   data-wide={wide} data-left={leftOpen} data-right={rightOpen||toolsOpen}
   style={command?{
    // svh is stable while scrolling, including on mobile browsers with dynamic chrome.
    // The map should resize only when the available viewport or heading size changes.
    '--command-height':`max(180px, calc(100svh - ${headerHeight}px - 12px))`,
    '--command-header-height':headerHeight+'px'
   } as CSSProperties:undefined}>
   <div className="workspace-heading" ref={heading}>{header}
    <CommandMapControls locale={locale}/><div className="workspace-view-bar" ref={switchHost}>
     <IncidentViewSwitch locale={locale} view={view} onChange={onView}/>
     {command&&<>
      <div className="actions command-panel-toggles">
       {(['left','right','tools','history'] as const).map((panel,index)=><button type="button" key={panel} ref={node=>{buttons.current[panel]=node;}}
        disabled={expanded} aria-expanded={panel==='left'?leftOpen:panel==='right'?rightOpen:panel==='tools'?toolsOpen:historyOpen}
        aria-controls={ids+'-'+panel} aria-label={wt(['roster','context','tools','history'][index])} onClick={()=>toggle(panel)}>{wt(panel==='left'?(leftOpen?'hideLeft':'showLeft'):panel==='right'?(rightOpen?'hideRight':'showRight'):panel+'Short')}</button>)}
       <button type="button" data-expand aria-pressed={expanded} onClick={()=>{setExpanded(v=>!v);if(!expanded)heading.current?.scrollIntoView({block:'start'});}}>{wt(expanded?'exit':'expand')}</button>
      </div>
      <p className="command-selection-summary" role="status">{wt('selected')}: {rts?.recipients.length??0} · {selected?t('copSelected'):wt('empty')}{expanded?' · '+wt('focusHelp'):''}</p>
     </>}
    </div>
   </div>
   <div className="workspace-tools" id={ids+'-tools'} hidden={command&&!toolsOpen} aria-label={wt('tools')}>
    {command&&<button type="button" className="command-panel-close" onClick={()=>close('tools')}>{wt('close')}</button>}
    <RtsSelectionToolbar locale={locale}/><SimulationPanel locale={locale}/><IncidentNavigationPanel locale={locale}/><AutonomousSimulationPanel locale={locale}/>
   </div>
   <div className="workspace-grid">
    <aside className="workspace-operational" id={ids+'-left'} hidden={command&&!leftOpen} aria-label={t('workspaceOperations')}>
     {command&&<button type="button" className="command-panel-close" onClick={()=>close('left')}>{wt('hideLeft')}</button>}
     {operations}<ScenarioEventsPanel locale={locale}/><div ref={setOperational}/>
    </aside>
    <div className="workspace-map" role="region" aria-label={wt('map')}>{children}</div>
    <aside className="workspace-selected" id={ids+'-right'} hidden={command&&!rightOpen} aria-label={t('copSelected')}>
     {command&&<button type="button" className="command-panel-close" onClick={()=>close('right')}>{wt('hideRight')}</button>}
     <h3>{t('copSelected')}</h3>
     {selected?<button type="button" onClick={()=>select(null)}>{t('workspaceClear')}</button>:<p>{t('workspaceSelect')}</p>}
     <CommandMapDetails locale={locale}/><ScenarioEventDetails locale={locale}/><div ref={setSelectedPane} aria-live="polite"/>
     {command&&<p>{wt('classicHelp')}</p>}
    </aside>
   </div>
   <div className="workspace-bottom" id={ids+'-history'} hidden={command&&!historyOpen}>
    {command&&<button type="button" className="command-panel-close" onClick={()=>close('history')}>{wt('close')}</button>}
    <div ref={setBottom}/>{secondary}
   </div>
  </section>
 </Context.Provider>;
}
function WorkspaceViews({operational,...props}:{operational:boolean;locale:Locale;header:ReactNode;operations:ReactNode;secondary:ReactNode;children:ReactNode}){
 const {view,choose}=useIncidentView();
 // Operational incidents retain the exact component/portal/map identity across modes.
 // Draft/closed classic screens keep their existing non-workspace composition.
 if(operational||view==='command')return <IncidentWorkspace {...props} view={view} onView={choose}/>;
 return <><div className="workspace-heading">{props.header}<div className="workspace-view-bar"><IncidentViewSwitch locale={props.locale} view={view} onChange={choose}/></div></div>
 <SimulationPanel locale={props.locale}/><IncidentNavigationPanel locale={props.locale}/><AutonomousSimulationPanel locale={props.locale}/>{props.operations}<ScenarioEventsPanel locale={props.locale}/>{props.children}{props.secondary}</>;
}
export function IncidentLayout({operational,locked,onAccessLost,simulation,...props}:{operational:boolean;locked:boolean;onAccessLost:()=>void;simulation:{account:string;org:string;incidentId:string;refresh:number;read:TaskRead;onInventoryChanged:()=>void};locale:Locale;header:ReactNode;operations:ReactNode;secondary:ReactNode;children:ReactNode}){
 const content=<SimulationProvider key={simulation.account+':'+simulation.org+':'+simulation.incidentId} {...simulation} locale={props.locale}><IncidentNavigationProvider {...simulation} locale={props.locale}><AutonomousSimulationProvider {...simulation} locale={props.locale}><CommandMapProvider {...simulation}><ScenarioEventsProvider {...simulation}><WorkspaceViews operational={operational} {...props}/></ScenarioEventsProvider></CommandMapProvider></AutonomousSimulationProvider></IncidentNavigationProvider></SimulationProvider>;
 return <RtsProvider key={simulation.account+':'+simulation.org+':'+simulation.incidentId} enabled={operational} locked={locked} onAccessLost={onAccessLost}>{operational?<IncidentLiveProvider account={simulation.account} org={simulation.org} incidentId={simulation.incidentId} read={simulation.read} onInvalidate={simulation.onInventoryChanged} onAccessLost={onAccessLost}>{content}</IncidentLiveProvider>:content}</RtsProvider>;
}
