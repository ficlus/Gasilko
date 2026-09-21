import type { SupabaseClient } from '@supabase/supabase-js';
import { RegistryError, payload, type Hydrant, type HydrantService, type HydrantType, type Organization, type Role } from './domain.ts';
export function apiError(error: { code?: string; message?: string }, status?: number): RegistryError {
  if (status === 401 || ['PGRST301', 'PGRST303'].includes(error.code ?? '')) return new RegistryError('expired');
  if (error.code === 'P0001' && error.message === 'HYDRANT_VERSION_CONFLICT') return new RegistryError('conflict');
  if (status === 403 || error.code === '42501') return new RegistryError('forbidden');
  if (/^(22|23)/.test(error.code ?? '')) return new RegistryError('validation');
  if (status === 0 || (!error.code && /fetch|network/i.test(error.message ?? ''))) return new RegistryError('network');
  return new RegistryError('server');
}
type Result<T> = { data: T | null; error: { code?: string; message?: string } | null; status?: number };
function checked<T>(r: Result<T>): T { if (r.error) throw apiError(r.error, r.status); if (r.data === null) throw new RegistryError('server'); return r.data; }
function record(data: unknown): Hydrant {
  const h = (Array.isArray(data) ? data[0] : data) as Hydrant | undefined;
  if (!h || !Number.isSafeInteger(h.version) || h.version < 1) throw new RegistryError('server');
  return h;
}
export function hydrantService(client: SupabaseClient): HydrantService {
  async function actor() {
    const r = await client.auth.getUser();
    if (r.error) throw r.error.status === 400 ? new RegistryError('expired') : apiError(r.error, r.error.status);
    if (!r.data.user) throw new RegistryError('expired');
    return r.data.user.id;
  }
  async function pages<T>(table: string, columns: string, filters: Record<string, string | null>, cursor = 'id'): Promise<T[]> {
    const all: T[] = []; let after: string | undefined;
    for (;;) {
      let q = client.from(table).select(columns).order(cursor).limit(100);
      for (const [key, value] of Object.entries(filters)) q = value === null ? q.is(key, null) : q.eq(key, value);
      if (after) q = q.gt(cursor, after);
      const page = checked(await q) as unknown as (T & Record<string, string>)[];
      all.push(...page); if (page.length < 100) return all;
      after = page[page.length - 1][cursor];
    }
  }
  async function find(org: string, id: string) {
    return checked(await client.from('hydrants').select('*').eq('organization_id', org).eq('id', id).limit(1)) as Hydrant[];
  }
  async function rpc(name: string, args: Record<string, unknown>) { return record(checked(await client.rpc(name, args))); }
  return {
    async organizations() {
      const user = await actor();
      const state = checked(await client.rpc('get_my_account_status'));
      if (state !== 'ACTIVE') throw new RegistryError('forbidden');
      const memberships = await pages<{ organization_id: string; role: Role }>('user_organizations', 'organization_id,role', { user_id: user }, 'organization_id');
      const organizations = await pages<Omit<Organization, 'role'>>('organizations', 'id,name,active', {});
      return organizations.flatMap(o => { const m = memberships.find(m => m.organization_id === o.id); return m && ['FIREFIGHTER','MANAGER','ADMIN'].includes(m.role) ? [{ ...o, role: m.role }] : []; });
    },
    async types(org) { return [...await pages<HydrantType>('hydrant_types', 'id,organization_id,code,name,active', { organization_id: null }), ...await pages<HydrantType>('hydrant_types', 'id,organization_id,code,name,active', { organization_id: org })]; },
    async list(q) {
      return checked(await client.rpc('search_hydrants', { organization: q.organizationId,
        search_text: q.search.trim(), type_id: q.typeId ?? null, status_filter: q.status ?? null,
        active_filter: q.active, after_id: q.after ?? null, page_size: 50 })) as Hydrant[];
    },
    async get(org, id) { const rows = await find(org, id); if (!rows.length) throw new RegistryError('unavailable'); return record(rows[0]); },
    async create(org, id, f) {
      const user = await actor(); const existing = await find(org, id);
      if (existing.length) { if (existing[0].created_by !== user) throw new RegistryError('forbidden'); return record(existing[0]); }
      return rpc('create_hydrant', { organization: org, hydrant_id: id, hydrant_type: f.hydrant_type_id, fields: payload(f, true) });
    },
    update: (organization, hydrant_id, f, expected_version) => rpc('update_hydrant', { organization, hydrant_id, changes: payload(f, false), expected_version }),
    status: (organization, hydrant_id, new_status, expected_version) => rpc('change_hydrant_status', { organization, hydrant_id, new_status, expected_version }),
    active: (organization, hydrant_id, is_active, expected_version) => rpc('set_hydrant_active', { organization, hydrant_id, is_active, expected_version }),
  };
}
