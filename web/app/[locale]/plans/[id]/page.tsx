import Link from 'next/link';
import {notFound,redirect} from 'next/navigation';
import {isLocale,dictionary} from '../../../../lib/i18n';
import {serverClient} from '../../../../lib/supabase/server';
import {loadAccount} from '../../../../lib/auth/load';
import {isUuid} from '../../../../lib/operational/entity';
import {integrationText} from '../../../../lib/operational/integrationMessages';
import {EntityLink} from '../../../../features/operational/EntityLink';
import {stateLabel} from '../../../../lib/planning/api';
import {SessionControls} from '../../../../features/auth/SessionControls';
export const dynamic='force-dynamic';
export default async function PlanReference({params,searchParams}:{params:Promise<{locale:string;id:string}>;searchParams:Promise<Record<string,string|string[]|undefined>>}){
 const {locale,id}=await params;if(!isLocale(locale)||!isUuid(id))notFound();
 const client=await serverClient(),account=await loadAccount(client);
 if(!client||account.state!=='ACTIVE')redirect('/'+locale+'/account');
 const query=await searchParams,page=typeof query.page==='string'&&/^\d{1,4}$/.test(query.page)?Number(query.page):0;
 // Destination independently reads under caller RLS. No incident access is used.
 const {data:plan,error}=await client.from('inspection_plans').select('id,organization_id,name,status').eq('id',id).maybeSingle();
 if(error||!plan)notFound();
 const {data:items,error:itemError}=await client.from('inspection_plan_items')
  .select('id,hydrant_id,route_order,hydrant:hydrants!inner(id,organization_id,code)').eq('plan_id',id).eq('active',true)
  .order('route_order',{nullsFirst:false}).order('id').range(page*50,page*50+50);
 const {error:managementError}=await client.rpc('web_hydrant_context',{root:plan.organization_id});
 const t=integrationText(locale),d=dictionary(locale);
 return <main className="registry-main"><h1>{plan.name}</h1><p>{stateLabel(d,plan.status)} · {t('readOnly')}</p>
  {!managementError&&<Link href={'/'+locale+'/admin/org/'+plan.organization_id+'/plans?plan='+id}>{t('manage')}</Link>}
  {itemError?<p role="alert">{t('error')}</p>:<ul>{(items??[]).slice(0,50).map(item=>{
   const h=Array.isArray(item.hydrant)?item.hydrant[0]:item.hydrant;return h?<li key={item.id}>{item.route_order??'—'} · <EntityLink locale={locale} entity={{type:'HYDRANT',id:h.id,context:{organizationId:h.organization_id}}}>{h.code??d.hMissing}</EntityLink></li>:null;
  })}</ul>}
  <nav>{page>0&&<Link href={'?page='+(page-1)}>{t('previous')}</Link>}{(items?.length??0)>50&&<Link href={'?page='+(page+1)}>{t('next')}</Link>}</nav>
  <Link href={'/'+locale+'/account'}>{t('open')}</Link><SessionControls locale={locale}/>
 </main>;
}
