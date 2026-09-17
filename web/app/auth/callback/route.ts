import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '../../../lib/supabase/server';
export async function GET(request: NextRequest) {
  const locale = request.nextUrl.searchParams.get('locale') === 'de' ? 'de' : 'sl';
  const code = request.nextUrl.searchParams.get('code');
  const client = await serverClient();
  if (code && client) { try { const { error } = await client.auth.exchangeCodeForSession(code); if (!error) return NextResponse.redirect(new URL('/' + locale + '/account', request.url)); } catch { /* No raw provider error returned. */ } }
  return NextResponse.redirect(new URL('/' + locale, request.url));
}
