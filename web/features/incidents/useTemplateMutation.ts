'use client';
import {useEffect,useRef,useState} from 'react';
import type {TemplateRead} from '../../lib/operational/templates';
import {templateError} from '../../lib/operational/templateMessages';
export type MutationRequest={name:string;args:Record<string,unknown>};
export type MutationState='IDLE'|'SENDING'|'CONFIRMED'|'DEFINITIVELY_REJECTED'|'OUTCOME_UNKNOWN'|'RECOVERING';
/** Exact durable request; absence of a receipt is never evidence of rejection. */
export function useTemplateMutation(account:string,org:string,surface:string,read:TemplateRead,onSuccess:(data:unknown,request:MutationRequest)=>void){
 const key='gasilko.template.pending.'+account+'.'+org+'.'+surface;
 const [pending,setPending]=useState<MutationRequest|null>(null),[state,setState]=useState<MutationState>('IDLE'),[error,setError]=useState(''),[correlation,setCorrelation]=useState(''),[ready,setReady]=useState(false);
 const current=useRef<MutationRequest|null>(null),locked=useRef(false),generation=useRef(0),success=useRef(onSuccess);success.current=onSuccess;
 useEffect(()=>{
  const n=++generation.current;current.current=null;locked.current=false;setPending(null);setState('IDLE');setError('');setReady(false);
  try{const raw=sessionStorage.getItem(key);if(raw&&raw.length<=200000){
   const r=JSON.parse(raw) as MutationRequest;
   if(['simulation_hazard_command','simulation_template_command','simulation_template_initialize','simulation_scenario_event_command'].includes(r.name)&&r.args?.p_organization_id===org&&typeof r.args.p_operation==='string'){current.current=r;setPending(r);setState('OUTCOME_UNKNOWN');}
  }}catch{setError('storage');}
  setReady(true);return()=>{if(generation.current===n)generation.current++;};
 },[key,org]);
 function confirmed(data:unknown,r:MutationRequest){
  try{sessionStorage.removeItem(key);}catch{/* The retained exact receipt can safely be reconciled again. */}
  current.current=null;setPending(null);setState('CONFIRMED');success.current(data,r);
 }
 async function send(r:MutationRequest,recover=false){
  if(locked.current)return;const n=generation.current,previous=!!current.current;
  locked.current=true;setError('');setCorrelation('');setState(recover?'RECOVERING':'SENDING');
  try{
   const raw=JSON.stringify(r);if(raw.length>200000)throw new Error('storage');
   sessionStorage.setItem(key,raw);if(sessionStorage.getItem(key)!==raw)throw new Error('storage');
  }catch{locked.current=false;setError('storage');setState(previous?'OUTCOME_UNKNOWN':'DEFINITIVELY_REJECTED');return;}
  current.current=r;setPending(r);
  try{
   const result=await read<unknown>(recover?'simulation_operation_resolve':r.name,recover?{p_organization_id:org,p_name:r.name,p_args:r.args}:r.args,undefined,account);
   if(generation.current!==n)return;
   if(recover){const resolved=result as {state:string;data?:unknown};if(resolved.state==='CONFIRMED')confirmed(resolved.data,r);else setState('OUTCOME_UNKNOWN');}
   else confirmed(result,r);
  }catch(e){
   if(generation.current!==n)return;
   const failure=e as Error&{outcome?:string;correlation?:string};
   setError(templateError(failure.message??'SERVER'));setCorrelation(failure.correlation??'');
   // A rejection of a later retry may precede receipt lookup (e.g. revoked permission).
   if(!previous&&!recover&&failure.outcome==='REJECTED'){
    current.current=null;setPending(null);setState('DEFINITIVELY_REJECTED');try{sessionStorage.removeItem(key);}catch{}
   }else setState('OUTCOME_UNKNOWN');
  }finally{if(generation.current===n)locked.current=false;}
 }
 function mutate(name:string,args:Record<string,unknown>){
  if(!ready||locked.current||current.current)return;
  void send({name,args:structuredClone({...args,p_organization_id:org,p_operation:crypto.randomUUID()})});
 }
 return {pending,state,ready,busy:state==='SENDING'||state==='RECOVERING',error,correlation,setError,mutate,
  retry:()=>{if(current.current)void send(current.current);},
  reconcile:()=>{if(current.current)void send(current.current,true);}};
}
