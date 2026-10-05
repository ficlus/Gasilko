// Auth administration is confined to this trusted function. Never log Auth responses.
Deno.serve(async (request: Request) => {
 const reply = (error?: string, status = 200) => Response.json(error ? {error} : {acknowledged:true}, {status, headers:{'Cache-Control':'no-store'}});
 if (request.method !== 'POST') return reply('VALIDATION',405);
 const authorization=request.headers.get('authorization')??'';
 if (!authorization.startsWith('Bearer ')) return reply('EXPIRED',401);
 const url=Deno.env.get('SUPABASE_URL'),key=Deno.env.get('SUPABASE_ANON_KEY'),secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),redirect=Deno.env.get('WEB_INVITATION_REDIRECT_URL');
 if (!url||!key||!secret||!redirect) return reply('INVITE_CONFIGURATION',503);
 try {
  const callback=new URL(redirect);
  if(callback.pathname!=='/auth/callback'||callback.search||callback.hash||(callback.protocol!=='https:'&&callback.hostname!=='localhost')) return reply('INVITE_CONFIGURATION',503);
  const raw=await request.text();if(raw.length>1024)return reply('VALIDATION',400);
  const body=JSON.parse(raw);
  if(typeof body.invitation!=='string'||!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(body.invitation))return reply('VALIDATION',400);
  const headers={apikey:key,Authorization:authorization,'Content-Type':'application/json'};
  const user=await fetch(url+'/auth/v1/user',{headers,signal:AbortSignal.timeout(15000)});
  if(!user.ok)return reply('EXPIRED',401);
  const authorize=()=>fetch(url+'/rest/v1/rpc/web_invitation_delivery',{method:'POST',headers,body:JSON.stringify({invitation:body.invitation}),signal:AbortSignal.timeout(15000)});
  const permission=await authorize();if(!permission.ok)return reply('FORBIDDEN',403);
  let target=await permission.json() as {email:string;existing:boolean};
  callback.searchParams.set('locale',body.locale==='de'?'de':'sl');
  const sendExisting=()=>fetch(url+'/auth/v1/otp?redirect_to='+encodeURIComponent(callback.toString()),{
   method:'POST',headers:{apikey:key,'Content-Type':'application/json'},body:JSON.stringify({email:target.email,create_user:false}),signal:AbortSignal.timeout(20000)});
  let sent:Response;
  if(target.existing)sent=await sendExisting();
  else {
   sent=await fetch(url+'/auth/v1/invite?redirect_to='+encodeURIComponent(callback.toString()),{method:'POST',
    headers:{apikey:secret,Authorization:'Bearer '+secret,'Content-Type':'application/json'},body:JSON.stringify({email:target.email}),signal:AbortSignal.timeout(20000)});
   // A concurrent signup must not strand the organization invitation.
   if(!sent.ok){const again=await authorize();if(!again.ok)return reply('FORBIDDEN',403);target=await again.json();if(target.existing)sent=await sendExisting();}
  }
  if(!sent.ok)return reply('INVITE_DELIVERY',502);
  return reply();
 }catch{return reply('INVITE_DELIVERY',502);}
});
