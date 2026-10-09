'use client';
import dynamic from 'next/dynamic';
import {useEffect,useState} from 'react';
import {useRouter} from 'next/navigation';
import type {Locale} from '../../lib/i18n';
import {browserClient} from '../../lib/supabase/browser';
import {integrationText} from '../../lib/operational/integrationMessages';
import {entityHref} from '../../lib/operational/entity';
import {EntityLink} from '../operational/EntityLink';
import {ContextActions} from '../incidents/workspace';
const CanonicalLocation=dynamic(()=>import('../map/CanonicalLocation'),{ssr:false});
type Reference={id:string;name:string;organization_id:string;status:string;included?:boolean;purpose?:string|null;reference_number?:string};
type Page={rows:Reference[];more:boolean};
export function HydrantOperationalContext({locale,hydrant}:{locale:Locale;hydrant:{id:string;organization_id:string;latitude:number|null;longitude:number|null}}){
 const t=integrationText(locale),router=useRouter(),[open,setOpen]=useState(false),[map,setMap]=useState(false),[blocked,setBlocked]=useState(false);
 const [account,setAccount]=useState(''),[revision,setRevision]=useState(0);
 useEffect(()=>{let live=true;const c=browserClient();void c?.auth.getUser().then(r=>{if(live)setAccount(r.data.user?.id??'');});
 const sub=c?.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT'||(account&&session?.user.id!==account)){setBlocked(true);setOpen(false);setMap(false);router.refresh();}});
 return()=>{live=false;sub?.data.subscription.unsubscribe();};},[account,router]);
 if(blocked||!account)return null;
 return <section className="admin-card">
  <ContextActions actions={[{id:'map',label:t('map'),enabled:true,requiresConfirmation:false,execute:()=>setMap(v=>!v)}]}/>
  {map&&<CanonicalLocation key={hydrant.id} locale={locale} hydrant={hydrant}/>}
  <details onToggle={e=>setOpen(e.currentTarget.open)}><summary>{t('context')}</summary>
   {open&&<><button onClick={()=>setRevision(v=>v+1)}>{t('refresh')}</button>
    <References key={'p'+account+hydrant.id+revision} locale={locale} account={account} hydrant={hydrant.id} kind="plan"/>
    <References key={'i'+account+hydrant.id+revision} locale={locale} account={account} hydrant={hydrant.id} kind="incident"/>
   </>}
  </details>
 </section>;
}
function References({locale,account,hydrant,kind}:{locale:Locale;account:string;hydrant:string;kind:'plan'|'incident'}){
 const t=integrationText(locale),router=useRouter(),[data,setData]=useState<Page|null>(null),[candidates,setCandidates]=useState<Page|null>(null),[error,setError]=useState(false),[chosen,setChosen]=useState('');
 useEffect(()=>{const ac=new AbortController();const c=browserClient();setData(null);setCandidates(null);setChosen('');setError(false);
 async function load(){
  if(!c)throw Error();const auth=await c.auth.getUser();if(auth.error||auth.data.user?.id!==account)throw Error();
  const name=kind==='plan'?'hydrant_plan_context':'hydrant_incident_context';
  const [refs,options]=await Promise.all([false,true].map(p_candidates=>c!.rpc(name,{p_hydrant:hydrant,p_candidates}).abortSignal(ac.signal)));
  if(refs.error||options.error)throw Error();
  if(!ac.signal.aborted){setData(refs.data as Page);setCandidates(options.data as Page);}
 }
 void load().catch(()=>{if(!ac.signal.aborted){setData(null);setCandidates(null);setError(true);}});return()=>ac.abort();
 },[kind,hydrant,account]);
 const target=candidates?.rows.find(r=>r.id===chosen);
 function proceed(){if(!target)return;
  if(kind==='plan')router.push('/'+locale+'/admin/org/'+target.organization_id+'/plans?plan='+target.id+'&addHydrant='+hydrant);
  else {const href=entityHref(locale,{type:'HYDRANT',id:hydrant,context:{incidentId:target.id,organizationId:target.organization_id}});if(href)router.push(href);}
 }
 return <section><h3>{t(kind==='plan'?'plans':'incidents')}</h3>
  {error?<p role="alert">{t('error')}</p>:!data?<p role="status">{t('loading')}</p>:<>
   {!data.rows.length&&<p>{t('empty')}</p>}<ul>{data.rows.map(r=><li key={r.id}><EntityLink locale={locale} entity={{type:kind==='plan'?'PLAN':'HYDRANT',id:kind==='plan'?r.id:hydrant,context:{organizationId:r.organization_id,...(kind==='incident'?{incidentId:r.id}:{})}}}>{r.reference_number? r.reference_number+' · ':''}{r.name}</EntityLink></li>)}</ul>
   {data.more&&<p>{t('more')}</p>}
   {!!candidates?.rows.length&&<><label>{t(kind==='plan'?'add':'link')}<select value={chosen} onChange={e=>setChosen(e.target.value)}><option value="">{t('choose')}</option>{candidates.rows.map(r=><option key={r.id} value={r.id}>{r.reference_number??''} {r.name}{r.included?' · '+t('existing'):''}</option>)}</select></label>
    <p>{t('preview')}</p>{target?.included?<p>{t('existing')}</p>:<ContextActions actions={[{id:kind+'-add',label:t(kind==='plan'?'add':'link'),enabled:!!target,disabledReason:!target?t('choose'):undefined,requiresConfirmation:true,execute:proceed}]}/>}{candidates.more&&<p>{t('more')}</p>}
   </>}
  </>}
 </section>;
}
