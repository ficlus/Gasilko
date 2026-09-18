import type { SupabaseClient } from '@supabase/supabase-js';
export async function startGoogle(client: SupabaseClient | null, origin: string, locale: string): Promise<boolean> {
  if (!client || !['sl','de'].includes(locale)) return false;
  try { const { error } = await client.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: origin + '/auth/callback?locale=' + locale } }); return !error; } catch { return false; }
}
