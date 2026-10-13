import type {ActionDefinition} from './tasks';
import type {TargetPreview,RtsRecipient} from './rts';
export type ContextEntity={kind:'INCIDENT_UNIT'|'HYDRANT'|'MAP_OBJECT'|'INCIDENT_SECTOR';id:string};
export type MapCommandContext=
 | {kind:'COORDINATE';key:string;label:string;preview:TargetPreview}
 | {kind:'ENTITY';key:string;label:string;entity:ContextEntity;preview:TargetPreview}
 | {kind:'UNIT';key:string;label:string;entity:ContextEntity;recipient:RtsRecipient};
export type ContextCommand={action:ActionDefinition;preview:TargetPreview;reason:string|null};
/** Catalog configuration defines behavior. This is UX filtering, never an authority grant. */
export function contextCommands(context:MapCommandContext,actions:readonly ActionDefinition[],recipients:readonly RtsRecipient[],authorizedTypes:readonly string[]|null):ContextCommand[]{
 return actions.flatMap(action=>{
  const cfg=action.configuration;
  let preview:TargetPreview=context.kind==='UNIT'?{target:{kind:'NONE'},geometry:null,label:''}:context.preview;
  if(context.kind!=='UNIT'&&!cfg.target_types.includes(preview.target.kind)){
   // Point entities may back coordinate-only actions. Retain identity in the preview.
   // Never approximate a sector or line by a centroid.
   if(preview.geometry?.type!=='Point'||!cfg.target_types.includes('COORDINATE'))return [];
   preview={...preview,target:{kind:'COORDINATE',coordinate:[...preview.geometry.coordinates]}};
  }
  let reason:string|null=null;
  if(!action.active||!cfg.active_for_new_commands||!cfg.id)reason='disabledAction';
  else if(authorizedTypes===null)reason='checking';
  else if(!authorizedTypes.length)reason='noAuthority';
  else if(!recipients.length&&!cfg.recipient_types.some(type=>authorizedTypes.includes(type)))reason='noEligible';
  else if(context.kind!=='UNIT'&&!preview.geometry)reason='invalidTarget';
  else if(context.kind!=='UNIT'&&['MOVE_TO','WITHDRAW_TO'].includes(cfg.native_behavior)&&preview.geometry?.type!=='Point')reason='pointRequired';
  else if(recipients.length&&!recipients.some(r=>cfg.recipient_types.includes(r.type)&&r.eligibility!=='UNAVAILABLE'))reason='noEligible';
  return [{action,preview,reason}];
 }).sort((a,b)=>Number(b.action.configuration.native_behavior==='MOVE_TO')-Number(a.action.configuration.native_behavior==='MOVE_TO')||a.action.code.localeCompare(b.action.code)||a.action.id.localeCompare(b.action.id));
}
