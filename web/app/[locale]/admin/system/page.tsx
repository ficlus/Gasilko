import Link from 'next/link';
import {notFound,redirect} from 'next/navigation';
import {isLocale} from '@/lib/i18n';
import {serverClient} from '@/lib/supabase/server';
import {administrationText} from '@/lib/administration/messages';
import {Administration} from '@/features/administration/Administration';
export const dynamic='force-dynamic';
export default async function Page({params}:{params:Promise<{locale:string}>}){
 const {locale}=await params;if(!isLocale(locale))notFound();const client=await serverClient(),user=client?await client.auth.getUser():null;
 if(!client||!user?.data.user)redirect('/'+locale);const t=administrationText(locale),access=await client.rpc('web_operator_access');
 if(access.error||access.data!==true)notFound();
 return <main><h1>{t.system}</h1><Link href={'/'+locale+'/account'}>{t.account}</Link><Administration key={user.data.user.id} locale={locale} root={null} section="system"/></main>;
}
