'use client';
import {useEffect,useRef,useState} from 'react';
import type {TemplateRead} from '../../lib/operational/templates';
import {templateError} from '../../lib/operational/templateMessages';
export type MutationRequest={name:string;args:Record<string,unknown>};
export type MutationState='IDLE'|'SENDING'|'CONFIRMED'|'DEFINITIVELY_REJECTED'|'OUTCOME_UNKNOWN'|'RECOVERING';
const names=['simulation_hazard_command','simulation_template_command','simulation_template_initialize','simulation_scenario_event_command'];
const identity=(r:MutationRequest)=>String(r.args.p_operation);
function target(r:MutationRequest){return r.name==='simulation_template_command'?String(r.args.p_template_id??'CREATE'):r.name;}
/** Bounded exact requests in one scoped storage envelope; legacy single requests remain readable. */
export function useTemplateMutation(account:string,org:string,surface:string,read:TemplateRead,onSuccess:(data:unknown,request:MutationRequest)=>void){
 const key='gasilko.template.pending.'+account+'.'+org+'.'+surface;
 const [requests,setRequests]=useState<MutationRequest[]>([]),[state,setState]=useState<MutationState>('IDLE'),[error,setError]=useState(''),[correlation,setCorrelation]=useState(''),[ready,setReady]=useState(false);
 const current=useRef<MutationRequest[]>([]),locked=useRef(false),generation=useRef(0),scope=useRef(key),loaded=useRef(''),success=useRef(onSuccess);scope.current=key;success.current=onSuccess;
 useEffect(()=>{
  const n=++generation.current;current.current=[];locked.current=false;loaded.current='';setRequests([]);setState('IDLE');setError('');setCorrelation('');setReady(false);
  try{
   const raw=sessionStorage.getItem(key);
   if(raw){
    if(raw.length>1000000)throw new Error('storage');
    const parsed=JSON.parse(raw),items=(Array.isArray(parsed.requests)?parsed.requests:[parsed]) as MutationRequest[];
    if(items.length>8||items.some(r=>!names.includes(r.name)||r.args?.p_organization_id!==org||typeof r.args.p_operation!=='string'||JSON.stringify(r).length>200000))throw new Error('storage');
    current.current=items;setRequests(items);if(items.length)setState('OUTCOME_UNKNOWN');
   }
   loaded.current=key;setReady(true);
  }catch{setError('storage');}
  return()=>{if(generation.current===n)generation.current++;loaded.current='';};
 },[key,org]);
 function persist(items:MutationRequest[]){
  if(items.length>8)throw new Error('storage');
  if(!items.length){sessionStorage.removeItem(key);if(sessionStorage.getItem(key)!==null)throw new Error('storage');return;}
  const raw=JSON.stringify({requests:items});if(raw.length>1000000||items.some(r=>JSON.stringify(r).length>200000))throw new Error('storage');
  sessionStorage.setItem(key,raw);if(sessionStorage.getItem(key)!==raw)throw new Error('storage');
 }
 function resolved(r:MutationRequest,nextState:MutationState){
  const remaining=current.current.filter(item=>identity(item)!==identity(r));
  // If cleanup fails, retain the safe original identity and block conflicting writes.
  try{persist(remaining);current.current=remaining;setRequests(remaining);}catch{setError('storage');}
  setState(nextState);
 }
 async function send(r:MutationRequest,recover=false){
  if(locked.current||loaded.current!==key||scope.current!==key)return;
  const n=generation.current,previous=current.current.some(item=>identity(item)===identity(r));
  locked.current=true;setError('');setCorrelation('');setState(recover?'RECOVERING':'SENDING');
  const items=previous?current.current:[...current.current,r];
  try{persist(items);}catch{locked.current=false;setError('storage');setState(previous?'OUTCOME_UNKNOWN':'DEFINITIVELY_REJECTED');return;}
  current.current=items;setRequests(items);
  let result:unknown,confirmed=false;
  try{
   result=await read<unknown>(recover?'simulation_operation_resolve':r.name,recover?{p_organization_id:org,p_name:r.name,p_args:r.args}:r.args,undefined,account);
   if(generation.current!==n||scope.current!==key)return;
   if(recover){const receipt=result as {state:string;data?:unknown};confirmed=receipt.state==='CONFIRMED';result=receipt.data;}
   else confirmed=true;
   if(confirmed)resolved(r,'CONFIRMED');else setState('OUTCOME_UNKNOWN');
  }catch(e){
   if(generation.current!==n||scope.current!==key)return;
   const failure=e as Error&{outcome?:string;correlation?:string};
   setError(templateError(failure.message??'SERVER'));setCorrelation(failure.correlation??'');
   if(!previous&&!recover&&failure.outcome==='REJECTED')resolved(r,'DEFINITIVELY_REJECTED');
   else setState('OUTCOME_UNKNOWN');
  }finally{if(generation.current===n&&scope.current===key)locked.current=false;}
  // A UI/refetch failure after acknowledgement must not relabel a database success as rejection.
  if(confirmed&&generation.current===n&&scope.current===key)success.current(result,r);
 }
 function conflicts(templateId:string|null){return current.current.some(r=>target(r)===String(templateId??'CREATE'));}
 function mutate(name:string,args:Record<string,unknown>){
  if(!ready||loaded.current!==key||locked.current||scope.current!==key)return;
  const r={name,args:structuredClone({...args,p_organization_id:org,p_operation:crypto.randomUUID()})};
  if(current.current.some(item=>target(item)===target(r)))return;
  void send(r);
 }
 const retryRequest=(r:MutationRequest)=>{const exact=current.current.find(item=>identity(item)===identity(r));if(exact)void send(exact);};
 const reconcileRequest=(r:MutationRequest)=>{const exact=current.current.find(item=>identity(item)===identity(r));if(exact)void send(exact,true);};
 return {pending:requests[0]??null,pendingRequests:requests,state,ready,busy:state==='SENDING'||state==='RECOVERING',error,correlation,setError,mutate,conflicts,retryRequest,reconcileRequest,
 retry:()=>{if(current.current[0])retryRequest(current.current[0]);},reconcile:()=>{if(current.current[0])reconcileRequest(current.current[0]);}};
}
