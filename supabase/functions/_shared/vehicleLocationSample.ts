/** Distinct20-field GPS sample domain. No JSON signing, history or consent. */
import {verifyP256BytesV1} from "./deviceProofV1.ts";
export const SAMPLE_KEYS=["sampleId","sessionId","account","organization","incident","deployment","vehicle","credentialId",
 "generation","policyVersion","bindingGeneration","sequence","observedAtMillis","latitudeE7","longitudeE7","accuracyCm","source","sessionContext"] as const;
export type LocationSample=Record<typeof SAMPLE_KEYS[number],string>;
const uuid=/^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export function encodeLocationSample(value:unknown):Uint8Array {
 if(!value||typeof value!=="object"||Array.isArray(value))throw Error("INVALID_LOCATION");
 const x=value as Record<string,unknown>;
 if(Object.keys(x).length!==SAMPLE_KEYS.length||SAMPLE_KEYS.some(k=>typeof x[k]!=="string"))throw Error("INVALID_LOCATION");
 const s=x as LocationSample;
 for(const k of SAMPLE_KEYS.slice(0,8))if(!uuid.test(s[k]))throw Error("INVALID_LOCATION");
 for(const k of ["generation","bindingGeneration","sequence","observedAtMillis"] as const)
  if(!/^[1-9][0-9]{0,18}$/.test(s[k])||BigInt(s[k])>9223372036854775807n)throw Error("INVALID_LOCATION");
 for(const [k,max] of [["latitudeE7",900000000n],["longitudeE7",1800000000n]] as const)
  if(!/^(0|-?[1-9][0-9]*)$/.test(s[k])||BigInt(s[k]) < -max||BigInt(s[k])>max)throw Error("INVALID_LOCATION");
 if(!/^[1-9][0-9]{0,4}$/.test(s.accuracyCm)||BigInt(s.accuracyCm)>10000n||
  !/^[A-Za-z0-9._-]{1,64}$/.test(s.policyVersion)||s.source!=="ANDROID_REAL_GNSS"||
  !/^[A-Za-z0-9_-]{43}$/.test(s.sessionContext))throw Error("INVALID_LOCATION");
 return new TextEncoder().encode(["GASILKO-REAL-VEHICLE-LOCATION-SAMPLE-V1","1",
  ...SAMPLE_KEYS.map(k=>s[k])].join("\n")+"\n");
}
export async function verifyLocationSample(sample:unknown,spki:Uint8Array,signature:Uint8Array) {
 const bytes=encodeLocationSample(sample);
 await verifyP256BytesV1({spki,signature,transcript:bytes});
 return sha256(bytes);
}
export async function sha256(bytes:Uint8Array) {
 return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes.slice().buffer as ArrayBuffer)),x=>x.toString(16).padStart(2,"0")).join("");
}
export function unhex(value:string,length:number):Uint8Array {
 if(value.length!==length*2||!/^[0-9a-f]+$/.test(value))throw Error("INVALID_ENCODING");
 return Uint8Array.from(value.match(/../g)!,x=>parseInt(x,16));
}

export async function requireSampleIdentity(sample:LocationSample) {
 const bytes=new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(
  "GASILKO-REAL-VEHICLE-SAMPLE-ID-V1\n"+sample.sessionId+"\n"+sample.sequence+"\n")));
 bytes[6]=(bytes[6]&15)|128;bytes[8]=(bytes[8]&63)|128;
 const h=Array.from(bytes.slice(0,16),b=>b.toString(16).padStart(2,"0")).join("");
 const id=h.slice(0,8)+"-"+h.slice(8,12)+"-"+h.slice(12,16)+"-"+h.slice(16,20)+"-"+h.slice(20);
 if(sample.sampleId!==id)throw Error("INVALID_LOCATION");
}
