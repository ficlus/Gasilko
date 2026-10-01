'use client';
import { useRouter } from 'next/navigation';
import { useTransition } from 'react';
import { dictionary, type Locale } from '../../lib/i18n';
import { accessLabel, adminUrl, type AdminOrganization, type AdminSection } from '../../lib/admin/model';

export function OrganizationSwitcher({ locale, organizations, selected, section }: {
  locale: Locale; organizations: AdminOrganization[]; selected: string; section: AdminSection;
}) {
  const router = useRouter(); const [pending, startTransition] = useTransition();
  const t = dictionary(locale);
  return <label className="admin-org-switch">{t.selectOrganization}
    <select value={selected} disabled={pending} aria-busy={pending} onChange={event => {
      const id = event.target.value;
      if (organizations.some(org => org.id === id)) startTransition(() => router.push(adminUrl(locale, id, section)));
    }}>
      {organizations.map(org => <option key={org.id} value={org.id}>{org.name} · {accessLabel(org.access, locale)}</option>)}
    </select>
  </label>;
}
