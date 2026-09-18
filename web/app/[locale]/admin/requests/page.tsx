import { notFound, redirect } from 'next/navigation';
import { dictionary, isLocale } from '../../../../lib/i18n';
import { serverClient } from '../../../../lib/supabase/server';
import { canReview } from '../../../../lib/access/review';
import { ReviewQueue } from '../../../../features/access/ReviewQueue';
import { SessionControls } from '../../../../features/auth/SessionControls';
export const dynamic = 'force-dynamic';
export default async function Requests({params}:{params:Promise<{locale:string}>}) {
  const {locale} = await params;
  if (!isLocale(locale)) notFound();
  const client = await serverClient();
  if (!await canReview(client)) redirect('/'+locale+'/account');
  const result = await client!.rpc('list_reviewable_access_requests');
  const t = dictionary(locale);
  return <main><h1>{t.reviewAccessRequests}</h1>
    {result.error ? <p role="alert">{t.requestError}</p> : <ReviewQueue locale={locale} initial={result.data ?? []}/>}
    <SessionControls locale={locale}/></main>;
}
