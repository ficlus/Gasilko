import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';
import { dictionary, isLocale } from '../../lib/i18n';
import { serverClient } from '../../lib/supabase/server';
import { loadAccount } from '../../lib/auth/load';
import { AuthForm } from '../../features/auth/AuthForm';
export const dynamic = 'force-dynamic';
export default async function Home({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params; if (!isLocale(locale)) notFound(); const t = dictionary(locale);
  const account = await loadAccount(await serverClient());
  if (account.state !== 'UNAUTHENTICATED' && account.state !== 'ERROR') redirect('/' + locale + '/account');
  return <main><h1>{t.title}</h1><AuthForm locale={locale}/><nav aria-label={t.language}><Link href="/sl" lang="sl">{t.slovenian}</Link><Link href="/de" lang="de">{t.german}</Link></nav></main>;
}
