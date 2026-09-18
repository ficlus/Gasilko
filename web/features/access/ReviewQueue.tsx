'use client';
import { useState } from 'react';
import { browserClient } from '../../lib/supabase/browser';
import { dictionary, type Locale } from '../../lib/i18n';
import { reviewRequest, type ReviewRequest } from '../../lib/access/review';

export function ReviewQueue({ locale, initial }: { locale: Locale; initial: ReviewRequest[] }) {
  const t = dictionary(locale);
  const [rows, setRows] = useState(initial);
  const [more, setMore] = useState(initial.length === 50);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  async function load(append: boolean) {
    const client = browserClient();
    if (!client) throw Error();
    const { data, error } = await client.rpc('list_reviewable_access_requests', { after_id: append ? rows.at(-1)?.id : null });
    if (error) throw Error();
    setRows(append ? [...rows, ...(data ?? [])] : data ?? []);
    setMore(data?.length === 50);
  }
  async function refresh(append = false) {
    setBusy(true);
    try { await load(append); } catch { setMessage(t.requestError); } finally { setBusy(false); }
  }
  async function decide(id: string, decision: string) {
    setBusy(true);
    const result = await reviewRequest(browserClient(), id, decision);
    const labels: Record<string,string> = {
      APPROVED: t.requestApproved, REJECTED: t.requestRejected,
      ALREADY_REVIEWED: t.alreadyReviewed, NOT_AUTHORIZED: t.notAuthorized,
      INELIGIBLE: t.ineligibleApplicant, UNAVAILABLE: t.requestError, ALREADY_MEMBER: t.alreadyMember,
    };
    setMessage(labels[result] ?? t.requestError);
    if (['APPROVED','REJECTED','ALREADY_REVIEWED'].includes(result)) {
      // Only remove a row after the database confirms its terminal state.
      setRows(current => current.filter(row => row.id !== id));
    }
    setBusy(false);
  }
  return <section><h2>{t.pendingRequests}</h2><p role="status">{message}</p>
    {rows.length === 0 && <p>{t.noPendingRequests}</p>}
    {rows.map(row => <article key={row.id}>
      <h3>{row.requester_name || t.unnamedRequester}</h3><p>{row.organization_name}</p>
      <p>{t.requestedRole}: {row.requested_role === 'MANAGER' ? t.manager : t.firefighter}</p>
      <p>{t.requestedAt}: <time dateTime={row.requested_at}>{new Date(row.requested_at).toLocaleString(locale, {timeZone:'UTC'})} UTC</time></p>
      <p>{t.requestPending}</p>
      <button disabled={busy} onClick={() => void decide(row.id,'APPROVED')}>{t.approve}</button>
      <button disabled={busy} onClick={() => void decide(row.id,'REJECTED')}>{t.reject}</button>
    </article>)}
    {more && <button disabled={busy} onClick={() => void refresh(true)}>{t.loadMore}</button>}
    <button disabled={busy} onClick={() => void refresh()}>{t.refreshRequests}</button>
  </section>;
}
