'use client';
import { useState, type FormEvent } from 'react';
import { useRouter } from 'next/navigation';
import { dictionary, type Locale } from '../../lib/i18n';
import { browserClient } from '../../lib/supabase/browser';
import { startGoogle } from '../../lib/auth/google';
import { errorKey } from '../../lib/auth/state';
export function AuthForm({ locale }: { locale: Locale }) {
  const t = dictionary(locale); const router = useRouter();
  const [signup, setSignup] = useState(false); const [busy, setBusy] = useState(false); const [message, setMessage] = useState('');
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setBusy(true); setMessage('');
    const form = event.currentTarget; const data = new FormData(form); const client = browserClient();
    if (!client) { setMessage(t.configuration); setBusy(false); return; }
    try {
      const email = String(data.get('email')).trim(); const password = String(data.get('password'));
      if (signup) {
        const name = String(data.get('display_name')).trim(); const language = data.get('preferred_language') === 'de' ? 'de' : 'sl';
        if (!name || password.length < 8) { setMessage(t.weakPassword); return; }
        const { data: result, error } = await client.auth.signUp({ email, password, options: { data: { display_name: name, preferred_language: language }, emailRedirectTo: window.location.origin + '/auth/callback?locale=' + locale } });
        if (error) setMessage(t[errorKey(error)]);
        else if (result.session) { router.replace('/' + locale + '/account'); router.refresh(); }
        else { form.reset(); setMessage(t.signupNotice); }
      } else {
        const { error } = await client.auth.signInWithPassword({ email, password });
        if (error) setMessage(t[errorKey(error)]);
        else { form.reset(); router.replace('/' + locale + '/account'); router.refresh(); }
      }
    } catch { setMessage(t.authError); } finally { setBusy(false); const field = form.elements.namedItem('password'); if (field instanceof HTMLInputElement) field.value = ''; }
  }
  return <section><button disabled={busy} onClick={async () => { setBusy(true); setMessage(''); if (!(await startGoogle(browserClient(), window.location.origin, locale))) setMessage(t.authError); setBusy(false); }}>{t.continueGoogle}</button><h2>{signup ? t.signUp : t.signIn}</h2><form onSubmit={submit}>
    <label>{t.email}<input name="email" type="email" autoComplete="email" required maxLength={254} disabled={busy}/></label>
    <label>{t.password}<input name="password" type="password" autoComplete={signup ? 'new-password' : 'current-password'} minLength={signup ? 8 : 1} maxLength={256} required disabled={busy}/></label>
    {signup && <><label>{t.displayName}<input name="display_name" autoComplete="name" required maxLength={120} disabled={busy}/></label><label>{t.language}<select name="preferred_language" defaultValue={locale} disabled={busy}><option value="sl">{t.slovenian}</option><option value="de">{t.german}</option></select></label></>}
    <button disabled={busy} type="submit">{busy ? t.loading : signup ? t.signUp : t.signIn}</button>
  </form><p role="status">{message}</p><button disabled={busy} onClick={() => { setSignup(!signup); setMessage(''); }}>{signup ? t.signIn : t.signUp}</button></section>;
}
