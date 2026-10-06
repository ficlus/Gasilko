import Link from 'next/link';
import {notFound,redirect} from 'next/navigation';
import {isLocale} from '../../../../lib/i18n';
import {serverClient} from '../../../../lib/supabase/server';
import {loadAccount} from '../../../../lib/auth/load';
import {incidentText} from '../../../../lib/incidents/messages';
import {IncidentArea} from '../../../../features/incidents/IncidentArea';
import {SessionControls} from '../../../../features/auth/SessionControls';
export const dynamic='force-dynamic';
export default async function Incidents({params,searchParams}:{params:Promise<{locale:string;route?:string[]}>;searchParams:Promise<Record<string,string|string[]|undefined>>}) {
 const {locale,route=[]}=await params;if(!isLocale(locale))notFound();
 const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
 if(route.length>1||(route.length===1&&route[0]!=='new'&&!uuid.test(route[0])))notFound();
 const client=await serverClient();const account=await loadAccount(client);
 if(account.state==='UNAUTHENTICATED')redirect('/'+locale);
 if(!client||account.state!=='ACTIVE')redirect('/'+locale+'/account');
 const {data:{user}}=await client.auth.getUser();if(!user)redirect('/'+locale);
 const query=await searchParams;const org=typeof query.org==='string'&&uuid.test(query.org)?query.org:undefined;
 if(query.org&&!org)notFound();const t=incidentText(locale);
 return <main className="registry-main admin-shell"><h1>{t('title')}</h1>
  <IncidentArea key={`${user.id}/${locale}/${route[0]??''}/${org??''}`} account={user.id} locale={locale} destination={route[0]} initialOrg={org}/>
  <nav><Link href={`/${locale}/account`}>{t('account')}</Link><Link href={`/${locale==='sl'?'de':'sl'}/incidents`}>{locale==='sl'?'Deutsch':'Slovenščina'}</Link></nav>
  <SessionControls locale={locale}/></main>;
}
