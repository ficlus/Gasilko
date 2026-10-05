import Link from 'next/link';
import {notFound,redirect} from 'next/navigation';
import {isLocale} from '@/lib/i18n';
import {serverClient} from '@/lib/supabase/server';
import {administrationText} from '@/lib/administration/messages';
import {Invitations} from '@/features/administration/Invitations';
export const dynamic='force-dynamic';
export default async function Page({params}:{params:Promise<{locale:string}>}){
 const {locale}=await params;if(!isLocale(locale))notFound();const client=await serverClient(),user=client?await client.auth.getUser():null;
 if(!user?.data.user)redirect('/'+locale);const t=administrationText(locale);
 return <main><h1>{t.invitations}</h1><Link href={'/'+locale+'/account'}>{t.account}</Link><Invitations key={user.data.user.id} account={user.data.user.id} locale={locale}/></main>;
}
