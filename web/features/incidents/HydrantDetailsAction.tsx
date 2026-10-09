'use client';
import {useRef,useEffect,useState} from 'react';
import {entityHref} from '../../lib/operational/entity';
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

   // Hydrant read authority is not Admin-shell authority.
   // Use the existing ordinary hydrant detail flow for every authorized reader;
   // the destination performs its own authoritative access check.
   if(!alive.current)return;
   const href=entityHref(locale,{type:'HYDRANT',id,context:{organizationId:organization}});if(href)router.push(href);
  }catch{if(alive.current)setError(true);}finally{if(alive.current)setBusy(false);}
 }
 return <div><button type="button" disabled={busy} onClick={()=>void open()}>{t.hDetails}</button>{error&&<p role="alert">{t.hForbidden}</p>}</div>;
}
