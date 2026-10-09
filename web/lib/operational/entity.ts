import type {Locale} from '../i18n';
export const entityTypes=['HYDRANT','PLAN','INCIDENT','INCIDENT_SECTOR','INCIDENT_MAP_OBJECT','INCIDENT_UNIT','OPERATIONAL_UNIT','OPERATIONAL_VEHICLE','TEAM','ORGANIZATION','ALLOCATION'] as const;
export type EntityType=typeof entityTypes[number];
export type EntityRef={type:EntityType;id:string;context?:{organizationId?:string;incidentId?:string}};
export const isUuid=(v:unknown):v is string=>typeof v==='string'&&/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(v);
export function parseEntityRef(value:unknown,context:EntityRef['context']={}):EntityRef|null{
 if(typeof value!=='string'||value.length>100)return null;
 const [type,id,...extra]=value.split(':');
 if(extra.length||!entityTypes.includes(type as EntityType)||!isUuid(id))return null;
 if(!context||typeof context!=='object'||Array.isArray(context)||Object.keys(context).some(k=>!['organizationId','incidentId'].includes(k))||Object.values(context).some(v=>v!==undefined&&!isUuid(v)))return null;
 if(context.incidentId&&!['HYDRANT','INCIDENT_SECTOR','INCIDENT_MAP_OBJECT','INCIDENT_UNIT','ALLOCATION'].includes(type))return null;
 if(['TEAM','OPERATIONAL_UNIT','OPERATIONAL_VEHICLE'].includes(type)&&!context.organizationId)return null;
 if(['INCIDENT_SECTOR','INCIDENT_MAP_OBJECT','INCIDENT_UNIT','ALLOCATION'].includes(type)&&!context.incidentId)return null;
 return {type:type as EntityType,id:id.toLowerCase(),context};
}
export function entityHref(locale:Locale,ref:EntityRef):string|null{
 const r=parseEntityRef(ref.type+':'+ref.id,ref.context);if(!r)return null;
 const org=r.context?.organizationId,incident=r.context?.incidentId;
 const query=new URLSearchParams(org?{org}:{});
 if(r.type==='HYDRANT'&&!incident)return '/'+locale+'/hydrants/'+r.id+'?'+query;
 if(r.type==='PLAN')return '/'+locale+'/plans/'+r.id+'?'+query;
 if(r.type==='INCIDENT')return '/'+locale+'/incidents/'+r.id+'?'+query;
 if(incident){query.set('selected',r.type+':'+r.id);return '/'+locale+'/incidents/'+incident+'?'+query;}
 if(r.type==='ORGANIZATION')return '/'+locale+'/admin/org/'+r.id;
 if(!org)return null;
 if(r.type==='TEAM')return '/'+locale+'/admin/org/'+org+'/teams?team='+r.id;
 return '/'+locale+'/admin/org/'+org+'/inventory?entity='+encodeURIComponent(r.type+':'+r.id);
}
const labels:Record<EntityType,[string,string]>={HYDRANT:['Hidrant','Hydrant'],PLAN:['Načrt','Plan'],INCIDENT:['Intervencija','Einsatz'],INCIDENT_SECTOR:['Sektor','Abschnitt'],INCIDENT_MAP_OBJECT:['Objekt na karti','Kartenobjekt'],INCIDENT_UNIT:['Intervencijska enota','Einsatzeinheit'],OPERATIONAL_UNIT:['Enota','Einheit'],OPERATIONAL_VEHICLE:['Vozilo','Fahrzeug'],TEAM:['Ekipa','Team'],ORGANIZATION:['Organizacija','Organisation'],ALLOCATION:['Dodelitev sredstva','Ressourcenzuweisung']};
export const entityLabel=(locale:Locale,ref:EntityRef)=>labels[ref.type][locale==='de'?1:0];
