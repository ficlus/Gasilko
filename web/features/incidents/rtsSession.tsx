'use client';
import {createContext,useCallback,useContext,useEffect,useRef,useState,type Dispatch,type ReactNode,type SetStateAction} from 'react';
import type {ActionDefinition,TaskTarget} from '../../lib/operational/tasks';
import type {Geometry} from '../../lib/incidents/cop';
import {recipientKey,typingTarget,type RtsMode,type RtsRecipient,type TargetPreview,type TaskIntent} from '../../lib/operational/rts';

type PickOptions={toggle?:boolean;range?:boolean;list:string};
type RtsController={
 enabled:boolean;locked:boolean;blocked:boolean;externalEditing:boolean;setExternalEditing:Dispatch<SetStateAction<boolean>>;hasPositionLayers:boolean;setHasPositionLayers:Dispatch<SetStateAction<boolean>>;copEditing:boolean;setCopEditing:Dispatch<SetStateAction<boolean>>;
 mode:RtsMode;requestMode:(mode:RtsMode)=>void;cancelMode:()=>void;
 recipients:RtsRecipient[];setRecipients:Dispatch<SetStateAction<RtsRecipient[]>>;
 pick:(row:RtsRecipient,visible:readonly RtsRecipient[],options:PickOptions)=>void;
 selectMany:(rows:readonly RtsRecipient[],add:boolean)=>void;remove:(key:string)=>void;clear:()=>void;
 multiTouch:boolean;setMultiTouch:Dispatch<SetStateAction<boolean>>;merge:boolean;setMerge:Dispatch<SetStateAction<boolean>>;
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
 const [externalEditing,setExternalEditing]=useState(false),[hasPositionLayers,setHasPositionLayers]=useState(false);
 const [blocked,setBlocked]=useState(false),[copEditing,setCopEditing]=useState(false),[mode,setMode]=useState<RtsMode>('NORMAL');
 const [recipients,writeRecipients]=useState<RtsRecipient[]>([]),selectedRef=useRef<RtsRecipient[]>([]);
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
  if(!interaction.current.open)setLaunch(v=>v+1);
  else root.current?.querySelector<HTMLElement>('[data-rts-editor]')?.focus();
 },[]);
 const revoke=useCallback(()=>{
  setBlocked(true);setRecipients([]);setAction(null);writePreview(emptyTarget);setIntent(null);setOpen(false);setMode('NORMAL');setMessage('authorityLost');
  latest.current.onAccessLost();
 },[setRecipients]);
 useEffect(()=>{if(!enabled||locked||copEditing||externalEditing)setMode('NORMAL');},[enabled,locked,copEditing,externalEditing]);
 useEffect(()=>{if(!enabled){setRecipients([]);setOpen(false);setAction(null);writePreview(emptyTarget);anchor.current=null;}},[enabled,setRecipients]);
 useEffect(()=>{if(!open)setMode('NORMAL');},[open]);
 useEffect(()=>{
  const kinds=action?.configuration.target_types.filter(k=>k!=='NONE')??[];
  setMapTargetKind((kinds.includes(preview.target.kind)?preview.target.kind:kinds.includes('COORDINATE')?'COORDINATE':kinds[0]??'NONE') as TaskTarget['kind']);
 },[action?.configuration.id]);
 const value:RtsController={enabled,locked,blocked,externalEditing,setExternalEditing,hasPositionLayers,setHasPositionLayers,copEditing,setCopEditing,mode,requestMode,cancelMode,recipients,setRecipients,pick,selectMany,clear,remove,multiTouch,setMultiTouch,merge,setMerge,
  action,setAction,preview,setTarget,hydrateTarget,mapTargetKind,setMapTargetKind,open,setOpen,launch,openPalette,intent,setIntent,message,setMessage,revoke};
 return <RtsContext.Provider value={value}><div ref={root} className="rts-workspace" onKeyDown={e=>{
  if(e.defaultPrevented||typingTarget(e.target)||e.nativeEvent.isComposing||!enabled||locked||blocked||copEditing||externalEditing||e.target instanceof Element&&e.target.closest('dialog'))return;
  const key=e.key.toLowerCase();
  if(key==='escape'){
   if(mode!=='NORMAL'){e.preventDefault();e.stopPropagation();setMode('NORMAL');}
   else if(open){e.preventDefault();e.stopPropagation();setOpen(false);}
  }else if((e.ctrlKey||e.metaKey)&&!e.altKey&&key==='k'){e.preventDefault();openPalette();}
  else if(!e.ctrlKey&&!e.metaKey&&!e.altKey&&(key==='b'||key==='l')){e.preventDefault();requestMode(key==='b'?'SELECT_BOX':'SELECT_LASSO');}
 }}>{children}</div></RtsContext.Provider>;
}
