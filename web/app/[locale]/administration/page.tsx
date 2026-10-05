import Link from 'next/link';
import {notFound,redirect} from 'next/navigation';
import {isLocale} from '@/lib/i18n';
import {serverClient} from '@/lib/supabase/server';
import {administrationText} from '@/lib/administration/messages';
import {Administration} from '@/features/administration/Administration';
export const dynamic='force-dynamic';
export default async function Page({params,searchParams}:{params:Promise<{locale:string}>;searchParams:Promise<{organization?:string}>}){
 const {locale}=await params;if(!isLocale(locale))notFound();const client=await serverClient(),user=client?await client.auth.getUser():null;
 if(!client||!user?.data.user)redirect('/'+locale);const t=administrationText(locale),result=await client.rpc('web_administration_roots');
 const roots=result.data as {operator:boolean;organizations:{id:string;name:string;active:boolean}[]}|null;
 const {organization}=await searchParams,selected=roots?.organizations.find(o=>o.id===organization);
 return <main><h1>{t.recover}</h1><Link href={'/'+locale+'/account'}>{t.account}</Link><p>{t.selectRoot}</p>{result.error?<p role="alert">{t.forbidden}</p>:<><nav className="actions">{roots?.organizations.map(o=><Link key={o.id} href={'/'+locale+'/administration?organization='+o.id}>{o.name} · {o.active?t.active:t.inactive}</Link>)}</nav>{roots?.operator&&<p><Link href={'/'+locale+'/admin/system'}>{t.system}</Link></p>}{selected&&<Administration key={user.data.user.id+selected.id} locale={locale} root={selected.id} section="organizations"/>}</>}</main>;
}
