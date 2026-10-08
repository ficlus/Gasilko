'use client';
import {useRef,useEffect,useState} from 'react';
import {useRouter} from 'next/navigation';
import {browserClient} from '../../lib/supabase/browser';
import {dictionary,type Locale} from '../../lib/i18n';

/** Enter an existing detail flow; never substitute incident authority for registry authority. */
export function HydrantDetailsAction({locale,account,id,organization}:{locale:Locale;account:string;id:string;organization:string}){
 const router=useRouter(),t=dictionary(locale),[busy,setBusy]=useState(false),[error,setError]=useState(false),alive=useRef(true);
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;};},[]);
 async function open(){
  if(busy)return;setBusy(true);setError(false);
  try{
   const client=browserClient();if(!client)throw Error();
   const {data:{user},error:authError}=await client.auth.getUser();
   if(authError||user?.id!==account)throw Error();
   // Existing web scope supports inherited read access. Ordinary members retain
   // their existing registry destination; each destination verifies access again.
   const result=await client.rpc('web_hydrant_context',{root:organization});
   if(result.error&&result.error.code!=='42501')throw Error();
   if(!alive.current)return;
   router.push(result.error?`/${locale}/hydrants/${id}?org=${organization}`:
    `/${locale}/admin/org/${organization}/hydrants?hydrant=${id}`);
  }catch{if(alive.current)setError(true);}finally{if(alive.current)setBusy(false);}
 }
 return <div><button type="button" disabled={busy} onClick={()=>void open()}>{t.hDetails}</button>{error&&<p role="alert">{t.hForbidden}</p>}</div>;
}
