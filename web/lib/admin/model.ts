import {operationalText} from '../operational/messages';
import { dictionary, type Locale } from '../i18n';
import {administrationText} from '../administration/messages';
import {exchangeText} from '../exchange/messages';

export type NamedConfiguration = { code: string; names: Record<string, string> };
export type AdminOrganization = {
  id: string; name: string; code: string; type: NamedConfiguration;
  directRole: 'ADMIN' | 'MANAGER' | 'FIREFIGHTER' | null;
  access: 'ADMIN' | 'MANAGER' | 'READ_ONLY';
};
export type AdminContext = {
  organizations: AdminOrganization[]; selected: string | null;
  path: { id: string; name: string }[]; positions: NamedConfiguration[];
};
export const adminSections = ['dashboard', 'hydrants', 'map', 'inspections', 'teams', 'plans', 'exchange', 'inventory', 'users', 'organizations', 'types', 'audit'] as const;
export type AdminSection = typeof adminSections[number];
export function sectionLabel(section: AdminSection, locale: Locale) {
  const t = dictionary(locale);
  return { inventory:operationalText(locale)('inventory'), dashboard: t.adminDashboard, hydrants: t.hTitle, map: t.adminMap, inspections: t.adminInspections,
    teams: t.adminTeams, plans: t.adminPlans, exchange:exchangeText(locale).title, users: t.adminUsers, organizations: t.adminOrganizations, types:administrationText(locale).types, audit: t.adminAudit }[section];
}
export function accessLabel(access: AdminOrganization['access'] | 'FIREFIGHTER' | null, locale: Locale) {
  const t = dictionary(locale);
  return access === 'ADMIN' ? t.adminAdministrator : access === 'MANAGER' ? t.manager :
    access === 'FIREFIGHTER' ? t.firefighter : access === 'READ_ONLY' ? t.adminInherited : t.adminNoDirectMembership;
}
export function configurationName(value: NamedConfiguration, locale: Locale) {
  return value.names[locale] ?? value.names.en ?? Object.entries(value.names).sort(([a], [b]) => a.localeCompare(b))[0]?.[1] ?? value.code;
}
export function adminUrl(locale: Locale, organization: string, section: AdminSection = 'dashboard') {
  return `/${locale}/admin/org/${encodeURIComponent(organization)}${section === 'dashboard' ? '' : '/' + section}`;
}
