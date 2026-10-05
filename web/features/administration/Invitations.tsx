'use client';
import {useEffect,useRef,useState} from 'react';
import {useRouter} from 'next/navigation';
import type {Locale} from '@/lib/i18n';
import {browserClient} from '@/lib/supabase/browser';
import {administrationRpc,errorText,stateLabel,str,type Page,type Row} from '@/lib/administration/api';
import {administrationText} from '@/lib/administration/messages';
import {Pager} from './Controls';

export function Invitations({locale,account}:{locale:Locale;account:string}){
 const t=administrationText(locale),router=useRouter(),[data,setData]=useState<Page>({rows:[],more:false}),[page,setPage]=useState(0),[revision,setRevision]=useState(0),[error,setError]=useState(''),[busy,setBusy]=useState(false),[loading,setLoading]=useState(true),blocked=useRef(false),running=useRef(false);
 useEffect(()=>{const c=browserClient(),sub=c?.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT'||(session&&session.user.id!==account)){blocked.current=true;setData({rows:[],more:false});router.replace('/'+locale+'/account');}});const timer=setInterval(()=>setRevision(v=>v+1),60000);return()=>{sub?.data.subscription.unsubscribe();clearInterval(timer);};},[locale,account,router]);
 useEffect(()=>{let live=true;setLoading(true);void administrationRpc<Page>('web_my_invitations',{page}).then(r=>{if(live&&!blocked.current){setData(r);setError('');}}).catch(e=>{if(live){setData({rows:[],more:false});setError(errorText(e,locale));}}).finally(()=>{if(live)setLoading(false);});return()=>{live=false;};},[page,revision,locale]);
 async function accept(row:Row){if(running.current||blocked.current)return;running.current=true;setBusy(true);setError('');try{await administrationRpc('web_accept_invitation',{invitation:row.id,expected_version:row.version});setRevision(v=>v+1);router.refresh();}catch(e){setError(errorText(e,locale));}finally{running.current=false;setBusy(false);}}
 return <section>{error&&<p role="alert">{error}</p>}{loading&&<p role="status">{t.loading}</p>}{!loading&&!data.rows.length&&<p>{t.empty}</p>}{data.rows.map(row=><article className="admin-card" key={str(row,'id')}><h2>{str(row,'organization_name')}</h2><p>{stateLabel(str(row,'role'),locale)} · {stateLabel(str(row,'effective_status'),locale)}</p><p>{t.expires}: {str(row,'expires_at')}</p><p>{str(row,'message')}</p>{row.effective_status==='PENDING'&&<button disabled={busy} onClick={()=>void accept(row)}>{t.accept}</button>}</article>)}<Pager {...{page,locale}} more={data.more} onPage={setPage}/></section>;
}
