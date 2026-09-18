import { notFound, redirect } from 'next/navigation';
import { dictionary, isLocale } from '../../../lib/i18n';
import { serverClient } from '../../../lib/supabase/server';
import { loadAccount } from '../../../lib/auth/load';
import { canRequest } from '../../../lib/access/client';
import { AccessRequests } from '../../../features/access/AccessRequests';
import { SessionControls } from '../../../features/auth/SessionControls';
export const dynamic='force-dynamic';
export default async function Requests({params}:{params:Promise<{locale:string}>}) {
 const {locale}=await params;if(!isLocale(locale))notFound();const account=await loadAccount(await serverClient());
 if(account.state==='UNAUTHENTICATED')redirect('/'+locale);
 if(!canRequest(account.state))redirect('/'+locale+'/account');
 return <main><h1>{dictionary(locale).title}</h1><AccessRequests locale={locale}/><SessionControls locale={locale}/></main>;
}
