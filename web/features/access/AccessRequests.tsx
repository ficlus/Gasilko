'use client';
import { useEffect, useState } from 'react';
import { browserClient } from '../../lib/supabase/browser';
import { dictionary, type Locale } from '../../lib/i18n';
import { submitAccess, type Choice, type Organization, type AccessRequest } from '../../lib/access/client';
export function AccessRequests({ locale }: { locale: Locale }) {
  const t = dictionary(locale); const [countries, setCountries] = useState<Choice[]>([]); const [country, setCountry] = useState('');
  const [trail, setTrail] = useState<Choice[]>([]); const [areas, setAreas] = useState<Choice[]>([]); const [areaMore, setAreaMore] = useState(false);
  const [organizations,setOrganizations] = useState<Organization[]>([]); const [orgMore,setOrgMore] = useState(false); const [selected,setSelected] = useState('');
  const [role,setRole] = useState('FIREFIGHTER'); const [history,setHistory] = useState<AccessRequest[]>([]); const [historyMore,setHistoryMore] = useState(false);
  const [busy,setBusy] = useState(false); const [message,setMessage] = useState(''); const area = trail.at(-1)?.id ?? null;
  useEffect(() => { let alive=true; const c=browserClient(); if(c) void c.from('countries').select('id,name').eq('active',true).order('name').then(({data,error})=>{if(alive){if(error)setMessage(t.requestError);else setCountries(data??[]);}}); return()=>{alive=false;}; },[t.requestError]);
  useEffect(() => { let alive=true; const c=browserClient(); if(c) void c.rpc('list_my_access_requests').then(({data,error})=>{if(alive){if(error)setMessage(t.requestError);else {setHistory(data??[]);setHistoryMore(data?.length===50);}}}); return()=>{alive=false;}; },[t.requestError]);
  useEffect(() => {
    let alive=true; const c=browserClient(); if(!country || !c) return;
    let q=c.from('administrative_areas').select('id,name').eq('country_id',country).eq('active',true).order('id').limit(50);
    q=area?q.eq('parent_id',area):q.is('parent_id',null);
    void Promise.all([q,c.rpc('discover_organizations',{country,area})]).then(([a,o])=>{if(alive){if(a.error||o.error)setMessage(t.requestError);else{setAreas(a.data??[]);setAreaMore(a.data?.length===50);setOrganizations(o.data??[]);setOrgMore(o.data?.length===50);}}});
    return()=>{alive=false;};
  },[country,area,t.requestError]);
  const resetSelection=()=>{setSelected('');setAreas([]);setOrganizations([]);setAreaMore(false);setOrgMore(false);setMessage('');};
  async function more(kind:'areas'|'orgs'|'history') {
    const c=browserClient(); if(!c)return;setBusy(true);
    try {
      if(kind==='history') {const last=history.at(-1);const r=await c.rpc('list_my_access_requests',last?{before_time:last.requested_at,before_id:last.id}:{});if(r.error)throw Error();setHistory([...history,...(r.data??[])]);setHistoryMore(r.data?.length===50);}
      if(kind==='orgs') {const r=await c.rpc('discover_organizations',{country,area,after_id:organizations.at(-1)?.id});if(r.error)throw Error();setOrganizations([...organizations,...(r.data??[])]);setOrgMore(r.data?.length===50);}
      if(kind==='areas') {let q=c.from('administrative_areas').select('id,name').eq('country_id',country).eq('active',true).order('id').limit(50).gt('id',areas.at(-1)?.id??'');q=area?q.eq('parent_id',area):q.is('parent_id',null);const r=await q;if(r.error)throw Error();setAreas([...areas,...(r.data??[])]);setAreaMore(r.data?.length===50);}
    } catch {setMessage(t.requestError);}finally{setBusy(false);}
  }
  return <section><h2>{t.requestAccess}</h2><p>{t.requestNoAccess}</p>
    <label>{t.selectCountry}<select disabled={busy} value={country} onChange={e=>{resetSelection();setTrail([]);setCountry(e.target.value);}}><option value="">{t.selectCountry}</option>{countries.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
    {country && <><p>{trail.map(a=>a.name).join(' / ')||t.allAreas}</p>{trail.length>0&&<button disabled={busy} onClick={()=>{resetSelection();setTrail(trail.slice(0,-1));}}>{t.parentArea}</button>}
    <label>{t.selectArea}<select value="" disabled={busy} onChange={e=>{const a=areas.find(a=>a.id===e.target.value);if(a){resetSelection();setTrail([...trail,a]);}}}><option value="">{t.allAreas}</option>{areas.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select></label>{areaMore&&<button disabled={busy} onClick={()=>void more('areas')}>{t.loadMore}</button>}
    <label>{t.selectOrganization}<select value={selected} disabled={busy} onChange={e=>setSelected(e.target.value)}><option value="">{t.selectOrganization}</option>{organizations.map(o=><option key={o.id} value={o.id}>{o.name} ({o.code})</option>)}</select></label>{orgMore&&<button disabled={busy} onClick={()=>void more('orgs')}>{t.loadMore}</button>}
    <label>{t.requestedRole}<select value={role} disabled={busy} onChange={e=>setRole(e.target.value)}><option value="FIREFIGHTER">{t.firefighter}</option><option value="MANAGER">{t.manager}</option></select></label>
    <button disabled={busy||!selected} onClick={async()=>{setBusy(true);const result=await submitAccess(browserClient(),selected,role);const labels:Record<string,string>={SUBMITTED:t.requestSubmitted,DUPLICATE_REQUEST:t.duplicateRequest,ALREADY_MEMBER:t.alreadyMember};setMessage(labels[result]??t.requestError);setBusy(false);if(result==='SUBMITTED'){const c=browserClient();const r=await c?.rpc('list_my_access_requests');if(r&&!r.error){setHistory(r.data??[]);setHistoryMore(r.data?.length===50);}}}}>{t.confirmRequest}</button></>}
    <p role="status">{message}</p><h2>{t.currentRequests}</h2>{history.length===0&&<p>{t.noRequests}</p>}
    <ul>{history.map(r=><li key={r.id}>{r.organization_name} — {r.requested_role==='MANAGER'?t.manager:t.firefighter} — {r.status==='PENDING'?t.requestPending:r.status==='APPROVED'?t.requestApproved:r.status==='REJECTED'?t.requestRejected:t.requestError}</li>)}</ul>
    {historyMore&&<button disabled={busy} onClick={()=>void more('history')}>{t.loadMore}</button>}
    <button disabled={busy} onClick={async()=>{setBusy(true);try{const r=await browserClient()?.rpc('list_my_access_requests');if(!r||r.error)throw Error();setHistory(r.data??[]);setHistoryMore(r.data?.length===50);}catch{setMessage(t.requestError);}finally{setBusy(false);}}}>{t.refreshRequests}</button>
  </section>;
}
