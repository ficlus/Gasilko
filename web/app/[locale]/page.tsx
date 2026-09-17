import Link from 'next/link';
import { notFound } from 'next/navigation';
import { dictionary, isLocale } from '../../lib/i18n';
export default async function Home({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const text = dictionary(locale);
  return <main><h1>{text.title}</h1><p>{text.foundation}</p><nav aria-label={text.language}><Link href="/sl" lang="sl" hrefLang="sl">{text.slovenian}</Link><Link href="/de" lang="de" hrefLang="de">{text.german}</Link></nav></main>;
}
