'use client';
import dynamic from 'next/dynamic';
import {useEffect,useRef,useState,type FormEvent} from 'react';
import type {Locale} from '../../lib/i18n';
import {incidentText} from '../../lib/incidents/messages';
import {mapKinds,type Cop,type CopFeedback,type Geometry,type Position,type MapKind} from '../../lib/incidents/cop';
import type {CommandAction} from './CommandSection';
import type {CopLayers} from './CopMap';
import {isUuid} from '../../lib/operational/entity';
import type {ContextHydrant} from '../../lib/hydrants/viewport';
import {useWorkspace,WorkspaceSlot,WorkspaceSection,ContextActions} from './workspace';
import {HydrantDetailsAction} from './HydrantDetailsAction';
import {useHydrantContext} from './useHydrantContext';
import type {ViewportBounds} from '../map/OperationalMapCanvas';
const CopMap=dynamic(()=>import('./CopMap'),{ssr:false});
type Read=<T>(name:string,args:Record<string,unknown>,signal?:AbortSignal,account?:string)=>Promise<T>;
type Draft={type:'sector'|'object';id:string;version:string;incidentVersion:string;code:string;label:string;description:string;kind:MapKind;sector:string;geometry:Geometry|null};
type Candidate={id:string;code:string|null;address:string|null;status:string};
export function IncidentCop({locale,account,org,incidentId,refresh,feedback,disabled,read,onAction}:{locale:Locale;account:string;org:string;incidentId:string;refresh:number;feedback:CopFeedback;disabled:boolean;read:Read;onAction:CommandAction}){
 const workspace=useWorkspace();
 const t=incidentText(locale),[cop,setCop]=useState<Cop|null>(null),[loading,setLoading]=useState(false),[error,setError]=useState('');
 const [epoch,setEpoch]=useState(0),[localSelected,setLocalSelected]=useState(''),[draft,setDraft]=useState<Draft|null>(null),[stale,setStale]=useState(false);
 const [drawing,setDrawing]=useState<Geometry['type']|null>(null),[vertices,setVertices]=useState<Position[]>([]);
 const [layers,setLayers]=useState<CopLayers>({sectors:true,markers:true,zones:true,hydrants:true});
 const [query,setQuery]=useState(''),[candidates,setCandidates]=useState<Candidate[]>([]),[candidate,setCandidate]=useState(''),[purpose,setPurpose]=useState('WATER_SUPPLY');
 const [finding,setFinding]=useState(false),[coordinateText,setCoordinateText]=useState('');
 const searchController=useRef<AbortController|null>(null),seenFeedback=useRef(feedback.sequence);
 const readController=useRef<AbortController|null>(null);
 const [linkId,setLinkId]=useState('');

 const [bounds,setBounds]=useState<ViewportBounds|null>(null),[background,setBackground]=useState(true);
 const context=useHydrantContext(account,bounds,background&&!!cop,refresh+epoch);
 const selected=workspace?(workspace.selected&&['INCIDENT_SECTOR','MAP_OBJECT','HYDRANT'].includes(workspace.selected.kind)?workspace.selected.id:''):localSelected;
 function setSelected(id:string){
  setLinkId('');
  if(!workspace){setLocalSelected(id);return;}
  if(!id){workspace.select(null);return;}
  workspace.select({kind:cop?.sectors.some(s=>s.id===id)?'INCIDENT_SECTOR':cop?.objects.some(o=>o.id===id)?'MAP_OBJECT':'HYDRANT',id});
 }
 useEffect(()=>{
  const ac=new AbortController();readController.current=ac;setLoading(true);setError('');
  read<Cop>('incident_cop',{p_incident_id:incidentId,p_acting_organization_id:org},ac.signal,account)
   .then(value=>{if(!ac.signal.aborted)setCop(value);})
   .catch(e=>{if(!ac.signal.aborted){setCop(null);setError('unavailable');if(e instanceof Error&&['NOT_AUTHORIZED','EXPIRED'].includes(e.message)){searchController.current?.abort();setDraft(null);setVertices([]);setCandidates([]);setSelected('');setDrawing(null);}}})
   .finally(()=>{if(!ac.signal.aborted)setLoading(false);});
  return()=>ac.abort();
 },[incidentId,org,account,refresh,epoch,read]);
 useEffect(()=>{
  if(feedback.sequence===seenFeedback.current)return;seenFeedback.current=feedback.sequence;
  if(feedback.kind==='saved'){setDraft(null);setDrawing(null);setVertices([]);setStale(false);setCandidate('');setLinkId('');setCandidates([]);}
  else if(feedback.kind==='stale'){setStale(true);setEpoch(n=>n+1);}
  else {readController.current?.abort();searchController.current?.abort();setCop(null);setDraft(null);setCandidates([]);setDrawing(null);setVertices([]);setLoading(false);setFinding(false);}
 },[feedback]);
 useEffect(()=>()=>searchController.current?.abort(),[]);
 const locked=disabled||loading,actionLocked=locked||!!draft;
 function begin(type:'sector'|'object',id?:string){
  if(!cop)return;const s=cop.sectors.find(x=>x.id===id),o=cop.objects.find(x=>x.id===id);
  const value:Draft={type,id:id??crypto.randomUUID(),version:s?.version??o?.version??'0',incidentVersion:cop.incident.version,code:s?.code??'',
   label:s?.name??o?.label??'',description:o?.description??'',kind:o?.kind??'NOTE',sector:o?.sector_id??(cop.can_manage?'':cop.sectors.find(x=>x.can_edit)?.id??''),geometry:s?.geometry??o?.geometry??null};
  setDraft(value);setCoordinateText(value.geometry?JSON.stringify(value.geometry):'');setStale(false);setDrawing(null);setVertices([]);
 }
 function geometry(value:Geometry|null){setDraft(d=>d?{...d,geometry:value}:d);setCoordinateText(value?JSON.stringify(value):'');}
 function point(value:Position){
  if(!draft||!drawing||locked)return;
  if(drawing==='Point'){geometry({type:'Point',coordinates:value});setDrawing(null);setVertices([]);}
  else if(vertices.length<(drawing==='Polygon'?1999:2000))setVertices(v=>[...v,value]);else setError('GEOMETRY_TOO_LARGE');
 }
 function finish(){
  if(drawing==='LineString'&&vertices.length>=2)geometry({type:'LineString',coordinates:vertices});
  else if(drawing==='Polygon'&&vertices.length>=3)geometry({type:'Polygon',coordinates:[[...vertices,vertices[0]]]});
  else {setError('INVALID_GEOMETRY');return;}
  setDrawing(null);setVertices([]);
 }
 const current=draft?.type==='sector'?cop?.sectors.find(s=>s.id===draft.id):cop?.objects.find(o=>o.id===draft?.id);
 const canSave=!!cop&&!!draft&&(draft.version==='0'?(draft.type==='sector'?cop.can_manage:cop.can_manage||cop.sectors.some(s=>s.id===draft.sector&&s.can_edit)):!!current?.can_edit);
 function save(e:FormEvent){
  e.preventDefault();if(!draft||!cop||stale||drawing||!canSave)return;
  if(draft.type==='sector'&&!/^[A-Z0-9][A-Z0-9_-]{0,63}$/.test(draft.code)){setError('workspaceSectorCode');return;}
  let g:Geometry|null=null;
  try{g=coordinateText.trim()?JSON.parse(coordinateText):null;if(g&&(!['Point','LineString','Polygon'].includes(g.type)||!Array.isArray(g.coordinates)))throw Error();}catch{setError('INVALID_GEOMETRY');return;}
  if(!g&&draft.type==='object'){setError('INVALID_GEOMETRY');return;}
  const payload=draft.type==='sector'?{id:draft.id,...(draft.version==='0'?{code:draft.code}:{version:draft.version}),name:draft.label,geometry:g}:
   {id:draft.id,version:draft.version,kind:draft.kind,label:draft.label,description:draft.description,geometry:g,sector_id:draft.sector||null};
  onAction(draft.type==='sector'?(draft.version==='0'?'sector_create':'sector_update'):'object_put',payload,
   {id:draft.id,incident_id:incidentId,organization_id:org,version:draft.incidentVersion,title:'',reference_number:''},draft.label);
 }
 function deactivate(type:'sector'|'object'|'link',id:string,version:string,label:string){
  if(!cop)return;onAction(type==='sector'?'sector_deactivate':type==='object'?'object_deactivate':'hydrant_unlink',{id,version},
   {id,incident_id:incidentId,organization_id:org,version:cop.incident.version,title:'',reference_number:''},label);
 }
 async function search(e:FormEvent){
  e.preventDefault();searchController.current?.abort();const ac=new AbortController();searchController.current=ac;setFinding(true);setCandidates([]);setCandidate('');setError('');
  try{const rows=await read<Candidate[]>('incident_cop_hydrants',{p_incident_id:incidentId,p_acting_organization_id:org,p_query:query},ac.signal,account);if(!ac.signal.aborted)setCandidates(rows);}
  catch{if(!ac.signal.aborted)setError('unavailable');}finally{if(!ac.signal.aborted)setFinding(false);}
 }
 function link(hydrantId=candidate,linkPurpose=purpose){
  if(!cop||!hydrantId)return;const id=linkId||crypto.randomUUID();setLinkId(id);
  onAction('hydrant_link',{id,hydrant_id:hydrantId,purpose:linkPurpose},{id,incident_id:incidentId,organization_id:org,version:cop.incident.version,title:'',reference_number:''},
   (candidates.find(c=>c.id===hydrantId)?.code??context.rows.find(c=>c.id===hydrantId)?.code??(targetHydrant?.id===hydrantId?targetHydrant.code:null)??t('copPendingCode'))+' · '+t(linkPurpose));
 }
 const kind=workspace?.selected?.kind;
 const selection=(!workspace||kind==='INCIDENT_SECTOR'?cop?.sectors.find(s=>s.id===selected):undefined)
  ??(!workspace||kind==='MAP_OBJECT'?cop?.objects.find(o=>o.id===selected):undefined)
  ??(!workspace||kind==='HYDRANT'?cop?.links.find(l=>l.id===selected||l.hydrant?.id===selected):undefined);
 const backgroundHydrant=(!workspace||kind==='HYDRANT')?context.rows.find(h=>h.id===selected):undefined;
 const [targetHydrant,setTargetHydrant]=useState<(Omit<ContextHydrant,'latitude'|'longitude'>&{latitude:number|null;longitude:number|null})|null>(null);
 useEffect(()=>{
  setTargetHydrant(null);if(!cop||!workspace||workspace.selected?.kind!=='HYDRANT'||!isUuid(selected))return;
  const ac=new AbortController();
  void fetch('/api/hydrant-context',{method:'POST',headers:{'Content-Type':'application/json','X-Gasilko-Account':account},body:JSON.stringify({id:selected}),signal:ac.signal,cache:'no-store'})
   .then(async r=>{if(!r.ok)throw Error();return r.json();}).then(r=>{if(!ac.signal.aborted)setTargetHydrant(r.hydrant??null);})
   .catch(()=>{if(!ac.signal.aborted)setTargetHydrant(null);});
  return()=>ac.abort();
 },[account,org,incidentId,selected,workspace?.selected?.kind,!!cop,refresh,epoch]);
 const resolvedHydrant=kind==='HYDRANT'&&targetHydrant?.id===selected?targetHydrant:null;
 const mapHydrants=resolvedHydrant&&resolvedHydrant.longitude!==null&&resolvedHydrant.latitude!==null&&!context.rows.some(h=>h.id===resolvedHydrant.id)?[...context.rows,{...resolvedHydrant,latitude:resolvedHydrant.latitude,longitude:resolvedHydrant.longitude}]:context.rows;
 const linked=(!workspace||kind==='HYDRANT')?cop?.links.find(l=>l.hydrant?.id===selected):undefined;
 const shownHydrant=backgroundHydrant??linked?.hydrant??resolvedHydrant;
 return <section className="admin-card cop-surface"><h2>{t('copTitle')}</h2><p>{t('copAuthority')}</p>
  <button disabled={locked} onClick={()=>setEpoch(n=>n+1)}>{t('refresh')}</button>
  {loading&&<p role="status">{t('loading')}</p>}{error&&<p role="alert">{t(error)}</p>}
  {cop&&<>
   <p>{t('status')}: {t(cop.incident.status)} · {t('copRevision')}: {cop.incident.revision}</p>
   <div className="actions">{(Object.keys(layers) as (keyof CopLayers)[]).map(k=><label key={k}><input type="checkbox" checked={layers[k]} onChange={e=>setLayers(v=>({...v,[k]:e.target.checked}))}/>{t('copLayer_'+k)}</label>)}</div>
   <label><input type="checkbox" checked={background} onChange={e=>setBackground(e.target.checked)}/>{t('workspaceHydrants')}</label>
   <p className="workspace-map-legend">{t('workspaceMarkerLegend')}</p>
   {context.loading&&<p role="status">{t('loading')}</p>}{context.error&&<p role="alert">{t('workspaceHydrantError')}</p>}{context.more&&<p role="status">{t('workspaceHydrantLimit')}</p>}
   <CopMap selected={selection||shownHydrant||selected==='primary'?selected:''} contextHydrants={mapHydrants} onBounds={setBounds} locale={locale} cop={cop} layers={layers} drawing={locked?null:drawing} draft={draft?.geometry??null} vertices={vertices} onPoint={point} onSelect={setSelected}/>
   {selected==='primary'&&<p>{t('copLocation')}: {cop.incident.latitude}, {cop.incident.longitude}</p>}
   <WorkspaceSlot name="selectedPane">
   {selected==='primary'&&<p>{t('copLocation')}: {cop.incident.latitude}, {cop.incident.longitude}</p>}
   {selected&&selected!=='primary'&&!selection&&!shownHydrant&&<p>{t('copMissing')}</p>}
   {selection&&!shownHydrant&&<aside className="admin-notice" aria-live="polite"><h3>{t('copSelected')}</h3>
    {'code'in selection?<p>{selection.code} · {selection.name}</p>:'label'in selection?<div><p>{t(selection.kind)} · {selection.label} · {selection.description}</p><p>{selection.sector_name??t('copIncidentWide')}</p></div>:
     <div><p>{selection.hydrant?.code??t(selection.hydrant?'copPendingCode':'copHiddenHydrant')} · {t(selection.purpose)}</p><p>{selection.hydrant?t(selection.hydrant.status):''}</p><p>{selection.hydrant?.address||selection.hydrant?.location_description}</p></div>}
    <p>{t('copVersion')}: {selection.version}</p>
    {'can_edit'in selection&&selection.can_edit&&<button disabled={actionLocked} onClick={()=>begin('code'in selection?'sector':'object',selection.id)}>{t('copEdit')}</button>}
   </aside>}
   {shownHydrant&&<section className="admin-notice">
    <h3>{shownHydrant.code??t('copPendingCode')}</h3><p>{t(shownHydrant.status)}</p>
    <small>{shownHydrant.id}</small><p>{shownHydrant.address||shownHydrant.location_description}</p>
    <p>{backgroundHydrant?.organization?.name??shownHydrant.organization_id}</p>
    {backgroundHydrant?.type&&<p>{backgroundHydrant.type.names?.[locale]??backgroundHydrant.type.name}</p>}
    <p>{linked?t(linked.purpose):t('workspaceNotLinked')}</p>
    <HydrantDetailsAction key={shownHydrant.id} locale={locale} account={account} id={shownHydrant.id} organization={shownHydrant.organization_id}/>
    <ContextActions actions={[
     ...(!linked&&cop.can_manage?(['WATER_SUPPLY','REFERENCE'] as const).map(p=>({id:'link-'+p,label:t('hydrant_link')+' · '+t(p),enabled:!actionLocked,requiresConfirmation:true,execute:()=>link(shownHydrant.id,p)})):[]),
     ...(linked?.can_unlink?[{id:'unlink',label:t('hydrant_unlink'),enabled:!actionLocked,requiresConfirmation:true,
      execute:()=>deactivate('link',linked.id,linked.version,shownHydrant.code??t('copPendingCode'))}]:[])
    ]}/>
   </section>}
   </WorkspaceSlot>
   {stale&&<section className="admin-notice" role="alert"><h3>{t('copStale')}</h3><p>{t('copStaleHelp')}</p>
    {draft&&<><h4>{t('copLocal')}</h4><pre style={{whiteSpace:'pre-wrap',overflowWrap:'anywhere',maxHeight:220,overflow:'auto'}}>{coordinateText||'—'}</pre>
     <h4>{t('copServer')}</h4><pre style={{whiteSpace:'pre-wrap',overflowWrap:'anywhere',maxHeight:220,overflow:'auto'}}>{current?JSON.stringify(current,null,2):t('copMissing')}</pre>
     {(current||draft.version==='0')&&<button disabled={locked||!canSave} onClick={()=>{setDraft({...draft,version:current?.version??'0',incidentVersion:cop.incident.version});setStale(false);}}>{t('copReedit')}</button>}</>}
   </section>}
   {draft&&<form onSubmit={save} className="incident-form"><fieldset disabled={locked}>
    <legend>{t(draft.type==='sector'?'copSector':'copObject')}</legend>
    {draft.type==='sector'?<label>{t('copCode')}<input required pattern={'[A-Z0-9][A-Z0-9_\\-]{0,63}'} maxLength={64} disabled={draft.version!=='0'} value={draft.code} onChange={e=>{
     const input=e.currentTarget,pos=input.selectionStart??input.value.length;
     const clean=(value:string)=>value.replace(/[a-z]/g,ch=>ch.toUpperCase()).replace(/[^A-Z0-9_-]/g,'').slice(0,64);
     const caret=clean(input.value.slice(0,pos)).length,code=clean(input.value);
     input.setCustomValidity('');setDraft({...draft,code});requestAnimationFrame(()=>input.setSelectionRange(caret,caret));
    }} onInvalid={e=>e.currentTarget.setCustomValidity(t('workspaceSectorCode'))}/></label>:
     <label>{t('type')}<select value={draft.kind} disabled={draft.version!=='0'} onChange={e=>{setDraft({...draft,kind:e.target.value as MapKind,geometry:null});setCoordinateText('');setDrawing(null);setVertices([]);}}>{mapKinds.map(k=><option key={k} value={k}>{t(k)}</option>)}</select></label>}
    <label>{t('copLabel')}<input required maxLength={200} value={draft.label} onChange={e=>setDraft({...draft,label:e.target.value})}/></label>
    {draft.type==='object'&&<><label>{t('copDescription')}<textarea maxLength={4000} value={draft.description} onChange={e=>setDraft({...draft,description:e.target.value})}/></label>
     <label>{t('copSector')}<select value={draft.sector} onChange={e=>setDraft({...draft,sector:e.target.value})}><option value="" disabled={!cop.can_manage}>{t('copIncidentWide')}</option>{cop.sectors.filter(s=>cop.can_manage||s.can_edit).map(s=><option key={s.id} value={s.id}>{s.code} · {s.name}</option>)}</select></label></>}
    <p>{t('copDrawHelp')}</p><div className="actions">
     {(draft.type==='sector'?['Polygon']:draft.kind==='HAZARD'?['Point','Polygon']:draft.kind==='PERIMETER'?['LineString','Polygon']:['Point']).map(k=><button type="button" key={k} onClick={()=>{setDrawing(k as Geometry['type']);setVertices([]);setError('');}}>{t('copDraw_'+k)}</button>)}
     {draft.type==='sector'&&<button type="button" onClick={()=>{geometry(null);setDrawing(null);setVertices([]);}}>{t('copNoGeometry')}</button>}
    </div>
    {drawing&&<div role="status"><p>{t('copDrawing')}: {t('copDraw_'+drawing)} · {vertices.length}</p><div className="actions">
     <button type="button" disabled={drawing==='Point'} onClick={finish}>{t('copFinish')}</button>
     <button type="button" onClick={()=>setVertices(v=>v.slice(0,-1))}>{t('copUndo')}</button>
     <button type="button" onClick={()=>{setDrawing(null);setVertices([]);}}>{t('copCancelDrawing')}</button></div></div>}
    <label>{t('copGeometry')}<textarea rows={4} value={coordinateText} onChange={e=>setCoordinateText(e.target.value)}/></label>
    <div className="actions"><button type="submit" disabled={stale||!!drawing||!canSave}>{t('save')}</button>
     <button type="button" onClick={()=>{setDraft(null);setDrawing(null);setVertices([]);setStale(false);}}>{t('dismiss')}</button></div>
   </fieldset></form>}
   <WorkspaceSlot name="operational"><WorkspaceSection title={t('copSectors')} open>
   <h3>{t('copSectors')}</h3>{cop.can_manage&&<button disabled={actionLocked} onClick={()=>begin('sector')}>{t('sector_create')}</button>}
   {cop.sectors.length===0&&<p>{t('copEmpty')}</p>}{cop.sectors.map(s=><article className="web-row" key={s.id}><strong>{s.code} · {s.name}</strong>
    <p>{t('SECTOR_COMMANDER')}: {s.commander??'—'} · {t('copVersion')}: {s.version}</p><div className="actions"><button onClick={()=>setSelected(s.id)}>{t('copSelect')}</button>
     {s.can_edit&&<button disabled={actionLocked} onClick={()=>begin('sector',s.id)}>{t('copEdit')}</button>}{s.can_deactivate&&<button disabled={actionLocked} onClick={()=>deactivate('sector',s.id,s.version,s.name)}>{t('sector_deactivate')}</button>}</div></article>)}
   </WorkspaceSection><WorkspaceSection title={t('copObjects')}>
   <h3>{t('copObjects')}</h3>{(cop.can_manage||cop.sectors.some(s=>s.can_edit))&&<button disabled={actionLocked} onClick={()=>begin('object')}>{t('copNewObject')}</button>}
   {cop.objects.length===0&&<p>{t('copEmpty')}</p>}{cop.objects.map(o=><article className="web-row" key={o.id}><strong>{t(o.kind)} · {o.label}</strong><p>{o.description}</p><p>{o.sector_name??t('copIncidentWide')} · {t('copVersion')}: {o.version}</p>
    <div className="actions"><button onClick={()=>setSelected(o.id)}>{t('copSelect')}</button>{o.can_edit&&<><button disabled={actionLocked} onClick={()=>begin('object',o.id)}>{t('copEdit')}</button><button disabled={actionLocked} onClick={()=>deactivate('object',o.id,o.version,o.label)}>{t('object_deactivate')}</button></>}</div></article>)}
   </WorkspaceSection><WorkspaceSection title={t('copHydrants')}>
   {background&&<label>{t('workspaceHydrants')}<select value={context.rows.some(h=>h.id===selected)?selected:''} onChange={e=>setSelected(e.target.value)}>
    <option value="">{t('select')}</option>{context.rows.map(h=><option key={h.id} value={h.id}>{h.code??t('copPendingCode')} · {t(h.status)} · {h.organization?.name??h.organization_id}</option>)}
   </select></label>}
   <h3>{t('copHydrants')}</h3>{cop.links.length===0&&<p>{t('copEmpty')}</p>}
   {cop.links.map(l=><article className="web-row" key={l.id}><strong>{l.hydrant?.code??t(l.hydrant?'copPendingCode':'copHiddenHydrant')}</strong><p>{t(l.purpose)} · {l.hydrant?t(l.hydrant.status):''}</p>
    <p>{l.hydrant?.address||l.hydrant?.location_description}</p><div className="actions"><button onClick={()=>setSelected(l.hydrant?.id??l.id)}>{t('copSelect')}</button>
     {l.can_unlink&&<button disabled={actionLocked} onClick={()=>deactivate('link',l.id,l.version,l.hydrant?.code??t('copHiddenHydrant'))}>{t('hydrant_unlink')}</button>}</div></article>)}
   {cop.can_manage&&<fieldset disabled={actionLocked}><legend>{t('hydrant_link')}</legend><p>{t('copHydrantSearch')}</p>
    <form onSubmit={search}><label>{t('search')}<input maxLength={100} value={query} onChange={e=>setQuery(e.target.value)}/></label><button disabled={finding}>{t('find')}</button></form>
    {finding&&<p>{t('loading')}</p>}<label>{t('select')}<select value={candidate} onChange={e=>{setCandidate(e.target.value);setLinkId('');}}><option value="">{t('select')}</option>{candidates.map(h=><option key={h.id} value={h.id}>{h.code??t('copPendingCode')} · {h.address}</option>)}</select></label>
    <label>{t('copPurpose')}<select value={purpose} onChange={e=>{setPurpose(e.target.value);setLinkId('');}}><option value="WATER_SUPPLY">{t('WATER_SUPPLY')}</option><option value="REFERENCE">{t('REFERENCE')}</option></select></label>
    <button disabled={!candidate} onClick={()=>link()}>{t('hydrant_link')}</button>
   </fieldset>}
   </WorkspaceSection></WorkspaceSlot>
  </>}
 </section>;
}
