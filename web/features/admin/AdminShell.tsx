import Link from 'next/link';
import { dictionary, type Locale } from '../../lib/i18n';
import { accessLabel, adminSections, adminUrl, sectionLabel, type AdminContext, type AdminOrganization, type AdminSection } from '../../lib/admin/model';
import { OrganizationSwitcher } from './OrganizationSwitcher';
import { SessionControls } from '../auth/SessionControls';

export function AdminShell({ locale, context, organization, section, user, children }: {
  locale: Locale; context: AdminContext; organization: AdminOrganization; section: AdminSection;
  user: string; children: React.ReactNode;
}) {
  const t = dictionary(locale);
  return <div className="admin-shell">
    <a className="admin-skip" href="#admin-content">{t.adminSkipNavigation}</a>
    <header className="admin-header">
      <Link className="admin-brand" href={adminUrl(locale, organization.id)}>Gasilko<span>{t.adminShell}</span></Link>
      <OrganizationSwitcher locale={locale} organizations={context.organizations} selected={organization.id} section={section}/>
      <span className={'admin-badge ' + (organization.access === 'READ_ONLY' ? 'admin-read-only' : '')}>{accessLabel(organization.access, locale)}</span>
      <div className="admin-session"><span className="admin-user">{user}</span>
        <nav aria-label={t.language} className="admin-languages">
          <Link href={adminUrl('sl', organization.id, section)} lang="sl" aria-current={locale === 'sl' ? 'page' : undefined}>{t.slovenian}</Link>
          <Link href={adminUrl('de', organization.id, section)} lang="de" aria-current={locale === 'de' ? 'page' : undefined}>{t.german}</Link>
        </nav>
        <SessionControls locale={locale}/>
      </div>
    </header>
    <div className="admin-workspace">
      <nav className="admin-navigation" aria-label={t.adminNavigation}>
        {adminSections.map(item => <Link key={item} href={adminUrl(locale, organization.id, item)} aria-current={section === item ? 'page' : undefined}>
          {sectionLabel(item, locale)}
        </Link>)}
        <Link className="admin-account" href={'/' + locale + '/account'}>{t.backAccount}</Link>
      </nav>
      <main id="admin-content" className="admin-main" tabIndex={-1}>
        <nav className="admin-breadcrumb" aria-label={t.adminHierarchy}>
          <ol>{context.path.map((org, index) => <li key={org.id}>
            {index > 0 && <span aria-hidden="true">› </span>}
            {org.id === organization.id ? <span aria-current="page">{org.name}</span> : <Link href={adminUrl(locale, org.id)}>{org.name}</Link>}
          </li>)}</ol>
        </nav>
        <p className="admin-eyebrow">{organization.name}</p><h1>{sectionLabel(section, locale)}</h1>
        {organization.access === 'READ_ONLY' && <p className="admin-notice">{t.adminReadOnlyNotice}</p>}
        {children}
      </main>
    </div>
  </div>;
}
