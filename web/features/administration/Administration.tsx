'use client';
import Link from 'next/link';
import {useEffect,useRef,useState} from 'react';
import type {Locale} from '@/lib/i18n';
import {administrationRpc,deliver,errorText,label,rows,stateLabel,str,type Page,type Row} from '@/lib/administration/api';
import {administrationText} from '@/lib/administration/messages';
import {ConfigurationPicker,Pager,StructuredData,useAdministrationScope} from './Controls';
import {Editor} from './Editor';

type Props={locale:Locale;root:string|null;section:string};
const configKinds=['countries','organization_types','relationship_types','rules','positions'];

function Command({locale,organization,action,request,title,onSaved}:{locale:Locale;organization:string|null;action:string;request:Row;title:string;onSaved:()=>void}){
 const t=administrationText(locale),pending=useRef<{organization:string|null;operation:string;action:string;request:Row}|null>(null),running=useRef(false);
 const [review,setReview]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState('');
 async function send(){if(running.current)return;running.current=true;setBusy(true);setError('');pending.current??={organization,operation:crypto.randomUUID(),action,request};
  try{await administrationRpc('web_administration_write',pending.current);if(action==='RESEND')await deliver(String(request.id),locale);onSaved();}
  catch(e){setError(errorText(e,locale));}finally{running.current=false;setBusy(false);}}
 return <div>{!review?<button onClick={()=>setReview(true)}>{title}</button>:<div className="admin-notice"><strong>{title}</strong><p>{t.review}</p><div className="actions"><button disabled={busy} onClick={()=>void send()}>{pending.current?t.retry:t.save}</button><button disabled={busy} onClick={()=>{pending.current=null;setReview(false);setError('');onSaved();}}>{t.cancel}</button></div>{error&&<p role="alert">{error}</p>}</div>}</div>;
}
function Delivery({id,locale}:{id:string;locale:Locale}){
 const t=administrationText(locale),[busy,setBusy]=useState(false),[message,setMessage]=useState('');
 return <div><button disabled={busy} onClick={()=>{setBusy(true);setMessage('');void deliver(id,locale).then(()=>setMessage(t.sent)).catch(e=>setMessage(errorText(e,locale))).finally(()=>setBusy(false));}}>{t.send}</button>{message&&<p role="status">{message}</p>}</div>;
}

