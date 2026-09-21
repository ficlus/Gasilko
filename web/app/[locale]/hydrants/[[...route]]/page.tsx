import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';
import { dictionary, isLocale } from '../../../../lib/i18n';
import { serverClient } from '../../../../lib/supabase/server';
import { loadAccount } from '../../../../lib/auth/load';
import { Registry } from '../../../../features/hydrants/Registry';
import { SessionControls } from '../../../../features/auth/SessionControls';
import type { Mode } from '../../../../lib/hydrants/controller';
import { parseFilters } from '../../../../lib/hydrants/query';
export const dynamic = 'force-dynamic';
export default async function Hydrants({ params, searchParams }: { params: Promise<{ locale: string; route?: string[] }>; searchParams: Promise<Record<string,string | string[] | undefined>> }) {
  const { locale, route = [] } = await params; if (!isLocale(locale)) notFound();
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  let mode: Mode = 'list'; let id: string | undefined;
  if (route.length === 1 && route[0] === 'new') mode = 'new';
  else if (route.length === 1 && uuid.test(route[0])) { mode = 'detail'; id = route[0]; }
  else if (route.length === 2 && uuid.test(route[0]) && route[1] === 'edit') { mode = 'edit'; id = route[0]; }
  else if (route.length) notFound();
  const account = await loadAccount(await serverClient());
  if (account.state === 'UNAUTHENTICATED') redirect('/' + locale);
  if (account.state !== 'ACTIVE') redirect('/' + locale + '/account');
  const query = await searchParams; const org = typeof query.org === 'string' && uuid.test(query.org) ? query.org : undefined;
  if (query.org && !org) notFound();
  const t = dictionary(locale);
  const filters = parseFilters(query);
  return <main className="registry-main"><h1>{t.hTitle}</h1><Registry key={`${locale}/${route.join('/')}/${org ?? ''}/${JSON.stringify(filters)}`} locale={locale} mode={mode} id={id} org={org} filters={filters}/><nav><Link href={`/${locale}/account`}>{t.backAccount}</Link></nav><SessionControls locale={locale}/></main>;
}
