'use client';
import {useEffect,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import type {Initialization,TemplateRead} from '../../lib/operational/templates';
import {templateError,templateText} from '../../lib/operational/templateMessages';
import {useTemplateMutation} from './useTemplateMutation';
import {TemplateConfirmation} from './TemplateLibrary';
export function TemplateInitialization({locale,account,org,incident,refresh,read,onRefresh}:{locale:Locale;account:string;org:string;incident:string;refresh:number;read:TemplateRead;onRefresh:()=>void}){
 const t=templateText(locale),[value,setValue]=useState<Initialization|null>(null),[error,setError]=useState(''),[loading,setLoading]=useState(true),[confirm,setConfirm]=useState<Initialization|null>(null);
 const mutation=useTemplateMutation(account,org,'initialize.'+incident,read,()=>{setConfirm(null);onRefresh();});
 useEffect(()=>{
  const ac=new AbortController();setLoading(true);setValue(null);setError('');
  read<Initialization|null>('simulation_template_initialization',{p_organization_id:org,p_incident_id:incident},ac.signal,account)
   .then(data=>{if(!ac.signal.aborted)setValue(data);})
   .catch(e=>{if(!ac.signal.aborted)setError(templateError(e instanceof Error?e.message:'SERVER'));})
   .finally(()=>{if(!ac.signal.aborted)setLoading(false);});
  return()=>ac.abort();
 },[account,org,incident,refresh,read]);
 if(!value&&!error)return null;
 const busy=loading||mutation.busy||!!mutation.pending;
 return <section className="admin-card"><h3>{t('initialization')}</h3>
  {(error||mutation.error)&&<p role="alert">{t(mutation.error||error)}</p>}
  {value&&mutation.error!=='denied'&&<>
   <p role="status">{t(value.state)} · {t('objects')}: {value.objects} · {t('units')}: {value.units}</p>
   <p>{t(value.state==='READY'?'readyHelp':'setupHelp')}</p>
   {value.clock_scale!==null&&value.response_profile!==null&&<p>{t('clock')}: {value.clock_scale}× · {t('profile')}: {t(value.response_profile)}</p>}
   {value.can_initialize&&<button disabled={busy} onClick={()=>setConfirm(value)}>{t('initialize')}</button>}
   {mutation.pending&&<><p>{t('pending')}</p><button disabled={loading||mutation.busy} onClick={mutation.retry}>{t('retry')}</button></>}
   {confirm&&<TemplateConfirmation locale={locale} busy={busy} onCancel={()=>setConfirm(null)} onConfirm={()=>{
    mutation.mutate('simulation_template_initialize',{p_incident_id:incident,p_expected_version:confirm.scenario_version,p_incident_version:confirm.incident_version});
   }}><p>{t('setupHelp')}</p><p>{t('reviewDefaults')}</p>
    {mutation.error&&<p role="alert">{t(mutation.error)}</p>}
    {mutation.pending&&<><p>{t('pending')}</p><button type="button" disabled={mutation.busy} onClick={mutation.retry}>{t('retry')}</button></>}
   </TemplateConfirmation>}
  </>}
 </section>;
}
