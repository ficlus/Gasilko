export const fields=['uuid','code','organization','type','status','latitude','longitude','address','location_description','notes','inspection_interval_months','active'] as const;
export const statuses=['WORKING','NOT_WORKING','NEEDS_INSPECTION','UNKNOWN'];
export type Field=typeof fields[number];
export type Cell=string|number|boolean;
export type Mapping={columns:Partial<Record<Field,number>>;statuses:Record<string,string>;types:Record<string,string>;decimal:'auto'|'point'|'comma';clear:boolean};
export type InputRow={row:number;organization:string;uuid?:string;code?:string;type?:string;data:Record<string,Cell|null>;error?:string;blank?:boolean;expected_version?:number;selected?:boolean;accept_warnings?:boolean};
export type Preview={row:number;action:string;organization_id?:string;id?:string;code?:string;version?:number;before?:Record<string,Cell|null>;after?:Record<string,Cell|null>;warnings?:string[];error?:string;latitude?:number;longitude?:number};
export type Context={organizations:{id:string;code:string;name:string;writable:boolean}[];types:{id:string;code:string;name:string;active:boolean;organization_id:string|null}[]};
export type Profile={id:string;organization_id:string;name:string;active:boolean;version:number;configuration:Mapping};
const aliases:Record<Field,string[]>={uuid:['uuid','hydrant_uuid','hydrant_id'],code:['hydrant_code','oznaka_hidranta','hydrantencode'],organization:['organization_code','organization_id','organizacija','organizacija_koda','organisation'],type:['type_code','hydrant_type','hydrant_type_id','tip','hydrantentyp'],status:['status','stanje','zustand'],latitude:['latitude','lat','sirina','geografska_sirina','breitengrad'],longitude:['longitude','lon','lng','dolzina','geografska_dolzina','langengrad'],address:['address','naslov','adresse'],location_description:['location_description','opis_lokacije','standortbeschreibung'],notes:['notes','opombe','notizen'],inspection_interval_months:['inspection_interval_months','interval_pregleda','prufintervall'],active:['active','aktiven','aktiv']};
export function autoMapping(headers:Cell[]):Mapping{
 const columns:Mapping['columns']={};const normalized=headers.map(h=>String(h).normalize('NFD').replace(/[\u0300-\u036f]/g,'').trim().toLowerCase().replace(/[\s-]+/g,'_'));
 for(const field of fields){const hits=normalized.flatMap((h,i)=>aliases[field].includes(h)?[i]:[]);if(hits.length===1)columns[field]=hits[0];}
 return {columns,statuses:{},types:{},decimal:'auto',clear:false};
}
function decimal(v:Cell,mode:Mapping['decimal']){
 if(typeof v==='number'){if(!Number.isFinite(v))throw Error('INVALID_NUMBER');return v;}
 const s=String(v).trim();if(!/^[+-]?\d+(?:[.,]\d+)?$/.test(s))throw Error('INVALID_NUMBER');
 if(mode==='point'&&s.includes(',')||mode==='comma'&&s.includes('.')||mode==='auto'&&/^[+-]?\d{1,3}[.,]\d{3}$/.test(s))throw Error('AMBIGUOUS_NUMBER');
 const n=Number(s.replace(',','.'));if(!Number.isFinite(n))throw Error('INVALID_NUMBER');return n;
}
export function normalize(rows:Cell[][],mapping:Mapping,organization:string):InputRow[]{
 if(!Array.isArray(rows)||rows.length<2)throw Error('INVALID_FILE');
 if(rows.length>10001||new Set(Object.values(mapping.columns)).size!==Object.values(mapping.columns).length)throw Error('INVALID_MAPPING');
 const result=rows.slice(1).map((cells,index):InputRow=>{
  const r:InputRow={row:index+2,organization,data:{}};if(cells.every(v=>String(v).trim()===''))return {...r,blank:true};
  try{for(const f of fields){const col=mapping.columns[f];if(col===undefined)continue;if(!Number.isInteger(col)||col<0||col>=64)throw Error('INVALID_MAPPING');
   const raw=cells[col]??'',s=String(raw).trim();if(s.length>4096)throw Error('LIMIT_EXCEEDED');
   if(!s){if(mapping.clear&&['address','location_description','notes','inspection_interval_months','latitude','longitude'].includes(f))r.data[f]=null;continue;}
   if(f==='organization')r.organization=s;
   else if(f==='uuid'||f==='code')r[f]=f==='uuid'?s.toLowerCase():s;
   else if(f==='type')r.type=mapping.types[s]||s;
   else if(f==='status'){const v=mapping.statuses[s]||s;if(!statuses.includes(v))throw Error('INVALID_STATUS');r.data.status=v;}
   else if(f==='latitude'||f==='longitude'||f==='inspection_interval_months'){
    const n=decimal(raw,mapping.decimal);if(f==='inspection_interval_months'&&(!Number.isInteger(n)||n<=0)||f!=='inspection_interval_months'&&Math.abs(n*1e6-Math.round(n*1e6))>0.000001)throw Error('INVALID_NUMBER');r.data[f]=n;
   }else if(f==='active'){if(!['true','false','1','0'].includes(s.toLowerCase()))throw Error('INVALID_FIELDS');r.data.active=['true','1'].includes(s.toLowerCase());}
   else r.data[f]=s;
  }}catch(e){r.error=e instanceof Error?e.message:'INVALID_FIELDS';}return r;
 });
 const identities=new Map<string,InputRow[]>();for(const row of result)for(const key of [row.uuid?'uuid:'+row.uuid:'',row.code?'code:'+row.organization+':'+row.code:''])if(key)identities.set(key,[...(identities.get(key)??[]),row]);
 for(const group of identities.values())if(group.length>1)for(const row of group)row.error='DUPLICATE_IDENTITY';return result;
}
export function neutralize(value:unknown):string{
 const s=value==null?'':String(value);return typeof value==='string'&&/^[\s\u0000-\u001f]*[=+@-]/.test(s)?"'"+s:s;
}
export function csv(rows:unknown[][]):string{return '\uFEFF'+rows.map(row=>row.map(v=>'"'+neutralize(v).replaceAll('"','""')+'"').join(';')).join('\r\n');}
