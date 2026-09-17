import sl from '../messages/sl.json';
import de from '../messages/de.json';
export const locales = ['sl', 'de'] as const;
export type Locale = (typeof locales)[number];
export const defaultLocale: Locale = 'sl';
export function isLocale(value: string): value is Locale { return locales.some(locale => locale === value); }
const messages: Record<Locale, typeof sl> = { sl, de };
export function dictionary(locale: Locale) { return messages[locale]; }
