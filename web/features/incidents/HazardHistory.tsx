'use client';
import {useEffect,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import type {TemplateRead} from '../../lib/operational/templates';
import {workflowText} from '../../lib/operational/workflowMessages';
import {templateText} from '../../lib/operational/templateMessages';
type Row={version:string;step:number;kind:string;recorded_at:string};
export function HazardHistory({locale,account,org,incident,model,read}:{locale:Locale;account:string;org:string;incident:string;model:string;read:TemplateRead}){
 const [open,setOpen]=useState(false),[rows,setRows]=useState<Row[]>([]),[before,setBefore]=useState<string|null>(null),[error,setError]=useState(false),w=workflowText(locale),t=templateText(locale);
 useEffect(()=>{const ac=new AbortController();setRows([]);setError(false);
 if(open)void read<Row[]>('simulation_hazard_history',{p_organization_id:org,p_incident_id:incident,p_model:model,p_before:before},ac.signal,account).then(r=>{if(!ac.signal.aborted)setRows(r);}).catch(()=>{if(!ac.signal.aborted)setError(true);});
 return()=>ac.abort();},[account,org,incident,model,read,open,before]);
 return <details open={open} onToggle={e=>setOpen(e.currentTarget.open)}><summary>{w('history')}</summary>
 {error&&<p role="alert">{t('error')}</p>}
 <ol>{rows.map(r=><li key={r.version}>{w('historyEntry')} · {r.version} · {r.step*5} s · {new Date(r.recorded_at).toLocaleString(locale)}</li>)}</ol>
 <div className="actions"><button disabled={!before} onClick={()=>setBefore(null)}>{t('first')}</button><button disabled={rows.length<25} onClick={()=>setBefore(rows.at(-1)?.version??null)}>{t('more')}</button></div></details>;
}
