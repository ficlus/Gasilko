'use client';
import Link from 'next/link';
import {useEffect,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import type {TaskRead} from '../../lib/operational/tasks';
import {incidentText} from '../../lib/incidents/messages';
import {simulationText} from '../../lib/operational/simulationMessages';
import {SimulationBanner} from './SimulationProvider';
type Row={id:string;incident_id:string;title:string;reference_number:string;status:string;incident_status?:string;updated_at:string;created_by:string;unit_count:number};
export function SimulationOverview({locale,account,org,read,view}:{locale:Locale;account:string;org:string;read:TaskRead;view?:'active'|'finished'}){
 const t=simulationText(locale),[rows,setRows]=useState<Row[]>([]),[page,setPage]=useState(0),[error,setError]=useState(false);
 useEffect(()=>{
  const ac=new AbortController();setRows([]);setError(false);
  void read<Row[]>('simulation_overview',{p_acting_organization_id:org,p_page:page,...(view?{p_view:view}:{})},ac.signal,account).then(r=>{if(!ac.signal.aborted)setRows(r);}).catch(()=>{if(!ac.signal.aborted)setError(true);});
  return()=>ac.abort();
 },[account,org,page,read,view]);
 return <details className="workspace-section" open={!!view}><summary>{t('title')}</summary><SimulationBanner locale={locale}/>
  {error&&<p role="alert">{t('SERVER')}</p>}{!error&&!rows.length&&<p>{t('none')}</p>}
  {rows.map(row=><article className="web-row" key={row.id}><strong>{row.reference_number} · {row.title}</strong><p>{t(row.status)} · {row.incident_status?incidentText(locale)(row.incident_status):''} · {t('count')}: {row.unit_count}</p>
   <p>{t('createdBy')}: {row.created_by} · {t('updated')}: {new Date(row.updated_at).toLocaleString(locale)}</p>
   <Link href={'/'+locale+'/incidents/'+row.incident_id+'?org='+encodeURIComponent(org)}>{t('open')}</Link></article>)}
  <div className="actions"><button disabled={!page} onClick={()=>setPage(v=>v-1)}>{t('first')}</button><button disabled={rows.length<25} onClick={()=>setPage(v=>v+1)}>{t('more')}</button></div>
 </details>;
}
