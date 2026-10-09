'use client';
import {useEffect,useRef,useState,type FormEvent} from 'react';
import {useSearchParams} from 'next/navigation';
import type {Locale} from '../../lib/i18n';
import {incidentPriorities,type InboxItem,type Mutation} from '../../lib/incidents/model';
import type {Cop,CopFeedback} from '../../lib/incidents/cop';
import {resolveTarget,validPosition} from '../../lib/operational/target';
import {isUuid,parseEntityRef} from '../../lib/operational/entity';
import {actionLabel,parameterLabel,parameterValueLabel,taskErrorCode,type ActionDefinition,type Recipient,type Task,type TaskDetail,type TaskPage,type TaskRead,type TaskTarget,type TaskAssignment} from '../../lib/operational/tasks';
import {taskText} from '../../lib/operational/taskMessages';
import {ParameterInputs} from '../operational/ActionFields';
import {useRtsSession} from './rtsSession';
import {recipientKey,typingTarget,type RtsRecipient} from '../../lib/operational/rts';
import {rtsText} from '../../lib/operational/rtsMessages';
import {ContextActions,WorkspaceSlot,WorkspaceSection,useWorkspace} from './workspace';

type Props={locale:Locale;account:string;org:string;incidentId:string;version:string;incidentReference:string;organizationName:string;operational:boolean;refresh:number;feedback:CopFeedback;disabled:boolean;read:TaskRead;
 onAction:(action:Mutation,payload:Record<string,unknown>,item?:InboxItem,description?:string)=>void};
