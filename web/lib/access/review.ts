import type { SupabaseClient } from '@supabase/supabase-js';

export type ReviewRequest = {
  id: string; requester_name: string | null; organization_id: string;
  organization_name: string; requested_role: string; requested_at: string; status: string;
};

export async function canReview(client: SupabaseClient | null): Promise<boolean> {
  if (!client) return false;
  try {
    const { data: { user }, error } = await client.auth.getUser();
    if (error || !user) return false;
    const status = await client.rpc('get_my_account_status');
    if (status.error || status.data !== 'ACTIVE') return false;
    const memberships = await client.from('user_organizations').select('user_id,role').eq('user_id', user.id);
    return !memberships.error && (memberships.data ?? []).some(m => m.user_id === user.id && ['MANAGER','ADMIN'].includes(m.role));
  } catch { return false; }
}

export async function reviewRequest(client: SupabaseClient | null, id: string, decision: string): Promise<string> {
  if (!client || !['APPROVED','REJECTED'].includes(decision)) return 'NOT_AUTHORIZED';
  try {
    const { data, error } = await client.rpc('review_organization_access', { request_id: id, decision });
    return !error && ['APPROVED','REJECTED','ALREADY_REVIEWED','NOT_AUTHORIZED','INELIGIBLE','UNAVAILABLE','ALREADY_MEMBER'].includes(data) ? data : 'ERROR';
  } catch { return 'ERROR'; }
}
