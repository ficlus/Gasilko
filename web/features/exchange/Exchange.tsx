'use client';
import {useEffect,useRef,useState} from 'react';
import dynamic from 'next/dynamic';
import {useRouter} from 'next/navigation';
import {browserClient} from '@/lib/supabase/browser';
import {exchangeText} from '@/lib/exchange/messages';
import {autoMapping,fields,statuses,type Cell,type Context,type InputRow,type Mapping,type Preview,type Profile} from '@/lib/exchange/model';
import type {Locale} from '@/lib/i18n';
const PreviewMap=dynamic(()=>import('./PreviewMap'),{ssr:false});
export async function exchangeRequest(root:string,action:string,body:unknown){
 const r=await fetch('/api/exchange?root='+encodeURIComponent(root)+'&action='+action,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
 const json=await r.json();if(!r.ok)throw Error(json.error??'REQUEST_FAILED');return json;
}
export async function downloadExchange(root:string,body:Record<string,unknown>){
 const client=browserClient(),account=(await client?.auth.getUser())?.data.user?.id;if(!account)throw Error('NOT_AUTHORIZED');
 const r=await fetch('/api/exchange?root='+encodeURIComponent(root)+'&action=download',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
 if(!r.ok){const error=await r.json();throw Error(error.error??'REQUEST_FAILED');}
 const blob=await r.blob();if((await client?.auth.getUser())?.data.user?.id!==account)throw Error('NOT_AUTHORIZED');
 const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='gasilko-'+body.kind+'.'+body.format;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
}
export function ExportActions({root,locale,kind,filters={}}:{root:string;locale:Locale;kind:string;filters?:Record<string,unknown>}){
 const [busy,setBusy]=useState(false),[error,setError]=useState('');const t=exchangeText(locale);
 return <div className="actions">{['csv','xlsx'].map(format=><button disabled={busy} key={format} onClick={()=>{setBusy(true);setError('');void downloadExchange(root,{kind,format,locale,filters}).catch(e=>setError(t.codes[e.message]??t.codes.REQUEST_FAILED)).finally(()=>setBusy(false));}}>{t.export} {format.toUpperCase()}</button>)}{error&&<p role="alert">{error}</p>}</div>;
}
type History={id:string;created_at:string;completed_at:string|null;filename:string;actor:string;visible_rows:number;summary:Record<string,number>};
type Result={row_number:number;intended:string;pending:boolean;result:{action:string;error?:string;code?:string;version?:number}|null;before:Record<string,Cell|null>;after:Record<string,Cell|null>};
export function Exchange({root,locale}:{root:string;locale:Locale}){
 const t=exchangeText(locale),router=useRouter();const [context,setContext]=useState<Context|null>(null),[blocked,setBlocked]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState('');
 const [file,setFile]=useState<File|null>(null),[sheets,setSheets]=useState<string[]>([]),[sheet,setSheet]=useState(''),[delimiter,setDelimiter]=useState(''),[rows,setRows]=useState<Cell[][]>([]),[hash,setHash]=useState('');
 const [mapping,setMapping]=useState<Mapping>(autoMapping([])),[organization,setOrganization]=useState(root),[preview,setPreview]=useState<Preview[]>([]),[inputs,setInputs]=useState<InputRow[]>([]),[selected,setSelected]=useState<Set<number>>(new Set());
 const [acceptWarnings,setAcceptWarnings]=useState(false),[reason,setReason]=useState(''),[page,setPage]=useState(0),[classification,setClassification]=useState('');
 const [profiles,setProfiles]=useState<Profile[]>([]),[profileId,setProfileId]=useState(''),[profileName,setProfileName]=useState('');
 const profileRequest=useRef<{key:string;body:Record<string,unknown>}|null>(null);
 const [operation,setOperation]=useState(''),[confirmed,setConfirmed]=useState(false),[remaining,setRemaining]=useState<number|null>(null);
 const frozen=useRef<{operation:string;manifest:unknown}|null>(null),alive=useRef(true),epoch=useRef(0),account=useRef<string|null>(null),scopeKey=useRef('');
 const [history,setHistory]=useState<History[]>([]),[historyPage,setHistoryPage]=useState(0),[historyState,setHistoryState]=useState(''),[historyOperation,setHistoryOperation]=useState(''),[results,setResults]=useState<Result[]>([]),[resultPage,setResultPage]=useState(0);
 const [exportKind,setExportKind]=useState('hydrants'),[from,setFrom]=useState(''),[to,setTo]=useState('');
 const clear=()=>{epoch.current++;setContext(null);setRows([]);setInputs([]);setPreview([]);setProfiles([]);setHistory([]);setResults([]);setOperation('');setFile(null);frozen.current=null;setBlocked(true);};
 useEffect(()=>{alive.current=true;const client=browserClient();let disposed=false;
  const refresh=async()=>{const user=await client?.auth.getUser();if(disposed)return;if(!user?.data.user||account.current&&account.current!==user.data.user.id){clear();return;}account.current=user.data.user.id;
   const r=await client!.rpc('web_exchange_context',{root});if(disposed)return;if(r.error){clear();return;}const key=JSON.stringify(r.data.organizations);if(scopeKey.current&&scopeKey.current!==key){clear();return;}scopeKey.current=key;setContext(r.data);};
  void refresh();const interval=setInterval(()=>void refresh(),60000);const listener=client?.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT'||account.current&&session?.user.id!==account.current){clear();router.replace('/'+locale+'/account');}});
  return()=>{disposed=true;alive.current=false;epoch.current++;clearInterval(interval);listener?.data.subscription.unsubscribe();};
 },[root,locale,router]);
 const run=async(task:()=>Promise<void>)=>{const current=epoch.current;setBusy(true);setError('');try{await task();}catch(e){if(alive.current&&current===epoch.current){const code=e instanceof Error?e.message:'REQUEST_FAILED';setError(t.codes[code]??t.codes.REQUEST_FAILED);if(code==='NOT_AUTHORIZED')clear();}}finally{if(alive.current)setBusy(false);}};
 const call=async(action:string,body:unknown)=>{const current=epoch.current;const data=await exchangeRequest(root,action,body);if(!alive.current||current!==epoch.current)throw Error('NOT_AUTHORIZED');return data;};
 const loadHistory=async()=>{setHistory(await call('history',{page:historyPage,state:historyState}));};
 useEffect(()=>{if(context&&!blocked)void run(async()=>{await loadHistory();setProfiles(await call('profiles',{}));});},[!!context,historyPage,historyState]);
 const invalidate=()=>{setPreview([]);setInputs([]);setSelected(new Set());setPage(0);};
 const updateMapping=(next:Mapping)=>{setMapping(next);invalidate();};
 const parse=async()=>{if(!file)return;const current=epoch.current;const params=new URLSearchParams({root,action:'parse',format:file.name.split('.').at(-1)?.toLowerCase()??'',sheet,delimiter});
  const response=await fetch('/api/exchange?'+params,{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:file});const data=await response.json();if(!response.ok)throw Error(data.error);if(current!==epoch.current||!alive.current)throw Error('NOT_AUTHORIZED');
  setSheets(data.sheets);setSheet(data.sheet??'');setRows(data.rows??[]);setHash(data.hash);setMapping(autoMapping(data.rows?.[0]??[]));invalidate();
 };
 const dryRun=async()=>{const data=await call('preview',{rows,mapping,organization});setPreview(data.previews);setInputs(data.inputs);setSelected(new Set());setPage(0);};
 const confirm=async()=>{
  if(!frozen.current){const id=crypto.randomUUID(),byRow=new Map(preview.map(p=>[p.row,p]));const manifest={filename:file!.name.replace(/^.*[/\\]/,'').slice(0,180),format:file!.name.split('.').at(-1)!.toLowerCase(),file_hash:hash,reason:reason.trim(),sheet,mapping,
   rows:inputs.map(row=>{const p=byRow.get(row.row)!;return {...row,selected:selected.has(row.row)&&['CREATE','UPDATE'].includes(p.action),...(p.version?{expected_version:p.version}:{}),accept_warnings:acceptWarnings};})};
   frozen.current={operation:id,manifest};setOperation(id);
  }await call('confirm',frozen.current);setConfirmed(true);setRemaining(selected.size);await loadHistory();
 };
 const apply=async()=>{let left=1;while(left>0&&alive.current&&!blocked){const r=await call('apply',{operation});left=r.remaining;setRemaining(left);}await loadHistory();setHistoryOperation(operation);setResultPage(0);setResults(await call('history',{operation,page:0}));};
 const profile=profiles.find(p=>p.id===profileId);
 const saveProfile=async(active=true)=>{const p=profile,body={organization:p?.organization_id??organization,profile:p?.id,expected_version:p?.version??0,name:profileName,configuration:mapping,active};const key=JSON.stringify(body);
  if(profileRequest.current?.key!==key)profileRequest.current={key,body:{...body,profile:p?.id??crypto.randomUUID(),operation:crypto.randomUUID()}};
  const saved=await call('profile',profileRequest.current.body);setProfileId(saved.id);setProfiles(await call('profiles',{}));profileRequest.current=null;
 };
 const sourceValues=(field:'status'|'type')=>{const col=mapping.columns[field];return col===undefined?[]:Array.from(new Set(rows.slice(1).map(r=>String(r[col]??'').trim()).filter(Boolean))).sort();};
 const visible=preview.filter(p=>!classification||p.action===classification||classification==='WARNING'&&!!p.warnings?.length);
 const choose=(mode:string)=>setSelected(new Set(preview.filter(p=>['CREATE','UPDATE'].includes(p.action)&&(mode==='valid'||mode==='warnings'&&!p.warnings?.length||mode===p.action)).map(p=>p.row)));
 if(blocked)return <p role="alert">{t.codes.NOT_AUTHORIZED}</p>;
 if(!context)return <p role="status">{t.loading}</p>;
 const writable=context.organizations.filter(o=>o.writable);
 return <section className="exchange"><h1>{t.title}</h1><p>{t.limits}</p>{error&&<p role="alert">{error}</p>}{busy&&<p role="status">{t.loading}</p>}
 <section className="admin-card"><h2>{t.export}</h2><label>{t.export}<select value={exportKind} onChange={e=>setExportKind(e.target.value)}>{(['hydrants','inspections','teams','plans'] as const).map(k=><option key={k} value={k}>{t[k]}</option>)}</select></label>
 <label>{t.organization}<select value={organization} disabled={!!operation} onChange={e=>{setOrganization(e.target.value);invalidate();}}><option value="">{t.all}</option>{context.organizations.map(o=><option key={o.id} value={o.id}>{o.name} ({o.code})</option>)}</select></label>
 {exportKind==='inspections'&&<div className="web-form-grid"><label>{t.from}<input type="date" value={from} onChange={e=>setFrom(e.target.value)}/></label><label>{t.to}<input type="date" value={to} onChange={e=>setTo(e.target.value)}/></label></div>}
 <ExportActions root={root} locale={locale} kind={exportKind} filters={{organization,active:'all',from,to}}/>
 <div className="actions">{['csv','xlsx'].map(format=><button key={format} disabled={busy} onClick={()=>void run(()=>downloadExchange(root,{kind:'template',format,locale}))}>{t.template} {format.toUpperCase()}</button>)}</div></section>
 <section className="admin-card"><h2>{t.import}</h2><p>{t.readOnly}</p>{!!writable.length&&<>
 <fieldset disabled={busy||!!operation}><label>{t.file}<input type="file" accept=".csv,.xls,.xlsx" onChange={e=>{setFile(e.target.files?.[0]??null);setRows([]);setSheets([]);setSheet('');invalidate();}}/></label>
 <label>{t.delimiter}<select value={delimiter} onChange={e=>{setDelimiter(e.target.value);invalidate();}}><option value="">{t.auto}</option><option value="," >,</option><option value=";">;</option><option value={'\t'}>Tab</option></select></label>
 {!!sheets.length&&<label>{t.sheet}<select value={sheet} onChange={e=>{setSheet(e.target.value);setRows([]);invalidate();}}><option value="">—</option>{sheets.map(s=><option key={s}>{s}</option>)}</select></label>}
 <button disabled={!file} onClick={()=>void run(parse)}>{t.analyze}</button>
 {!!rows.length&&<><h3>{t.mapping}</h3><p>{t.blankHelp}</p><div className="web-form-grid">{fields.map(f=><label key={f}>{t.fields[f]}<select value={mapping.columns[f]??''} onChange={e=>{const columns={...mapping.columns};if(e.target.value==='')delete columns[f];else columns[f]=Number(e.target.value);updateMapping({...mapping,columns});}}><option value="">{t.ignore}</option>{rows[0].map((h,i)=><option key={i} value={i}>{i+1}: {String(h)||'—'}</option>)}</select></label>)}</div>
 <label>{t.decimal}<select value={mapping.decimal} onChange={e=>updateMapping({...mapping,decimal:e.target.value as Mapping['decimal']})}><option value="auto">{t.auto}</option><option value="point">{t.point}</option><option value="comma">{t.comma}</option></select></label>
 <label><input type="checkbox" checked={mapping.clear} onChange={e=>updateMapping({...mapping,clear:e.target.checked})}/>{t.clear}</label>
 {(['status','type'] as const).map(f=><details key={f}><summary>{f==='status'?t.statusMap:t.typeMap}</summary>{sourceValues(f).map(v=><label key={v}>{v}<select value={(f==='status'?mapping.statuses:mapping.types)[v]??''} onChange={e=>updateMapping({...mapping,[f==='status'?'statuses':'types']:{...(f==='status'?mapping.statuses:mapping.types),[v]:e.target.value}})}><option value="">{t.auto}</option>{f==='status'?statuses.map(s=><option key={s} value={s}>{t.codes[s]} ({s})</option>):context.types.filter(v=>v.active).map(v=><option key={v.id} value={v.id}>{v.name} ({v.code}) · {context.organizations.find(o=>o.id===v.organization_id)?.name??t.all}</option>)}</select></label>)}</details>)}
 <details><summary>{t.profiles}</summary><p>{t.profileHelp}</p><select aria-label={t.profiles} value={profileId} onChange={e=>{setProfileId(e.target.value);const p=profiles.find(p=>p.id===e.target.value);setProfileName(p?.name??'');if(p)updateMapping(p.configuration);}}><option value="">{t.newProfile}</option>{profiles.map(p=><option key={p.id} value={p.id}>{p.name}{p.active?'':' — '+t.deactivate}</option>)}</select>
 <label>{t.profileName}<input maxLength={120} value={profileName} onChange={e=>setProfileName(e.target.value)}/></label><button disabled={!profileName.trim()||!writable.some(o=>o.id===(profile?.organization_id??organization))} onClick={()=>void run(()=>saveProfile(true))}>{t.save}</button>{profile&&<button onClick={()=>void run(()=>saveProfile(!profile.active))}>{profile.active?t.deactivate:t.activate}</button>}</details>
 <button onClick={()=>void run(dryRun)}>{t.preview}</button></>}
 </fieldset></>}
 {!!preview.length&&<><h3>{t.previewTitle}</h3><p>{t.selected}: {selected.size} / {preview.length}</p><fieldset disabled={busy||!!operation}><div className="actions"><button onClick={()=>choose('valid')}>{t.selectValid}</button><button onClick={()=>choose('warnings')}>{t.excludeWarnings}</button><button onClick={()=>choose('CREATE')}>{t.creates}</button><button onClick={()=>choose('UPDATE')}>{t.updates}</button><button onClick={()=>choose('none')}>{t.none}</button></div></fieldset>
 <label>{t.classification}<select value={classification} onChange={e=>{setClassification(e.target.value);setPage(0);}}><option value="">{t.all}</option>{['CREATE','UPDATE','UNCHANGED','SKIP','WARNING','CONFLICT','ERROR'].map(c=><option key={c} value={c}>{t.codes[c]} ({preview.filter(p=>c==='WARNING'?p.warnings?.length:p.action===c).length})</option>)}</select></label>
 <div className="exchange-table"><table><thead><tr><th>{t.selected}</th><th>{t.row}</th><th>{t.classification}</th><th>{t.details}</th></tr></thead><tbody>{visible.slice(page*50,page*50+50).map(p=><tr key={p.row}><td><input type="checkbox" aria-label={t.row+' '+p.row} disabled={busy||!!operation||!['CREATE','UPDATE'].includes(p.action)} checked={selected.has(p.row)} onChange={e=>setSelected(s=>{const next=new Set(s);e.target.checked?next.add(p.row):next.delete(p.row);return next;})}/></td><td>{p.row}<br/>{p.code}</td><td>{t.codes[p.action]}{p.error&&<p role="alert">{t.codes[p.error]??t.codes.REQUEST_FAILED}</p>}{p.warnings?.map(w=><p key={w}>{t.codes[w]??t.warning}</p>)}</td><td><ChangeValues before={p.before} after={p.after} locale={locale}/></td></tr>)}</tbody></table></div>
 <div className="actions"><button disabled={!page} onClick={()=>setPage(p=>p-1)}>{t.previous}</button><span>{page+1}</span><button disabled={(page+1)*50>=visible.length} onClick={()=>setPage(p=>p+1)}>{t.next}</button></div>
 <PreviewMap rows={preview} locale={locale}/><p>{t.partialHelp}</p>
 <fieldset disabled={busy||!!operation}><label>{t.reason}<input maxLength={500} value={reason} onChange={e=>setReason(e.target.value)}/></label><label><input type="checkbox" checked={acceptWarnings} onChange={e=>setAcceptWarnings(e.target.checked)}/>{t.warnings}</label></fieldset>
 {!confirmed&&<button disabled={busy||!selected.size||!reason.trim()||!acceptWarnings&&preview.some(p=>selected.has(p.row)&&p.warnings?.length)} onClick={()=>void run(confirm)}>{t.confirm}</button>}</>}
 {operation&&<section><p>{t.frozen} <code>{operation}</code></p>{remaining!==null&&<p>{t.remaining}: {remaining}</p>}{confirmed&&remaining!==0&&<button disabled={busy} onClick={()=>void run(apply)}>{t.apply}</button>}<button disabled={busy} onClick={()=>{setOperation('');frozen.current=null;setConfirmed(false);setRemaining(null);setFile(null);setRows([]);invalidate();}}>{t.reset}</button></section>}
 </section>
 <section className="admin-card"><h2>{t.history}</h2><select aria-label={t.classification} value={historyState} onChange={e=>{setHistoryState(e.target.value);setHistoryPage(0);}}><option value="">{t.all}</option><option value="PENDING">{t.codes.PENDING}</option><option value="DONE">{t.results}</option></select><button disabled={busy} onClick={()=>void run(loadHistory)}>{t.refresh}</button>
 {!history.length&&<p>{t.empty}</p>}{history.map(h=><article className="web-row" key={h.id}><strong>{h.filename}</strong><p>{new Date(h.created_at).toLocaleString(locale)} · {h.visible_rows} · {h.completed_at?t.results:t.codes.PENDING}</p><code>{h.id}</code><p>{Object.entries(h.summary).map(([key,count])=>(t.codes[key]??key)+': '+count).join(' · ')}</p><div className="actions"><button disabled={busy} onClick={()=>void run(async()=>{setHistoryOperation(h.id);setResultPage(0);setResults(await call('history',{operation:h.id,page:0}));})}>{t.details}</button>{!h.completed_at&&h.actor===account.current&&<button disabled={busy} onClick={()=>{setOperation(h.id);setConfirmed(true);setRemaining(null);}}>{t.resume}</button>}{[false,true].map(errorsOnly=><button key={String(errorsOnly)} disabled={busy} onClick={()=>void run(()=>downloadExchange(root,{kind:'results',format:'csv',locale,operation:h.id,errorsOnly}))}>{errorsOnly?t.errors:t.results}</button>)}</div></article>)}
 <div className="actions"><button disabled={busy||!historyPage} onClick={()=>setHistoryPage(p=>p-1)}>{t.previous}</button><span>{historyPage+1}</span><button disabled={busy||history.length<50} onClick={()=>setHistoryPage(p=>p+1)}>{t.next}</button></div>
 {historyOperation&&<><h3>{t.details}</h3>{results.map(r=><article key={r.row_number}><strong>{t.row} {r.row_number} · {t.codes[r.result?.action??'PENDING']}</strong><p>{r.result?.code} {r.result?.error&&(t.codes[r.result.error]??t.codes.REQUEST_FAILED)}</p><ChangeValues before={r.before} after={r.after} locale={locale}/></article>)}<div className="actions"><button disabled={busy||!resultPage} onClick={()=>void run(async()=>{const page=resultPage-1;setResults(await call('history',{operation:historyOperation,page}));setResultPage(page);})}>{t.previous}</button><span>{resultPage+1}</span><button disabled={busy||results.length<100} onClick={()=>void run(async()=>{const page=resultPage+1;setResults(await call('history',{operation:historyOperation,page}));setResultPage(page);})}>{t.next}</button></div></>}
 </section></section>;
}
function ChangeValues({before={},after={},locale}:{before?:Record<string,Cell|null>;after?:Record<string,Cell|null>;locale:Locale}){const t=exchangeText(locale);return <dl>{Object.entries(after).map(([k,v])=><div key={k}><dt>{t.fields[k]??k}</dt><dd>{t.before}: {String(before[k]??'—')} → {t.after}: <strong>{String(v??'—')}</strong></dd></div>)}</dl>;}
