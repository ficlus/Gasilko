'use client';
import {useEffect,useRef,useState,type FormEvent} from 'react';
import type {EntityRef} from '../../lib/operational/entity';
import {useRouter} from 'next/navigation';
import type {Locale} from '../../lib/i18n';
import {browserClient} from '../../lib/supabase/browser';
import {operationalText} from '../../lib/operational/messages';
import {inventoryRpc,inventoryWrites} from '../../lib/operational/api';

type Kind=keyof typeof inventoryWrites;
type Item={id:string;version:string;active:boolean;name:string;capabilities?:string[];[key:string]:unknown};
type Config={code:string;names:Record<string,string>;active:boolean};
type Page={rows:Item[];more:boolean;configuration:Record<string,Config[]>};
type Pending={kind:Kind;p_operation:string;p_organization_id:string;p_payload:Record<string,unknown>};
const fields:Record<Kind,string[]>={VEHICLE:['callsign','name','category_code','registration','availability','seats','water_litres'],UNIT:['callsign','name','unit_kind','vehicle_id'],RESOURCE:['name','resource_type_code','unit_of_measure_code','total_quantity']};
const kinds=['VEHICLE_CREW','RESCUE_TEAM','DRONE_TEAM','MEDICAL_TEAM','OTHER'];
const configs:Record<string,string>={category_code:'operational_vehicle_categories',resource_type_code:'operational_resource_types',unit_of_measure_code:'operational_units_of_measure'};
export function OperationalInventory({locale,org,initialEntity}:{locale:Locale;org:string;initialEntity?:EntityRef}){
 const t=operationalText(locale),router=useRouter();
 const [account,setAccount]=useState(''),[kind,setKind]=useState<Kind>(initialEntity?.type==='OPERATIONAL_UNIT'?'UNIT':'VEHICLE'),[query,setQuery]=useState(''),[page,setPage]=useState(0),[refresh,setRefresh]=useState(0);
 const [data,setData]=useState<Page|null>(null),[error,setError]=useState(''),[draft,setDraft]=useState<Item|null>(null),[review,setReview]=useState(false),[busy,setBusy]=useState(false);
 const [pending,setPending]=useState<Pending|null>(null),[stale,setStale]=useState(false),[serverItem,setServerItem]=useState<Item|null>(null);
 const [vehicleQuery,setVehicleQuery]=useState(''),[vehicles,setVehicles]=useState<Item[]>([]);
 const alive=useRef(true),sending=useRef(false),blocked=useRef(false),readAbort=useRef<AbortController|null>(null);
 useEffect(()=>{alive.current=true;const client=browserClient();let original='';
  void client?.auth.getUser().then(r=>{if(alive.current){original=r.data.user?.id??'';setAccount(original);}});
  const sub=client?.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT'||(original&&session?.user.id!==original)){blocked.current=true;readAbort.current?.abort();setData(null);setDraft(null);setVehicles([]);setPending(null);router.replace('/'+locale+'/account');}});
  return()=>{alive.current=false;sub?.data.subscription.unsubscribe();readAbort.current?.abort();};
 },[locale,router]);
 function failure(e:unknown){const code=e instanceof Error?e.message:'SERVER';setError(code);if(['NOT_AUTHORIZED','EXPIRED'].includes(code)){blocked.current=true;setData(null);setDraft(null);setVehicles([]);readAbort.current?.abort();}}
 useEffect(()=>{if(!account||blocked.current)return;const ac=new AbortController();readAbort.current=ac;setData(null);
  void inventoryRpc<Page>('operational_inventory',{p_organization_id:org,p_kind:kind,p_query:query,p_page:page},account,ac.signal)
   .then(r=>{if(!ac.signal.aborted&&!blocked.current){setData(r);setError('');}}).catch(e=>{if(!ac.signal.aborted)failure(e);});
  return()=>ac.abort();
 },[account,org,kind,query,page,refresh]);
 useEffect(()=>{if(!account||kind!=='UNIT'||!draft||blocked.current)return;const ac=new AbortController();setVehicles([]);
  void inventoryRpc<Page>('operational_inventory',{p_organization_id:org,p_kind:'VEHICLE',p_query:vehicleQuery,p_page:0},account,ac.signal)
   .then(r=>{if(!ac.signal.aborted&&!blocked.current)setVehicles(r.rows.filter(v=>v.active));}).catch(e=>{if(!ac.signal.aborted)failure(e);});
  return()=>ac.abort();
 },[account,org,kind,vehicleQuery,draft?.id]);
 useEffect(()=>{
  if(!account||blocked.current||!initialEntity||!['OPERATIONAL_UNIT','OPERATIONAL_VEHICLE'].includes(initialEntity.type)||kind!==(initialEntity.type==='OPERATIONAL_UNIT'?'UNIT':'VEHICLE'))return;
  const ac=new AbortController();
  void inventoryRpc<Item>('operational_inventory_item',{p_organization_id:org,p_kind:initialEntity.type==='OPERATIONAL_UNIT'?'UNIT':'VEHICLE',p_id:initialEntity.id},account,ac.signal)
   .then(item=>{if(!ac.signal.aborted&&!blocked.current)begin(item);}).catch(e=>{if(!ac.signal.aborted)failure(e);});
  return()=>ac.abort();
 },[account,org,initialEntity?.id,kind]);
 function begin(item?:Item){setDraft(item?{...item,capabilities:[...(item.capabilities??[])]}:{id:crypto.randomUUID(),version:'0',active:true,name:'',callsign:'',category_code:'OTHER',registration:'',availability:'AVAILABLE',seats:0,water_litres:0,unit_kind:'OTHER',vehicle_id:null,resource_type_code:'OTHER',unit_of_measure_code:'EACH',total_quantity:'0',capabilities:[]});setStale(false);setServerItem(null);setReview(false);setError('');}
 async function send(){
  if(!draft||sending.current||blocked.current)return;sending.current=true;setBusy(true);setError('');
  const payload:Record<string,unknown>={id:draft.id,version:draft.version,active:draft.active};
  for(const key of fields[kind])payload[key]=draft[key]??null;
  if(kind!=='RESOURCE')payload.capabilities=draft.capabilities??[];
  const request=pending??{kind,p_operation:crypto.randomUUID(),p_organization_id:org,p_payload:payload};setPending(request);
  try{const {kind:operationKind,...args}=request;await inventoryRpc(inventoryWrites[operationKind],args,account);
   if(alive.current&&!blocked.current){setPending(null);setDraft(null);setReview(false);setRefresh(v=>v+1);}
  }catch(e){if(alive.current&&!blocked.current){const code=e instanceof Error?e.message:'SERVER';failure(e);
   if(code!=='SERVER'){setPending(null);if(code==='STALE_VERSION')setStale(true);}
  }}finally{sending.current=false;if(alive.current)setBusy(false);}
 }
 async function current(){
  if(!draft)return;
  try{const result=await inventoryRpc<Item>('operational_inventory_item',{p_organization_id:org,p_kind:kind,p_id:draft.id},account);if(alive.current&&!blocked.current)setServerItem(result);}
  catch(e){if(alive.current)failure(e);}
 }
 const locked=busy||!!pending;
 return <section className="administration"><h2>{t('inventory')}</h2><p>{t('readOnly')}</p>
  <nav className="actions">{(Object.keys(fields) as Kind[]).map(k=><button key={k} disabled={locked} aria-pressed={kind===k} onClick={()=>{setKind(k);setQuery('');setPage(0);setDraft(null);setData(null);}}>{t(k)}</button>)}</nav>
  {error&&<p role="alert">{t(error)}</p>}
  {!blocked.current&&<><label>{t('search')}<input disabled={locked} maxLength={100} value={query} onChange={e=>{setQuery(e.target.value);setPage(0);}}/></label>
  <div className="actions"><button disabled={locked||!data} onClick={()=>begin()}>{t('create')}</button><button disabled={locked} onClick={()=>setRefresh(v=>v+1)}>{t('refresh')}</button></div>
  {!data?<p role="status">{t('loading')}</p>:<>{!data.rows.length&&<p>{t('empty')}</p>}{data.rows.map(item=><article className="admin-card" key={item.id}>
   <h3>{String(item.callsign??'')} · {item.name}</h3><p>{t(item.active?'active':'inactive')} · {item.availability?t(String(item.availability)):t(String(item.unit_kind??item.resource_type_code??''))}</p>
   {kind==='RESOURCE'&&<p>{t('total_quantity')}: {String(item.total_quantity)} · {t('allocated_quantity')}: {String(item.allocated_quantity)} · {t(String(item.unit_of_measure_code))}</p>}
   <button disabled={locked} onClick={()=>begin(item)}>{t('edit')}</button>
  </article>)}<div className="actions"><button disabled={!page||locked} onClick={()=>setPage(v=>v-1)}>{t('previous')}</button><span>{page+1}</span><button disabled={!data.more||locked} onClick={()=>setPage(v=>v+1)}>{t('next')}</button></div></>}
  {draft&&<section className="admin-card"><form onSubmit={(e:FormEvent)=>{e.preventDefault();setReview(true);}}>
   <fieldset disabled={locked||review||stale}><legend>{t('edit')} · {t(kind)}</legend>
   {fields[kind].map(key=><label key={key}>{t(key)}{configs[key]?<select value={String(draft[key]??'')} onChange={e=>setDraft({...draft,[key]:e.target.value})}>
    {(data?.configuration[configs[key]]??[]).filter(c=>c.active||c.code===draft[key]).map(c=><option key={c.code} value={c.code}>{c.names[locale]??c.code}</option>)}</select>
    :key==='unit_kind'||key==='availability'?<select value={String(draft[key])} onChange={e=>setDraft({...draft,[key]:e.target.value})}>{(key==='unit_kind'?kinds:['AVAILABLE','UNAVAILABLE']).map(c=><option key={c} value={c}>{t(c)}</option>)}</select>
    :key==='vehicle_id'?<><input aria-label={t('search')} maxLength={100} value={vehicleQuery} onChange={e=>setVehicleQuery(e.target.value)}/><select value={String(draft.vehicle_id??'')} onChange={e=>setDraft({...draft,vehicle_id:e.target.value||null})}><option value="">{t('none')}</option>
     {!!draft.vehicle_id&&!vehicles.some(v=>v.id===draft.vehicle_id)&&<option value={String(draft.vehicle_id)}>{String(draft.vehicle_id)}</option>}{vehicles.map(v=><option key={v.id} value={v.id}>{String(v.callsign)} · {v.name}</option>)}</select></>
    :<input required={key!=='registration'} type={['seats','water_litres','total_quantity'].includes(key)?'number':'text'} min="0" step={key==='total_quantity'?'0.001':'1'} maxLength={key==='name'?200:80} value={String(draft[key]??'')} onChange={e=>setDraft({...draft,[key]:e.target.value})}/>}</label>)}
   <label><input type="checkbox" checked={draft.active} onChange={e=>setDraft({...draft,active:e.target.checked})}/>{t('active')}</label>
   {kind!=='RESOURCE'&&<fieldset><legend>{t('capabilities')}</legend>{(data?.configuration.operational_capabilities??[]).filter(c=>c.active||draft.capabilities?.includes(c.code)).map(c=><label key={c.code}><input type="checkbox" checked={draft.capabilities?.includes(c.code)??false} onChange={e=>setDraft({...draft,capabilities:e.target.checked?[...(draft.capabilities??[]),c.code]:(draft.capabilities??[]).filter(x=>x!==c.code)})}/>{c.names[locale]??c.code}</label>)}</fieldset>}
   <button type="submit">{t('save')}</button></fieldset>
  </form>
  {stale&&<aside role="alert"><p>{t('stale')}</p><button onClick={()=>void current()}>{t('refresh')}</button>{serverItem&&<><h3>{t('current')}</h3><pre className="administration-payload">{JSON.stringify(serverItem,null,2)}</pre><button onClick={()=>{setDraft({...draft,version:serverItem.version});setReview(false);setStale(false);}}>{t('reedit')}</button></>}</aside>}
  {review&&!stale&&<aside className="admin-notice"><p>{t('review')}</p><dl>{fields[kind].map(key=><div key={key}><dt>{t(key)}</dt><dd>{String(draft[key]??'—')}</dd></div>)}</dl><p>{t(draft.active?'active':'inactive')}</p><p>{(draft.capabilities??[]).join(' · ')}</p><button disabled={busy} onClick={()=>void send()}>{t(pending?'retry':'confirm')}</button></aside>}
  {pending&&<p role="status">{t('pending')}</p>}
  <button disabled={locked} onClick={()=>{setDraft(null);setReview(false);setStale(false);}}>{t('cancel')}</button>
  </section>}</>}
 </section>;
}