type HydrantOption={id:string;code:string|null;address:string|null};
type Chosen=RtsRecipient;
export function IncidentTasks({locale,account,org,incidentId,version,incidentReference,organizationName,operational,refresh,feedback,disabled,read,onAction}:Props){
 const urlQuery=useSearchParams();
 const rts=useRtsSession(),rt=rtsText(locale);
 const t=taskText(locale),workspace=useWorkspace(),alive=useRef(true),blocked=useRef(false);
 const [page,setPage]=useState(0),[history,setHistory]=useState(false),[reload,setReload]=useState(0),[rows,setRows]=useState<TaskPage<Task>|null>(null),[error,setError]=useState('');
 const [localSelected,setLocalSelected]=useState<string|null>(null),[detail,setDetail]=useState<TaskDetail|null>(null);
 useEffect(()=>{if(workspace)return;const ref=parseEntityRef(urlQuery.get('selected'),{incidentId,organizationId:org});setLocalSelected(ref?.type==='TASK'?ref.id:null);},[urlQuery,!!workspace,incidentId,org]);
 const selected=workspace?.selected,taskId=workspace?(selected?.kind==='TASK'?selected.id:null):localSelected;
 const formSession=useRef(0),editor=useRef<HTMLElement>(null);
 const {open,setOpen,action,setAction,recipients:chosen,setRecipients:setChosen,setTarget}=rts,target=rts.preview.target;
 const [taskUuid,setTaskUuid]=useState(''),[baseVersion,setBaseVersion]=useState(version);
 const [catalog,setCatalog]=useState<TaskPage<ActionDefinition>|null>(null),[catalogQuery,setCatalogQuery]=useState(''),[catalogPage,setCatalogPage]=useState(0);
 const [candidates,setCandidates]=useState<TaskPage<Recipient>|null>(null),[query,setQuery]=useState(''),[recipientPage,setRecipientPage]=useState(0);
 const [lon,setLon]=useState(''),[lat,setLat]=useState(''),[cop,setCop]=useState<Cop|null>(null);
 const [hydrantQuery,setHydrantQuery]=useState(''),[hydrants,setHydrants]=useState<HydrantOption[]>([]);
 const [parameters,setParameters]=useState<Record<string,unknown>>({}),[priority,setPriority]=useState('NORMAL'),[title,setTitle]=useState(''),[notes,setNotes]=useState(''),[stale,setStale]=useState(false);
 const [reasons,setReasons]=useState<Record<string,string>>({});
 const [readUnavailable,setReadUnavailable]=useState(false);
 const [checking,setChecking]=useState(false),[verifyEpoch,setVerifyEpoch]=useState(0),[actionChanged,setActionChanged]=useState(false);
 const verified=useRef(new Map<string,Recipient|null>()),verifiedEpoch=useRef(''),seenLaunch=useRef(0);
 const locked=disabled||rts.locked||rts.copEditing||rts.externalEditing;
 const selectionKeys=chosen.map(recipientKey).sort().join('|');
 const scope={p_incident_id:incidentId,p_acting_organization_id:org};
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;};},[]);
 function failure(e:unknown){const code=taskErrorCode(e);setError(code);setReadUnavailable(true);
  if(['NOT_AUTHORIZED','EXPIRED'].includes(code)){rts.revoke();blocked.current=true;setRows(null);setDetail(null);setCatalog(null);setCandidates(null);setChosen([]);setCop(null);setHydrants([]);setOpen(false);}}
 useEffect(()=>{
  if(feedback.kind==='blocked'){failure(new Error('NOT_AUTHORIZED'));return;}
  if(feedback.sequence>0&&feedback.kind==='saved'){if(open&&taskUuid){if(workspace)workspace.select({kind:'TASK',id:taskUuid});else setLocalSelected(taskUuid);}setOpen(false);setChosen([]);setTarget({kind:'NONE'});setAction(null);setStale(false);setReasons({});setError('');}
  if(feedback.kind==='stale'){setStale(true);setActionChanged(true);setReload(v=>v+1);}
 },[feedback.sequence]);
 useEffect(()=>{
  if(blocked.current)return;const ac=new AbortController();setRows(null);
  void read<TaskPage<Task>>('incident_tasks_page',{...scope,p_history:history,p_page:page},ac.signal,account).then(r=>{if(!ac.signal.aborted&&!blocked.current)setRows(r);}).catch(e=>{if(!ac.signal.aborted)failure(e);});
  return()=>ac.abort();
 },[account,org,incidentId,history,page,refresh,reload,read]);
 useEffect(()=>{
  const ac=new AbortController();setDetail(null);
  if(taskId&&!blocked.current)void read<TaskDetail>('incident_task_detail',{...scope,p_id:taskId},ac.signal,account).then(r=>{if(!ac.signal.aborted&&!blocked.current)setDetail(r);}).catch(e=>{if(!ac.signal.aborted)failure(e);});
  return()=>ac.abort();
 },[taskId,account,org,incidentId,refresh,reload,read]);
 useEffect(()=>{
  if(!open||blocked.current)return;const ac=new AbortController();setCatalog(null);
  const timer=setTimeout(()=>{void read<TaskPage<ActionDefinition>>('operational_action_catalog',{p_organization_id:org,p_query:catalogQuery,p_page:catalogPage},ac.signal,account)
   .then(r=>{if(!ac.signal.aborted&&!blocked.current){setCatalog(r);const current=r.rows.find(d=>d.id===action?.id);if(current&&current.configuration.id!==action?.configuration.id)setActionChanged(true);}}).catch(e=>{if(!ac.signal.aborted)failure(e);});},300);
  return()=>{clearTimeout(timer);ac.abort();};
 },[open,account,org,catalogQuery,catalogPage,refresh,reload,read]);
 useEffect(()=>{
  if(!operational||blocked.current)return;const ac=new AbortController();setCandidates(null);
  const timer=setTimeout(()=>{void read<TaskPage<Recipient>>('incident_task_recipients',{...scope,p_query:query,p_page:recipientPage},ac.signal,account)
   .then(r=>{if(!ac.signal.aborted&&!blocked.current){setCandidates(r);verified.current=new Map([...verified.current].filter(([key])=>chosen.some(row=>recipientKey(row)===key)));r.rows.forEach(row=>verified.current.set(recipientKey(row),row));}}).catch(e=>{if(!ac.signal.aborted)failure(e);});},300);
  return()=>{clearTimeout(timer);ac.abort();};
 },[operational,account,org,incidentId,query,recipientPage,refresh,reload,read]);
 useEffect(()=>{
  if(!open||blocked.current)return;const ac=new AbortController();setCop(null);
  void read<Cop>('incident_cop',scope,ac.signal,account).then(r=>{if(!ac.signal.aborted&&!blocked.current)setCop(r);}).catch(e=>{if(!ac.signal.aborted)failure(e);});
  return()=>ac.abort();
 },[open,account,org,incidentId,refresh,reload,read]);
 useEffect(()=>{
  if(!open||target.kind!=='HYDRANT'||blocked.current)return;const ac=new AbortController();setHydrants([]);
  const timer=setTimeout(()=>{void read<HydrantOption[]>('incident_cop_hydrants',{...scope,p_query:hydrantQuery},ac.signal,account)
   .then(r=>{if(!ac.signal.aborted&&!blocked.current)setHydrants(r);}).catch(e=>{if(!ac.signal.aborted)failure(e);});},300);
  return()=>{clearTimeout(timer);ac.abort();};
 },[open,target.kind,hydrantQuery,account,org,incidentId,read]);

 useEffect(()=>{
  if(!open){formSession.current++;return;}
  const frame=requestAnimationFrame(()=>editor.current?.focus());
  return()=>cancelAnimationFrame(frame);
 },[open]);
 // Only selected identities absent from the current authorized page need a bounded lookup.
 // Four in flight at most; cancellation/epoch keys prevent cross-scope or stale updates.
 useEffect(()=>{
  if(blocked.current||!operational)return;
  const epoch=refresh+'/'+reload+'/'+verifyEpoch;
  if(verifiedEpoch.current!==epoch){verified.current.clear();verifiedEpoch.current=epoch;}
  const ac=new AbortController(),snapshot=[...chosen],missing=snapshot.filter(r=>!verified.current.has(recipientKey(r)));
  const apply=()=>setChosen(current=>current.map((row):RtsRecipient=>{
   const key=recipientKey(row);if(!verified.current.has(key))return {...row,eligibility:'UNKNOWN'};
   const authorized=verified.current.get(key);
   return authorized?{...row,...authorized,eligibility:'ELIGIBLE'}:{...row,eligibility:'UNAVAILABLE'};
  }));
  apply();setChecking(missing.length>0);let next=0;
  const work=async()=>{while(next<missing.length&&!ac.signal.aborted&&!blocked.current){
   const row=missing[next++];
   try{
    const page=await read<TaskPage<Recipient>>('incident_task_recipients',{...scope,p_id:row.id},ac.signal,account);
    if(ac.signal.aborted||blocked.current)return;
    verified.current.set(recipientKey(row),page.rows.find(r=>recipientKey(r)===recipientKey(row))??null);apply();
   }catch(e){if(!ac.signal.aborted){failure(e);}return;}
  }};
  void Promise.all(Array.from({length:Math.min(4,missing.length)},work)).finally(()=>{if(!ac.signal.aborted)setChecking(false);});
  return()=>ac.abort();
 },[selectionKeys,refresh,reload,verifyEpoch,operational,account,org,incidentId,read]);
 useEffect(()=>{
  if(rts.launch===seenLaunch.current)return;seenLaunch.current=rts.launch;begin(false,true);
 },[rts.launch]);
 useEffect(()=>{
  if(!open||target.kind!=='COORDINATE'||!rts.preview.geometry)return;
  setLon(Number.isFinite(target.coordinate[0])?String(target.coordinate[0]):'');
  setLat(Number.isFinite(target.coordinate[1])?String(target.coordinate[1]):'');
 },[target]);
 useEffect(()=>{
  if(!open||target.kind==='NONE'||rts.preview.geometry)return;
  const geometry=resolveTarget(target,{cop:cop??undefined});
  if(geometry)rts.hydrateTarget(target,geometry,targetLabel(target));
 },[open,target,cop,rts.preview.geometry,rts.hydrateTarget]);
 useEffect(()=>{
  rts.setIntent(!open&&detail?{...detail,label:actionLabel(detail.configuration,locale)}:null);
 },[detail,open,locale,rts.setIntent]);

 function begin(prefill=false,preserveRecipients=false){
  if(locked||!operational)return;
  const session=++formSession.current;
  setTaskUuid(crypto.randomUUID());setBaseVersion(version);setOpen(true);setError('');setReadUnavailable(false);setStale(false);setAction(null);if(!preserveRecipients)setChosen([]);setActionChanged(false);setParameters({});setTitle('');setNotes('');setPriority('NORMAL');setLon('');setLat('');
  setTarget(prefill&&selected&&['HYDRANT','INCIDENT_SECTOR','MAP_OBJECT'].includes(selected.kind)?selected.kind==='HYDRANT'?{kind:'HYDRANT',entityId:selected.id}:
   {kind:selected.kind==='MAP_OBJECT'?'INCIDENT_MAP_OBJECT':'INCIDENT_SECTOR',entityId:selected.id,incidentId}:{kind:'NONE'});
  if(prefill&&selected?.kind==='INCIDENT_UNIT'){
   void read<TaskPage<Recipient>>('incident_task_recipients',{...scope,p_id:selected.id},undefined,account).then(r=>{
    if(alive.current&&!blocked.current&&session===formSession.current&&r.rows[0])setChosen([{...r.rows[0],assignmentId:crypto.randomUUID(),eligibility:'ELIGIBLE'}]);
   }).catch(e=>{if(alive.current)failure(e);});
  }
 }
 function chooseAction(id:string){const d=catalog?.rows.find(d=>d.id===id)??null;setAction(d);setActionChanged(false);if(d)setPriority(d.configuration.default_priority);}
 function chooseRecipient(r:Recipient,checked:boolean){setChosen(current=>checked?current.some(c=>recipientKey(c)===recipientKey(r))?current:[...current,{...r,assignmentId:crypto.randomUUID(),eligibility:'ELIGIBLE'}]:current.filter(c=>recipientKey(c)!==recipientKey(r)));}
 function selectTask(id:string){formSession.current++;setOpen(false);if(workspace)workspace.select({kind:'TASK',id});else setLocalSelected(id);}
 function command(actionName:Mutation,payload:Record<string,unknown>,expected:string,summary:string){
  onAction(actionName,payload,{id:String(payload.id),incident_id:incidentId,organization_id:org,version:expected,title:'',reference_number:''},summary);
 }
 function targetLabel(v:TaskTarget):string{
  if(rts.preview.label&&JSON.stringify(v)===JSON.stringify(target))return rts.preview.label;
  if(v.kind==='NONE')return t('NONE');
  if(v.kind==='COORDINATE')return v.coordinate.join(', ');
  if(v.kind==='HYDRANT')return (cop?.links.find(l=>l.hydrant?.id===v.entityId)?.hydrant?.code??hydrants.find(h=>h.id===v.entityId)?.code??v.entityId)+' · '+v.entityId;
  return (v.kind==='INCIDENT_SECTOR'?cop?.sectors.find(s=>s.id===v.entityId)?.name:cop?.objects.find(o=>o.id===v.entityId)?.label)??v.entityId;
 }
 function review(e:FormEvent){
  e.preventDefault();if(!action||!chosen.length||stale||locked||checking||actionChanged||readUnavailable||!catalog||!cop)return;
  if(chosen.some(r=>r.eligibility!=='ELIGIBLE')){setError('INVALID_TASK_RECIPIENT');return;}
  const cfg=action.configuration;
  const v:TaskTarget=target.kind==='COORDINATE'?{kind:'COORDINATE',coordinate:[lon.trim()===''?NaN:Number(lon),lat.trim()===''?NaN:Number(lat)]}:target;
  if(!cfg.target_types.includes(v.kind)){setError('targetMismatch');return;}
  if(v.kind==='COORDINATE'&&!validPosition(v.coordinate)){setError('INVALID_TASK_TARGET');return;}
  if('entityId' in v&&!isUuid(v.entityId)){setError('INVALID_TASK_TARGET');return;}
  if(chosen.some(r=>!cfg.recipient_types.includes(r.type))){setError('INVALID_TASK_RECIPIENT');return;}
  if(['MOVE_TO','WITHDRAW_TO'].includes(cfg.native_behavior)&&v.kind!=='HYDRANT'&&(rts.preview.geometry??resolveTarget(v.kind==='NONE'?{kind:'COORDINATE',coordinate:[NaN,NaN]}:v,{cop:cop??undefined}))?.type!=='Point'){setError('TASK_POINT_REQUIRED');return;}
  const parameterSummary=cfg.parameter_definitions.map(p=>parameterLabel(p,locale)+': '+parameterValueLabel(p,parameters[p.code],locale)).join('\n');
  const summary=[rt('incident')+': '+incidentReference,rt('actingOrg')+': '+organizationName,rt('recipientCount')+': '+chosen.length,actionLabel(cfg,locale)+' · '+t('version')+' '+cfg.version_number,t('native')+': '+t(cfg.native_behavior),t('ack')+': '+t(cfg.requires_acknowledgement?'yes':'no'),t('priority')+': '+t(priority),
   t('recipients')+': '+chosen.map(r=>t(r.type)+': '+r.name+' ('+r.organization_name+')').join('; '),t('target')+': '+t(v.kind)+' · '+targetLabel(v),('entityId' in v?v.entityId:''),rts.preview.geometry?.type==='Point'?rts.preview.geometry.coordinates.join(', '):'',parameterSummary,title,notes,t('intentNotice')].filter(Boolean).join('\n');
  command('issue_task',{id:taskUuid,action_version_id:cfg.id,priority,title,notes,target:v,parameters,
   recipients:chosen.map(r=>({id:r.assignmentId,type:r.type,recipient_id:r.id}))},baseVersion,summary);
 }
 function transition(a:TaskAssignment,status:string){
  const reason=(reasons[a.id]??'').trim();if(['BLOCKED','UNABLE'].includes(status)&&!reason){setError('VALIDATION_FAILED');return;}
  command('transition_task_assignment',{id:a.id,status,...(['BLOCKED','UNABLE'].includes(status)?{reason}:{})},a.version,
   [detail? actionLabel(detail.configuration,locale):'',a.recipient_name,t(a.status)+' → '+t(status),reason].filter(Boolean).join('\n'));
 }
 function executionStates(a:TaskAssignment):string[]{
  if(!a.can_execute)return [];
  if(a.status==='ISSUED')return ['ACKNOWLEDGED',...(!detail?.configuration.requires_acknowledgement?['IN_PROGRESS']:[]),'UNABLE'];
  if(a.status==='ACKNOWLEDGED'||a.status==='BLOCKED')return ['IN_PROGRESS','UNABLE'];
  if(a.status==='IN_PROGRESS')return ['BLOCKED','COMPLETED'];return [];
 }
 const supportedSelected=selected&&['HYDRANT','INCIDENT_SECTOR','MAP_OBJECT','INCIDENT_UNIT'].includes(selected.kind)&&selected.id!=='primary';
 const cfg=action?.configuration,targetAllowed=!cfg||cfg.target_types.includes(target.kind);
 const visibleRecipients:Chosen[]=(candidates?.rows??[]).map(r=>({...r,assignmentId:chosen.find(c=>recipientKey(c)===recipientKey(r))?.assignmentId??crypto.randomUUID(),eligibility:'ELIGIBLE',sector_name:cop?.sectors.find(s=>s.id===r.sector_id)?.name}));
 const invalidRecipients=chosen.some(r=>r.eligibility!=='ELIGIBLE'||!!cfg&&!cfg.recipient_types.includes(r.type));
 const currentHydrantId=target.kind==='HYDRANT'?target.entityId:'';
 const hydrantOptions=Array.from(new Map([...(cop?.links.flatMap(l=>l.hydrant?[{id:l.hydrant.id,code:l.hydrant.code,address:l.hydrant.address}]:[])??[]),...hydrants].map(h=>[h.id,h])).values());
 if(blocked.current)return <WorkspaceSlot name="operational"><p role="alert">{t(error||'NOT_AUTHORIZED')}</p></WorkspaceSlot>;
 return <>
  <WorkspaceSlot name="operational">{operational&&<WorkspaceSection title={rt('rtsTitle')} open>
   <p>{rt('listHints')}</p><p>{rt('eligibilityNotice')}</p>
   <label>{t('search')}<input maxLength={100} value={query} onChange={e=>{setQuery(e.target.value);setRecipientPage(0);}}/></label>
   <div className="actions"><button type="button" disabled={locked||!candidates} onClick={()=>rts.selectMany(visibleRecipients.filter(r=>!cfg||cfg.recipient_types.includes(r.type)),rts.merge)}>{rt('visible')}</button>
    <button type="button" disabled={locked||!chosen.length||checking} onClick={()=>{setError('');setReadUnavailable(false);setVerifyEpoch(v=>v+1);}}>{rt('checkRecipients')}</button></div>
   {checking&&<p role="status">{rt('checking')}</p>}
   <div className="rts-recipient-list" tabIndex={0} aria-label={rt('rtsTitle')} onKeyDown={e=>{
    if(!locked&&!typingTarget(e.target)&&!e.nativeEvent.isComposing&&(e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='a'){
     e.preventDefault();e.stopPropagation();rts.selectMany(visibleRecipients.filter(r=>!cfg||cfg.recipient_types.includes(r.type)),rts.merge);
    }
   }}>
    {!candidates?<p>{t('loading')}</p>:!visibleRecipients.length?<p>{t('empty')}</p>:visibleRecipients.map(row=><button type="button" key={recipientKey(row)}
     className="web-row rts-recipient" disabled={locked} aria-pressed={chosen.some(r=>recipientKey(r)===recipientKey(row))}
     onClick={e=>rts.pick(row,visibleRecipients,{list:'recipients:'+query+':'+recipientPage,toggle:e.ctrlKey||e.metaKey,range:e.shiftKey})}>
     <strong>{row.name}</strong><span>{t(row.type)} · {row.organization_name}</span>
     {row.sector_name&&<span>{rt('sector')}: {row.sector_name}</span>}
     <small>{rt(cfg&&!cfg.recipient_types.includes(row.type)?'unsupported':'eligible')}</small>
    </button>)}
   </div>
   <div className="actions"><button type="button" disabled={locked||recipientPage===0} onClick={()=>setRecipientPage(v=>v-1)}>{t('previous')}</button>
    <span>{recipientPage+1}</span><button type="button" disabled={locked||!candidates?.more} onClick={()=>setRecipientPage(v=>v+1)}>{t('next')}</button></div>
  </WorkspaceSection>}<WorkspaceSection title={t('tasks')}>
   {error&&<p role="alert">{t(error)}</p>}<p>{t('intentNotice')}</p>
   <div className="actions">{operational&&<button disabled={locked} onClick={()=>begin()}>{t('newTask')}</button>}
    <button disabled={disabled} onClick={()=>{setError('');setReadUnavailable(false);setReload(v=>v+1);}}>{t('refresh')}</button>
    <button onClick={()=>{setHistory(!history);setPage(0);}}>{t(history?'openTasks':'history')}</button></div>
   <h4>{t(history?'history':'openTasks')}</h4>
   {!rows?<p>{t('loading')}</p>:<>{!rows.rows.length&&<p>{t('empty')}</p>}{rows.rows.map(task=><article className="web-row" key={task.id}>
    <button onClick={()=>selectTask(task.id)}>{actionLabel(task.configuration,locale)}{task.title?' · '+task.title:''}</button>
    <p><strong className="task-priority" data-priority={task.priority}>{t('priority')}: {t(task.priority)}</strong> · {t(task.status)}{task.outcome?' · '+t(task.outcome):''}</p>
    <small>{task.target_label_snapshot??t(task.target_type)} · {new Date(task.issued_at).toLocaleString(locale)}</small>
   </article>)}<div className="actions"><button disabled={page===0} onClick={()=>setPage(v=>v-1)}>{t('previous')}</button><button disabled={!rows.more} onClick={()=>setPage(v=>v+1)}>{t('next')}</button></div></>}
  </WorkspaceSection></WorkspaceSlot>
  {supportedSelected&&operational&&<WorkspaceSlot name="selectedPane"><ContextActions actions={[{id:'create-task',label:t(selected.kind==='INCIDENT_UNIT'?'issueToUnit':'createHere'),enabled:!locked,requiresConfirmation:false,execute:()=>begin(true)}]}/></WorkspaceSlot>}
  {open&&operational&&<WorkspaceSlot name="selectedPane"><section className="admin-card rts-editor" ref={editor} data-rts-editor tabIndex={-1}><h3>{rt('palette')}</h3><p>{rt('paletteHelp')}</p>
   <p>{rt('incident')}: {incidentReference} · {rt('actingOrg')}: {organizationName}</p>
   {stale&&<><p role="alert">{t('stale')}</p><button disabled={disabled||!catalog} onClick={()=>{setBaseVersion(version);setActionChanged(true);setStale(false);setError('');setVerifyEpoch(v=>v+1);}}>{t('reedit')}</button></>}
   {error&&<p role="alert">{t(error)}</p>}
   {readUnavailable&&<p role="alert">{rt('readUnavailable')}</p>}
   {actionChanged&&<p role="alert">{rt('actionChanged')}</p>}
   <form className="task-editor" onSubmit={review}><fieldset disabled={locked||stale}><legend>{t('action')}</legend>
    <label>{t('search')}<input maxLength={100} value={catalogQuery} onChange={e=>{setCatalogQuery(e.target.value);setCatalogPage(0);}}/></label>
    <label>{t('action')}<select required value={actionChanged?'':action?.id??''} onChange={e=>chooseAction(e.target.value)}><option value="">{t('select')}</option>
     {action&&!catalog?.rows.some(d=>d.id===action.id)&&<option value={action.id}>{actionLabel(action.configuration,locale)}</option>}
     {catalog?.rows.map(d=><option key={d.id} value={d.id}>{actionLabel(d.configuration,locale)} · {d.code}</option>)}</select></label>
    <div className="actions"><button type="button" disabled={catalogPage===0} onClick={()=>setCatalogPage(v=>v-1)}>{t('previous')}</button><button type="button" disabled={!catalog?.more} onClick={()=>setCatalogPage(v=>v+1)}>{t('next')}</button></div>
    {cfg&&<><p>{locale==='de'?cfg.description_de:cfg.description_sl}</p>
     <p>{t('version')}: {cfg.version_number} · {t(cfg.native_behavior)} · {t('ack')}: {t(cfg.requires_acknowledgement?'yes':'no')}</p>
     <p>{t('recipients')}: {cfg.recipient_types.map(t).join(' · ')}<br/>{t('target')}: {cfg.target_types.map(t).join(' · ')}</p>
     <fieldset><legend>{t('recipients')} ({chosen.length}/100)</legend>
      {chosen.map(r=><p key={recipientKey(r)}>{r.name} · {t(r.type)} · {r.organization_name} · {rt(!cfg.recipient_types.includes(r.type)?'unsupported':r.eligibility==='ELIGIBLE'?'eligible':r.eligibility==='UNKNOWN'?'unknown':'unavailable')}
       <button type="button" onClick={()=>chooseRecipient(r,false)}>{rt('remove')}</button></p>)}
      {!chosen.length&&<p>{t('empty')}</p>}{invalidRecipients&&<p role="alert">{rt('resolveRecipients')}</p>}
      <button type="button" disabled={checking} onClick={()=>{setError('');setVerifyEpoch(v=>v+1);}}>{rt('checkRecipients')}</button>
     </fieldset>
     {cfg.target_types.some(k=>k!=='NONE')&&<div className="rts-target-controls">
      <label>{rt('mapTargetKind')}<select value={rts.mapTargetKind} onChange={e=>rts.setMapTargetKind(e.target.value as TaskTarget['kind'])}>
       {cfg.target_types.filter(k=>k!=='NONE').map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
      <button type="button" disabled={actionChanged} aria-pressed={rts.mode==='CHOOSE_TARGET'} onClick={()=>rts.requestMode('CHOOSE_TARGET')}>{rt('targetOnMap')}</button>
      {rts.mode!=='NORMAL'&&<button type="button" onClick={rts.cancelMode}>{rt('cancelMode')}</button>}
      <p>{rt('targetResolvedLater')}</p>
     </div>}
     <label>{t('target')}<select value={target.kind} onChange={e=>{const kind=e.target.value as TaskTarget['kind'];setLon('');setLat('');setTarget(kind==='NONE'?{kind}:kind==='COORDINATE'?{kind,coordinate:[NaN,NaN]}:kind==='HYDRANT'?{kind,entityId:''}:{kind,entityId:'',incidentId});}}>
      {!targetAllowed&&<option value={target.kind}>{t(target.kind)}</option>}{cfg.target_types.map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>
     {!targetAllowed&&<p role="alert">{t('targetMismatch')}</p>}
     {['MOVE_TO','WITHDRAW_TO'].includes(cfg.native_behavior)&&<p>{t('pointNotice')}</p>}
     {target.kind==='COORDINATE'&&<><label>{t('longitude')}<input required type="number" min={-180} max={180} step="any" value={lon} onChange={e=>{setLon(e.target.value);setTarget({kind:'COORDINATE',coordinate:[e.target.value.trim()===''?NaN:Number(e.target.value),lat.trim()===''?NaN:Number(lat)]});}}/></label><label>{t('latitude')}<input required type="number" min={-90} max={90} step="any" value={lat} onChange={e=>{setLat(e.target.value);setTarget({kind:'COORDINATE',coordinate:[lon.trim()===''?NaN:Number(lon),e.target.value.trim()===''?NaN:Number(e.target.value)]});}}/></label></>}
     {target.kind==='HYDRANT'&&<><label>{t('search')}<input maxLength={100} value={hydrantQuery} onChange={e=>setHydrantQuery(e.target.value)}/></label>
      <label>{t('HYDRANT')}<select required value={currentHydrantId} onChange={e=>setTarget({kind:'HYDRANT',entityId:e.target.value})}><option value="">{t('select')}</option>
       {currentHydrantId&&!hydrantOptions.some(h=>h.id===currentHydrantId)&&<option value={currentHydrantId}>{currentHydrantId}</option>}
       {hydrantOptions.map(h=><option key={h.id} value={h.id}>{h.code??h.id} · {h.address}</option>)}</select></label></>}
     {(target.kind==='INCIDENT_MAP_OBJECT'||target.kind==='INCIDENT_SECTOR')&&<label>{t(target.kind)}<select required value={target.entityId} onChange={e=>setTarget({...target,entityId:e.target.value})}>
      <option value="">{t('select')}</option>{target.kind==='INCIDENT_SECTOR'?cop?.sectors.map(s=><option key={s.id} value={s.id}>{s.name}</option>):
       cop?.objects.map(o=><option key={o.id} value={o.id}>{o.label} · {o.geometry.type}</option>)}</select></label>}
     <ParameterInputs locale={locale} definitions={cfg.parameter_definitions} value={parameters} onChange={setParameters}/>
     {Object.keys(parameters).filter(code=>!cfg.parameter_definitions.some(p=>p.code===code)).map(code=><p role="alert" key={code}>
      {t('INVALID_ACTION_PARAMETERS')} {code}: {String(parameters[code])} <button type="button" onClick={()=>{const next={...parameters};delete next[code];setParameters(next);}}>{t('remove')}</button>
     </p>)}
     <label>{t('priority')}<select value={priority} onChange={e=>setPriority(e.target.value)}>{incidentPriorities.map(p=><option key={p} value={p}>{t(p)}</option>)}</select></label>
     <label>{t('title')}<input maxLength={200} value={title} onChange={e=>setTitle(e.target.value)}/></label>
     <label>{t('notes')}<textarea maxLength={4000} value={notes} onChange={e=>setNotes(e.target.value)}/></label>
     <button disabled={!chosen.length||!targetAllowed||invalidRecipients||checking||actionChanged||readUnavailable||!catalog||!cop} type="submit">{t('review')}</button>
    </>}
   </fieldset></form>
   <button disabled={locked} onClick={()=>{formSession.current++;setOpen(false);rts.cancelMode();}}>{rt('closePalette')}</button>
  </section></WorkspaceSlot>}
  {taskId&&!open&&<WorkspaceSlot name="selectedPane"><section className="admin-card">
   {!detail?<p>{t('loading')}</p>:<><h3>{actionLabel(detail.configuration,locale)}</h3>
    <p>{t(detail.configuration.native_behavior)} · {t('version')} {detail.configuration.version_number}</p>
    <p><strong className="task-priority" data-priority={detail.priority}>{t('priority')}: {t(detail.priority)}</strong> · {t(detail.status)} {detail.outcome&&t(detail.outcome)}</p>
    <p>{detail.title}</p><p className="incident-prose">{detail.notes}</p><p>{t('issuer')}: {detail.issuer_name} · {detail.organization_name}</p><p>{t('issued')}: {new Date(detail.issued_at).toLocaleString(locale)}</p>
    <p>{t('target')}: {t(detail.target_type)} · {detail.target_label_snapshot??detail.target_entity_id??'—'}</p>
    {detail.target_geometry_snapshot&&<details><summary>{t('target')}</summary><pre style={{whiteSpace:'pre-wrap',overflowWrap:'anywhere'}}>{JSON.stringify(detail.target_geometry_snapshot)}</pre></details>}
    <dl>{detail.configuration.parameter_definitions.map(p=><div key={p.code}><dt>{parameterLabel(p,locale)}</dt><dd>{parameterValueLabel(p,detail.parameters[p.code],locale)}</dd></div>)}</dl>
    {stale&&<><p role="alert">{t('stale')}</p><button disabled={disabled} onClick={()=>{setStale(false);setError('');}}>{t('reedit')}</button></>}
    {detail.assignments.map(a=><article key={a.id} className="web-row"><strong>{a.recipient_name}</strong><p>{t(a.recipient_type)} · {t(a.status)}</p>
     {a.blocked_reason&&<p>{t('BLOCKED')}: {a.blocked_reason}</p>}{a.unable_reason&&<p>{t('UNABLE')}: {a.unable_reason}</p>}
     <small>{[a.acknowledged_at,a.started_at,a.blocked_at,a.completed_at,a.unable_at,a.cancelled_at].filter(Boolean).map(v=>new Date(v!).toLocaleString(locale)).join(' · ')}</small>
     {executionStates(a).some(s=>s==='BLOCKED'||s==='UNABLE')&&<label>{t('reason')}<textarea disabled={disabled||stale} maxLength={2000} value={reasons[a.id]??''} onChange={e=>setReasons({...reasons,[a.id]:e.target.value})}/></label>}
     <div className="actions">{executionStates(a).map(s=><button key={s} disabled={disabled||stale||(['BLOCKED','UNABLE'].includes(s)&&!(reasons[a.id]??'').trim())} onClick={()=>transition(a,s)}>{t(s)}</button>)}
      {a.can_cancel&&<button disabled={disabled||stale} onClick={()=>transition(a,'CANCELLED')}>{t('CANCELLED')}</button>}</div>
    </article>)}
    {detail.can_cancel&&<button disabled={disabled||stale} onClick={()=>command('cancel_task',{id:detail.id},detail.version,
     actionLabel(detail.configuration,locale)+'\n'+detail.assignments.map(a=>a.recipient_name+': '+t(a.status)).join('\n'))}>{t('cancel_task')}</button>}
   </>}
  </section></WorkspaceSlot>}
 </>;
}
