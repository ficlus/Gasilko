'use client';
import dynamic from 'next/dynamic';
import {useEffect,useState} from 'react';
import {dictionary,type Locale} from '@/lib/i18n';
import {initialFilters,rpc,type Row,type Scope} from '@/lib/hydrants/admin';
import {statuses} from '@/lib/hydrants/domain';
import {planningRpc,planningError,type Team,type Page,type PlanDetail,stateLabel} from '@/lib/planning/api';
import {statusLabel,typeLabel} from '../hydrants/Registry';
import {dueLabel} from '../hydrants/HydrantDetail';
import type {Bounds} from '../map/HydrantMap';
import {MutationNotice,Pager,usePlanningMutation} from './shared';
const Map=dynamic(()=>import('../map/HydrantMap'),{ssr:false});

export function PlanEditor({root,locale,scope,initial,initialAddition,onBack,onSaved}:{root:string;locale:Locale;scope:Scope;initial?:PlanDetail;initialAddition?:Row;onBack:()=>void;onSaved:(id:string)=>void}){
 // Freeze the editing base independently of background monitoring/refetches.
 const [base]=useState(initial);
 initial=base;
 const t=dictionary(locale),[id]=useState(()=>initial?.plan.id??crypto.randomUUID()),[organization,setOrg]=useState(initial?.plan.organization_id??scope.organizations.find(o=>o.writable)?.id??'');
 const [name,setName]=useState(initial?.plan.name??''),[state,setState]=useState(initial?.plan.status??'DRAFT');
 const [lat,setLat]=useState(initial?.plan.start_latitude?.toString()??''),[lon,setLon]=useState(initial?.plan.start_longitude?.toString()??''),[returnToStart,setReturn]=useState(initial?.plan.return_to_start??false);
 const [teams,setTeams]=useState(initial?.teams.map(t=>t.id)??[]),[teamRows,setTeamRows]=useState<Team[]>([]),[teamPage,setTeamPage]=useState(0),[teamMore,setTeamMore]=useState(false),[teamSearch,setTeamSearch]=useState('');
 const [selection,setSelection]=useState<Row[]>(()=>{const rows=initial?.items.map(i=>i.hydrant)??[];return initialAddition&&initialAddition.organization_id===initial?.plan.organization_id&&!rows.some(h=>h.id===initialAddition.id)?[...rows,initialAddition]:rows;}),[filters,setFilters]=useState({...initialFilters,organization}),[page,setPage]=useState(0),[rows,setRows]=useState<Row[]>([]),[more,setMore]=useState(false),[markers,setMarkers]=useState<Row[]>([]),[limited,setLimited]=useState(false),[bounds,setBounds]=useState<Bounds|null>(null),[selected,setSelected]=useState<Row|null>(initialAddition??null);
 const [error,setError]=useState(''),[pointMode,setPointMode]=useState(false),[review,setReview]=useState(false),[locationBusy,setLocationBusy]=useState(false),[accuracy,setAccuracy]=useState<number|null>(null);
 const mutation=usePlanningMutation(locale,()=>onSaved(id),onBack);
 const writable=scope.organizations.some(o=>o.id===organization&&o.writable),disabled=mutation.locked||!writable;
 const changeOrg=(org:string)=>{setOrg(org);setFilters({...initialFilters,organization:org});setSelection([]);setTeams([]);setTeamRows([]);setTeamPage(0);setPage(0);setSelected(null);setMarkers([]);setRows([]);setReview(false);};
 useEffect(()=>{let live=true;const timer=setTimeout(()=>{void planningRpc<Page<Team>>('web_teams',{root,owner:organization,state:'active',search:teamSearch,page:teamPage}).then(r=>{if(live){setTeamRows(r.rows);setTeamMore(r.more);}}).catch(e=>{if(live)setError(planningError(locale,e));});},300);return()=>{live=false;clearTimeout(timer);};},[root,organization,teamPage,teamSearch,locale]);
 useEffect(()=>{let live=true;const timer=setTimeout(()=>{void rpc<Page<Row>>('web_hydrants',{root,filters,page,sort_by:'code'}).then(r=>{if(live){setRows(r.rows);setMore(r.more);}}).catch(()=>{if(live){setRows([]);setError(t.hServer);}});},300);return()=>{live=false;clearTimeout(timer);};},[root,filters,page,t.hServer]);
 useEffect(()=>{if(!bounds)return;let live=true;const timer=setTimeout(()=>{void rpc<Page<Row>>('web_hydrants',{root,filters,bounds,sort_by:'code'}).then(r=>{if(live){setMarkers(r.rows);setLimited(r.more);}}).catch(()=>{if(live){setMarkers([]);setError(t.hServer);}});},300);return()=>{live=false;clearTimeout(timer);};},[root,filters,bounds,t.hServer]);
 const changeFilter=(key:string,value:string)=>{setFilters(f=>({...f,[key]:value}));setPage(0);};
 const toggle=(h:Row)=>{if(disabled||h.organization_id!==organization)return;setSelection(s=>s.some(v=>v.id===h.id)?s.filter(v=>v.id!==h.id):[...s,h]);setReview(false);};
 const choosePoint=(point:[number,number])=>{if(disabled)return;setLon(String(point[0]));setLat(String(point[1]));setAccuracy(null);setReview(false);};
 const validPoint=lat.trim()!==''&&lon.trim()!==''&&Number.isFinite(Number(lat))&&Number.isFinite(Number(lon))&&Math.abs(Number(lat))<=90&&Math.abs(Number(lon))<=180;
 const location=()=>{if(!navigator.geolocation){setError(t.pLocationUnavailable);return;}setLocationBusy(true);setError('');navigator.geolocation.getCurrentPosition(p=>{choosePoint([p.coords.longitude,p.coords.latitude]);setAccuracy(p.coords.accuracy);setLocationBusy(false);},()=>{setError(t.pLocationUnavailable);setLocationBusy(false);},{enableHighAccuracy:true,timeout:15000,maximumAge:30000});};
 const submit=()=>{if(disabled)return;if((lat.trim()!==''||lon.trim()!=='')&&!validPoint){setError(t.pRouteCoordinates);return;}
  void mutation.submit(organization,'SAVE',{id,version:initial?.plan.version??0,name:name.trim(),status:state,
   selection_mode:initial?.plan.selection_mode??'MANUAL',selection_snapshot:initial?.plan.selection_snapshot??{...filters,source:'WEB_MANUAL'},
   teams,hydrants:selection.map(h=>h.id),start_latitude:validPoint?Number(lat):null,start_longitude:validPoint?Number(lon):null,return_to_start:returnToStart});};
 const visibleTeams=[...teamRows,...(initial?.teams.filter(t=>!teamRows.some(r=>r.id===t.id))??[])];
 return <section className="web-detail"><button disabled={mutation.busy} onClick={onBack}>{t.pBack}</button><h2>{initial?t.pEditPlan:t.pNewPlan}</h2>
 <MutationNotice locale={locale} mutation={mutation}/>{error&&<p className="admin-notice" role="alert">{error}</p>}
 <fieldset disabled={disabled||review} className="admin-card"><legend>{t.pBasics}</legend><div className="web-form-grid">
 <label>{t.selectOrganization}<select value={organization} disabled={!!initial} onChange={e=>changeOrg(e.target.value)}>{scope.organizations.filter(o=>o.writable||o.id===organization).map(o=><option key={o.id} value={o.id}>{o.name}</option>)}</select></label>
 <label>{t.pPlanName}<input maxLength={120} required value={name} onChange={e=>setName(e.target.value)}/></label>
 <label>{t.hStatus}<select value={state} onChange={e=>setState(e.target.value as typeof state)}>{(initial?['DRAFT','PLANNED','CANCELLED']:['DRAFT','PLANNED']).map(s=><option key={s} value={s}>{stateLabel(t,s)}</option>)}</select></label></div></fieldset>
 <fieldset disabled={disabled||review} className="admin-card"><legend>{t.adminTeams} · {t.pSelected}: {teams.length}</legend><label>{t.hSearch}<input value={teamSearch} maxLength={200} onChange={e=>{setTeamSearch(e.target.value);setTeamPage(0);}}/></label><div className="planning-choices">{visibleTeams.map(team=><label key={team.id}><input type="checkbox" checked={teams.includes(team.id)} onChange={e=>setTeams(v=>e.target.checked?[...v,team.id]:v.filter(id=>id!==team.id))}/>{team.name} {!team.active&&t.hInactive}</label>)}</div><Pager locale={locale} page={teamPage} more={teamMore} onPage={setTeamPage}/></fieldset>
 <fieldset disabled={disabled||review} className="admin-card"><legend>{t.pSelectHydrants} · {selection.length}</legend><p>{t.pSelectionNotice}</p><div className="web-form-grid">
 <label>{t.hSearch}<input maxLength={200} value={filters.search} onChange={e=>changeFilter('search',e.target.value)}/></label>
 <label>{t.hType}<select value={filters.type} onChange={e=>changeFilter('type',e.target.value)}><option value="">{t.hAll}</option>{scope.types.filter(v=>!v.organization_id||v.organization_id===organization).map(v=><option key={v.id} value={v.id}>{typeLabel(t,v,locale)}</option>)}</select></label>
 <label>{t.hStatus}<select value={filters.status} onChange={e=>changeFilter('status',e.target.value)}><option value="">{t.hAll}</option>{statuses.map(s=><option value={s} key={s}>{statusLabel(t,s)}</option>)}</select></label>
 <label>{t.wDue}<select value={filters.due} onChange={e=>changeFilter('due',e.target.value)}><option value="">{t.hAll}</option>{['CURRENT','DUE_SOON','OVERDUE','NEVER_INSPECTED'].map(s=><option value={s} key={s}>{dueLabel(t,s)}</option>)}</select></label>
 <label>{t.hActive}<select value={filters.active} onChange={e=>changeFilter('active',e.target.value)}><option value="active">{t.hActive}</option><option value="inactive">{t.hInactive}</option><option value="all">{t.hAll}</option></select></label></div>
 <div className="planning-selection">{rows.map(h=><label className="web-row" key={h.id}><input type="checkbox" checked={selection.some(s=>s.id===h.id)} onChange={()=>toggle(h)}/><strong>{h.code??t.hMissing}</strong> · {statusLabel(t,h.status)} · {dueLabel(t,h.due_state)}<small>{h.organization_name} · {h.address||h.location_description}</small></label>)}</div><Pager locale={locale} page={page} more={more} onPage={setPage}/>
 <details><summary>{t.pSelected}: {selection.length}</summary><div className="planning-selection">{selection.map(h=><button type="button" key={h.id} onClick={()=>toggle(h)}>{h.code??h.id.slice(0,8)} · {t.pRemove}</button>)}</div></details></fieldset>
 <fieldset disabled={disabled||review||locationBusy} className="admin-card"><legend>{t.pStart}</legend><div className="web-form-grid"><label>{t.hLatitude}<input type="number" step="any" min="-90" max="90" value={lat} onChange={e=>{setLat(e.target.value);setAccuracy(null);}}/></label><label>{t.hLongitude}<input type="number" step="any" min="-180" max="180" value={lon} onChange={e=>{setLon(e.target.value);setAccuracy(null);}}/></label></div><div className="actions"><button onClick={location}>{t.pMyLocation}</button><button aria-pressed={pointMode} onClick={()=>setPointMode(v=>!v)}>{t.pChooseStart}</button><button onClick={()=>{setLat('');setLon('');setAccuracy(null);}}>{t.pClearStart}</button></div><label><input type="checkbox" checked={returnToStart} onChange={e=>setReturn(e.target.checked)}/>{t.pReturn}</label><p>{t.wChooseLocation}</p>{accuracy!==null&&<p>{t.pAccuracy}: {Math.round(accuracy)} m</p>}</fieldset>
 {limited&&<p role="status">{t.wViewportLimit}</p>}
 <p>{t.pSelectionMapLegend}</p>
 <Map locale={locale} rows={[...markers.filter(h=>!selection.some(s=>s.id===h.id)),...selection]} highlightedIds={selection.map(h=>h.id)} selected={selected} onSelect={setSelected} onBounds={setBounds} onOpen={h=>{if(!review)toggle(h);}} actionLabel={selected&&selection.some(h=>h.id===selected.id)?t.pDeselect:t.pSelect} point={validPoint?[Number(lon),Number(lat)]:null} onPoint={pointMode&&!disabled&&!review&&!locationBusy?choosePoint:undefined}/>
 {review&&<section className="admin-card"><h2>{t.pReview}</h2><p>{name} · {stateLabel(t,state)}</p><p>{scope.organizations.find(o=>o.id===organization)?.name}</p><p>{t.adminTeams}: {teams.length} · {t.adminHydrants}: {selection.length}</p><p>{t.pStart}: {validPoint?`${lat}, ${lon}`:t.pNoStart} · {t.pReturn}: {returnToStart?t.pYes:t.pNo}</p><p>{t.pAssignmentAfterSave}</p></section>}
 <div className="actions">{review?<><button disabled={disabled} onClick={()=>setReview(false)}>{t.pEditPlan}</button><button disabled={disabled} onClick={submit}>{t.hSave}</button></>:<button disabled={disabled||locationBusy||!name.trim()||(!validPoint&&(!!lat.trim()||!!lon.trim()))||(state==='PLANNED'&&(!teams.length||!selection.length))} onClick={()=>setReview(true)}>{t.pReview}</button>}</div>
 </section>;
}
