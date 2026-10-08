'use client';
import {useEffect,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import {incidentText} from '../../lib/incidents/messages';
import type {Timeline} from '../../lib/incidents/model';
type Read=<T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,account?:string)=>Promise<T>;
export function IncidentTimeline({locale,account,org,incident,revision,read}:{locale:Locale;account:string;org:string;incident:string;revision:number;read:Read}){
 const t=incidentText(locale),[open,setOpen]=useState(false),[cursor,setCursor]=useState<string|number>(0);
 const [timeline,setTimeline]=useState<Timeline|null>(null),[error,setError]=useState(false);
 useEffect(()=>{
  const ac=new AbortController();setTimeline(null);setError(false);
  if(open)void read<Timeline>('incident_timeline_page',{p_acting_organization_id:org,p_incident_id:incident,p_after_sequence:cursor,p_limit:30},ac.signal,account)
   .then(value=>{if(!ac.signal.aborted)setTimeline(value);}).catch(()=>{if(!ac.signal.aborted)setError(true);});
  return()=>ac.abort();
 },[open,cursor,revision,account,org,incident,read]);
 return <details className="workspace-section" onToggle={e=>setOpen(e.currentTarget.open)}><summary>{t('timeline')}</summary>
  {error?<p role="alert">{t('unavailable')}</p>:!timeline?<p>{t('loading')}</p>:<>
   {!timeline.events.length&&<p>{t('noEvents')}</p>}
   <ol>{timeline.events.map(event=><li key={event.id}><strong>{t(event.event_code)}</strong>{event.subject_name&&<p>{event.subject_name}</p>}
    <p>{new Date(event.recorded_at).toLocaleString(locale)} · {event.actor_name??'—'} · {event.actor_organization_name}</p>{event.data.reason&&<p>{event.data.reason}</p>}</li>)}</ol>
   <div className="actions">{String(cursor)!=='0'&&<button onClick={()=>setCursor(0)}>{t('older')}</button>}
    {timeline.events.length===30&&<button onClick={()=>setCursor(timeline.events[timeline.events.length-1].sequence)}>{t('later')}</button>}</div>
  </>}
 </details>;
}
