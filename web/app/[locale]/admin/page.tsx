import { notFound, redirect } from 'next/navigation';
import { dictionary, isLocale } from '../../../lib/i18n';
import { adminContext } from '../../../lib/admin/context';
import { adminUrl } from '../../../lib/admin/model';
import { SessionControls } from '../../../features/auth/SessionControls';
export const dynamic = 'force-dynamic';
export default async function Admin({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params; if (!isLocale(locale)) notFound();
  const { context } = await adminContext(locale);
  if (context?.selected) redirect(adminUrl(locale, context.selected));
  if (context) redirect('/' + locale + '/account');
  const t = dictionary(locale);
  return <main><h1>{t.adminShell}</h1><p role="alert">{t.adminUnavailable}</p><SessionControls locale={locale}/></main>;
}
