'use client';
import {useRef,useState} from 'react';
import type {Locale} from '@/lib/i18n';
import {administrationRpc,deliver,errorText,stateLabel,str,type Row,type Scope} from '@/lib/administration/api';
import {administrationText} from '@/lib/administration/messages';
import {ConfigurationPicker} from './Controls';

type Props={locale:Locale;root:string|null;scope:Scope;action:string;initial?:Row;kind?:string;onSaved:()=>void;onCancel:()=>void};
type Values=Record<string,string|boolean|string[]>;
export function Editor({locale,root,scope,action,initial={},kind,onSaved,onCancel}:Props){
 const t=administrationText(locale),names=initial.names as Record<string,string>|undefined;
 const [values,setValues]=useState<Values>(()=>({name:str(initial,'name'),code:str(initial,'code'),email:str(initial,'email'),role:str(initial,'role')||'FIREFIGHTER',active:initial.active!==false,
  organization_id:action==='TYPE'&&initial.id&&initial.organization_id===null?'':str(initial,'organization_id')||root||'',organization_type_id:str(initial,'organization_type_id'),country_id:str(initial,'country_id'),
  parent_organization_id:str(initial,'parent_organization_id')||root||'',child_organization_id:str(initial,'child_organization_id'),relationship_type:str(initial,'relationship_type'),
  parent_type_id:str(initial,'parent_type_id'),child_type_id:str(initial,'child_type_id'),position_id:'',position_ids:[],
  sl:names?.sl??'',de:names?.de??'',display_order:str(initial,'display_order')||'0',inspection_interval_months:str(initial,'inspection_interval_months')||'12',
  default_language:str(initial,'default_language')||locale,valid_from:'',valid_to:'',message:'',reason:'',confirmed:false,
  legacy_type:str(initial,'legacy_type')||'FIRE_DEPARTMENT',classification:str(initial,'classification')||'ORGANIZATIONAL',suggested_role:str(initial,'suggested_role'),
  system_managed:initial.system_managed!==false,inherits_read:initial.inherits_read===true,hierarchical:initial.hierarchical===true,path_priority:str(initial,'path_priority')||'100'}));
 const [busy,setBusy]=useState(false),[locked,setLocked]=useState(false),[error,setError]=useState('');
 const pending=useRef<{organization:string|null;operation:string;action:string;request:Row}|null>(null),running=useRef(false);
 const change=(key:string,value:string|boolean|string[])=>setValues(v=>({...v,[key]:value}));
 const value=(key:string)=>String(values[key]??'');
 const input=(key:string,title:string,type='text',required=true,disabled=false)=><label>{title}<input type={type} required={required} disabled={disabled} value={value(key)} onChange={e=>change(key,e.target.value)} maxLength={type==='text'?254:undefined}/></label>;
 const check=(key:string,title:string)=><label className="administration-check"><input type="checkbox" checked={values[key]===true} onChange={e=>change(key,e.target.checked)}/>{title}</label>;
 const select=(key:string,title:string,options:[string,string][],required=true,disabled=false)=><label>{title}<select required={required} disabled={disabled} value={value(key)} onChange={e=>change(key,e.target.value)}>{!required&&<option value="">{t.global}</option>}{required&&<option value="">{t.choose}</option>}{options.map(([id,name])=><option key={id} value={id}>{name}</option>)}</select></label>;
 const roles:[string,string][]=['FIREFIGHTER','MANAGER','ADMIN'].map(r=>[r,stateLabel(r,locale)]);
 const picker=(key:string,config:string,title:string,multiple=false)=><div><strong>{title}</strong><ConfigurationPicker locale={locale} kind={config} multiple={multiple} value={multiple?values[key] as string[]:value(key)?[value(key)]:[]} onChange={ids=>change(key,multiple?ids:ids[0]??'')}/></div>;
 const dates=<>{input('valid_from',t.from,'datetime-local',false)}{input('valid_to',t.to,'datetime-local',false)}</>;
 const localized=<>{input('sl',t.slName)}{input('de',t.deName)}</>;
 const organizationSelect=select('organization_id',t.organization,scope.organizations.filter(o=>o.admin&&o.active).map(o=>[o.id,o.name]),action!=='TYPE'||!scope.operator,!!initial.organization_id);
 const creating=!initial.id&&!initial.code;
 function requestData():{organization:string|null;operation:string;action:string;request:Row}{
  const id=str(initial,'id')||crypto.randomUUID(),revision=initial.revision??null;
  const datesData={valid_from:value('valid_from')?new Date(value('valid_from')).toISOString():null,valid_to:value('valid_to')?new Date(value('valid_to')).toISOString():null};
  let request:Row={id,revision,reason:value('reason')},organization=value('organization_id')||null;
  if(action==='MEMBERSHIP')request={...request,user_id:initial.user_id??null,email:value('email'),role:value('role'),active:values.active};
  if(action==='POSITION')request={...request,user_id:initial.user_id,position_id:value('position_id'),...datesData};
  if(action==='ORGANIZATION'){organization=str(initial,'id');request={...request,name:value('name'),code:value('code'),organization_type_id:value('organization_type_id'),active:values.active,default_language:value('default_language'),inspection_interval_months:Number(value('inspection_interval_months'))};}
  if(action==='CHILD'){organization=root;request={...request,name:value('name'),code:value('code'),organization_type_id:value('organization_type_id'),default_language:value('default_language'),relationship_id:crypto.randomUUID(),relationship_type:value('relationship_type'),confirmed:values.confirmed};}
  if(action==='RELATIONSHIP'){organization=value('parent_organization_id');request={...request,parent_organization_id:organization,child_organization_id:value('child_organization_id'),relationship_type:value('relationship_type'),replacement_id:initial.id?crypto.randomUUID():null,active:values.active,confirmed:values.confirmed,...datesData};}
  if(action==='TYPE')request={...request,name:value('name'),code:value('code'),names:{...names,sl:value('sl'),de:value('de')},display_order:Number(value('display_order')),active:values.active};
  if(action==='INVITE')request={...request,email:value('email'),role:value('role'),position_ids:values.position_ids,message:value('message')};
  if(action==='CONFIGURATION'){
   organization=null;
   const data:Row={id,code:value('code'),names:{...names,sl:value('sl'),de:value('de')},active:values.active};
   if(kind==='countries')data.name=value('name');
   if(kind==='organization_types')Object.assign(data,{country_id:value('country_id')||null,legacy_type:value('legacy_type'),display_order:Number(value('display_order')),system_managed:values.system_managed});
   if(kind==='relationship_types')Object.assign(data,{inherits_read:values.inherits_read,hierarchical:values.hierarchical,path_priority:Number(value('path_priority'))});
   if(kind==='rules')Object.assign(data,{parent_type_id:value('parent_type_id'),child_type_id:value('child_type_id'),relationship_type:value('relationship_type')});
   if(kind==='positions')Object.assign(data,{country_id:value('country_id')||null,organization_type_id:value('organization_type_id')||null,classification:value('classification'),suggested_role:value('suggested_role')||null,system_managed:values.system_managed});
   request={...request,kind,data,confirmed:values.confirmed};
  }
  return {organization,action,request,operation:crypto.randomUUID()};
 }
 async function submit(){if(running.current)return;running.current=true;setBusy(true);setError('');try{
  pending.current??=requestData();setLocked(true);await administrationRpc('web_administration_write',pending.current);
  if(action==='INVITE')await deliver(String(pending.current.request.id),locale);
  onSaved();
 }catch(e){setError(errorText(e,locale));}finally{running.current=false;setBusy(false);}}
 return <section className="admin-card administration-editor"><h2>{action==='CHILD'?t.child:action==='POSITION'?t.assign:action==='INVITE'?t.invite:t.edit}</h2>
 <form onSubmit={e=>{e.preventDefault();void submit();}}><fieldset disabled={locked||busy}>
  {['MEMBERSHIP','INVITE','POSITION','TYPE'].includes(action)&&organizationSelect}
  {action==='MEMBERSHIP'&&<>{!initial.user_id&&input('email',t.email,'email')}{select('role',t.role,roles)}{check('active',t.active)}</>}
  {action==='INVITE'&&<><p>{t.inviteNotice}</p>{input('email',t.email,'email')}{select('role',t.role,roles)}{picker('position_ids','positions',t.positions,true)}{input('message',t.message,'text',false)}</>}
  {action==='POSITION'&&<><p>{t.positionNotice}</p>{picker('position_id','positions',t.position)}{dates}</>}
  {['ORGANIZATION','CHILD'].includes(action)&&<>{input('name',t.name)}{input('code',t.code)}{picker('organization_type_id','organization_types',t.orgType)}{select('default_language',t.language,[['sl',t.sl],['de',t.de]])}
   {action==='ORGANIZATION'?<>{input('inspection_interval_months',t.interval,'number')}{check('active',t.active)}</>:<><p>{t.bootstrap}</p>{root&&picker('relationship_type','relationship_types',t.relationship)}</>}
  </>}
  {action==='RELATIONSHIP'&&<>{picker('parent_organization_id','organization_targets',t.parent)}{picker('child_organization_id','organization_targets',t.childOrg)}{picker('relationship_type','relationship_types',t.relationship)}{dates}{check('active',t.active)}<p>{t.hierarchyWarning}</p></>}
  {action==='TYPE'&&<>{input('name',t.name)}{input('code',t.code,'text',true,!!initial.id)}{localized}{input('display_order',t.order,'number')}{check('active',t.active)}</>}
  {action==='CONFIGURATION'&&<><p>{t.immutable}</p>
   {kind!=='rules'&&input('code',t.code,'text',true,!creating)}{kind==='countries'?input('name',t.name):kind!=='rules'&&localized}
   {(kind==='organization_types'||kind==='positions')&&<fieldset disabled={!creating}>{picker('country_id','countries',t.country)}</fieldset>}
   {kind==='organization_types'&&<>{select('legacy_type',t.legacy,[['MUNICIPALITY',t.municipality],['FIRE_DEPARTMENT',t.fireDepartment],['WATER_UTILITY',t.waterUtility],['OTHER',t.other]],true,!creating)}{input('display_order',t.order,'number')}</>}
   {kind==='relationship_types'&&<>{check('inherits_read',t.inherits)}{check('hierarchical',t.hierarchical)}{input('path_priority',t.priority,'number')}</>}
   {kind==='rules'&&<fieldset disabled={!creating}>{picker('parent_type_id','organization_types',t.parent)}{picker('child_type_id','organization_types',t.childOrg)}{picker('relationship_type','relationship_types',t.relationship)}</fieldset>}
   {kind==='positions'&&<><fieldset disabled={!creating}>{picker('organization_type_id','organization_types',t.orgType)}</fieldset>{select('classification',t.classification,[['ORGANIZATIONAL',t.organizational],['OPERATIONAL',t.operational]])}{select('suggested_role',t.suggested,roles,false)}<p>{t.positionNotice}</p></>}
   {check('active',t.active)}{['organization_types','positions'].includes(kind??'')&&check('system_managed',t.managed)}<p role="note">{t.systemWarning}</p>
  </>}
  {input('reason',t.reason,'text',false)}
  {['CHILD','RELATIONSHIP','CONFIGURATION'].includes(action)&&<label className="administration-check"><input type="checkbox" required checked={values.confirmed===true} onChange={e=>change('confirmed',e.target.checked)}/>{t.confirm}</label>}
 </fieldset><div className="actions">{!locked&&<button disabled={busy} type="submit">{t.save}</button>}<button type="button" disabled={busy} onClick={onCancel}>{locked?t.reload:t.cancel}</button></div></form>
 {busy&&<p role="status">{t.loading}</p>}{error&&<div role="alert"><p>{error}</p><button disabled={busy} onClick={()=>void submit()}>{t.retry}</button></div>}
 </section>;
}
