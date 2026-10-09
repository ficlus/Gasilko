import {isUuid} from '../../../lib/operational/entity';
import {NextResponse} from 'next/server';
import {serverClient} from '../../../lib/supabase/server';
import {loadAccount} from '../../../lib/auth/load';

/** Bounded adapter over the registry's existing SELECT/RLS contract.
 * No incident argument, incident privilege, service credential or shared cache. */
export async function POST(request:Request){
 const headers={'Cache-Control':'no-store'};
 if(request.headers.get('origin')!==new URL(request.url).origin)return NextResponse.json({error:'NOT_AUTHORIZED'},{status:403,headers});
 const client=await serverClient(),account=await loadAccount(client);
 if(!client||account.state!=='ACTIVE')return NextResponse.json({error:'NOT_AUTHORIZED'},{status:403,headers});
 const {data:{user},error:authError}=await client.auth.getUser();
 if(authError||!user||request.headers.get('X-Gasilko-Account')!==user.id)return NextResponse.json({error:'EXPIRED'},{status:403,headers});
 try{
  const text=await request.text();if(text.length>512)return NextResponse.json({error:'INVALID_QUERY'},{status:400,headers});
  const {bounds,id}=JSON.parse(text) as {bounds:unknown;id:unknown};
  if(id!==undefined){
   if(!isUuid(id))return NextResponse.json({error:'INVALID_QUERY'},{status:400,headers});
   const {data,error}=await client.from('hydrants').select('id,organization_id,code,status,latitude,longitude,address,location_description,organization:organizations(name),type:hydrant_types(code,name,names,organization_id)').eq('id',id).maybeSingle().abortSignal(request.signal);
   if(error)return NextResponse.json({error:'UNAVAILABLE'},{status:503,headers});
   return NextResponse.json({hydrant:data},{headers});
  }
  if(!Array.isArray(bounds)||bounds.length!==4||!bounds.every(n=>typeof n==='number'&&Number.isFinite(n))
   ||bounds[0]<-180||bounds[2]>180||bounds[1]<-90||bounds[3]>90||bounds[0]>bounds[2]||bounds[1]>bounds[3])
   return NextResponse.json({error:'INVALID_QUERY'},{status:400,headers});
  // Ordinary member, exact manager and hierarchical web scopes are all enforced
  // by the same hydrants policies used outside incidents. Related DTOs also use RLS.
  const {data,error}=await client.from('hydrants')
   .select('id,organization_id,code,status,latitude,longitude,address,location_description,organization:organizations(name),type:hydrant_types(code,name,names,organization_id)')
   .eq('active',true).gte('longitude',bounds[0]).lte('longitude',bounds[2])
   .gte('latitude',bounds[1]).lte('latitude',bounds[3]).order('id').limit(501).abortSignal(request.signal);
  if(error)return NextResponse.json({error:'UNAVAILABLE'},{status:503,headers});
  return NextResponse.json({rows:(data??[]).slice(0,500),more:(data?.length??0)>500},{headers});
 }catch{return NextResponse.json({error:'UNAVAILABLE'},{status:503,headers});}
}
