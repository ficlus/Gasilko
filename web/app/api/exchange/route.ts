import {createHash} from 'node:crypto';
import {serverClient} from '@/lib/supabase/server';
import {boundedBody,spreadsheet,type Parsed} from '@/lib/exchange/server';
import {csv,normalize,type Cell,type Mapping,type Preview} from '@/lib/exchange/model';
import {exchangeText} from '@/lib/exchange/messages';
export const runtime='nodejs';
export const dynamic='force-dynamic';
export const maxDuration=60;
const uuid=/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
export async function POST(request:Request){
 try{
  if(request.headers.get('origin')!==new URL(request.url).origin)return Response.json({error:'NOT_AUTHORIZED'},{status:403});
  const client=await serverClient();if(!client||(await client.auth.getUser()).error)return Response.json({error:'NOT_AUTHORIZED'},{status:401});
  const url=new URL(request.url),root=url.searchParams.get('root')??'';if(!uuid.test(root))throw Error('INVALID_QUERY');
  const scope=await client.rpc('web_exchange_context',{root});if(scope.error)return Response.json({error:'NOT_AUTHORIZED'},{status:403});
  const rpc=async(name:string,args:Record<string,unknown>)=>{const r=await client.rpc(name,args);if(r.error)throw Error(r.error.code==='42501'?'NOT_AUTHORIZED':safeCode(r.error.message));return r.data;};
  const action=url.searchParams.get('action');
  if(action==='parse'){
   const format=url.searchParams.get('format');if(!['csv','xls','xlsx'].includes(format??''))throw Error('INVALID_FILE');
   const bytes=await boundedBody(request,10*1024*1024);const result=await spreadsheet<Parsed>({format,bytes:bytes.toString('base64'),sheet:url.searchParams.get('sheet'),delimiter:url.searchParams.get('delimiter')});
   if(Buffer.byteLength(JSON.stringify(result))>16*1024*1024)throw Error('LIMIT_EXCEEDED');
   return Response.json({...result,hash:createHash('sha256').update(bytes).digest('hex')},{headers:{'Cache-Control':'no-store'}});
  }
  const body=JSON.parse((await boundedBody(request,16*1024*1024)).toString('utf8'));
  if(action==='preview'){
   const inputs=normalize(body.rows as Cell[][],body.mapping as Mapping,body.organization);const previews:Preview[]=[];
   for(let i=0;i<inputs.length;i+=200)previews.push(...await rpc('web_import_preview',{root,rows:inputs.slice(i,i+200)}));
   const ids=new Map<string,Preview[]>();for(const p of previews)if(p.id)ids.set(p.id,[...(ids.get(p.id)??[]),p]);
   for(const group of ids.values())if(group.length>1)for(const p of group){p.action='ERROR';p.error='DUPLICATE_IDENTITY';}
   return Response.json({inputs,previews},{headers:{'Cache-Control':'no-store'}});
  }
  if(action==='confirm')return Response.json(await rpc('web_import_confirm',{root,operation:body.operation,manifest:body.manifest}));
  if(action==='apply')return Response.json(await rpc('web_import_apply',{root,operation:body.operation}));
  if(action==='history')return Response.json(await rpc('web_import_history',{root,operation:body.operation??null,page:body.page??0,state:body.state??''}));
  if(action==='profiles')return Response.json(await rpc('web_import_profiles',{root}));
  if(action==='profile'){
   if(!scope.data.organizations.some((o:{id:string;writable:boolean})=>o.id===body.organization&&o.writable))throw Error('NOT_AUTHORIZED');
   return Response.json(await rpc('web_import_profile_save',body));
  }
  if(action!=='download')throw Error('INVALID_QUERY');
  const locale=body.locale==='de'?'de':'sl',t=exchangeText(locale),format=body.format==='csv'?'csv':'xlsx';
  let sheets:{name:string;rows:unknown[][]}[]=[];let filename='gasilko';
  const metadata=[['Gasilko','M9'],[t.generated,new Date().toISOString()],[t.organization,root],[t.filters,JSON.stringify(body.filters??{})],[t.language,locale]];
  if(body.kind==='template'){
   filename+='-template';sheets=[{name:'Hydrants',rows:[['uuid','hydrant_code','organization_code','type_code','status','latitude','longitude','address','location_description','notes','inspection_interval_months','active']]},
    {name:'Reference',rows:[[t.organization,'UUID','code',t.name],...scope.data.organizations.filter((o:{writable:boolean})=>o.writable).map((o:{id:string;code:string;name:string})=>['organization',o.id,o.code,o.name]),
     ...scope.data.types.filter((v:{active:boolean;organization_id:string|null})=>v.active&&(!v.organization_id||scope.data.organizations.some((o:{id:string;writable:boolean})=>o.id===v.organization_id&&o.writable))).map((v:{id:string;code:string;name:string})=>['type',v.id,v.code,v.name]),
     ...['WORKING','NOT_WORKING','NEEDS_INSPECTION','UNKNOWN'].map(s=>['status','',s,t.codes[s]??s])]},
    {name:'Instructions',rows:[[t.instructions],[t.templateHelp],[t.blankHelp],[t.partialHelp],...metadata]}];
  }else if(body.kind==='results'){
   filename+='-results';const rows:unknown[][]=[[t.row,t.classification,t.error,t.code,t.version]];for(let page=0;page<100;page++){
    const batch=await rpc('web_import_history',{root,operation:body.operation,page,state:''});
    for(const r of batch)if(!body.errorsOnly||['ERROR','CONFLICT'].includes(r.result?.action))rows.push([r.row_number,t.codes[r.result?.action??'PENDING'],t.codes[r.result?.error]??r.result?.error??'',r.result?.code??'',r.result?.version??'']);if(batch.length<100)break;
   }sheets=[{name:'Results',rows}];
  }else{
   if(!['hydrants','inspections','teams','plans'].includes(body.kind))throw Error('INVALID_QUERY');filename+='-'+body.kind;
   const records:Record<string,unknown>[]=[];let after_id:string|null=null,bytes=0;
   while(true){const batch:Record<string,unknown>[]=await rpc('web_exchange_export',{root,kind:body.kind,filters:body.filters??{},after_id});bytes+=Buffer.byteLength(JSON.stringify(batch));
    if(records.length+batch.length>50000||bytes>24*1024*1024)throw Error('EXPORT_LIMIT');records.push(...batch);if(batch.length<500)break;after_id=String(batch.at(-1)!.uuid);
   }
   const current=await client.rpc('web_exchange_context',{root});if(current.error||records.some(r=>!current.data.organizations.some((o:{id:string})=>o.id===r.organization_id)))throw Error('NOT_AUTHORIZED');
   const columns=records.length?Object.keys(records[0]):['uuid'];sheets=[{name:body.kind,rows:[columns,...records.map(r=>columns.map(k=>r[k]??''))]},{name:'Metadata',rows:[...metadata,...['WORKING','NOT_WORKING','NEEDS_INSPECTION','UNKNOWN'].map(s=>[s,t.codes[s]]),...current.data.types.map((v:{code:string;name:string})=>[v.code,v.name])]}];
  }
  const output=format==='csv'?Buffer.from(csv(sheets[0].rows),'utf8'):Buffer.from((await spreadsheet<{bytes:string}>({action:'write',sheets})).bytes,'base64');
  // Recheck scope after potentially long parsing/export work before releasing bytes.
  const finalScope=await client.rpc('web_exchange_context',{root});
  if(finalScope.error||scope.data.organizations.some((old:{id:string;writable:boolean})=>!finalScope.data.organizations.some((now:{id:string;writable:boolean})=>now.id===old.id&&(!old.writable||now.writable))))throw Error('NOT_AUTHORIZED');
  return new Response(new Uint8Array(output),{headers:{'Content-Type':format==='csv'?'text/csv; charset=utf-8':'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','Content-Disposition':`attachment; filename="${filename}.${format}"`,'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
 }catch(e){return Response.json({error:safeCode(e instanceof Error?e.message:'INVALID_FILE')},{status:400,headers:{'Cache-Control':'no-store'}});}
}
function safeCode(message:string){return ['NOT_AUTHORIZED','INVALID_QUERY','INVALID_FILE','LIMIT_EXCEEDED','BUSY','DELIMITER_REQUIRED','ENCRYPTED_FILE','INVALID_CSV','FORMULA_VALUE_MISSING','INVALID_CELL','INVALID_MAPPING','INVALID_IMPORT','DUPLICATE_IDENTITY','OPERATION_REUSED','WARNINGS_REQUIRE_CONFIRMATION','EXPECTED_VERSION_REQUIRED','STALE_VERSION','INVALID_PROFILE','EXPORT_LIMIT'].includes(message)?message:'REQUEST_FAILED';}
