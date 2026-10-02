import Link from 'next/link';
import { notFound } from 'next/navigation';
import { dictionary, isLocale } from '@/lib/i18n';
import { adminContext } from '@/lib/admin/context';
import { accessLabel, adminSections, configurationName, type AdminSection } from '@/lib/admin/model';
import { AdminShell } from '@/features/admin/AdminShell';
import { SessionControls } from '@/features/auth/SessionControls';
import { ReviewQueue } from '@/features/access/ReviewQueue';
import { AdminHydrants } from '@/features/hydrants/AdminHydrants';

export const dynamic = 'force-dynamic';
export default async function OrganizationAdmin({ params }: {
  params: Promise<{ locale: string; organizationId: string; section?: string[] }>;
}) {
  const { locale, organizationId, section: segments } = await params;
  if (!isLocale(locale) || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(organizationId) || (segments?.length ?? 0) > 1) notFound();
  const section = segments?.[0] ?? 'dashboard';
  if (!adminSections.some(item => item === section)) notFound();
  const t = dictionary(locale);
  const { client, context, user } = await adminContext(locale, organizationId.toLowerCase());
  if (!context) return <main><h1>{t.adminShell}</h1><p role="alert">{t.adminUnavailable}</p><SessionControls locale={locale}/></main>;
  const organization = context.organizations.find(org => org.id === organizationId.toLowerCase() && org.id === context.selected);
  if (!organization) notFound();
  // This check is per page request, not just a persistent Next layout. The scoped
  // RPC below and existing review mutation independently enforce database roles.
  const reviews = section === 'users' && organization.access !== 'READ_ONLY'
    ? await client.rpc('list_organization_access_reviews', { organization: organization.id }) : null;
  return <AdminShell locale={locale} context={context} organization={organization} section={section as AdminSection} user={user}>
    {section === 'dashboard' ? <>
      <div className="admin-cards">
        <section className="admin-card"><h2>{t.adminActiveOrganization}</h2><p className="admin-value">{organization.name}</p>
          <dl><dt>{t.adminOrganizationType}</dt><dd>{configurationName(organization.type, locale)}</dd>
            <dt>{t.hCode}</dt><dd>{organization.code}</dd></dl></section>
        <section className="admin-card"><h2>{t.adminAccess}</h2><dl>
          <dt>{t.adminDirectRole}</dt><dd>{accessLabel(organization.directRole, locale)}</dd>
          <dt>{t.adminEffectiveAccess}</dt><dd>{accessLabel(organization.access, locale)}</dd>
        </dl><p>{t.adminWriteNotice}</p></section>
        <section className="admin-card"><h2>{t.adminPositions}</h2>
          {context.positions.length ? <ul>{context.positions.map((position, index) => <li key={position.code + ':' + index}>{configurationName(position, locale)}</li>)}</ul> : <p>{t.adminNoPositions}</p>}
          <p>{t.adminPositionNotice}</p></section>
      </div>
      <section className="admin-card"><h2>{t.adminHierarchy}</h2><p>{context.path.map(org => org.name).join(' › ')}</p><p>{t.adminPathNotice}</p></section>
    </> : !['hydrants','map','inspections','users'].includes(section) && <section className="admin-card"><h2>{t.adminComingTitle}</h2><p>{t.adminComingNotice}</p></section>}
    {['dashboard','hydrants','map','inspections'].includes(section) && <AdminHydrants key={organization.id+':'+section} locale={locale} root={organization.id} section={section}/>}
    {reviews && <section className="admin-card"><h2>{t.reviewAccessRequests}</h2>
      {reviews.error ? <p role="alert">{t.requestError}</p> : <ReviewQueue key={organization.id + ':' + organization.access}
        locale={locale} organization={organization.id} initial={reviews.data ?? []}/>}
    </section>}
    <p><Link href={'/' + locale + '/requests'}>{t.currentRequests}</Link></p>
  </AdminShell>;
}
