import type { SupabaseClient } from '@supabase/supabase-js';
import { accountState, canEnterAdmin, type AccountState } from './state.ts';
export type Account = { state: AccountState; admin: boolean };
export async function loadAccount(client: SupabaseClient | null): Promise<Account> {
  if (!client) return { state: 'ERROR', admin: false };
  try {
    const { data: { user }, error } = await client.auth.getUser();
    if (error) return { state: error.status === 400 || error.status === 401 || error.status === 403 ? 'UNAUTHENTICATED' : 'ERROR', admin: false };
    if (!user) return { state: 'UNAUTHENTICATED', admin: false };
    const status = await client.rpc('get_my_account_status');
    if (status.error) return { state: 'ERROR', admin: false };
    const state = accountState(status.data);
    if (state !== 'ACTIVE') return { state, admin: false };
    const membership = await client.from('user_organizations').select('user_id,organization_id,role').eq('user_id', user.id).eq('role', 'ADMIN');
    if (membership.error) return { state: 'ERROR', admin: false };
    return { state, admin: canEnterAdmin(state, membership.data ?? [], user.id) };
  } catch { return { state: 'ERROR', admin: false }; }
}
export async function signOutSession(client: SupabaseClient | null): Promise<boolean> {
  if (!client) return false;
  try { return !(await client.auth.signOut({ scope: 'local' })).error; } catch { return false; }
}
