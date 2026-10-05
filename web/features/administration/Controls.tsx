'use client';
import {useEffect,useId,useRef,useState} from 'react';
import {useRouter} from 'next/navigation';
import type {Locale} from '@/lib/i18n';
import {browserClient} from '@/lib/supabase/browser';
import {administrationRpc,AdministrationError,errorText,label,str,type Page,type Row,type Scope} from '@/lib/administration/api';
import {administrationText} from '@/lib/administration/messages';

export function Pager({page,more,onPage,locale}:{page:number;more:boolean;onPage:(page:number)=>void;locale:Locale}){const t=administrationText(locale);return <div className="actions"><button type="button" disabled={!page} onClick={()=>onPage(page-1)}>{t.previous}</button><span>{page+1}</span><button type="button" disabled={!more} onClick={()=>onPage(page+1)}>{t.next}</button></div>;}

export function useAdministrationScope(root:string|null,locale:Locale){
 const [scope,setScope]=useState<Scope|null>(null),[error,setError]=useState(''),[revision,setRevision]=useState(0),blocked=useRef(false),router=useRouter();
 useEffect(()=>{let live=true;void(async()=>{try{
  const result=root?await administrationRpc<Scope>('web_administration_context',{root}):await administrationRpc<boolean>('web_operator_access',{});
  if(!result)throw new AdministrationError('FORBIDDEN');
  if(live&&!blocked.current){setScope(typeof result==='boolean'?{operator:result,organizations:[]}:result);setError('');}
 }catch(e){if(live){setScope(null);setError(errorText(e,locale));}}})();return()=>{live=false;};},[root,locale,revision]);
 useEffect(()=>{let user:string|undefined,live=true;const c=browserClient();void c?.auth.getUser().then(r=>{if(live&&!user)user=r.data.user?.id;});
  const sub=c?.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT'||(user&&session?.user.id!==user)){blocked.current=true;setScope(null);router.replace('/'+locale+'/account');}else if(session&&!user)user=session.user.id;});
  const timer=setInterval(()=>setRevision(v=>v+1),60000);return()=>{live=false;clearInterval(timer);sub?.data.subscription.unsubscribe();};
 },[locale,router]);
 return {scope,error,revision,reload:()=>setRevision(v=>v+1)};
}

// Search and page selectors on the server; never load a national personnel directory.
export function ConfigurationPicker({kind,value,onChange,locale,multiple=false}:{kind:string;value:string[];onChange:(ids:string[])=>void;locale:Locale;multiple?:boolean}){
 const t=administrationText(locale),group=useId(),[search,setSearch]=useState(''),[page,setPage]=useState(0),[data,setData]=useState<Page>({rows:[],more:false}),[error,setError]=useState('');
 useEffect(()=>{let live=true;setData({rows:[],more:false});const timer=setTimeout(()=>{void administrationRpc<Page>('web_administration_configuration',{kind,search,page}).then(r=>{if(live){setData(r);setError('');}}).catch(e=>{if(live)setError(errorText(e,locale));});},200);return()=>{live=false;clearTimeout(timer);};},[kind,search,page,locale]);
 return <fieldset><legend>{t.lookup}</legend><label>{t.search}<input value={search} onChange={e=>{setSearch(e.target.value);setPage(0);}}/></label>
  {error&&<p role="alert">{error}</p>}<div className="administration-options">{data.rows.map(r=>{const id=str(r,kind==='relationship_types'?'code':'id');return <label key={id}><input type={multiple?'checkbox':'radio'} name={group} checked={value.includes(id)} onChange={()=>onChange(multiple?(value.includes(id)?value.filter(v=>v!==id):[...value,id]):[id])}/>{label(r,locale)}{r.active===false?' · '+t.inactive:''}</label>;})}</div>
  <Pager {...{page,locale}} more={data.more} onPage={setPage}/>{!!value.length&&<small>{value.join(' · ')}</small>}<button type="button" onClick={()=>onChange([])}>{t.cancel}</button>
 </fieldset>;
}

export function StructuredData({value}:{value:unknown}){return <pre className="administration-payload">{JSON.stringify(value,null,2)}</pre>;}
