'use client';
import {useEffect,useRef,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import {isDisabledVehicleCapability,type VehicleLocationScope} from '../../lib/incidents/vehicleLocationCapability';
import {vehicleLocationText} from '../../lib/incidents/vehicleLocationText';
type Read=<T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,account?:string)=>Promise<T>;
type Props=VehicleLocationScope&{locale:Locale;fingerprint:string;locked:boolean;read:Read};

/** Manual optional read, isolated from B1/RTS authority and all command state. */
export function VehicleLocationCapability(props:Props) {
 // Remount local result and abort any old read on identity, scope or authorization loss.
 const identity=[props.account,props.org,props.incidentId,props.fingerprint,String(props.locked)].join('/');
 return <CapabilityCheck key={identity} {...props}/>;
}
function CapabilityCheck({locale,account,org,incidentId,fingerprint,locked,read}:Props) {
 const t=vehicleLocationText(locale),controller=useRef<AbortController|null>(null),alive=useRef(false);
 const [state,setState]=useState<'IDLE'|'READING'|'DISABLED'|'UNAVAILABLE'>('IDLE');
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;controller.current?.abort();};},[]);
 async function check() {
  if(locked||controller.current||!/^[0-9a-f]{32}$/.test(fingerprint))return;
  const ac=new AbortController();controller.current=ac;setState('READING');
  const timeout=setTimeout(()=>{ac.abort();if(alive.current)setState('UNAVAILABLE');},5000);
  try {
   const value=await read<unknown>('incident_vehicle_location_capabilities',{p_acting_organization_id:org,p_incident_id:incidentId},ac.signal,account);
   if(alive.current&&!ac.signal.aborted)setState(isDisabledVehicleCapability(value,{account,org,incidentId},fingerprint)?'DISABLED':'UNAVAILABLE');
  } catch {
   if(alive.current&&!ac.signal.aborted)setState('UNAVAILABLE');
  } finally {clearTimeout(timeout);}
 }
 return <section aria-label={t('off')}>
  <h4>□ {t('off')}</h4><p>{t('blocked')}</p><p>{t('noCapture')}</p>
  <p role="status">{state==='READING'?t('checking'):state==='DISABLED'?t('serverOff'):state==='UNAVAILABLE'?t('unverified'):''}</p>
  <button type="button" disabled={locked||state!=='IDLE'||!/^[0-9a-f]{32}$/.test(fingerprint)} onClick={()=>void check()}>{t('check')}</button>
 </section>;
}
