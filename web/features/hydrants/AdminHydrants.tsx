'use client';
import dynamic from 'next/dynamic';
import {useEffect,useRef,useState} from 'react';
import {useRouter} from 'next/navigation';
import {dictionary,type Locale} from '@/lib/i18n';
import {browserClient} from '@/lib/supabase/browser';
import {initialFilters,organizationColor,rpc,type Filters,type Row,type Scope} from '@/lib/hydrants/admin';
import {statuses,failure} from '@/lib/hydrants/domain';
import {statusLabel,typeLabel} from './Registry';
import {resultLabel} from './ManualInspection';
import {HydrantDetail,dueLabel} from './HydrantDetail';
import {HydrantEditor} from './HydrantEditor';
import type {Bounds} from '../map/HydrantMap';
const Map=dynamic(()=>import('../map/HydrantMap'),{ssr:false});
type Dashboard={metrics:Record<string,number>;inspections:{id:string;hydrant_id:string;code:string;result:string;completed_at:string;organization_name:string}[];changes:{id:string;code:string;status:Row['status'];updated_at:string;organization_name:string}[]};
export function AdminHydrants({locale,root,section,initialId}:{locale:Locale;root:string;section:string;initialId?:string}){
 const t=dictionary(locale),router=useRouter();const [scope,setScope]=useState<Scope|null>(null),[filters,setFilters]=useState<Filters>(initialFilters),[page,setPage]=useState(0),[sort,setSort]=useState('code');
 const [rows,setRows]=useState<Row[]>([]),[markers,setMarkers]=useState<Row[]>([]),[selected,setSelected]=useState<Row|null>(null),[more,setMore]=useState(false),[limited,setLimited]=useState(false);
 const [bounds,setBounds]=useState<Bounds|null>(null),[view,setView]=useState(section==='map'?'map':'list'),[detail,setDetail]=useState<string|null>(initialId??null),[create,setCreate]=useState(false);
 const [error,setError]=useState(''),[revision,setRevision]=useState(0),[loading,setLoading]=useState(false),[dashboard,setDashboard]=useState<Dashboard|null>(null);
 const [blocked,setBlocked]=useState(false);
 const listRef=useRef<HTMLDivElement>(null);const creating=useRef(false);creating.current=create;
 const change=(patch:Partial<Filters>)=>{setFilters(f=>({...f,...patch}));setPage(0);setSelected(null);};
 useEffect(()=>{let alive=true;setError('');void rpc<Scope>('web_hydrant_context',{root}).then(s=>{if(alive){setScope(s);setSelected(h=>h&&s.organizations.some(o=>o.id===h.organization_id)?h:null);}}).catch(e=>{if(alive){if(['forbidden','expired'].includes(failure(e))){setScope(null);setRows([]);setMarkers([]);setSelected(null);setDashboard(null);}setError(t.hForbidden);}});return()=>{alive=false;};},[root,revision,t.hForbidden]);
 useEffect(()=>{let alive=true;const c=browserClient();let account:string|undefined;
 void c?.auth.getUser().then(r=>{account=r.data.user?.id;});
 const auth=c?.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT'||(account&&session?.user.id!==account)){alive=false;setBlocked(true);setScope(null);setRows([]);setMarkers([]);setDashboard(null);setSelected(null);setDetail(null);setCreate(false);router.replace('/'+locale+'/account');}});
 const timer=setInterval(()=>{if(alive&&!creating.current)setRevision(v=>v+1);},60000);
 return()=>{alive=false;clearInterval(timer);auth?.data.subscription.unsubscribe();};},[router,locale]);
 useEffect(()=>{if(!scope||detail||create)return;let alive=true;setLoading(true);setError('');
 const timer=setTimeout(()=>{void rpc<{rows:Row[];more:boolean}>('web_hydrants',{root,filters,page,sort_by:sort}).then(r=>{if(alive){setRows(r.rows);setMore(r.more);setSelected(s=>s?r.rows.find(h=>h.id===s.id)??s:null);}}).catch(()=>{if(alive){setRows([]);setMarkers([]);setSelected(null);setError(t.hForbidden);}}).finally(()=>{if(alive)setLoading(false);});},300);
 return()=>{alive=false;clearTimeout(timer);};},[scope,root,filters,page,sort,detail,create,t.hForbidden]);
 useEffect(()=>{if(!scope||!bounds||detail||create)return;let alive=true;setMarkers([]);setLimited(false);
 const timer=setTimeout(()=>{void rpc<{rows:Row[];more:boolean}>('web_hydrants',{root,filters,bounds,sort_by:'code'}).then(r=>{if(alive){setMarkers(r.rows);setLimited(r.more);setSelected(s=>s?r.rows.find(h=>h.id===s.id)??s:null);}}).catch(()=>{if(alive){setMarkers([]);setSelected(null);setError(t.hServer);}});},300);return()=>{alive=false;clearTimeout(timer);};},[scope,root,bounds,filters,detail,create,t.hServer]);
 useEffect(()=>{if(!scope||section!=='dashboard')return;let alive=true;void rpc<Dashboard>('web_hydrant_dashboard',{root}).then(d=>{if(alive)setDashboard(d);}).catch(()=>{if(alive){setDashboard(null);setError(t.hForbidden);}});return()=>{alive=false;};},[scope,root,section,t.hForbidden]);
 const orgs=Array.from(new Set([...rows,...markers].map(r=>r.organization_id))).sort().slice(0,20).join(',');
 useEffect(()=>{if(detail||create||!orgs)return;const c=browserClient();if(!c)return;const channel=c.channel('web-hydrants:'+root);let timer:ReturnType<typeof setTimeout>;
 for(const org of orgs.split(','))for(const table of ['hydrants','inspections','hydrant_photos','inspection_photos'])channel.on('postgres_changes',{event:'*',schema:'public',table,filter:'organization_id=eq.'+org},()=>{clearTimeout(timer);timer=setTimeout(()=>setRevision(v=>v+1),500);});
 channel.subscribe();return()=>{clearTimeout(timer);void c.removeChannel(channel);};},[root,orgs,detail,create]);
 useEffect(()=>{if(selected)listRef.current?.querySelector(`[data-hydrant="${selected.id}"]`)?.scrollIntoView({block:'nearest'});},[selected]);
 const reload=()=>setRevision(v=>v+1);
 if(blocked)return <p role="alert">{t.hExpired}</p>;
 if(!scope)return <p role={error?'alert':'status'}>{error||t.loading}</p>;
 if(create)return <HydrantEditor locale={locale} scope={scope} onCancel={()=>{setCreate(false);reload();}} onSaved={h=>{setCreate(false);setDetail(h.id);reload();}}/>;
 if(detail)return <HydrantDetail key={root+detail} locale={locale} root={root} id={detail} scope={scope} onBack={()=>{setDetail(null);reload();}} onChanged={reload}/>;
 const displayRows:Row[]=selected&&!rows.some(r=>r.id===selected.id)?[selected,...rows]:rows;
 return <section className="web-hydrants"><div className="actions"><button onClick={reload}>{t.hRefresh}</button>{scope.organizations.some(o=>o.writable)&&<button onClick={()=>setCreate(true)}>{t.hAdd}</button>}</div>
 {error&&<p role="alert">{error}</p>}
 {section==='dashboard'&&dashboard&&<><div className="admin-cards web-metrics">{Object.entries(dashboard.metrics).map(([k,n])=><article className="admin-card" key={k}><span>{k==='total'?t.wActiveTotal:k==='OVERDUE'||k==='NEVER_INSPECTED'?dueLabel(t,k):statusLabel(t,k as Row['status'])}</span><strong>{n}</strong></article>)}</div>
 <div className="admin-cards"><section className="admin-card"><h2>{t.wRecentInspections}</h2>{dashboard.inspections.map(i=><button className="web-row" key={i.id} onClick={()=>setDetail(i.hydrant_id)}><strong>{i.code}</strong> {resultLabel(t,i.result)}<small>{i.organization_name} · {new Date(i.completed_at).toLocaleString(locale)}</small></button>)}</section>
 <section className="admin-card"><h2>{t.wRecentChanges}</h2>{dashboard.changes.map(h=><button className="web-row" key={h.id} onClick={()=>setDetail(h.id)}><strong>{h.code}</strong> {statusLabel(t,h.status)}<small>{h.organization_name} · {new Date(h.updated_at).toLocaleString(locale)}</small></button>)}</section></div></>}
 <div className="web-form-grid admin-card"><label>{t.hSearch}<input type="search" value={filters.search} maxLength={200} onChange={e=>change({search:e.target.value})}/></label>
 <label>{t.selectOrganization}<select value={filters.organization} onChange={e=>change({organization:e.target.value})}><option value="">{t.wAllDescendants}</option>{scope.organizations.map(o=><option key={o.id} value={o.id}>{o.name}</option>)}</select></label>
 <label>{t.hType}<select value={filters.type} onChange={e=>change({type:e.target.value})}><option value="">{t.hAll}</option>{scope.types.filter(v=>!filters.organization||!v.organization_id||v.organization_id===filters.organization).map(v=><option key={v.id} value={v.id}>{typeLabel(t,v,locale)}</option>)}</select></label>
 <label>{t.hStatus}<select value={filters.status} onChange={e=>change({status:e.target.value})}><option value="">{t.hAll}</option>{statuses.map(s=><option key={s} value={s}>{statusLabel(t,s)}</option>)}</select></label>
 <label>{t.hActive}<select value={filters.active} onChange={e=>change({active:e.target.value})}><option value="active">{t.hActive}</option><option value="inactive">{t.hInactive}</option><option value="all">{t.hAll}</option></select></label>
 <label>{t.wDue}<select value={filters.due} onChange={e=>change({due:e.target.value})}><option value="">{t.hAll}</option>{['CURRENT','DUE_SOON','OVERDUE','NEVER_INSPECTED'].map(d=><option value={d} key={d}>{dueLabel(t,d)}</option>)}</select></label>
 <label>{t.wSort}<select value={sort} onChange={e=>{setSort(e.target.value);setPage(0);}}><option value="code">{t.hCode}</option><option value="updated">{t.wRecentChanges}</option><option value="due">{t.wNextDue}</option></select></label></div>
 <details className="admin-card"><summary>{t.wOrganizationLegend}</summary><p>{t.wMarkerLegend}</p><div className="web-legend">{scope.organizations.map(o=><label key={o.id}><input type="checkbox" checked={!filters.hidden.includes(o.id)} onChange={e=>change({hidden:e.target.checked?filters.hidden.filter(id=>id!==o.id):[...filters.hidden,o.id]})}/><span style={{backgroundColor:organizationColor(o.id)}}/>{o.name}</label>)}</div><p>{statuses.map(s=>statusLabel(t,s)).join(' · ')}</p></details>
 <div className="actions web-view-switch"><button aria-pressed={view==='list'} onClick={()=>setView('list')}>{t.wList}</button><button aria-pressed={view==='map'} onClick={()=>setView('map')}>{t.adminMap}</button></div>
 <div className={'web-split show-'+view}><div className="web-list" ref={listRef} aria-busy={loading}>
 {loading&&<p role="status">{t.loading}</p>}{displayRows.map(h=><article data-hydrant={h.id} key={h.id} className={'web-row '+(h.id===selected?.id?'selected':'')}><button onClick={()=>setSelected(h)}><strong>{h.code??t.hMissing}</strong><span>{statusLabel(t,h.status)} · {typeLabel(t,{name:h.type_name,code:h.type_code,organization_id:h.type_organization_id,names:h.type_names},locale)}</span><small>{h.organization_name}</small><span>{h.address||h.location_description}</span><small>{dueLabel(t,h.due_state)}</small></button><button onClick={()=>setDetail(h.id)}>{t.hDetails}</button></article>)}
 {!rows.length&&!loading&&<p>{t.hNoMatches}</p>}<div className="actions"><button disabled={!page||loading} onClick={()=>setPage(p=>p-1)}>{t.wPrevious}</button><span>{page+1}</span><button disabled={!more||loading} onClick={()=>setPage(p=>p+1)}>{t.wNext}</button></div></div>
 <div className="web-map-panel">{limited&&<p role="status">{t.wViewportLimit}</p>}<Map locale={locale} rows={selected&&!markers.some(m=>m.id===selected.id)?[...markers,selected]:markers} selected={selected} onBounds={setBounds} onSelect={setSelected} onOpen={h=>setDetail(h.id)}/></div></div>
 </section>;
}
