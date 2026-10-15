'use client';
import {createContext,useCallback,useContext,useEffect,useRef,useState,type Dispatch,type ReactNode,type SetStateAction} from 'react';
import type {ActionDefinition,TaskTarget,TaskPage} from '../../lib/operational/tasks';
import type {Geometry} from '../../lib/incidents/cop';
import {recipientKey,typingTarget,type RecipientKey,type RtsMode,type RtsRecipient,type TargetPreview,type TaskIntent} from '../../lib/operational/rts';

type GroupResolver=(refs:readonly RecipientKey[],signal:AbortSignal)=>Promise<RtsRecipient[]>;
type PickOptions={toggle?:boolean;range?:boolean;list:string};
type RtsController={
 enabled:boolean;locked:boolean;blocked:boolean;agentEditing:boolean;setAgentEditing:Dispatch<SetStateAction<boolean>>;navigationEditing:boolean;setNavigationEditing:Dispatch<SetStateAction<boolean>>;externalEditing:boolean;setExternalEditing:Dispatch<SetStateAction<boolean>>;hasPositionLayers:boolean;setHasPositionLayers:Dispatch<SetStateAction<boolean>>;copEditing:boolean;setCopEditing:Dispatch<SetStateAction<boolean>>;
 mode:RtsMode;requestMode:(mode:RtsMode)=>void;cancelMode:()=>void;
 recipients:RtsRecipient[];setRecipients:Dispatch<SetStateAction<RtsRecipient[]>>;
 groups:ReadonlyMap<number,readonly RecipientKey[]>;saveGroup:(number:number)=>void;clearGroup:(number:number)=>void;recallGroup:(number:number)=>void;groupBusy:boolean;bindGroupResolver:(resolver:GroupResolver)=>()=>void;
 pick:(row:RtsRecipient,visible:readonly RtsRecipient[],options:PickOptions)=>void;
 selectMany:(rows:readonly RtsRecipient[],add:boolean)=>void;remove:(key:string)=>void;clear:()=>void;
 multiTouch:boolean;setMultiTouch:Dispatch<SetStateAction<boolean>>;merge:boolean;setMerge:Dispatch<SetStateAction<boolean>>;
 catalogError:boolean;setCatalogError:Dispatch<SetStateAction<boolean>>;
 catalog:TaskPage<ActionDefinition>|null;setCatalog:Dispatch<SetStateAction<TaskPage<ActionDefinition>|null>>;
 commandTypes:string[]|null;setCommandTypes:Dispatch<SetStateAction<string[]|null>>;
 contextLaunch:boolean;openContext:(action:ActionDefinition|null,preview:TargetPreview,recipients?:readonly RtsRecipient[])=>void;
 action:ActionDefinition|null;setAction:Dispatch<SetStateAction<ActionDefinition|null>>;
 preview:TargetPreview;setTarget:(target:TaskTarget,geometry?:Geometry|null,label?:string)=>void;
 hydrateTarget:(target:TaskTarget,geometry:Geometry,label:string)=>void;
 mapTargetKind:TaskTarget['kind'];setMapTargetKind:Dispatch<SetStateAction<TaskTarget['kind']>>;
 open:boolean;setOpen:Dispatch<SetStateAction<boolean>>;launch:number;openPalette:()=>void;
 intent:TaskIntent|null;setIntent:Dispatch<SetStateAction<TaskIntent|null>>;
 message:string;setMessage:Dispatch<SetStateAction<string>>;revoke:()=>void;
};
const RtsContext=createContext<RtsController|null>(null);
export const useRts=()=>useContext(RtsContext);
export function useRtsSession(){const value=useRts();if(!value)throw new Error('RTS workspace provider required');return value;}
const emptyTarget:TargetPreview={target:{kind:'NONE'},geometry:null,label:''};

