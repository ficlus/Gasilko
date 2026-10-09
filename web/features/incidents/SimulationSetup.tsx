'use client';
import dynamic from 'next/dynamic';
import type {Locale} from '../../lib/i18n';
import type {Core} from '../../lib/incidents/model';
import {simulationTemplates,type SimulationSetup as Setup} from '../../lib/operational/simulation';
import {simulationText} from '../../lib/operational/simulationMessages';
import {SimulationBanner} from './SimulationProvider';
const Canvas=dynamic(()=>import('../map/OperationalMapCanvas').then(m=>m.OperationalMapCanvas),{ssr:false});
export function SimulationSetup({locale,value,onChange,core,onCore}:{locale:Locale;value:Setup;onChange:(value:Setup)=>void;core:Core;onCore:(value:Core)=>void}){
 const t=simulationText(locale);
 return <fieldset className="simulation-setup"><legend>{t('new')}</legend><SimulationBanner locale={locale}/><p>{t('environment')}</p>
  <label>{t('template')}<select value={value.template} onChange={e=>onChange({...value,template:e.target.value as Setup['template']})}>{simulationTemplates.map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
  <label>{t('seed')}<input type="number" required min={0} max={2147483646} value={value.seed} onChange={e=>onChange({...value,seed:Number(e.target.value)})}/></label>
  <label>{t('radius')}<input type="number" required min={10} max={5000} value={value.radius_m} onChange={e=>onChange({...value,radius_m:Number(e.target.value)})}/></label>
  <p>{t('centerHelp')}</p><Canvas locale={locale} label={t('center')} initialPoints={core.longitude.trim()&&core.latitude.trim()?[[Number(core.longitude),Number(core.latitude)]]:[]}
   onClick={(_,event)=>onCore({...core,longitude:String(event.lngLat.lng),latitude:String(event.lngLat.lat),unknown_location_reason:''})}>{()=>null}</Canvas>
  <p>{t('longitude')}: {core.longitude||'—'} · {t('latitude')}: {core.latitude||'—'}</p><p>{t('setup')}</p>
 </fieldset>;
}
