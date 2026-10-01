import 'server-only';
import { redirect } from 'next/navigation';
import { serverClient } from '../supabase/server';
import { loadAccount } from '../auth/load';
import type { Locale } from '../i18n';
import type { AdminContext } from './model';

/** Per-request SSR authorization. No service credential, shared cache or trusted URL preference. */
export async function adminContext(locale: Locale, organization: string | null = null) {
  const client = await serverClient();
  const account = await loadAccount(client);
  if (account.state === 'UNAUTHENTICATED') redirect('/' + locale);
  if (!client || account.state !== 'ACTIVE' || !account.admin) redirect('/' + locale + '/account');
  const { data: { user }, error: authError } = await client.auth.getUser();
  if (authError || !user) redirect('/' + locale + '/account');
  // The RPC computes the accessible set and selected context inside the database.
  // Fail closed on an unavailable migration/backend; never fall back to client roles.
  let context: AdminContext | null = null;
  try {
    const result = await client.rpc('web_admin_context', { organization });
    if (!result.error) context = result.data as AdminContext | null;
  } catch { /* Render the localized unavailable state without exposing provider errors. */ }
  return { client, context, user: user.email ?? user.id };
}
