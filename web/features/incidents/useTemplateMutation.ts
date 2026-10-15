'use client';
import {useEffect,useRef,useState} from 'react';
import {copErrors} from '../../lib/incidents/cop';
import {simulationErrors} from '../../lib/operational/simulation';
import {resourceErrors} from '../../lib/operational/model';
import type {TemplateRead} from '../../lib/operational/templates';
import {templateError} from '../../lib/operational/templateMessages';
type Request={name:string;args:Record<string,unknown>};
/** Durable exact request per account + organization + surface; no rebase on retry. */
export function useTemplateMutation(account:string,org:string,surface:string,read:TemplateRead,onSuccess:(data:unknown)=>void){
 const key='gasilko.template.pending.'+account+'.'+org+'.'+surface;
 const [pending,setPending]=useState<Request|null>(null),[busy,setBusy]=useState(false),[error,setError]=useState('');
 const locked=useRef(false),alive=useRef(true),success=useRef(onSuccess);success.current=onSuccess;
 useEffect(()=>{
  alive.current=true;
  try{const saved=sessionStorage.getItem(key);if(saved){const value=JSON.parse(saved) as Request;
   if(['simulation_template_command','simulation_template_initialize'].includes(value.name)&&value.args.p_organization_id===org)setPending(value);}}
  catch{/* Storage may be unavailable. */}
  return()=>{alive.current=false;};
 },[key,org]);
 async function send(request:Request){
  if(locked.current)return;locked.current=true;setBusy(true);setError('');setPending(request);
  try{
   const encoded=JSON.stringify(request);sessionStorage.setItem(key,encoded);
   if(sessionStorage.getItem(key)!==encoded)throw new Error('storage');
  }catch{
   // Do not send an operation whose identity cannot survive an ambiguous response.
   locked.current=false;setBusy(false);setPending(null);setError('storage');return;
  }
  try{
   const data=await read<unknown>(request.name,request.args,undefined,account);
   try{sessionStorage.removeItem(key);}catch{}
   if(alive.current){setPending(null);success.current(data);}
  }catch(e){
   if(!alive.current)return;
   const code=e instanceof Error?e.message:'SERVER';setError(templateError(code));
   // Network/unknown failures retain the exact intent. Known rejection cannot have committed.
   if(!['SERVER','Failed to fetch','NetworkError'].includes(code)&&
    [...copErrors,...simulationErrors,...resourceErrors,'NOT_AUTHORIZED','EXPIRED','SIMULATION_DISABLED','STALE_VERSION','VALIDATION_FAILED','INVALID_TRANSITION','OPERATION_REUSED',
     'INVALID_GEOMETRY','UNSUPPORTED_GEOMETRY','GEOMETRY_TOO_LARGE','INVALID_SIMULATION_STATE','INVALID_SIMULATION_UNIT','TEMPLATE_SETUP_REQUIRED'].includes(code)){
    setPending(null);try{sessionStorage.removeItem(key);}catch{}
   }
  }finally{locked.current=false;if(alive.current)setBusy(false);}
 }
 function mutate(name:string,args:Record<string,unknown>){
  if(pending||locked.current)return;
  void send({name,args:{...args,p_organization_id:org,p_operation:crypto.randomUUID()}});
 }
 return {pending,busy,error,setError,mutate,retry:()=>{if(pending)void send(pending);}};
}
