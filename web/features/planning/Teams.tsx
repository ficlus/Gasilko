'use client';
import {useEffect,useRef,useState} from 'react';
import Link from 'next/link';
import {dictionary,type Locale} from '@/lib/i18n';
import {planningRpc,planningError,stateLabel,type Team,type TeamDetail,type Page} from '@/lib/planning/api';
import type {Scope} from '@/lib/hydrants/admin';
import {MutationNotice,Pager,usePlanningMutation,usePlanningScope} from './shared';

function PeoplePicker({locale,organization,selected,onChange,disabled=false}:{locale:Locale;organization:string;selected:string[];onChange:(ids:string[])=>void;disabled?:boolean}){
 const t=dictionary(locale),[search,setSearch]=useState(''),[rows,setRows]=useState<{id:string;display_name:string}[]>([]),[error,setError]=useState('');
 useEffect(()=>{let live=true;setRows([]);const timer=setTimeout(()=>{void planningRpc<typeof rows>('web_inspection_performers',{organization,search}).then(r=>{if(live){setRows(r);setError('');}}).catch(e=>{if(live)setError(planningError(locale,e));});},300);return()=>{live=false;clearTimeout(timer);};},[organization,search,locale]);
 return <fieldset disabled={disabled}><legend>{t.pMembers}</legend><p>{t.pMembershipNotice}</p><label>{t.hSearch}<input maxLength={200} value={search} onChange={e=>setSearch(e.target.value)}/></label>{error&&<p role="alert">{error}</p>}
 <div className="planning-choices">{rows.map(p=><label key={p.id}><input type="checkbox" checked={selected.includes(p.id)} onChange={e=>onChange(e.target.checked?[...selected,p.id]:selected.filter(id=>id!==p.id))}/>{p.display_name||t.hMissing}</label>)}</div><small>{t.pDirectoryHint} · {t.pSelected}: {selected.length}</small></fieldset>;
}
function TeamEditor({root,locale,scope,id,onBack}:{root:string;locale:Locale;scope:Scope;id:string|null;onBack:()=>void}){
 const t=dictionary(locale),[detail,setDetail]=useState<TeamDetail|null>(null),[organization,setOrg]=useState(scope.organizations.find(o=>o.writable)?.id??''),[name,setName]=useState(''),[selected,setSelected]=useState<string[]>([]),[page,setPage]=useState(0),[revision,setRevision]=useState(0),[error,setError]=useState('');
 const [newId]=useState(()=>crypto.randomUUID());
 const baseRevision=useRef<string|null>(null);
 const mutation=usePlanningMutation(locale,()=>{if(!id)onBack();else{baseRevision.current=null;setSelected([]);setRevision(v=>v+1);}});
 useEffect(()=>{if(!id)return;let live=true;void planningRpc<TeamDetail>('web_team_detail',{root,team:id,page}).then(d=>{if(live){setDetail(d);if(baseRevision.current===null){setName(d.team.name);baseRevision.current=d.revision;}setOrg(d.team.organization_id);setError('');}}).catch(e=>{if(live){setDetail(null);setError(planningError(locale,e));}});return()=>{live=false;};},[root,id,page,revision,locale]);
 const writable=scope.organizations.some(o=>o.id===organization&&o.writable)&&(!id||detail?.writable),disabled=mutation.locked||!writable;
 const submit=(operation:string,extra:Record<string,unknown>={})=>void mutation.submit(organization,'TEAM',{id:id??newId,operation,revision:baseRevision.current,...extra});
 if(id&&!detail)return <><button onClick={onBack}>{t.pBack}</button><p role="status">{error||t.loading}</p></>;
 if(!scope.organizations.some(o=>o.id===organization))return <p role="alert">{t.hForbidden}</p>;
 return <section className="web-detail"><button disabled={mutation.busy} onClick={onBack}>{t.pBack}</button><h2>{id?detail?.team.name:t.pNewTeam}</h2><MutationNotice locale={locale} mutation={mutation}/>
 <form className="admin-card web-form-grid" onSubmit={e=>{e.preventDefault();submit(id?'RENAME':'CREATE',{team_name:name,initial_members:selected});}}>
 <label>{t.selectOrganization}<select disabled={!!id||mutation.locked} value={organization} onChange={e=>{setOrg(e.target.value);setSelected([]);}}>{scope.organizations.filter(o=>o.writable||o.id===organization).map(o=><option key={o.id} value={o.id}>{o.name}</option>)}</select></label>
 <label>{t.pTeamName}<input required maxLength={120} disabled={disabled} value={name} onChange={e=>setName(e.target.value)}/></label>
 {!id&&<PeoplePicker locale={locale} organization={organization} selected={selected} onChange={setSelected} disabled={disabled}/>}
 {writable&&<button disabled={disabled||!name.trim()||(!id&&!selected.length)}>{t.hSave}</button>}</form>
 {id&&detail&&<><div className="actions"><span className="admin-badge">{detail.team.active?t.hActive:t.hInactive}</span>{writable&&<button disabled={disabled} onClick={()=>submit('ACTIVE',{enabled:!detail.team.active})}>{detail.team.active?t.hDeactivate:t.pActivate}</button>}</div>
 <section className="admin-card"><h2>{t.pMembers} · {detail.member_count}</h2>{detail.members.map(m=><div className="planning-member" key={m.user_id}><span>{m.display_name||t.hMissing} · {m.active?t.hActive:t.hInactive}</span>{writable&&<button disabled={disabled} onClick={()=>submit(m.active?'REMOVE':'ADD',{member:m.user_id})}>{m.active?t.pRemoveMember:t.pAddMember}</button>}</div>)}<Pager locale={locale} page={page} more={detail.more} onPage={setPage}/>
 {writable&&<><PeoplePicker locale={locale} organization={organization} selected={selected} onChange={ids=>setSelected(ids.slice(-1))} disabled={disabled}/><button disabled={disabled||selected.length!==1} onClick={()=>submit('ADD',{member:selected[0]})}>{t.pAddMember}</button></>}</section>
 <section className="admin-card"><h2>{t.pParticipation}</h2>{detail.plans.map(p=><p key={p.id}><Link href={`/${locale}/admin/org/${root}/plans?plan=${p.id}`}>{p.name}</Link> · {stateLabel(t,p.status)}</p>)}{!detail.plans.length&&<p>{t.hNoMatches}</p>}</section></>}
 </section>;
}
export function Teams({root,locale,initialId}:{root:string;locale:Locale;initialId?:string}){
 const t=dictionary(locale),{scope,error,revision,reload}=usePlanningScope(root,locale),[rows,setRows]=useState<Team[]>([]),[page,setPage]=useState(0),[more,setMore]=useState(false),[search,setSearch]=useState(''),[state,setState]=useState(''),[owner,setOwner]=useState(''),[failure,setFailure]=useState(''),[editing,setEditing]=useState<string|null|undefined>(initialId);
 useEffect(()=>{if(!scope||editing!==undefined)return;let live=true;const timer=setTimeout(()=>{void planningRpc<Page<Team>>('web_teams',{root,page,search,state,owner:owner||null}).then(r=>{if(live){setRows(r.rows);setMore(r.more);setFailure('');}}).catch(e=>{if(live){setRows([]);setFailure(planningError(locale,e));}});},300);return()=>{live=false;clearTimeout(timer);};},[root,scope,page,search,state,owner,revision,editing,locale]);
 if(!scope)return <p role="status">{error||t.loading}</p>;
 if(editing!==undefined)return <TeamEditor key={editing??'new'} root={root} locale={locale} scope={scope} id={editing} onBack={()=>{setEditing(undefined);reload();}}/>;
 return <section className="web-detail"><div className="actions"><button onClick={reload}>{t.hRefresh}</button>{scope.organizations.some(o=>o.writable)&&<button onClick={()=>setEditing(null)}>{t.pNewTeam}</button>}</div>
 <div className="admin-card web-form-grid"><label>{t.hSearch}<input maxLength={200} value={search} onChange={e=>{setSearch(e.target.value);setPage(0);}}/></label><label>{t.hActive}<select value={state} onChange={e=>{setState(e.target.value);setPage(0);}}><option value="">{t.hAll}</option><option value="active">{t.hActive}</option><option value="inactive">{t.hInactive}</option></select></label><label>{t.selectOrganization}<select value={owner} onChange={e=>{setOwner(e.target.value);setPage(0);}}><option value="">{t.wAllDescendants}</option>{scope.organizations.map(o=><option key={o.id} value={o.id}>{o.name}</option>)}</select></label></div>
 {failure&&<p role="alert">{failure}</p>}<div className="admin-cards">{rows.map(team=><article className="admin-card" key={team.id}><h2>{team.name}</h2><p>{team.organization_name}</p><span className="admin-badge">{team.active?t.hActive:t.hInactive}</span><p>{t.pMembers}: {team.member_count} · {t.pParticipation}: {team.plan_count}</p><button onClick={()=>setEditing(team.id)}>{t.hDetails}</button></article>)}</div>{!rows.length&&<p>{t.hNoMatches}</p>}<Pager locale={locale} page={page} more={more} onPage={setPage}/></section>;
}
