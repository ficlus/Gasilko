import {ActionCatalog} from '@/features/operational/ActionCatalog';
import {isUuid,parseEntityRef} from '@/lib/operational/entity';
import {OperationalInventory} from '@/features/operational/OperationalInventory';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { dictionary, isLocale } from '@/lib/i18n';
import { adminContext } from '@/lib/admin/context';
import { accessLabel, adminSections, configurationName, type AdminSection } from '@/lib/admin/model';
import { AdminShell } from '@/features/admin/AdminShell';
import { SessionControls } from '@/features/auth/SessionControls';
import { Administration, AdministrationDashboard } from '@/features/administration/Administration';
import { AdminHydrants } from '@/features/hydrants/AdminHydrants';
import { Teams } from '@/features/planning/Teams';
import { Plans, PlanningDashboard } from '@/features/planning/Plans';
import { Exchange } from '@/features/exchange/Exchange';

export const dynamic = 'force-dynamic';
export default async function OrganizationAdmin({ params, searchParams }: {
  params: Promise<{ locale: string; organizationId: string; section?: string[] }>;
  searchParams: Promise<{plan?:string;hydrant?:string;team?:string;entity?:string;addHydrant?:string}>;
}) {
  const { locale, organizationId, section: segments } = await params;
  if (!isLocale(locale) || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(organizationId) || (segments?.length ?? 0) > 1) notFound();
  const section = segments?.[0] ?? 'dashboard';
  if (!adminSections.some(item => item === section)) notFound();
  const t = dictionary(locale);
  const query = await searchParams;
  const planId = typeof query.plan === 'string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(query.plan) ? query.plan : undefined;
  const hydrantId = typeof query.hydrant === 'string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(query.hydrant) ? query.hydrant : undefined;
  const { context, user } = await adminContext(locale, organizationId.toLowerCase());
  if (!context) return <main><h1>{t.adminShell}</h1><p role="alert">{t.adminUnavailable}</p><SessionControls locale={locale}/></main>;
  const organization = context.organizations.find(org => org.id === organizationId.toLowerCase() && org.id === context.selected);
  if (!organization) notFound();
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
    </> : null}
    {['users','organizations','types','audit'].includes(section)&&<Administration key={organization.id+':'+section} locale={locale} root={organization.id} section={section}/>}
    {section==='dashboard'&&<AdministrationDashboard key={organization.id} locale={locale} root={organization.id}/>}
    {section === 'inventory' && <OperationalInventory key={organization.id+':'+(query.entity??'')} locale={locale} org={organization.id} initialEntity={parseEntityRef(query.entity,{organizationId:organization.id})??undefined}/>}
    {section === 'inventory' && <ActionCatalog key={organization.id} locale={locale} org={organization.id}/>}
    {section === 'exchange' && <Exchange key={organization.id} locale={locale} root={organization.id}/>}
    {section === 'teams' && <Teams key={organization.id+':'+(query.team??'')} locale={locale} root={organization.id} initialId={isUuid(query.team)?query.team:undefined}/>}
    {section === 'plans' && <Plans key={organization.id} locale={locale} root={organization.id} initialId={planId}/>}
    {section === 'dashboard' && <PlanningDashboard key={organization.id} locale={locale} root={organization.id}/>}
    {['dashboard','hydrants','map','inspections'].includes(section) && <AdminHydrants key={organization.id+':'+section+':'+(hydrantId??'')} locale={locale} root={organization.id} section={section} initialId={section==='hydrants'?hydrantId:undefined}/>}
    <p><Link href={'/' + locale + '/requests'}>{t.currentRequests}</Link></p>
  </AdminShell>;
}
