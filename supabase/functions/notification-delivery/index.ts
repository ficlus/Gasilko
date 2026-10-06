// Trusted scheduled dispatch only. No arbitrary recipients/content accepted from callers.
const encoder = new TextEncoder();
const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
const json64 = (value: unknown) => b64(encoder.encode(JSON.stringify(value)));
async function request(url: string, init: RequestInit) {
  return await fetch(url,{...init,signal:AbortSignal.timeout(15000)});
}
async function accessToken() {
  const config=JSON.parse(Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON') ?? '{}');
  if(!config.project_id || !config.client_email || !config.private_key)throw new Error('CONFIGURATION');
  const now=Math.floor(Date.now()/1000);
  const value=json64({alg:'RS256',typ:'JWT'})+'.'+json64({iss:config.client_email,
    scope:'https://www.googleapis.com/auth/firebase.messaging',aud:'https://oauth2.googleapis.com/token',iat:now,exp:now+3600});
  const pem=String(config.private_key).replace(/-----[^-]+-----/g,'').replace(/\s/g,'');
  const key=await crypto.subtle.importKey('pkcs8',Uint8Array.from(atob(pem),c=>c.charCodeAt(0)),
    {name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['sign']);
  const signature=await crypto.subtle.sign('RSASSA-PKCS1-v1_5',key,encoder.encode(value));
  const response=await request('https://oauth2.googleapis.com/token',{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},
    body:new URLSearchParams({grant_type:'urn:ietf:params:oauth:grant-type:jwt-bearer',assertion:value+'.'+b64(new Uint8Array(signature))})});
  if(!response.ok)throw new Error('PROVIDER_AUTH');
  const token=await response.json();if(!token.access_token)throw new Error('PROVIDER_AUTH');
  return {project:config.project_id,token:String(token.access_token)};
}
async function rpc(name: string, body: unknown) {
  const key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const response=await request(Deno.env.get('SUPABASE_URL')+'/rest/v1/rpc/'+name,{method:'POST',
    headers:{apikey:key,Authorization:'Bearer '+key,'content-type':'application/json'},body:JSON.stringify(body)});
  if(!response.ok)throw new Error('DATABASE');
  const text=await response.text();return text?JSON.parse(text):null;
}
Deno.serve(async req=>{
  const secret=Deno.env.get('NOTIFICATION_DISPATCH_SECRET');
  // Deployment must disable platform JWT verification for this function only; this header is mandatory.
  if(req.method!=='POST' || !secret || req.headers.get('x-dispatch-secret')!==secret)return new Response(null,{status:401});
  try {
    const auth=await accessToken(); // Configuration failure does not consume delivery attempts.
    const rows=await rpc('claim_notification_deliveries',{});
    for(let index=0;index<rows.length;index+=5)await Promise.all(rows.slice(index,index+5).map(async (row: Record<string,string>)=>{
      let outcome='RETRY',provider: string|null=null;
      try {
        const data=Object.fromEntries(['account','event','type','category','entity_type','entity','organization'].map(k=>[k,row[k]]));
        const response=await request(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(auth.project)}/messages:send`,{
          method:'POST',headers:{Authorization:'Bearer '+auth.token,'content-type':'application/json'},
          body:JSON.stringify({message:{token:row.token,data,android:{priority:'HIGH',ttl:'86400s'}}})});
        const result=await response.json();
        if(response.ok) { outcome='ACCEPTED';provider=typeof result.name==='string'?result.name:null; }
        else {
          const invalid=result.error?.details?.some((d: Record<string,string>)=>d['@type']==='type.googleapis.com/google.firebase.fcm.v1.FcmError' &&
            (d.errorCode==='UNREGISTERED' || (d.errorCode==='INVALID_ARGUMENT' && /registration token.*(?:not a valid|invalid)/i.test(result.error?.message ?? ''))));
          outcome=invalid?'INVALID_TOKEN':(response.status===429 || response.status>=500 || response.status===401?'RETRY':'FAILED');
        }
      } catch { /* No provider body, key, token or personal data in logs. Leased retry is bounded. */ }
      await rpc('finish_notification_delivery',{delivery:row.id,claim:row.lease,outcome,provider});
    }));
    return Response.json({processed:rows.length});
  } catch { return Response.json({error:'DISPATCH_UNAVAILABLE'},{status:503}); }
});
