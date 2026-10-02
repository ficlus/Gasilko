import { browserClient } from '../supabase/browser';
import { apiError } from './service';
import { RegistryError, type Hydrant, type HydrantType } from './domain';
export type Row = Hydrant & { organization_name: string; type_name: string; type_code: string; type_organization_id: string|null;
 preview_path: string|null; last_inspection_at:string|null; next_due:string|null; due_state:'CURRENT'|'DUE_SOON'|'OVERDUE'|'NEVER_INSPECTED'; updated_at:string };
export type Scope = { organizations:{id:string;name:string;writable:boolean}[]; types:HydrantType[] };
export type Filters = { search:string; organization:string; status:string; type:string; active:string; due:string; hidden:string[] };
export const initialFilters:Filters = {search:'',organization:'',status:'',type:'',active:'active',due:'',hidden:[]};
export type Inspection = {id:string; mode:string; result:string; completed_at:string; performer:string|null; entered_by:string|null;
 performer_organization:string|null; source:string; corrects_inspection_id:string|null; pressure_bar:number|null; flow_l_min:number|null; notes:string|null; photo_count:number};
export type Detail = {hydrant:Row;writable:boolean;history:Inspection[];audit:{action:string;actor:string|null;created_at:string;old_data:Record<string,unknown>|null;new_data:Record<string,unknown>|null}[]};
export type Photo = {id:string;storage_path:string;mime_type:string;uploaded_at:string|null;captured_at?:string;created_at:string};
export async function rpc<T>(name:string,args:Record<string,unknown>):Promise<T> {
 const c=browserClient(); if(!c) throw new RegistryError('unavailable');
 const r=await c.rpc(name,args); if(r.error) throw apiError(r.error,r.status); return r.data as T;
}
export const organizationColor=(id:string)=>{
 const palette=['#00689d','#a64b00','#6b459c','#007c6a','#a52e65','#606500','#414f9c','#795548'];
 let hash=2166136261; for(const ch of id) hash=Math.imul(hash^ch.charCodeAt(0),16777619); return palette[(hash>>>0)%palette.length];
};
