'use client';
import Link from 'next/link';
import {useState} from 'react';
import type {Locale} from '../../lib/i18n';
import type {TemplateRead} from '../../lib/operational/templates';
import {workflowText} from '../../lib/operational/workflowMessages';
import {templateText} from '../../lib/operational/templateMessages';
import {SimulationOverview} from './SimulationOverview';
import './simWorkflow.css';
export function SimulationHome({locale,account,org,canCreate,read}:{locale:Locale;account:string;org:string;canCreate:boolean;read:TemplateRead}){
 const w=workflowText(locale),t=templateText(locale),[view,setView]=useState<'active'|'finished'>('active'),base='/'+locale+'/incidents?org='+encodeURIComponent(org);
 return <section><h2>{w('home')}</h2>{canCreate&&<div className="sim-home-cards">
 <article className="admin-card"><h3>{w('quick')}</h3><p>{w('quickHelp')}</p><Link href={'/'+locale+'/incidents/new?org='+encodeURIComponent(org)+'&training=1'}>{w('quick')}</Link></article>
 <article className="admin-card"><h3>{t('library')}</h3><p>{w('scenarioHelp')}</p><div className="actions"><Link href={base+'&templates=1'}>{t('library')}</Link><Link href={base+'&templates=1&templateStatus=DRAFT'}>{t('DRAFT')}</Link></div></article></div>}
 <div className="actions">{(['active','finished'] as const).map(v=><button key={v} aria-pressed={v===view} onClick={()=>setView(v)}>{w(v==='active'?'activeExercises':'finishedExercises')}</button>)}</div>
 <SimulationOverview key={account+org+view} locale={locale} account={account} org={org} read={read} view={view}/>
 </section>;
}
