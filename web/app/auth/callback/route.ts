import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '../../../lib/supabase/server';
export async function GET(request: NextRequest) {
  const locale = request.nextUrl.searchParams.get('locale') === 'de' ? 'de' : 'sl';
  const code = request.nextUrl.searchParams.get('code');
  const client = await serverClient();
  const tokenHash=request.nextUrl.searchParams.get('token_hash'),type=request.nextUrl.searchParams.get('type');
  if(tokenHash&&client&&(type==='invite'||type==='email')){try{
    const {error}=await client.auth.verifyOtp({token_hash:tokenHash,type});
    if(!error){const response=NextResponse.redirect(new URL('/'+locale+'/invitations',request.url));response.headers.set('Cache-Control','no-store');response.headers.set('Referrer-Policy','no-referrer');return response;}
  }catch{/* Never return a token or raw provider error. */}}
  if (code && client) { try { const { error } = await client.auth.exchangeCodeForSession(code); if (!error) return NextResponse.redirect(new URL('/' + locale + '/account', request.url)); } catch { /* No raw provider error returned. */ } }
  return NextResponse.redirect(new URL('/' + locale, request.url));
}
