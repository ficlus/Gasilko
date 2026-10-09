'use client';
import {useEffect,useRef,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import {integrationText} from '../../lib/operational/integrationMessages';
import {incidentText} from '../../lib/incidents/messages';
import type {Unit} from '../../lib/operational/model';
import type {Mutation} from '../../lib/incidents/model';
import {ContextActions} from './workspace';
export type CrewOutcomes=Record<string,{state:'saved'|'failed'|'pending';error?:string}>;
type Read=<T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,account?:string)=>Promise<T>;
type Page={rows:{id:string;name:string;eligible?:boolean}[];more:boolean};
export function TeamCrewTemplate({locale,account,org,incidentId,unit,locked,read,ask,outcomes}:{locale:Locale;account:string;org:string;incidentId:string;unit:Unit;locked:boolean;read:Read;ask:(action:Mutation,payload:Record<string,unknown>,description:string)=>void;outcomes:CrewOutcomes}){
 const t=integrationText(locale),errors=incidentText(locale),[open,setOpen]=useState(false),[team,setTeam]=useState(''),[page,setPage]=useState(0),[revision,setRevision]=useState(0);
 const [data,setData]=useState<Page|null>(null),[error,setError]=useState(false);
 // Frozen relationship identities survive preview paging and successful sibling joins.
 const ids=useRef(new Map<string,string>());
 useEffect(()=>{
  setData(null);setError(false);if(!open||!unit.can_crew)return;
  const ac=new AbortController();
  void read<Page>('incident_team_template',{p_incident_id:incidentId,p_acting_organization_id:org,p_unit_assignment_id:unit.id,p_team:team||null,p_page:page},ac.signal,account)
   .then(r=>{if(!ac.signal.aborted)setData(r);}).catch(()=>{if(!ac.signal.aborted){setData(null);setError(true);}});
  return()=>ac.abort();
 },[open,team,page,revision,account,org,incidentId,unit.id,unit.can_crew,read]);
 if(!unit.can_crew)return null;
 return <section className="admin-card"><ContextActions actions={[{id:'crew-template',label:t('template'),enabled:!locked,requiresConfirmation:false,execute:()=>setOpen(v=>!v)}]}/>
  {open&&<><p>{t('snapshot')}</p><p>{t('memberCheck')}</p>
   <fieldset disabled={locked}><legend>{t('template')}</legend>
    {team&&<button onClick={()=>{setTeam('');setPage(0);}}>{t('previous')}</button>}
    <button onClick={()=>{ids.current.clear();setRevision(v=>v+1);}}>{t('refresh')}</button>
    {error?<p role="alert">{t('error')}</p>:!data?<p role="status">{t('loading')}</p>:<>
     {!data.rows.length&&<p>{t('empty')}</p>}
     <ul>{data.rows.map(person=>{
      const joined=unit.crew.some(c=>c.user_id===person.id),outcome=ids.current.has(person.id)?outcomes[unit.id+':'+person.id]:undefined;
      return <li key={person.id}><strong>{person.name}</strong>
       {!team?<button onClick={()=>{setTeam(person.id);setPage(0);}}>{t('choose')}</button>:<>
        {joined?<span> · {t('joined')}</span>:<button disabled={!person.eligible||outcome?.state==='pending'||outcome?.state==='saved'} onClick={()=>{
         let id=ids.current.get(person.id);if(!id){id=crypto.randomUUID();ids.current.set(person.id,id);}
         ask('add_crew_member',{id,unit_assignment_id:unit.id,user_id:person.id,crew_role:'RESPONDER'},unit.callsign+' · '+person.name);
        }}>{t('join')}</button>}
        {!joined&&!person.eligible&&<p>{t('ineligible')}</p>}
        {outcome?.state==='failed'&&<p role="alert">{person.name}: {errors(outcome.error??'error')}</p>}
        {outcome?.state==='pending'&&<p role="status">{person.name}: {t('memberPending')}</p>}
        {outcome?.state==='saved'&&!joined&&<p role="status">{person.name}: {t('joined')}</p>}
       </>}
      </li>;
     })}</ul>
     <div className="actions"><button disabled={!page} onClick={()=>setPage(v=>v-1)}>{t('previous')}</button><button disabled={!data.more} onClick={()=>setPage(v=>v+1)}>{t('next')}</button></div>
    </>}
   </fieldset>
  </>}
 </section>;
}
