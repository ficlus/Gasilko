import Link from 'next/link';
import { canReview } from '../../../lib/access/review';
import { notFound, redirect } from 'next/navigation';
import { dictionary, isLocale } from '../../../lib/i18n';
import { serverClient } from '../../../lib/supabase/server';
import { loadAccount } from '../../../lib/auth/load';
import { SessionControls } from '../../../features/auth/SessionControls';
import {administrationText} from '@/lib/administration/messages';
import {incidentText} from '../../../lib/incidents/messages';
export const dynamic = 'force-dynamic';
export default async function Account({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params; if (!isLocale(locale)) notFound(); const t = dictionary(locale);
  const account = await loadAccount(await serverClient());
  if (account.state === 'UNAUTHENTICATED') redirect('/' + locale);
  const reviewer = account.state === 'ACTIVE' && await canReview(await serverClient());
  const text = { ACTIVE: t.active, PENDING_APPROVAL: t.pending, SUSPENDED: t.suspended, REJECTED: t.rejected, ERROR: t.profileUnavailable }[account.state];
  const a=administrationText(locale);
  return <main><h1>{t.title}</h1><p>{text}</p>{account.state === 'ACTIVE' && <><p>{t.authorizationNotice}</p><p><Link href={'/'+locale+'/hydrants'}>{t.hTitle}</Link></p><p><Link href={'/'+locale+'/incidents'}>{incidentText(locale)('title')}</Link></p><p><Link href={'/'+locale+'/administration'}>{a.recover}</Link></p></>}{account.admin && <Link href={'/' + locale + '/admin'}>{t.adminShell}</Link>}{reviewer && <p><Link href={'/'+locale+'/admin/requests'}>{t.reviewAccessRequests}</Link></p>}{(account.state==='ACTIVE'||account.state==='PENDING_APPROVAL')&&<><p><Link href={'/'+locale+'/requests'}>{t.requestAccess}</Link></p><p><Link href={'/'+locale+'/invitations'}>{a.invitations}</Link></p></>}<SessionControls locale={locale}/></main>;
}
