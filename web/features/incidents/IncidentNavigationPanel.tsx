'use client';
import {useEffect,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import {navigationText} from '../../lib/operational/navigationMessages';
import {taskText} from '../../lib/operational/taskMessages';
import {accessDistance} from '../../lib/operational/navigation';
import {useIncidentNavigation} from './IncidentNavigationProvider';
import {useSimulation} from './SimulationProvider';
import {WorkspaceSlot,useWorkspace} from './workspace';
export function IncidentNavigationPanel({locale}:{locale:Locale}){
 const nav=useIncidentNavigation(),workspace=useWorkspace(),sim=useSimulation(),t=navigationText(locale),tt=taskText(locale);
 const [replacement,setReplacement]=useState('');
 useEffect(()=>{nav?.scopeUnit(workspace?.selected?.kind==='INCIDENT_UNIT'?workspace.selected.id:null);setReplacement('');},[workspace?.selected?.kind,workspace?.selected?.id]);
 if(!nav)return null;
 const row=nav.data?.rows.find(a=>a.id===nav.assignment),s=nav.data?.session,r=nav.route;
 const locked=nav.busy||nav.pending;
 const original=r?.origin_snapshot,position=sim?.data?.positions.find(p=>p.incident_unit_id===original?.incident_unit_id);
 const stale=!!s?.origin_stale||(original?.source==='SIMULATED_POSITION'&&position&&position.version!==original.version);
 const terminal=!!s&&!['PLANNED','ACTIVE','PAUSED'].includes(s.status);
 const state=s?.effective_status;
 const distances=r?[accessDistance(r.origin_snapshot.coordinate,r.snapped_origin),accessDistance(r.destination_snapshot.geometry.coordinates,r.snapped_destination)]:[];
 return <WorkspaceSlot name="operational"><details className="workspace-section incident-navigation-panel" open={workspace?.view!=='command'||undefined}>
  <summary>{t('title')} · {nav.data?.rows.length??0}</summary><p>{t('planningNotice')}</p>
  <button disabled={locked} onClick={nav.refresh}>{t('refresh')}</button>
  {nav.error&&<p role="alert">{t(nav.error)}</p>}
  {!nav.data?<p>{t('loading')}</p>:<>
   {!nav.assignment&&<><div className="navigation-assignment-list">{nav.data.rows.map(a=><article key={a.id} className="web-row">
    <strong>{a.callsign}</strong><p>{locale==='de'?a.label_de:a.label_sl} → {a.target}</p><p>{tt(a.status)}</p>
    <button disabled={locked} onClick={()=>{nav.select(a.id);workspace?.select({kind:'INCIDENT_UNIT',id:a.unit_id});}}>{t('open')} · {a.callsign}</button>
   </article>)}</div>{!nav.data.rows.length&&<p>{t('empty')}</p>}
   <div className="actions"><button disabled={locked||nav.page===0} onClick={()=>nav.pageTo(nav.page-1)}>{t('previous')}</button><button disabled={locked||!nav.data.more} onClick={()=>nav.pageTo(nav.page+1)}>{t('next')}</button></div></>}
   {row&&<><h4>{row.callsign}</h4><p>{locale==='de'?row.label_de:row.label_sl} → {row.target}</p><p>{tt(row.status)}</p>
    <button disabled={locked} onClick={()=>nav.select(null)}>{t('previous')}</button>
    {!row.can_execute||!row.ack_ready?<p>{t('executorNotice')}</p>:null}
    {row.can_plan&&<div className="navigation-origin-actions">
     {row.sim_available?<button disabled={locked||nav.picking} onClick={()=>nav.prepare('SIMULATED_POSITION')}>{t(terminal?'newSession':s?'recalculate':'prepare')} · {t('SIMULATED_POSITION')}</button>:<p>{t('unavailable')}</p>}
     <button disabled={locked||nav.picking} onClick={nav.pick}>{t('manual')}</button>
    </div>}
    {nav.picking&&<aside role="status"><p>{t('originHelp')}</p>{nav.candidate&&<p>{nav.candidate.join(', ')}</p>}
     <button disabled={!nav.candidate||locked} onClick={()=>nav.prepare('MANUAL_PLANNING_POINT')}>{t('confirm')}</button><button onClick={nav.cancelPick}>{t('cancel')}</button></aside>}
    {s&&<><h4>{t(state??s.status)}</h4>
     {nav.data.sessions.length>1&&<label>{t('history')}<select disabled={locked} value={s.id} onChange={e=>nav.session(e.target.value)}>{nav.data.sessions.map(h=><option key={h.id} value={h.id}>{t(h.status)} · {new Date(h.created_at).toLocaleString(locale)}</option>)}</select></label>}
     {r&&<><p><strong>{t(nav.history?'historical':'current')} · {r.revision}</strong></p>
      <dl><dt>{t('distance')}</dt><dd>{(r.distance_m/1000).toLocaleString(locale,{maximumFractionDigits:1})} km</dd>
       <dt>{t('duration')}</dt><dd>{Math.ceil(r.duration_s/60)} min</dd><dt>{t('provider')}</dt><dd>{r.provider}</dd>
       <dt>{t('calculated')}</dt><dd>{new Date(r.calculated_at).toLocaleString(locale)}</dd></dl>
      <p>{t(r.origin_snapshot.source)} · {r.origin_snapshot.coordinate.join(', ')}</p>
      {r.origin_snapshot.observed_at&&<p>{new Date(r.origin_snapshot.observed_at).toLocaleString(locale)} {Date.now()-Date.parse(r.origin_snapshot.observed_at)>300000?' · '+t('older'):''}</p>}
      {stale&&<p role="status">{t('stale')}</p>}
      <p>{t('snap')}: {distances.map(d=>Math.round(d).toLocaleString(locale)).join(' / ')}</p>
      {distances.some(d=>d>100)&&<p role="note">{t('snapWarning')}</p>}
      <button onClick={nav.show}>{t('show')}</button>
     </>}
     {!terminal&&<div className="actions">
      {row.can_execute&&row.ack_ready&&state==='PLANNED'&&<button disabled={locked} onClick={()=>nav.command('START')}>{t('START')}</button>}
      {row.can_execute&&state==='ACTIVE'&&<button disabled={locked} onClick={()=>nav.command('PAUSE')}>{t('PAUSE')}</button>}
      {row.can_execute&&row.ack_ready&&state==='PAUSED'&&<button disabled={locked} onClick={()=>nav.command('RESUME')}>{t('RESUME')}</button>}
      {row.can_execute&&['ACTIVE','PAUSED'].includes(state??'')&&<><button disabled={locked} onClick={()=>nav.command('STOP')}>{t('STOP')}</button><button disabled={locked||!row.ack_ready} onClick={()=>nav.command('ARRIVE')}>{t('ARRIVE')}</button></>}
      {row.can_plan&&<button disabled={locked} onClick={()=>nav.command('CANCEL')}>{t('CANCEL')}</button>}
     </div>}
     {!terminal&&row.can_plan&&!!nav.data.replacements?.length&&<div><label>{t('replacement')}<select value={replacement} onChange={e=>setReplacement(e.target.value)}><option value="">—</option>{nav.data.replacements.map(h=><option value={h.id} key={h.id}>{h.target??h.id}</option>)}</select></label><button disabled={locked||!replacement} onClick={()=>nav.command('SUPERSEDE',replacement)}>{t('SUPERSEDE')}</button></div>}
     <details><summary>{t('history')}</summary>{nav.data.history.map(h=><p key={h.id}><button onClick={()=>nav.viewRoute(h.id)}>{h.revision} · {new Date(h.calculated_at).toLocaleString(locale)}</button></p>)}
      <button onClick={nav.current}>{t('current')}</button><button disabled={nav.data.history.length<20} onClick={nav.older}>{t('olderRoutes')}</button></details>
     <details><summary>{t('events')}</summary>{nav.data.events.map(e=><p key={e.id}>{new Date(e.created_at).toLocaleString(locale)} · {t(e.new_state)}</p>)}</details>
    </>}
   </>}
  </>}
 </details></WorkspaceSlot>;
}