/** Workspace-local presentation state. No mutation, authorization or persistent grouping. */
export function RtsProvider({enabled,locked,onAccessLost,children}:{enabled:boolean;locked:boolean;onAccessLost:()=>void;children:ReactNode}){
 const root=useRef<HTMLDivElement>(null),latest=useRef({enabled,locked,onAccessLost});latest.current={enabled,locked,onAccessLost};
 const [simulationEditing,setExternalEditing]=useState(false),[navigationEditing,setNavigationEditing]=useState(false);
 const [agentEditing,setAgentEditing]=useState(false);
 const externalEditing=simulationEditing||navigationEditing||agentEditing;
 const [hasPositionLayers,setHasPositionLayers]=useState(false);
 const [blocked,setBlocked]=useState(false),[copEditing,setCopEditing]=useState(false),[mode,setMode]=useState<RtsMode>('NORMAL');
 const [recipients,writeRecipients]=useState<RtsRecipient[]>([]),selectedRef=useRef<RtsRecipient[]>([]);
 const [groups,setGroups]=useState<Map<number,readonly RecipientKey[]>>(()=>new Map());
 const [groupBusy,setGroupBusy]=useState(false),groupResolver=useRef<GroupResolver|null>(null),groupRequest=useRef<AbortController|null>(null);
 const [catalogError,setCatalogError]=useState(false);
 const [catalog,setCatalog]=useState<TaskPage<ActionDefinition>|null>(null),[commandTypes,setCommandTypes]=useState<string[]|null>(null);
 const [contextLaunch,setContextLaunch]=useState(false);
 const [action,setAction]=useState<ActionDefinition|null>(null),[preview,writePreview]=useState<TargetPreview>(emptyTarget);
 const [mapTargetKind,setMapTargetKind]=useState<TaskTarget['kind']>('COORDINATE');
 const [multiTouch,setMultiTouch]=useState(false),[merge,setMerge]=useState(false);
 const [open,setOpen]=useState(false),[launch,setLaunch]=useState(0),[intent,setIntent]=useState<TaskIntent|null>(null),[message,setMessage]=useState('');
 const anchor=useRef<{list:string;key:string}|null>(null);
 const interaction=useRef({blocked,copEditing,externalEditing,hasPositionLayers,open,multiTouch,action});interaction.current={blocked,copEditing,externalEditing,hasPositionLayers,open,multiTouch,action};
 const setRecipients=useCallback<Dispatch<SetStateAction<RtsRecipient[]>>>((input)=>{
  const previous=selectedRef.current,next=typeof input==='function'?input(previous):input;
  const unique=Array.from(new Map(next.map(r=>[recipientKey(r),r])).values());
  if(unique.length>100){setMessage('selectionLimit');return;}
  selectedRef.current=unique;writeRecipients(unique);
 },[]);
 const canInteract=()=>latest.current.enabled&&!latest.current.locked&&!interaction.current.blocked&&!interaction.current.externalEditing;
 const groupAllowed=()=>canInteract()&&!interaction.current.copEditing&&!interaction.current.open&&modeRef.current==='NORMAL'&&!document.querySelector('dialog[open],[aria-modal="true"]');
 const modeRef=useRef(mode);modeRef.current=mode;
 const bindGroupResolver=useCallback((resolver:GroupResolver)=>{groupResolver.current=resolver;return()=>{groupRequest.current?.abort();groupRequest.current=null;groupResolver.current=null;setGroupBusy(false);};},[]);
 const saveGroup=useCallback((number:number)=>{if(!groupAllowed()||groupRequest.current||number<1||number>9)return;setGroups(current=>{const next=new Map(current);if(selectedRef.current.length)next.set(number,selectedRef.current.map(row=>({type:row.type,id:row.id})));else next.delete(number);return next;});},[]);
 const clearGroup=useCallback((number:number)=>{if(!groupAllowed()||groupRequest.current)return;setGroups(current=>{const next=new Map(current);next.delete(number);return next;});},[]);
 const recallGroup=useCallback((number:number)=>{
  if(!groupAllowed()||groupRequest.current)return;const refs=groups.get(number);if(!refs?.length)return;
  const resolver=groupResolver.current;if(!resolver){setMessage('readUnavailable');return;}
  const selectionAtRecall=selectedRef.current,controller=new AbortController();groupRequest.current=controller;setGroupBusy(true);setMessage('checking');
  const timeout=setTimeout(()=>{controller.abort();if(groupRequest.current===controller){groupRequest.current=null;setGroupBusy(false);setMessage('readUnavailable');}},15000);
  void resolver(refs,controller.signal).then(rows=>{
   if(controller.signal.aborted||!groupAllowed()||selectedRef.current!==selectionAtRecall)return;
   // Recall never reuses a past task assignment UUID or cached permission flags.
   setRecipients(rows.map(row=>({...row,assignmentId:selectedRef.current.find(old=>recipientKey(old)===recipientKey(row))?.assignmentId??crypto.randomUUID(),eligibility:'UNKNOWN'})));
   setMessage(rows.length===refs.length?'groupRecalled':'groupUnavailable');
  }).catch(error=>{if(!controller.signal.aborted){if(error instanceof Error&&['NOT_AUTHORIZED','EXPIRED'].includes(error.message))revoke();else setMessage('readUnavailable');}})
   .finally(()=>{clearTimeout(timeout);if(groupRequest.current===controller){groupRequest.current=null;setGroupBusy(false);}});
 },[groups,setRecipients]);
 useEffect(()=>()=>groupRequest.current?.abort(),[]);
 useEffect(()=>{if(locked||blocked||!enabled||copEditing||externalEditing||open||mode!=='NORMAL'){groupRequest.current?.abort();groupRequest.current=null;setGroupBusy(false);}},[locked,blocked,enabled,copEditing,externalEditing,open,mode]);
 const selectMany=useCallback((rows:readonly RtsRecipient[],add:boolean)=>{
  if(!canInteract())return;
  setRecipients(previous=>add?[...previous,...rows.filter(r=>!previous.some(p=>recipientKey(p)===recipientKey(r)))]:rows.map(r=>previous.find(p=>recipientKey(p)===recipientKey(r))??r));
 },[setRecipients]);
 const pick=useCallback((row:RtsRecipient,visible:readonly RtsRecipient[],options:PickOptions)=>{
  if(!canInteract())return;
  const key=recipientKey(row),old=anchor.current;
  if(options.range&&old?.list===options.list){
   const from=visible.findIndex(r=>recipientKey(r)===old.key),to=visible.findIndex(r=>recipientKey(r)===key);
   if(from>=0&&to>=0){selectMany(visible.slice(Math.min(from,to),Math.max(from,to)+1),!!options.toggle);return;}
  }
  anchor.current={list:options.list,key};
  if(options.toggle||interaction.current.multiTouch)setRecipients(previous=>previous.some(r=>recipientKey(r)===key)?previous.filter(r=>recipientKey(r)!==key):[...previous,row]);
  else selectMany([row],false);
 },[selectMany,setRecipients]);
 const clear=useCallback(()=>{if(canInteract()){setRecipients([]);anchor.current=null;setMessage('');}},[setRecipients]);
 const remove=useCallback((key:string)=>{if(canInteract())setRecipients(previous=>previous.filter(r=>recipientKey(r)!==key));},[setRecipients]);
 const cancelMode=useCallback(()=>setMode('NORMAL'),[]);
 const requestMode=useCallback((next:RtsMode)=>{
  if(next==='NORMAL'){setMode(next);return;}
  if(!canInteract())return;
  if(interaction.current.copEditing||interaction.current.externalEditing){setMessage('drawingBusy');return;}
  if(next==='CHOOSE_TARGET'&&!interaction.current.action)return;
  setMessage((next==='SELECT_BOX'||next==='SELECT_LASSO')&&!interaction.current.hasPositionLayers?'noPositions':'');setMode(next);
 },[]);
 const setTarget=useCallback((target:TaskTarget,geometry:Geometry|null=null,label='')=>{
  writePreview({target,geometry:geometry?structuredClone(geometry):null,label});setMode('NORMAL');setMessage('');
 },[]);
 const hydrateTarget=useCallback((target:TaskTarget,geometry:Geometry,label:string)=>{
  writePreview(current=>!current.geometry&&JSON.stringify(current.target)===JSON.stringify(target)?{...current,geometry:structuredClone(geometry),label}:current);
 },[]);
 const openPalette=useCallback(()=>{
  if(!canInteract())return;
  if(interaction.current.copEditing||interaction.current.externalEditing){setMessage('drawingBusy');return;}
  setMode('NORMAL');
  if(!interaction.current.open){setContextLaunch(false);setLaunch(v=>v+1);}
  else root.current?.querySelector<HTMLElement>('[data-rts-editor]')?.focus();
 },[]);
 const openContext=useCallback((definition:ActionDefinition|null,target:TargetPreview,rows?:readonly RtsRecipient[])=>{
  if(!canInteract()||interaction.current.copEditing||interaction.current.open)return;
  if(rows)setRecipients([...rows]);
  setAction(definition);setTarget(target.target,target.geometry,target.label);setContextLaunch(true);setLaunch(v=>v+1);
 },[setRecipients,setTarget]);
 const revoke=useCallback(()=>{
  setCatalog(null);setCommandTypes(null);setContextLaunch(false);setBlocked(true);setGroups(new Map());groupRequest.current?.abort();groupRequest.current=null;setRecipients([]);setAction(null);writePreview(emptyTarget);setIntent(null);setOpen(false);setMode('NORMAL');setMessage('authorityLost');
  latest.current.onAccessLost();
 },[setRecipients]);
 useEffect(()=>{if(!enabled||locked||copEditing||externalEditing)setMode('NORMAL');},[enabled,locked,copEditing,externalEditing]);
 useEffect(()=>{if(!enabled){setGroups(new Map());groupRequest.current?.abort();groupRequest.current=null;setRecipients([]);setOpen(false);setAction(null);writePreview(emptyTarget);anchor.current=null;}},[enabled,setRecipients]);
 useEffect(()=>{if(!open)setMode('NORMAL');},[open]);
 useEffect(()=>{
  const kinds=action?.configuration.target_types.filter(k=>k!=='NONE')??[];
  setMapTargetKind((kinds.includes(preview.target.kind)?preview.target.kind:kinds.includes('COORDINATE')?'COORDINATE':kinds[0]??'NONE') as TaskTarget['kind']);
 },[action?.configuration.id]);
 const value:RtsController={enabled,locked,blocked,agentEditing,setAgentEditing,navigationEditing,setNavigationEditing,externalEditing,setExternalEditing,hasPositionLayers,setHasPositionLayers,copEditing,setCopEditing,mode,requestMode,cancelMode,recipients,setRecipients,groups,saveGroup,clearGroup,recallGroup,groupBusy,bindGroupResolver,pick,selectMany,clear,remove,multiTouch,setMultiTouch,merge,setMerge,
  catalogError,setCatalogError,catalog,setCatalog,commandTypes,setCommandTypes,contextLaunch,openContext,action,setAction,preview,setTarget,hydrateTarget,mapTargetKind,setMapTargetKind,open,setOpen,launch,openPalette,intent,setIntent,message,setMessage,revoke};
 return <RtsContext.Provider value={value}><div ref={root} className="rts-workspace" onKeyDown={e=>{
  if(e.defaultPrevented||typingTarget(e.target)||e.nativeEvent.isComposing||!enabled||locked||blocked||copEditing||externalEditing||e.target instanceof Element&&e.target.closest('dialog'))return;
  const key=e.key.toLowerCase();
  if(key==='escape'){
   if(mode!=='NORMAL'){e.preventDefault();e.stopPropagation();setMode('NORMAL');}
   else if(open){e.preventDefault();e.stopPropagation();setOpen(false);}
  }else if((e.ctrlKey||e.metaKey)&&!e.altKey&&key==='k'){e.preventDefault();openPalette();}
  else if(/^[1-9]$/.test(key)&&!e.altKey&&!e.shiftKey&&!e.repeat&&mode==='NORMAL'&&!open&&!groupBusy&&e.target instanceof Element&&!!e.target.closest('.command-workspace')&&!e.target.closest('form')&&!document.querySelector('dialog[open],[aria-modal="true"]')){if(e.ctrlKey||e.metaKey){e.preventDefault();e.stopPropagation();saveGroup(Number(key));}else if(!e.shiftKey){e.preventDefault();e.stopPropagation();recallGroup(Number(key));}}
  else if(!e.ctrlKey&&!e.metaKey&&!e.altKey&&(key==='b'||key==='l')){e.preventDefault();requestMode(key==='b'?'SELECT_BOX':'SELECT_LASSO');}
 }}>{children}</div></RtsContext.Provider>;
}
