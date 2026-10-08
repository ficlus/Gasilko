'use client';
import {useEffect,useState} from 'react';
import type {ViewportBounds} from '../map/OperationalMapCanvas';
import type {HydrantViewport} from '../../lib/hydrants/viewport';
export function useHydrantContext(account:string,bounds:ViewportBounds|null,enabled:boolean,refresh:number){
 const [result,setResult]=useState<HydrantViewport>({rows:[],more:false}),[error,setError]=useState(false),[loading,setLoading]=useState(false);
 useEffect(()=>{
  const ac=new AbortController();setResult({rows:[],more:false});setError(false);setLoading(false);
  if(!enabled||!bounds)return()=>ac.abort();
  setLoading(true);
  const timer=setTimeout(()=>{void fetch('/api/hydrant-context',{method:'POST',headers:{'Content-Type':'application/json','X-Gasilko-Account':account},
   body:JSON.stringify({bounds}),cache:'no-store',signal:ac.signal}).then(async response=>{
    if(!response.ok)throw Error();const data=await response.json() as HydrantViewport;if(!ac.signal.aborted)setResult(data);
   }).catch(()=>{if(!ac.signal.aborted){setResult({rows:[],more:false});setError(true);}})
   .finally(()=>{if(!ac.signal.aborted)setLoading(false);});},300);
  return()=>{clearTimeout(timer);ac.abort();};
 },[account,bounds,enabled,refresh]);
 return {...result,error,loading};
}
