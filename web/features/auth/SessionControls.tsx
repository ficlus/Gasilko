'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '../../lib/supabase/browser';
import { dictionary, type Locale } from '../../lib/i18n';
import { signOutSession } from '../../lib/auth/load';
export function SessionControls({ locale }: { locale: Locale }) {
  const router = useRouter(); const t = dictionary(locale); const [message, setMessage] = useState(''); const [busy, setBusy] = useState(false);
  useEffect(() => {
    const refresh = () => router.refresh();
    const client = browserClient();
    const listener = client?.auth.onAuthStateChange(event => { if (event === 'SIGNED_OUT' || event === 'TOKEN_REFRESHED') refresh(); });
    const timer = setInterval(refresh, 60000); window.addEventListener('focus', refresh);
    return () => { clearInterval(timer); window.removeEventListener('focus', refresh); listener?.data.subscription.unsubscribe(); };
  }, [router]);
  return <><div className="actions"><button onClick={() => router.refresh()} disabled={busy}>{t.refreshStatus}</button><button disabled={busy} onClick={async () => {
    setBusy(true); if (await signOutSession(browserClient())) { router.replace('/' + locale); router.refresh(); } else setMessage(t.authError); setBusy(false);
  }}>{t.signOut}</button></div><p role="status">{message}</p></>;
}
