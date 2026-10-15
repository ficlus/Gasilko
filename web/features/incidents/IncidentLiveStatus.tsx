'use client';
import {useRts} from './rtsSession';
import {useState} from 'react';
import type {Locale} from '../../lib/i18n';
import {incidentText} from '../../lib/incidents/messages';
import {useWorkspace} from './workspace';
import {useIncidentLive} from './IncidentLiveProvider';
export function IncidentLiveStatus({locale}:{locale:Locale}){
 const rts=useRts(),live=useIncidentLive(),workspace=useWorkspace(),t=incidentText(locale),[open,setOpen]=useState(false);
 if(!live)return null;
 const interacting=!!(rts?.locked||rts?.open||rts?.copEditing||rts?.externalEditing);
 const toast=live.notifications.find(note=>note.priority!=='INFO'||live.lowPriorityToasts);
 return <div className="incident-live-status" aria-live="polite">
  <button type="button" className={'incident-live-indicator '+live.status.toLowerCase()} onClick={()=>{setOpen(value=>!value);live.markSeen();}} aria-expanded={open} aria-label={t('liveNotifications')}>
   {t('live_'+live.status)} {live.unread>0&&<strong aria-label={t('liveUnread')}>({live.unread})</strong>}
  </button>
  {!open&&!interacting&&toast&&<div className={'incident-live-toast '+toast.priority.toLowerCase()} role={toast.priority==='CRITICAL'?'alert':'status'}><button type="button" onClick={()=>{if(toast.entity)workspace?.select(toast.entity);live.dismiss(toast.id);}}>{t(toast.eventCode)}</button></div>}
  {open&&<section className="incident-live-panel" aria-label={t('liveNotifications')}>
   <div className="actions"><button type="button" onClick={live.requestRefresh}>{t('refresh')}</button><button type="button" onClick={()=>live.setLowPriorityToasts(!live.lowPriorityToasts)}>{t(live.lowPriorityToasts?'liveLowOn':'liveLowOff')}</button></div>
   <p>{t('live_'+live.status)}{live.lastSuccess?' · '+new Date(live.lastSuccess).toLocaleTimeString(locale==='de'?'de-DE':'sl-SI'):''}</p>
   {!live.notifications.length?<p>{t('liveNoNotifications')}</p>:<ol>{live.notifications.map(note=><li key={note.id} className={'incident-live-note '+note.priority.toLowerCase()}>
    <button type="button" disabled={interacting} onClick={()=>{if(note.entity)workspace?.select(note.entity);live.dismiss(note.id);}}>{t(note.eventCode)}</button><small>{t('live_'+note.priority)}</small>
   </li>)}</ol>}
  </section>}
 </div>;
}
