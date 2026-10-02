import 'server-only';
export type Suggestion={label:string;latitude:number;longitude:number};
export type GeocodingQuery={query:string|null;latitude:number|null;longitude:number|null;language:'sl'|'de'};
// Deployment chooses the endpoint and protocol. There is no default public or
// paid service; credentials and upstream URLs remain server-only.
export async function geocode(input:GeocodingQuery):Promise<Suggestion[]|null>{
 const endpoint=process.env.GEOCODING_ADAPTER_URL;if(!endpoint)return null;
 const url=new URL(endpoint);if(url.protocol!=='https:')return null;
 const protocol=process.env.GEOCODING_ADAPTER_PROTOCOL??'normalized';
 if(!['normalized','nominatim'].includes(protocol))return null;
 const headers:Record<string,string>={Accept:'application/json'};
 if(process.env.GEOCODING_ADAPTER_TOKEN)headers.Authorization='Bearer '+process.env.GEOCODING_ADAPTER_TOKEN;
 if(process.env.GEOCODING_USER_AGENT)headers['User-Agent']=process.env.GEOCODING_USER_AGENT;
 let body:string|undefined;
 if(protocol==='nominatim'){
 url.pathname=url.pathname.replace(/\/$/,'')+(input.query?'/search':'/reverse');
 url.searchParams.set('format','jsonv2');url.searchParams.set('accept-language',input.language);
 if(input.query){url.searchParams.set('q',input.query);url.searchParams.set('limit','5');}
 else{url.searchParams.set('lat',String(input.latitude));url.searchParams.set('lon',String(input.longitude));}
 }else{headers['Content-Type']='application/json';body=JSON.stringify({...input,limit:5});}
 const r=await fetch(url,{method:body?'POST':'GET',body,headers,redirect:'error',cache:'no-store',signal:AbortSignal.timeout(5000)});
 if(!r.ok||!r.body)throw Error('GEOCODING_UNAVAILABLE');
 const reader=r.body.getReader();const chunks:Uint8Array[]=[];let size=0;
 try{for(;;){const part=await reader.read();if(part.done)break;size+=part.value.byteLength;if(size>65536)throw Error('GEOCODING_RESPONSE_TOO_LARGE');chunks.push(part.value);}}
 finally{await reader.cancel();reader.releaseLock();}
 const bytes=new Uint8Array(size);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.byteLength;}
 let payload:unknown=JSON.parse(new TextDecoder().decode(bytes));
 if(protocol==='nominatim'){
 const values=Array.isArray(payload)?payload:[payload];payload=values.map((v:unknown)=>{const p=v as Record<string,unknown>|null;return {label:p?.display_name,latitude:Number(p?.lat),longitude:Number(p?.lon)};});
 }
 if(!Array.isArray(payload)||payload.length>5)throw Error('GEOCODING_INVALID_RESPONSE');
 return payload.filter((v:unknown):v is Suggestion=>{if(!v||typeof v!=='object')return false;const s=v as Record<string,unknown>;
 return typeof s.label==='string'&&s.label.length<=500&&typeof s.latitude==='number'&&Number.isFinite(s.latitude)&&Math.abs(s.latitude)<=90&&typeof s.longitude==='number'&&Number.isFinite(s.longitude)&&Math.abs(s.longitude)<=180;});
}
