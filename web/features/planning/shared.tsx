'use client';
import {useEffect,useRef,useState} from 'react';
import {useRouter} from 'next/navigation';
import {dictionary,type Locale} from '@/lib/i18n';
import {browserClient} from '@/lib/supabase/browser';
import {rpc,type Scope} from '@/lib/hydrants/admin';
import {planningError,planningRpc,routePlan,type Plan} from '@/lib/planning/api';

export function usePlanningScope(root:string,locale:Locale){
 const [scope,setScope]=useState<Scope|null>(null),[error,setError]=useState(''),[revision,setRevision]=useState(0),router=useRouter(),blocked=useRef(false);
 useEffect(()=>{if(blocked.current)return;let live=true;void rpc<Scope>('web_hydrant_context',{root}).then(s=>{if(live&&!blocked.current){setScope(s);setError('');}}).catch(()=>{if(live){setScope(null);setError(dictionary(locale).hForbidden);}});return()=>{live=false;};},[root,locale,revision]);
 useEffect(()=>{const c=browserClient();let account:string|undefined,live=true;
 void c?.auth.getUser().then(r=>{if(live&&!account)account=r.data.user?.id;});
 const sub=c?.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT'||(account&&session?.user.id!==account)){blocked.current=true;setScope(null);router.replace('/'+locale+'/account');}else if(session&&!account)account=session.user.id;});
 const timer=setInterval(()=>setRevision(v=>v+1),60000);
 return()=>{live=false;clearInterval(timer);sub?.data.subscription.unsubscribe();};},[locale,router]);
 return {scope,error,revision,reload:()=>setRevision(v=>v+1)};
}

// Freeze the entire submitted request after a failure. Explicit retry reuses its UUID/payload.
// Explicit reload/discard, rather than a background refresh, is needed before another edit.
export function usePlanningMutation(locale:Locale,done:()=>void,discarded:()=>void=done){
 const [busy,setBusy]=useState(false),[locked,setLocked]=useState(false),[error,setError]=useState('');
 const pending=useRef<{organization:string;operation:string;action:string;request:Record<string,unknown>}|null>(null),running=useRef(false);
 async function submit(organization?:string,action?:string,request?:Record<string,unknown>){
  if(running.current)return;
  if(!pending.current){if(!organization||!action||!request)return;pending.current={organization,action,request,operation:crypto.randomUUID()};}
  const p=pending.current;running.current=true;setBusy(true);setLocked(true);setError('');
  try{if(p.action==='ROUTE')await routePlan(p.organization,{...p.request,operation_id:p.operation});
   else await planningRpc('web_planning_write',p);
   pending.current=null;setLocked(false);done();
  }catch(e){setError(planningError(locale,e));}finally{running.current=false;setBusy(false);}
 }
 return {busy,locked,error,submit,discard:()=>{if(!running.current){pending.current=null;setLocked(false);setError('');discarded();}}};
}
export function MutationNotice({locale,mutation}:{locale:Locale;mutation:ReturnType<typeof usePlanningMutation>}){
 const t=dictionary(locale);return <>{mutation.busy&&<p role="status">{t.loading}</p>}{mutation.error&&<div role="alert" className="admin-notice"><p>{mutation.error}</p><p>{t.pRetryNotice}</p><div className="actions"><button disabled={mutation.busy} onClick={()=>void mutation.submit()}>{t.hRetry}</button><button disabled={mutation.busy} onClick={mutation.discard}>{t.pDiscardReload}</button></div></div>}</>;
}
export function Pager({locale,page,more,onPage}:{locale:Locale;page:number;more:boolean;onPage:(v:number)=>void}){const t=dictionary(locale);return <div className="actions"><button disabled={!page} onClick={()=>onPage(page-1)}>{t.wPrevious}</button><span>{page+1}</span><button disabled={!more} onClick={()=>onPage(page+1)}>{t.wNext}</button></div>;}
export function Progress({locale,plan}:{locale:Locale;plan:Pick<Plan,'total'|'completed'|'skipped'>}){
 const t=dictionary(locale);return <div className="plan-progress"><progress aria-label={t.pProgress} max={Math.max(plan.total,1)} value={plan.completed}/><strong>{plan.completed} / {plan.total} · {plan.total?Math.round(plan.completed/plan.total*100):0}%</strong><small>{t.pRemaining}: {plan.total-plan.completed} · {t.pSkipped}: {plan.skipped}</small></div>;
}