export function Administration({locale,root,section}:Props){
 const t=administrationText(locale),access=useAdministrationScope(root,locale),scope=access.scope;
 const tabs=section==='users'?['users','invitations','requests']:section==='organizations'?['organizations','relationships']:section==='system'?[...configKinds,'organizations','relationships','types','audit']:['types','audit'].includes(section)?[section]:['organizations'];
 const [kind,setKind]=useState(tabs[0]),[filters,setFilters]=useState<Record<string,string>>({}),[page,setPage]=useState(0),[data,setData]=useState<Page>({rows:[],more:false}),[loading,setLoading]=useState(true),[error,setError]=useState('');
 const [editor,setEditor]=useState<{action:string;initial?:Row}|null>(null),[detail,setDetail]=useState<Row|null>(null);
 const serialized=JSON.stringify(filters),configuration=configKinds.includes(kind);
 const refresh=()=>{setEditor(null);setDetail(null);access.reload();};
 useEffect(()=>{let live=true;setData({rows:[],more:false});setLoading(true);if(!scope)return;
  const queryFilters={...filters};if(kind==='audit')for(const key of ['from','to']){if(queryFilters[key]){const date=new Date(queryFilters[key]);queryFilters[key]=Number.isNaN(date.getTime())?'':date.toISOString();}}
  const timer=setTimeout(()=>{void administrationRpc<Page>(configuration?'web_administration_configuration':kind==='audit'?'web_administration_audit':'web_administration_list',configuration?{kind,search:filters.search??'',page}:kind==='audit'?{root,filters:queryFilters,page}:{root,kind,filters:queryFilters,page}).then(r=>{if(live){setData(r);setError('');}}).catch(e=>{if(live){setData({rows:[],more:false});setDetail(null);setEditor(null);setError(errorText(e,locale));}}).finally(()=>{if(live)setLoading(false);});},200);
  return()=>{live=false;clearTimeout(timer);};
 // Serialized filters make only actual filter changes reload this bounded query.
 // eslint-disable-next-line react-hooks/exhaustive-deps
 },[root,kind,serialized,page,locale,scope,access.revision,configuration]);
 const change=(key:string,value:string)=>{setFilters(v=>({...v,[key]:value}));setPage(0);setDetail(null);setEditor(null);};
 if(!scope)return <section className="admin-card"><p role={access.error?'alert':'status'}>{access.error||t.loading}</p></section>;
 const canEdit=(row:Row)=>scope.organizations.some(o=>o.id===str(row,'organization_id')&&o.admin&&o.active);
 const orgAdmin=scope.organizations.some(o=>o.admin&&o.active);
 const current=scope.organizations.find(o=>o.id===root);
 const heading=(key:string)=>(t as Record<string,string>)[key]??key;
 const field=(key:string,title:string,type='text')=><label>{title}<input type={type} value={filters[key]??''} onChange={e=>change(key,e.target.value)}/></label>;
 const selectedOrg=<label>{t.organization}<select value={filters.organization??''} onChange={e=>change('organization',e.target.value)}><option value="">{t.all}</option>{scope.organizations.map(o=><option key={o.id} value={o.id}>{o.name}</option>)}</select></label>;
 const entryAction=(action:string,initial?:Row)=>{setDetail(null);setEditor({action,initial});};
 function renderRow(row:Row){
  const id=str(row,'id'),org=str(row,'organization_id'),writable=canEdit(row);
  if(kind==='users')return <><h3>{str(row,'display_name')||str(row,'email')}</h3><p>{str(row,'email')} · {str(row,'organization_name')}</p><p><strong>{stateLabel(str(row,'role'),locale)}</strong> · {row.active?t.active:t.inactive} · {t.account}: {stateLabel(str(row,'account_status'),locale)}</p>
   <ul>{rows(row,'positions').filter(p=>p.active===true).map(p=><li key={str(p,'id')}>{label(p,locale)} · {str(p,'valid_from')} – {str(p,'valid_to')}</li>)}</ul>
   <div className="actions"><button onClick={()=>setDetail(row)}>{t.history}</button>{writable&&<><button onClick={()=>entryAction('MEMBERSHIP',row)}>{t.membership}</button>{row.active===true&&<button onClick={()=>entryAction('POSITION',row)}>{t.assign}</button>}</>}</div></>;
  if(kind==='invitations')return <><h3>{str(row,'email')}</h3><p>{str(row,'organization_name')} · {stateLabel(str(row,'role'),locale)} · {stateLabel(str(row,'effective_status'),locale)}</p><p>{t.expires}: {str(row,'expires_at')}</p>{str(row,'message')&&<p>{str(row,'message')}</p>}{writable&&row.status==='PENDING'&&<div className="actions"><Delivery id={id} locale={locale}/><Command {...{locale,organization:org,onSaved:refresh}} action="RESEND" request={{id,version:row.version}} title={t.resend}/><Command {...{locale,organization:org,onSaved:refresh}} action="REVOKE" request={{id,version:row.version}} title={t.revoke}/></div>}</>;
  if(kind==='requests')return <><h3>{str(row,'display_name')||str(row,'email')}</h3><p>{str(row,'email')} · {str(row,'organization_name')} · {stateLabel(str(row,'requested_role'),locale)} · {stateLabel(str(row,'status'),locale)}</p><p>{str(row,'requested_at')}</p></>;
  if(kind==='organizations')return <><h3>{str(row,'name')}</h3><p>{str(row,'code')} · {row.active?t.active:t.inactive} · {label({names:row.type_names},locale)}</p><p>{t.country}: {str(row,'country_name')||t.global} · {t.members}: {str(row,'member_count')} · {t.admins}: {str(row,'admin_count')}</p><div className="actions"><button onClick={()=>setDetail(row)}>{t.details}</button>{row.active===true&&<Link href={'/'+locale+'/admin/org/'+id+'/organizations'}>{t.organization}</Link>}{scope.organizations.some(o=>o.id===id&&o.admin)&&<button onClick={()=>entryAction('ORGANIZATION',row)}>{t.edit}</button>}</div></>;
  if(kind==='relationships')return <><h3>{str(row,'parent_name')} → {str(row,'child_name')}</h3><p>{label({names:row.type_names},locale)} · {row.active?t.active:t.inactive}</p><p>{str(row,'valid_from')} – {str(row,'valid_to')}</p><p><small>{str(row,'parent_organization_id')} → {str(row,'child_organization_id')}</small></p>{(scope.operator||[row.parent_organization_id,row.child_organization_id].every(id=>scope.organizations.some(o=>o.id===id&&o.admin&&o.active)))&&<button onClick={()=>entryAction('RELATIONSHIP',row)}>{t.edit}</button>}</>;
  if(kind==='types')return <><h3>{label(row,locale)}</h3><p>{str(row,'code')} · {str(row,'organization_name')||t.global} · {row.active?t.active:t.inactive}</p><p>{t.usage}: {str(row,'usage_count')} · {t.order}: {str(row,'display_order')}</p>{(writable||(!row.organization_id&&scope.operator))&&<button onClick={()=>entryAction('TYPE',row)}>{t.edit}</button>}</>;
  if(kind==='audit')return <><h3>{str(row,'action')}</h3><p>{str(row,'created_at')} · {str(row,'actor')||str(row,'user_id')} · {str(row,'organization_name')||t.global}</p><p>{str(row,'entity_type')} · {str(row,'entity_id')}</p>{str(row,'reason')&&<p>{t.reason}: {str(row,'reason')}</p>}<button onClick={()=>setDetail(row)}>{t.details}</button></>;
  return <><h3>{label(row,locale)}</h3><p>{str(row,'code')} · {row.active?t.active:t.inactive}</p>{kind==='rules'&&<p>{str(row,'parent_type_id')} → {str(row,'child_type_id')} · {str(row,'relationship_type')}</p>}<div className="actions"><button onClick={()=>setDetail(row)}>{t.details}</button>{scope.operator&&<button onClick={()=>entryAction('CONFIGURATION',row)}>{t.edit}</button>}</div></>;
 }
 return <section className="administration"><nav className="actions" aria-label={t.title}>{tabs.map(tab=><button key={tab} aria-pressed={kind===tab} onClick={()=>{setKind(tab);setFilters({});setPage(0);setDetail(null);setEditor(null);}}>{heading(tab)}</button>)}</nav>
  <h2>{heading(kind)}</h2>{section==='system'&&<p className="admin-notice">{t.systemWarning}</p>}{!orgAdmin&&!scope.operator&&<p className="admin-notice">{t.readOnly}</p>}
  {kind==='requests'&&<p>{t.requestNotice} <Link href={'/'+locale+'/account'}>{t.account}</Link></p>}
  <div className="administration-filters">{kind!=='audit'&&field('search',t.search)}{!configuration&&root&&selectedOrg}
   {kind==='users'&&<><label>{t.role}<select value={filters.role??''} onChange={e=>change('role',e.target.value)}><option value="">{t.all}</option>{['FIREFIGHTER','MANAGER','ADMIN'].map(r=><option key={r} value={r}>{stateLabel(r,locale)}</option>)}</select></label><details><summary>{t.position}</summary><ConfigurationPicker locale={locale} kind="positions" value={filters.position?[filters.position]:[]} onChange={v=>change('position',v[0]??'')}/></details></>}
   {['users','organizations','invitations'].includes(kind)&&<label>{t.state}<select value={filters.state??''} onChange={e=>change('state',e.target.value)}><option value="">{t.all}</option>{(kind==='invitations'?['PENDING','ACCEPTED','REVOKED','EXPIRED']:['active','inactive']).map(s=><option key={s} value={s}>{s==='active'?t.active:s==='inactive'?t.inactive:stateLabel(s,locale)}</option>)}</select></label>}
   {kind==='audit'&&<>{field('from',t.dateFrom,'datetime-local')}{field('to',t.dateTo,'datetime-local')}{field('actor',t.actor)}{field('action',t.event)}{field('entity_type',t.entityType)}{field('entity_id',t.entityId)}<label><input type="checkbox" checked={filters.descendants!=='false'} onChange={e=>change('descendants',String(e.target.checked))}/>{t.descendants}</label><label><input type="checkbox" checked={filters.security==='true'} onChange={e=>change('security',String(e.target.checked))}/>{t.security}</label></>}
  </div>
  <div className="actions">{kind==='users'&&orgAdmin&&<button onClick={()=>entryAction('MEMBERSHIP')}>{t.addExisting}</button>}{kind==='invitations'&&orgAdmin&&<button onClick={()=>entryAction('INVITE')}>{t.invite}</button>}
   {kind==='organizations'&&current?.admin&&current.active&&<button onClick={()=>entryAction('CHILD')}>{t.child}</button>}
   {kind==='relationships'&&(orgAdmin||scope.operator)&&<button onClick={()=>entryAction('RELATIONSHIP')}>{t.create}</button>}
   {kind==='types'&&(orgAdmin||scope.operator)&&<button onClick={()=>entryAction('TYPE')}>{t.create}</button>}
   {configuration&&scope.operator&&<button onClick={()=>entryAction('CONFIGURATION')}>{t.create}</button>}
   {section==='system'&&scope.operator&&<button onClick={()=>entryAction('CHILD')}>{t.rootCreate}</button>}
  </div>
  {editor&&<Editor key={editor.action+':'+str(editor.initial??{},'id')+':'+str(editor.initial??{},'user_id')} {...{locale,root,scope,kind}} {...editor} onSaved={refresh} onCancel={refresh}/>}
  {detail&&<section className="admin-card"><h3>{t.details}</h3><button onClick={()=>setDetail(null)}>{t.close}</button>
   {kind==='users'?<><h4>{t.history}</h4><p>{t.positionNotice}</p>{rows(detail,'positions').map(p=><div key={str(p,'id')}><p>{label(p,locale)} · {p.active?t.active:t.inactive} · {str(p,'valid_from')} – {str(p,'valid_to')}</p>{p.active===true&&canEdit(detail)&&<Command locale={locale} organization={str(detail,'organization_id')} action="END_POSITION" request={{id:p.id,user_id:detail.user_id,revision:detail.revision}} title={t.end} onSaved={refresh}/>}</div>)}<h4>{t.ended}</h4>{detail.history_more===true&&<p>{t.historyLimit}</p>}{rows(detail,'endings').map(e=><p key={str(e,'id')}>{stateLabel(str(e,'role'),locale)} · {str(e,'started_at')} – {str(e,'ended_at')} · {str(e,'ended_by')}</p>)}</>:
    kind==='audit'?<><p>{t.auditNotice}</p><p>{t.operation}: {str(detail,'operation_id')}</p><h4>{t.before}</h4><StructuredData value={detail.old_data}/><h4>{t.after}</h4><StructuredData value={detail.new_data}/></>:<StructuredData value={detail}/>}</section>}
  {loading&&<p role="status">{t.loading}</p>}{error&&<p role="alert">{error}</p>}{!loading&&!data.rows.length&&!error&&<p>{t.empty}</p>}
  <div className="admin-cards">{data.rows.map(row=><article className="admin-card" key={str(row,'id')||(row.user_id?str(row,'user_id')+':'+str(row,'organization_id'):str(row,'code'))}>{renderRow(row)}</article>)}</div>
  <Pager {...{page,locale}} more={data.more} onPage={v=>{setPage(v);setDetail(null);setEditor(null);}}/>
 </section>;
}

export function AdministrationDashboard({locale,root}:{locale:Locale;root:string}){
 const t=administrationText(locale),access=useAdministrationScope(root,locale),[data,setData]=useState<Row|null>(null),[error,setError]=useState('');
 useEffect(()=>{let live=true;if(!access.scope){setData(null);return;}void administrationRpc<Row>('web_administration_dashboard',{root}).then(r=>{if(live){setData(r);setError('');}}).catch(e=>{if(live){setData(null);setError(errorText(e,locale));}});return()=>{live=false;};},[root,locale,access.scope,access.revision]);
 return <section className="admin-card"><h2>{t.overview}</h2><p>{t.bounded}</p>{(access.error||error)&&<p role="alert">{access.error||error}</p>}{data&&<><dl>{([['invitations',t.invitations],['requests',t.requests],['ended',t.ended],['no_admin',t.noAdmin]] as const).map(([key,name])=><div key={key}><dt>{name}</dt><dd>{str(data,key)}</dd></div>)}</dl>{data.recent!=null&&<p>{t.recent}: {str(data.recent as Row,'action')} · {str(data.recent as Row,'created_at')}</p>}</>}</section>;
}
