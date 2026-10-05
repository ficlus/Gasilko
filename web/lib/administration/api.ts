import {browserClient} from '../supabase/browser';
import {administrationText} from './messages';
import type {Locale} from '../i18n';
export type Row=Record<string,unknown>;
export type Page={rows:Row[];more:boolean};
export type Scope={organizations:{id:string;name:string;active:boolean;admin:boolean}[];operator:boolean};
export const str=(row:Row,key:string)=>typeof row[key]==='string'?row[key] as string:row[key]==null?'':String(row[key]);
export const rows=(row:Row,key:string)=>Array.isArray(row[key])?row[key] as Row[]:[];
export function label(row:Row,locale:Locale){const names=row.names as Record<string,string>|undefined;return names?.[locale]||names?.en||str(row,'name')||str(row,'code')||str(row,'id');}
export class AdministrationError extends Error{}
export async function administrationRpc<T>(name:string,args:Record<string,unknown>):Promise<T>{
 const c=browserClient();if(!c)throw new AdministrationError('SERVER');
 const {data,error,status}=await c.rpc(name,args);
 if(error)throw new AdministrationError(status===401?'FORBIDDEN':error.code==='42501'?'FORBIDDEN':error.code==='40001'?'CONFLICT':/^22|^23/.test(error.code??'')?'VALIDATION':'SERVER');
 return data as T;
}
export async function deliver(invitation:string,locale:Locale){const response=await fetch('/api/organization-invite',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({invitation,locale})});if(!response.ok)throw new AdministrationError('DELIVERY');}
export function errorText(e:unknown,locale:Locale){const t=administrationText(locale);return e instanceof AdministrationError?({FORBIDDEN:t.forbidden,CONFLICT:t.conflict,VALIDATION:t.validation,DELIVERY:t.delivery} as Record<string,string>)[e.message]??t.error:t.error;}
export function stateLabel(value:string,locale:Locale){const t=administrationText(locale);return ({FIREFIGHTER:t.firefighter,MANAGER:t.manager,ADMIN:t.admin,ACTIVE:t.active,PENDING_APPROVAL:t.pendingAccount,SUSPENDED:t.suspended,REJECTED:t.rejected,PENDING:t.pending,ACCEPTED:t.accepted,REVOKED:t.revoked,EXPIRED:t.expired,APPROVED:t.approved} as Record<string,string>)[value]??value;}
