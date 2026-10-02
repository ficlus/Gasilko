'use client';
import dynamic from 'next/dynamic';
import {useEffect,useMemo,useRef,useState} from 'react';
import type {CSSProperties} from 'react';
import {dictionary,type Locale} from '@/lib/i18n';
import {browserClient} from '@/lib/supabase/browser';
import {type Row,type Scope} from '@/lib/hydrants/admin';
import {PlanningError,planningRpc,planningError,stateLabel,providerLabel,type PlanDetail as Detail,type Item} from '@/lib/planning/api';
import {statusLabel} from '../hydrants/Registry';
import {HydrantDetail,dueLabel} from '../hydrants/HydrantDetail';
import {modeLabel,resultLabel} from '../hydrants/ManualInspection';
import {PhotoGallery} from '../hydrants/PrivatePhotos';
import {MutationNotice,Pager,Progress,usePlanningMutation} from './shared';
import {PlanEditor} from './PlanEditor';
import {teamColors} from './teamColors';
const Map=dynamic(()=>import('../map/HydrantMap'),{ssr:false});

export function PlanDetail({root,id,locale,scope,onBack}:{root:string;id:string;locale:Locale;scope:Scope;onBack:()=>void}){
 const t=dictionary(locale),[data,setData]=useState<Detail|null>(null),[revision,setRevision]=useState(0),[historyPage,setHistoryPage]=useState(0),[error,setError]=useState('');
 const [edit,setEdit]=useState(false),[selected,setSelected]=useState<Row|null>(null),[hydrant,setHydrant]=useState<string|null>(null),[team,setTeam]=useState(''),[stopPage,setStopPage]=useState(0);
 const [preview,setPreview]=useState<Record<string,string|null>|null>(null),[previewBusy,setPreviewBusy]=useState(false),[confirmActivation,setConfirmActivation]=useState(false);
 const [moving,setMoving]=useState<Item|null>(null),[destination,setDestination]=useState(''),[reason,setReason]=useState('');
 const [inspectionItem,setInspectionItem]=useState<string|null>(null);
 const transferPanel=useRef<HTMLElement>(null);
 useEffect(()=>{if(moving)transferPanel.current?.scrollIntoView({block:'center',behavior:'smooth'});},[moving?.id]);
 const reload=()=>setRevision(v=>v+1),mutation=usePlanningMutation(locale,()=>{setMoving(null);setPreview(null);setConfirmActivation(false);reload();});
 const paused=useRef(false);paused.current=edit||mutation.locked||!!moving||!!preview||previewBusy||confirmActivation;
 useEffect(()=>{let live=true;void planningRpc<Detail>('web_plan_detail',{root,plan:id,history_page:historyPage}).then(d=>{if(live&&!paused.current){setData(d);setSelected(s=>s?d.items.find(i=>i.hydrant_id===s.id)?.hydrant??null:null);setError('');}}).catch(e=>{if(live){if(e instanceof PlanningError&&['FORBIDDEN','EXPIRED'].includes(e.message)){setData(null);setSelected(null);setHydrant(null);setMoving(null);setPreview(null);setConfirmActivation(false);setEdit(false);}setError(planningError(locale,e));}});return()=>{live=false;};},[root,id,revision,historyPage,locale]);
 useEffect(()=>{const c=browserClient();if(!c)return;let debounce:ReturnType<typeof setTimeout>;
 const changed=()=>{clearTimeout(debounce);debounce=setTimeout(()=>{if(!paused.current)reload();},500);};
 const channel=c.channel('web-plan:'+id).on('postgres_changes',{event:'*',schema:'public',table:'inspection_plans',filter:'id=eq.'+id},changed);
 for(const table of ['inspection_plan_items','inspection_plan_teams','inspection_plan_routes','plan_reassignments'])channel.on('postgres_changes',{event:'*',schema:'public',table,filter:'plan_id=eq.'+id},changed);
 channel.subscribe();const timer=setInterval(()=>{if(!paused.current)reload();},20000);
 return()=>{clearTimeout(debounce);clearInterval(timer);void c.removeChannel(channel);};},[id]);
 const displayed=useMemo(()=>data?.items.map(i=>preview?{...i,team_id:preview[i.id]??null,route_order:null}:i).filter(i=>!team||i.team_id===team)
  .sort((a,b)=>(a.team_id??'').localeCompare(b.team_id??'')||(a.route_order??Number.MAX_SAFE_INTEGER)-(b.route_order??Number.MAX_SAFE_INTEGER)||a.hydrant_id.localeCompare(b.hydrant_id))??[],[data,team,preview]);
 const colors=useMemo(()=>teamColors(data?.teams.map(t=>t.id)??[]),[data?.teams]);
 const overlay=useMemo(()=>({fitKey:id+':'+team+':'+data?.plan.version+':'+(preview?'preview':'saved'),stops:Object.fromEntries(displayed.map(i=>[i.hydrant_id,{color:colors[i.team_id??'']??'#68767e',number:preview?null:i.route_order,completed:!!i.inspection_id,skipped:!i.inspection_id&&!!i.skipped_at}])),
 routes:preview?[]:(data?.routes??[]).filter(r=>!team||r.team_id===team).map(r=>({color:colors[r.team_id]??'#68767e',valid:r.valid,geometry:r.geometry}))}),[data,displayed,id,team,preview,colors]);
 if(!data)return <><button onClick={onBack}>{t.pBack}</button><p role="status">{error||t.loading}</p><button onClick={reload}>{t.hRefresh}</button></>;
 const p=data.plan,writable=data.writable&&scope.organizations.some(o=>o.id===p.organization_id&&o.writable),planning=['DRAFT','PLANNED'].includes(p.status),operational=p.status==='ACTIVE',unfinished=planning||operational;
 if(!scope.organizations.some(o=>o.id===p.organization_id))return <p role="alert">{t.hForbidden}</p>;
 const disabled=mutation.locked||previewBusy||!writable,teamName=(id:string|null)=>data.teams.find(t=>t.id===id)?.name??t.pUnassigned;
 if(edit&&writable)return <PlanEditor root={root} locale={locale} scope={scope} initial={data} onBack={()=>{setEdit(false);reload();}} onSaved={()=>{setEdit(false);reload();}}/>;
 if(hydrant)return <HydrantDetail key={hydrant} root={root} id={hydrant} locale={locale} scope={scope} onBack={()=>{setHydrant(null);reload();}} onChanged={reload}/>;
 const inspected=data.items.find(i=>i.id===inspectionItem);
 if(inspected?.inspection){const inspection=inspected.inspection;return <section className="admin-card"><button onClick={()=>setInspectionItem(null)}>{t.pBack}</button><h2>{inspected.hydrant.code??t.hMissing} · {modeLabel(t,inspection.mode)}</h2><p>{p.organization_name} · {p.name}</p><p>{resultLabel(t,inspection.result)} · {new Date(inspection.completed_at).toLocaleString(locale)}</p><p>{inspection.notes}</p><p>{t.wPressure}: {inspection.pressure_bar??t.hMissing} · {t.wFlow}: {inspection.flow_l_min??t.hMissing}</p><PhotoGallery locale={locale} org={p.organization_id} hydrant={inspected.hydrant_id} inspection={inspection.id} refresh={revision}/></section>;}
 const assignPreview=async()=>{setPreviewBusy(true);setError('');try{const r=await planningRpc<Record<string,string|null>>('web_assignment_preview',{organization:p.organization_id,request:{id:p.id,version:p.version,operation_id:crypto.randomUUID(),action:'ASSIGN'}});setPreview(r);}catch(e){setError(planningError(locale,e));}finally{setPreviewBusy(false);}};
 const route=(team_id?:string)=>void mutation.submit(p.organization_id,'ROUTE',{id:p.id,version:p.version,action:operational?'ROUTE_REMAINING':'ROUTE',...(team_id?{team_id}:{})});
 const closeMove=()=>{setMoving(null);setDestination('');setReason('');reload();};
 const transfer=()=>{if(!moving||!destination||disabled)return;
  void mutation.submit(p.organization_id,operational?'REASSIGN':'MANUAL',operational?{plan_id:p.id,item_id:moving.id,from_team_id:moving.team_id,to_team_id:destination,version:moving.execution_version,reason:reason.trim()}:{id:p.id,version:p.version,assignments:{[moving.id]:destination}});};
 const totalPreviewUnassigned=preview?Object.values(preview).filter(v=>v===null).length:p.unassigned;
 return <section className="web-detail"><div className="actions"><button disabled={mutation.busy} onClick={onBack}>{t.pBack}</button><button disabled={paused.current} onClick={reload}>{t.hRefresh}</button></div>
 <header className="admin-card"><h2>{p.name}</h2><p>{p.organization_name} · <span className="admin-badge">{stateLabel(t,p.status)}</span></p><Progress locale={locale} plan={p}/><small>{t.pUpdated}: {new Date(p.updated_at).toLocaleString(locale)} · {t.pCreated}: {new Date(p.created_at).toLocaleString(locale)}</small>
 {p.started_at&&<p>{t.pStarted}: {new Date(p.started_at).toLocaleString(locale)}</p>}{p.completed_at&&<p>{t.pFinished}: {new Date(p.completed_at).toLocaleString(locale)}</p>}
 <p>{t.pStart}: {p.start_latitude===null?t.pNoStart:`${p.start_latitude}, ${p.start_longitude}`} · {t.pReturn}: {p.return_to_start?t.pYes:t.pNo}</p>
 {!writable&&<p>{t.adminWriteNotice}</p>}{!unfinished&&<p>{t.pReadOnlyHistory}</p>}</header>
 <MutationNotice locale={locale} mutation={mutation}/>{error&&<p role="alert" className="admin-notice">{error}</p>}
 {data.limited&&<p role="alert" className="admin-notice">{t.pDetailLimit}</p>}
 {writable&&unfinished&&<div className="actions">
 {planning&&<><button disabled={disabled||data.limited||!!preview||!!moving} onClick={()=>setEdit(true)}>{t.pEditPlan}</button><button disabled={disabled||!!moving||!!preview} onClick={()=>void assignPreview()}>{t.pAssignmentPreview}</button></>}
 <button disabled={disabled||!!preview||!!moving} onClick={()=>route()}>{operational?t.pRemainingRoutes:t.pCalculateRoutes}</button>
 {p.status==='PLANNED'&&<button disabled={disabled||!!preview||!!moving} onClick={()=>setConfirmActivation(true)}>{t.pActivatePlan}</button>}
 </div>}
 {confirmActivation&&<section className="admin-card" role="region" aria-label={t.pActivatePlan}><h2>{t.pActivationReview}</h2><p>{t.adminTeams}: {data.teams.length} · {t.adminHydrants}: {p.total} · {t.pUnassigned}: {p.unassigned}</p><p>{t.pStaleRoutes}: {p.stale_routes} · {t.pRoutes}: {data.routes.length}</p><p>{t.pStart}: {p.start_latitude===null?t.pNoStart:`${p.start_latitude}, ${p.start_longitude}`} · {t.pReturn}: {p.return_to_start?t.pYes:t.pNo}</p><p>{t.pActivationNotice}</p><div className="actions"><button disabled={disabled} onClick={()=>void mutation.submit(p.organization_id,'ACTIVATE',{id:p.id,version:p.version})}>{t.pConfirmActivation}</button><button disabled={mutation.busy} onClick={()=>{setConfirmActivation(false);reload();}}>{t.hCancel}</button></div></section>}
 {preview&&<section className="admin-notice"><h2>{t.pAssignmentPreview}</h2><p>{t.pPreviewNotice}</p><p>{t.pUnassigned}: {totalPreviewUnassigned}</p><div className="actions"><button disabled={disabled} onClick={()=>void mutation.submit(p.organization_id,'ASSIGN',{id:p.id,version:p.version,preview})}>{t.pCommitAssignment}</button><button disabled={mutation.busy} onClick={()=>{setPreview(null);reload();}}>{t.hCancel}</button></div></section>}
 {!!totalPreviewUnassigned&&<p className="admin-notice">{t.pUnassigned}: {totalPreviewUnassigned} · {t.pUnassignedNotice}</p>}
 {p.stale_routes>0&&<p className="admin-notice">{t.pStaleNotice}</p>}
 {!data.routes.length&&<p className="admin-notice">{t.pNoRoutes}</p>}
 <div className="admin-cards">{data.teams.map(team=>{const items=data.items.filter(i=>i.team_id===team.id),r=data.routes.find(r=>r.team_id===team.id),previewCount=preview?Object.values(preview).filter(id=>id===team.id).length:null;
 return <article key={team.id} className="admin-card team-card" style={{'--team-color':colors[team.id]} as CSSProperties}><h2>{team.name}</h2><Progress locale={locale} plan={{total:team.total,completed:team.completed,skipped:team.skipped}}/>{previewCount!==null&&<p>{t.pPreviewAssigned}: {previewCount}</p>}
 {team.latest_activity&&<small>{t.pLatestActivity}: {new Date(team.latest_activity).toLocaleString(locale)}</small>}
 {r?<><p>{r.valid?t.pValidRoute:t.pStaleRoute} · {providerLabel(t,r.provider)}</p><p>{(r.distance_m/1000).toLocaleString(locale,{maximumFractionDigits:1})} km · {Math.round(r.duration_s/60)} min</p><small>{new Date(r.calculated_at).toLocaleString(locale)}</small><p>{r.provider==='OSRM'?t.pOsrmAttribution:t.pGraphHopperAttribution}</p></>:<p>{t.pNoRoutes}</p>}
 <button onClick={()=>{setTeam(team.id);setStopPage(0);setSelected(null);}}>{t.pShowTeam}</button>
 {operational&&writable&&<button disabled={disabled||!!preview||!!moving} onClick={()=>route(team.id)}>{r&&!r.valid?t.pRecalculateStale:t.pRemainingRoute}</button>}
 {!items.length&&!data.limited&&<small>{t.hNoMatches}</small>}</article>;})}</div>
 <div className="web-form-grid"><label>{t.adminTeams}<select value={team} onChange={e=>{setTeam(e.target.value);setStopPage(0);setSelected(null);}}><option value="">{t.hAll}</option>{data.teams.map(team=><option key={team.id} value={team.id}>{team.name}</option>)}</select></label></div>
 <div className="web-legend">{data.teams.map(team=><label key={team.id}><span style={{backgroundColor:colors[team.id]}}/>{team.name}</label>)}</div><p>{t.pMapLegend}</p>
 <Map locale={locale} rows={displayed.map(i=>i.hydrant)} selected={selected} onSelect={setSelected} onOpen={h=>setHydrant(h.id)} plan={overlay} point={p.start_latitude!==null&&p.start_longitude!==null?[p.start_longitude,p.start_latitude]:null}/>
 <section className="admin-card"><h2>{t.pStops}</h2>{displayed.some(i=>i.route_order===null)&&<p>{t.pFallbackOrder}</p>}
 {displayed.slice(stopPage*50,(stopPage+1)*50).map(i=><article className={'plan-stop '+(i.inspection_id?'completed':i.skipped_at?'skipped':'')} key={i.id} style={{borderInlineStartColor:colors[i.team_id??'']??'#68767e'}}>
 <button onClick={()=>setSelected(i.hydrant)}><strong>{i.route_order!==null?`${i.route_order}. `:''}{i.hydrant.code??i.hydrant_id.slice(0,8)}</strong> · {teamName(i.team_id)}</button>
 <p>{i.inspection_id?t.pCompleted:i.skipped_at?t.pSkipped:t.pRemaining} · {statusLabel(t,i.hydrant.status)} · {dueLabel(t,i.hydrant.due_state)}</p><small>{i.hydrant.organization_name} · {i.hydrant.address||i.hydrant.location_description}</small>
 {i.inspection_id&&<p>{resultLabel(t,i.inspection_result??'')} · {i.completed_at&&new Date(i.completed_at).toLocaleString(locale)}</p>}{!i.inspection_id&&i.skip_reason&&<p>{t.pSkipReason}: {i.skip_reason}</p>}
 <div className="actions"><button onClick={()=>setHydrant(i.hydrant_id)}>{t.hDetails}</button>{i.inspection_id&&<button onClick={()=>setInspectionItem(i.id)}>{t.pViewInspection}</button>}
 {writable&&unfinished&&!i.inspection_id&&<button disabled={disabled||!!preview||!!moving} onClick={()=>{setMoving(i);setDestination('');setReason('');}}>{operational?t.pReassign:t.pAssignTeam}</button>}</div></article>)}
 <Pager locale={locale} page={stopPage} more={displayed.length>(stopPage+1)*50} onPage={setStopPage}/></section>
 {moving&&<section ref={transferPanel} className="admin-card" role="region" aria-label={t.pReassign}><h2>{moving.hydrant.code??t.hMissing} · {t.pReassign}</h2><p>{t.pCurrentTeam}: {teamName(moving.team_id)}</p><label>{t.pDestination}<select disabled={disabled} value={destination} onChange={e=>setDestination(e.target.value)}><option value="">{t.pChooseTeam}</option>{data.teams.filter(team=>team.active&&team.id!==moving.team_id).map(team=><option key={team.id} value={team.id}>{team.name}</option>)}</select></label>
 {operational&&<label>{t.pReason}<textarea disabled={disabled} required maxLength={2000} value={reason} onChange={e=>setReason(e.target.value)}/></label>}<p className="admin-notice">{t.pReassignNotice}</p><div className="actions"><button disabled={disabled||!destination||(operational&&!reason.trim())} onClick={transfer}>{t.hSave}</button><button disabled={mutation.busy} onClick={closeMove}>{t.hCancel}</button></div></section>}
 <section className="admin-card"><h2>{t.pReassignmentHistory}</h2>{data.history.map(h=><article key={h.id}><p>{data.items.find(i=>i.id===h.item_id)?.hydrant.code??h.item_id.slice(0,8)} · {teamName(h.from_team_id)} → {teamName(h.to_team_id)}</p><p>{h.reason}</p><small>{h.actor??t.hMissing} · {new Date(h.created_at).toLocaleString(locale)}</small></article>)}{!data.history.length&&<p>{t.hNoMatches}</p>}<Pager locale={locale} page={historyPage} more={data.history_more} onPage={setHistoryPage}/></section>
 <details className="admin-card"><summary>{t.wRecentChanges}</summary>{data.audit.map((a,index)=><p key={index}>{auditLabel(t,a.action)} · {a.actor??t.hMissing} · {new Date(a.created_at).toLocaleString(locale)}</p>)}</details>
 </section>;
}
function auditLabel(t:ReturnType<typeof dictionary>,action:string){return ({PLAN_SAVED:t.pPlanSaved,PLAN_ASSIGNED:t.pAssignmentSaved,PLAN_ASSIGNMENT_CLEARED:t.pAssignmentCleared,PLAN_ACTIVATED:t.pActivated,PLAN_ROUTES_CALCULATED:t.pRoutesCalculated} as Record<string,string>)[action]??t.wRecentChanges;}
