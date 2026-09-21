import { statuses, type Hydrant, type Role, type Status } from './domain.ts';
export type ActiveFilter = 'active' | 'inactive' | 'all';
export type RegistryFilters = { search: string; typeId?: string; status?: Status; active: ActiveFilter; after?: string };
export type HydrantQuery = RegistryFilters & { organizationId: string };
export const defaultFilters = (): RegistryFilters => ({ search: '', active: 'active' });
export const isUuid = (value: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
export function parseFilters(params: Record<string, string | string[] | undefined>): RegistryFilters {
  const one = (key: string) => typeof params[key] === 'string' ? params[key] as string : '';
  const type = one('type'), after = one('after'), status = one('status');
  return { search: one('q').trim().slice(0,200), typeId: isUuid(type) ? type : undefined,
    status: statuses.includes(status as Status) ? status as Status : undefined,
    active: one('active') === 'all' || one('active') === 'inactive' ? one('active') as ActiveFilter : 'active',
    after: isUuid(after) ? after : undefined };
}
export function roleFilters(filters: RegistryFilters, role: Role): RegistryFilters { return { ...filters, search: filters.search.trim().slice(0,200), active: role === 'FIREFIGHTER' ? 'active' : filters.active }; }
export function queryString(org: string, filters: RegistryFilters) {
  const p = new URLSearchParams({ org });
  if (filters.search) p.set('q',filters.search);
  if (filters.typeId) p.set('type',filters.typeId);
  if (filters.status) p.set('status',filters.status);
  if (filters.active !== 'active') p.set('active',filters.active);
  if (filters.after) p.set('after',filters.after);
  return '?' + p.toString();
}
export function hasFilters(q: RegistryFilters) { return !!(q.search || q.typeId || q.status || q.active !== 'active'); }
// Immediate reconciliation of already-visible rows, never client-side registry querying.
export function matches(h: Hydrant, q: RegistryFilters) {
  const needle = q.search.trim().toLowerCase();
  return (!q.typeId || h.hydrant_type_id === q.typeId) && (!q.status || h.status === q.status)
    && (q.active === 'all' || h.active === (q.active === 'active'))
    && (!needle || [h.code,h.address,h.location_description].some(v => v?.toLowerCase().includes(needle)));
}
