import type { SupabaseClient } from '@supabase/supabase-js';
export type Choice = { id: string; name: string };
export type Organization = Choice & { code: string; type: string; administrative_area_id: string };
export type AccessRequest = { id: string; organization_id: string; organization_name: string; requested_role: string; status: string; requested_at: string };
export function canRequest(state: string) { return state === 'ACTIVE' || state === 'PENDING_APPROVAL'; }
export async function submitAccess(client: SupabaseClient | null, organization: string, role: string): Promise<string> {
  if (!client || !['FIREFIGHTER','MANAGER'].includes(role)) return 'INVALID_ROLE';
  try {
    const { data, error } = await client.rpc('request_organization_access', { organization, desired_role: role });
    return !error && ['SUBMITTED','DUPLICATE_REQUEST','ALREADY_MEMBER','INVALID_ROLE','NOT_ALLOWED','UNAVAILABLE'].includes(data?.result) ? data.result : 'ERROR';
  } catch { return 'ERROR'; }
}
