import {NextResponse,type NextRequest} from 'next/server';
import {serverClient} from '@/lib/supabase/server';
import {geocode} from '@/lib/geocoding/provider';
// Optional provider-neutral HTTP adapter contract. Deployment supplies a trusted
// HTTPS adapter endpoint; request parameters cannot select a URL or credential.
export async function GET(request:NextRequest){
 const client=await serverClient(),q=request.nextUrl.searchParams;
 if(!client)return new NextResponse(null,{status:503});
 const {data:user}=await client.auth.getUser();if(!user.user)return new NextResponse(null,{status:401});
 const {data,error}=await client.rpc('web_admin_context',{organization:q.get('organization')});
 const org=data?.organizations?.find((o:{id:string;access:string})=>o.id===data.selected);
 if(error||!org||org.access==='READ_ONLY')return new NextResponse(null,{status:403});
 try{
 const lat=q.get('lat'),lon=q.get('lon'),search=q.get('q');
 if(search){if(search.length>200)return new NextResponse(null,{status:400});}
 else if(lat===null||lon===null||!Number.isFinite(Number(lat))||!Number.isFinite(Number(lon))||Math.abs(Number(lat))>90||Math.abs(Number(lon))>180)return new NextResponse(null,{status:400});
 const results=await geocode({query:search,latitude:lat===null?null:Number(lat),longitude:lon===null?null:Number(lon),language:q.get('locale')==='de'?'de':'sl'});
 if(results===null)return new NextResponse(null,{status:503});
 return NextResponse.json(results,{headers:{'Cache-Control':'private, no-store'}});
 }catch{return new NextResponse(null,{status:502});}
}
