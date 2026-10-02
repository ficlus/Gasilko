'use client';
import Link from 'next/link';
import {useEffect,useState} from 'react';
import {dictionary,type Locale} from '@/lib/i18n';
import {planningRpc,planningError,planStates,stateLabel,providerLabel,type Plan,type Page} from '@/lib/planning/api';
import {Pager,Progress,usePlanningScope} from './shared';
import {PlanDetail} from './PlanDetail';
import {PlanEditor} from './PlanEditor';

export function Plans({root,locale,initialId}:{root:string;locale:Locale;initialId?:string}){
 const t=dictionary(locale),{scope,error,revision,reload}=usePlanningScope(root,locale),[detail,setDetail]=useState(initialId??''),[create,setCreate]=useState(false),[page,setPage]=useState(0),[search,setSearch]=useState(''),[state,setState]=useState(''),[owner,setOwner]=useState(''),[rows,setRows]=useState<Plan[]>([]),[more,setMore]=useState(false),[failure,setFailure]=useState('');
 useEffect(()=>{if(!scope||detail||create)return;let live=true;const timer=setTimeout(()=>{void planningRpc<Page<Plan>>('web_plans',{root,page,search,state,owner:owner||null}).then(r=>{if(live){setRows(r.rows);setMore(r.more);setFailure('');}}).catch(e=>{if(live){setRows([]);setFailure(planningError(locale,e));}});},300);return()=>{live=false;clearTimeout(timer);};},[root,scope,revision,detail,create,page,search,state,owner,locale]);
 const back=()=>{setDetail('');setCreate(false);window.history.replaceState(null,'',`/${locale}/admin/org/${root}/plans`);reload();};
 const open=(id:string)=>{setDetail(id);window.history.replaceState(null,'',`/${locale}/admin/org/${root}/plans?plan=${id}`);};
 if(!scope)return <p role="status">{error||t.loading}</p>;
 if(create)return <PlanEditor root={root} locale={locale} scope={scope} onBack={back} onSaved={id=>{setCreate(false);open(id);reload();}}/>;
 if(detail)return <PlanDetail key={detail} root={root} id={detail} locale={locale} scope={scope} onBack={back}/>;
 return <section className="web-detail"><div className="actions"><button onClick={reload}>{t.hRefresh}</button>{scope.organizations.some(o=>o.writable)&&<button onClick={()=>setCreate(true)}>{t.pNewPlan}</button>}</div>
 <div className="admin-card web-form-grid"><label>{t.hSearch}<input maxLength={200} value={search} onChange={e=>{setSearch(e.target.value);setPage(0);}}/></label><label>{t.hStatus}<select value={state} onChange={e=>{setState(e.target.value);setPage(0);}}><option value="">{t.hAll}</option>{planStates.map(s=><option key={s} value={s}>{stateLabel(t,s)}</option>)}</select></label><label>{t.selectOrganization}<select value={owner} onChange={e=>{setOwner(e.target.value);setPage(0);}}><option value="">{t.wAllDescendants}</option>{scope.organizations.map(o=><option key={o.id} value={o.id}>{o.name}</option>)}</select></label></div>
 {failure&&<p role="alert">{failure}</p>}<div className="admin-cards">{rows.map(p=><article className="admin-card" key={p.id}><h2>{p.name}</h2><p>{p.organization_name} · {stateLabel(t,p.status)}</p><Progress locale={locale} plan={p}/><p>{t.adminTeams}: {p.team_count} · {t.pUnassigned}: {p.unassigned}</p><p>{p.route_summary.length?p.route_summary.map(r=>`${providerLabel(t,r.provider)} · ${r.valid?t.pValidRoute:t.pStaleRoute}`).join(' / '):t.pNoRoutes}</p><small>{t.pUpdated}: {new Date(p.updated_at).toLocaleString(locale)}</small><button onClick={()=>open(p.id)}>{t.hDetails}</button></article>)}</div>{!rows.length&&<p>{t.hNoMatches}</p>}<Pager locale={locale} page={page} more={more} onPage={setPage}/></section>;
}

type Overview={draft:number;active:number;teams:number;stale:number;plans:Plan[];finished:Plan[]};
export function PlanningDashboard({root,locale}:{root:string;locale:Locale}){
 const t=dictionary(locale),{scope,error,revision,reload}=usePlanningScope(root,locale),[data,setData]=useState<Overview|null>(null),[failure,setFailure]=useState('');
 useEffect(()=>{if(!scope)return;let live=true;void planningRpc<Overview>('web_planning_dashboard',{root}).then(d=>{if(live){setData(d);setFailure('');}}).catch(e=>{if(live){setData(null);setFailure(planningError(locale,e));}});return()=>{live=false;};},[scope,root,revision,locale]);
 if(!scope)return <p role="status">{error||t.loading}</p>;
 return <section className="web-detail"><h2>{t.pOperations}</h2><button onClick={reload}>{t.hRefresh}</button>{failure&&<p role="alert">{failure}</p>}{data&&<><div className="admin-cards web-metrics">{[[t.pDraft,data.draft],[t.pActive,data.active],[t.pActiveTeams,data.teams],[t.pStaleRoutes,data.stale]].map(([label,n])=><article className="admin-card" key={label}><span>{label}</span><strong>{n}</strong></article>)}</div>
 <div className="admin-cards">{[[t.pActivePlans,data.plans],[t.pRecentCompleted,data.finished]].map(([title,plans])=><section className="admin-card" key={title as string}><h2>{title as string}</h2>{(plans as Plan[]).map(p=><article key={p.id}><Link href={`/${locale}/admin/org/${root}/plans?plan=${p.id}`}>{p.name}</Link><p>{p.organization_name}</p><Progress locale={locale} plan={p}/>{p.stale_routes>0&&<p>{t.pStaleRoutes}: {p.stale_routes}</p>}</article>)}{!(plans as Plan[]).length&&<p>{t.hNoMatches}</p>}</section>)}</div><Link href={`/${locale}/admin/org/${root}/plans`}>{t.adminPlans}</Link></>}</section>;
}
