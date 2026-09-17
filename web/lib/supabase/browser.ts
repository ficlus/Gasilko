'use client';
import { createBrowserClient } from '@supabase/ssr';
import { publicConfig } from './config';
export function browserClient() {
  const config = publicConfig();
  return config ? createBrowserClient(config.url, config.key) : null;
}
