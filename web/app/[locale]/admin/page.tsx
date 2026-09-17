import { notFound, redirect } from 'next/navigation';
import { dictionary, isLocale } from '../../../lib/i18n';
import { serverClient } from '../../../lib/supabase/server';
import { loadAccount } from '../../../lib/auth/load';
import { SessionControls } from '../../../features/auth/SessionControls';
export const dynamic = 'force-dynamic';
export default async function Admin({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params; if (!isLocale(locale)) notFound();
  const account = await loadAccount(await serverClient());
  if (account.state === 'UNAUTHENTICATED') redirect('/' + locale);
  if (!account.admin) redirect('/' + locale + '/account');
  const t = dictionary(locale);
  return <main><h1>{t.adminShell}</h1><p>{t.shellNotice}</p><SessionControls locale={locale}/></main>;
}
